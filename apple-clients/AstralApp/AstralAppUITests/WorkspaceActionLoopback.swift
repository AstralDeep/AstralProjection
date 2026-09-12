import CryptoKit
import Foundation
import Network
import XCTest

/// A bounded HTTP peer owned by one UI test, never by the product. The native
/// app exercises its normal URLSession, authorization, export and share paths.
final class WorkspaceActionLoopback: @unchecked Sendable {
    enum Route: Hashable { case authorization, presentation, share, componentCSV }
    struct Reply {
        var status = 200
        var error: String? = nil
        var held = false
    }
    struct Request {
        let route: Route
        let method: String
        let path: String
        let authorization: String
        let body: Data
    }

    static let chat = "11111111-1111-4111-8111-111111111111"
    static let token =
        "fixture."
        + Data(#"{"iss":"https://issuer.invalid","sub":"workspace-ui-fixture","name":"Workspace UI Fixture"}"#.utf8)
        .base64EncodedString() + ".fixture"
    let ready = XCTestExpectation(description: "workspace action loopback ready")
    let listener: NWListener
    private let queue = DispatchQueue(label: "astral.workspace-actions.ui-loopback")
    private var replies: [Route: [Reply]]
    private var observations: [Request] = []
    private var unexpected: [String] = []
    private var previewPaths: [String] = []
    private var connections: [NWConnection] = []
    private var pending: [(NWConnection, Data)] = []
    private let supportsWebSocket: Bool
    private var componentWire: [Data] = []
    private var registrationCount = 0
    private var socketConnections: [NWConnection] = []
    private var socketPaused = false

    init(replies: [Route: [Reply]], supportsWebSocket: Bool = false) throws {
        self.replies = replies
        self.supportsWebSocket = supportsWebSocket
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    var requests: [Request] { queue.sync { observations } }
    var unexpectedRequests: [String] { queue.sync { unexpected } }
    var nativePreviewRequests: [String] { queue.sync { previewPaths } }
    var port: UInt16? { listener.port?.rawValue }
    var componentFrames: [Data] { queue.sync { componentWire } }
    var registrations: Int { queue.sync { registrationCount } }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            guard self.connections.count < 16 else {
                connection.cancel()
                return
            }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    func releaseHeldReplies() {
        queue.sync {
            let held = pending
            pending.removeAll()
            for (connection, response) in held { send(response, on: connection) }
        }
    }

    func refuseLastComponent() {
        queue.sync {
            guard let data = componentWire.last,
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let submission = event["submission_id"] as? String, let connection = socketConnections.last,
                let response = try? JSONSerialization.data(withJSONObject: [
                    "type": "error", "submission_id": submission, "accepted": false,
                    "code": "capacity_exceeded", "message": "Synthetic capacity refusal",
                    "retryable": true, "retry_after_ms": NSNull(),
                ])
            else {
                unexpected.append("Missing component request for refusal")
                return
            }
            sendSocket(response, on: connection)
        }
    }

    func pauseSocketConnections() {
        queue.sync {
            socketPaused = true
            for connection in socketConnections { connection.cancel() }
            socketConnections.removeAll()
        }
    }

    func resumeSocketConnections() { queue.sync { socketPaused = false } }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
            pending.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, done, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var data = accumulated
            data.append(bytes ?? Data())
            guard data.count <= 8 * 1024 * 1024 + 65536 else {
                connection.cancel()
                return
            }
            if let boundary = data.range(of: Data("\r\n\r\n".utf8)) {
                guard boundary.lowerBound < 65536 else {
                    connection.cancel()
                    return
                }
                let lines = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
                    .components(separatedBy: "\r\n")
                let headers = Dictionary(
                    lines.dropFirst().compactMap { line -> (String, String)? in
                        guard let colon = line.firstIndex(of: ":") else { return nil }
                        return (
                            line[..<colon].lowercased(),
                            line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        )
                    }, uniquingKeysWith: { first, _ in first })
                guard let length = Int(headers["content-length"] ?? "0"), (0...8 * 1024 * 1024).contains(length) else {
                    connection.cancel()
                    return
                }
                if data.count >= boundary.upperBound + length {
                    self.respond(
                        connection, firstLine: lines[0], headers: headers,
                        body: data.subdata(in: boundary.upperBound..<(boundary.upperBound + length)))
                    return
                }
            }
            if done { connection.cancel() } else { self.receive(connection, accumulated: data) }
        }
    }

    private func respond(_ connection: NWConnection, firstLine: String, headers: [String: String], body: Data) {
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3 else {
            connection.cancel()
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        // Normal bootstrap may attempt its control socket. This fixture does
        // not pretend that the HTTP peer is a live authenticated backend.
        if method == "GET", path == "/ws", headers["upgrade"]?.lowercased() == "websocket" {
            if supportsWebSocket {
                upgradeSocket(connection, headers: headers)
                return
            }
            send(response(status: 426, body: Data()), on: connection)
            return
        }
        // After an explicit native ShareLink tap, iOS may fetch public URL
        // preview metadata. Record this closed loopback-only set and return 404;
        // it never supplies credentials, fake content, or a successful share.
        if supportsWebSocket, method == "GET",
            [
                "/apple-touch-icon-precomposed.png", "/apple-touch-icon.png", "/favicon.ico",
                "/share/synthetic_workspace_ui_link",
            ].contains(path)
        {
            guard previewPaths.count < 8, (headers["authorization"] ?? "").isEmpty else {
                unexpected.append("Invalid native preview request")
                connection.cancel()
                return
            }
            previewPaths.append(path)
            send(response(status: 404, body: Data()), on: connection)
            return
        }
        let route: Route
        switch (method, path) {
        case ("GET", "/api/export/canvas/\(Self.chat).html?render_revision=0"): route = .authorization
        case ("POST", "/api/export/canvas/\(Self.chat)/presentation?render_revision=0"): route = .presentation
        case ("POST", "/api/share"): route = .share
        case ("GET", "/api/export/component/component-table.csv?chat_id=\(Self.chat)"): route = .componentCSV
        default:
            unexpected.append("\(method) \(path)")
            send(response(status: 404, body: Data()), on: connection)
            return
        }
        observations.append(
            Request(
                route: route, method: method, path: path,
                authorization: headers["authorization"] ?? "", body: body))
        guard headers["authorization"] == "Bearer \(Self.token)", var choices = replies[route], !choices.isEmpty else {
            unexpected.append("Unexpected authorization or repeated \(route)")
            send(response(status: 403, body: Data()), on: connection)
            return
        }
        let reply = choices.removeFirst()
        replies[route] = choices
        let data: Data
        if let error = reply.error {
            data =
                (try? JSONSerialization.data(withJSONObject: ["error": error, "detail": "PRIVATE_SERVER_DETAIL"]))
                ?? Data()
        } else if route == .authorization {
            data = Data("AUTHORIZATION_ONLY_HTML".utf8)
        } else if route == .componentCSV {
            data = Data("Label,Value\nAlpha,2\n".utf8)
        } else if route == .share {
            data = Data(#"{"share_url":"/share/synthetic_workspace_ui_link"}"#.utf8)
        } else if let capture = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let viewport = capture["viewport"], let theme = capture["theme"]
        {
            data =
                (try? JSONSerialization.data(withJSONObject: [
                    "version": "astral.canvas-export/v1", "viewport": viewport, "theme": theme,
                    "html": "<div class=\"dynamic-renderer\"><p>Visible workspace action result</p></div>",
                ])) ?? Data()
        } else {
            unexpected.append("Invalid presentation capture")
            data = Data()
        }
        let bytes = response(status: reply.status, body: data)
        if reply.held { pending.append((connection, bytes)) } else { send(bytes, on: connection) }
    }

    private func response(status: Int, body: Data) -> Data {
        let header =
            "HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nX-Astral-Render-Revision: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private final class SocketState {
        var registered = false
        var frames = 0
    }

    /// Test-owned RFC6455 text transport: masked, final frames only, bounded to
    /// 64KiB/32 frames/120 seconds. It records dispatch, never restores a canvas.
    private func upgradeSocket(_ connection: NWConnection, headers: [String: String]) {
        guard !socketPaused else {
            send(response(status: 426, body: Data()), on: connection)
            return
        }
        guard headers["sec-websocket-version"] == "13", let key = headers["sec-websocket-key"],
            Data(base64Encoded: key)?.count == 16
        else {
            connection.cancel()
            return
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let bytes = Data(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                .utf8)
        socketConnections.append(connection)
        connection.send(
            content: bytes,
            completion: .contentProcessed { [weak self] error in
                guard error == nil else {
                    connection.cancel()
                    return
                }
                self?.receiveSocket(connection, state: SocketState(), accumulated: Data())
            })
        queue.asyncAfter(deadline: .now() + 120) { [weak connection] in connection?.cancel() }
    }

    private func receiveSocket(_ connection: NWConnection, state: SocketState, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, done, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var data = accumulated
            data.append(bytes ?? Data())
            guard data.count <= 2 * 65536 + 28 else {
                connection.cancel()
                return
            }
            while data.count >= 2 {
                let frame = [UInt8](data)
                guard frame[0] & 0xF0 == 0x80, frame[1] & 0x80 != 0 else {
                    connection.cancel()
                    return
                }
                let opcode = frame[0] & 0x0F
                var size = Int(frame[1] & 0x7F)
                var offset = 2
                if size == 126 {
                    guard frame.count >= 4 else { break }
                    size = Int(frame[2]) * 256 + Int(frame[3])
                    offset = 4
                } else if size == 127 {
                    guard frame.count >= 10 else { break }
                    guard frame[2..<8].allSatisfy({ $0 == 0 }) else {
                        connection.cancel()
                        return
                    }
                    size = Int(frame[8]) * 256 + Int(frame[9])
                    offset = 10
                }
                guard size <= 65536 else {
                    connection.cancel()
                    return
                }
                guard frame.count >= offset + 4 + size else { break }
                let mask = Array(frame[offset..<(offset + 4)])
                offset += 4
                let payload = Data((0..<size).map { frame[offset + $0] ^ mask[$0 % 4] })
                data.removeFirst(offset + size)
                state.frames += 1
                guard state.frames <= 32 else {
                    connection.cancel()
                    return
                }
                if opcode == 8 {
                    connection.cancel()
                    return
                }
                if opcode == 9, size <= 125 {
                    sendSocket(payload, opcode: 10, on: connection)
                    continue
                }
                guard opcode == 1, let text = String(data: payload, encoding: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                else {
                    connection.cancel()
                    return
                }
                if !state.registered {
                    guard object["type"] as? String == "register_ui", object["token"] as? String == Self.token else {
                        unexpected.append("Invalid fixture registration")
                        connection.cancel()
                        return
                    }
                    state.registered = true
                    registrationCount += 1
                    sendSocket(Data(#"{"type":"pong"}"#.utf8), on: connection)
                } else if object["type"] as? String == "ui_event", let action = object["action"] as? String {
                    if ["component_refine", "component_restore"].contains(action) {
                        componentWire.append(payload)
                    } else if !["get_history", "discover_agents", "update_device", "new_chat", "load_chat"].contains(
                        action)
                    {
                        unexpected.append("Unexpected fixture socket action")
                    }
                } else {
                    unexpected.append("Unexpected fixture socket frame")
                }
            }
            if done { connection.cancel() } else { receiveSocket(connection, state: state, accumulated: data) }
        }
    }

    private func sendSocket(_ payload: Data, opcode: UInt8 = 1, on connection: NWConnection) {
        guard payload.count <= 65535 else {
            connection.cancel()
            return
        }
        var frame = Data([0x80 | opcode])
        if payload.count <= 125 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        }
        frame.append(payload)
        connection.send(
            content: frame, completion: .contentProcessed { error in if error != nil { connection.cancel() } })
    }
}
