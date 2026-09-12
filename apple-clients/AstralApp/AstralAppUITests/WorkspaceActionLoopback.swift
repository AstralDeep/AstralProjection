import Foundation
import Network
import XCTest

/// A bounded HTTP peer owned by one UI test, never by the product. The native
/// app exercises its normal URLSession, authorization, export and share paths.
final class WorkspaceActionLoopback: @unchecked Sendable {
    enum Route: Hashable { case authorization, presentation, share }
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
    private var connections: [NWConnection] = []
    private var pending: [(NWConnection, Data)] = []

    init(replies: [Route: [Reply]]) throws {
        self.replies = replies
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    var requests: [Request] { queue.sync { observations } }
    var unexpectedRequests: [String] { queue.sync { unexpected } }
    var port: UInt16? { listener.port?.rawValue }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
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
            send(response(status: 426, body: Data()), on: connection)
            return
        }
        let route: Route
        switch (method, path) {
        case ("GET", "/api/export/canvas/\(Self.chat).html?render_revision=0"): route = .authorization
        case ("POST", "/api/export/canvas/\(Self.chat)/presentation?render_revision=0"): route = .presentation
        case ("POST", "/api/share"): route = .share
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
}
