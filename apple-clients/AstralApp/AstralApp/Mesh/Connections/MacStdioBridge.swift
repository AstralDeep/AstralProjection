// Serves one stdio MCP server on a loopback HTTP endpoint with Network.framework: it checks the bearer, writes each JSON-RPC message to the server and answers with the reply that carries the same id.
// MacStdioLauncher starts one per server and hands its address and bearer to the Kernel, which is the only caller that knows the bearer.

#if os(macOS)
    import CryptoKit
    import Foundation
    import Network

    nonisolated protocol MacStdioChannel: AnyObject, Sendable {
        func send(_ line: Data) -> Bool
    }

    nonisolated final class MacStdioBridge: @unchecked Sendable {
        static let bodyLimit = 4 * 1024 * 1024
        static let headLimit = 16 * 1024
        static let path = "/mcp"

        private let bearer: String
        private let channel: any MacStdioChannel
        private let replyTimeout: TimeInterval
        private let queue = DispatchQueue(label: "com.personalailabs.astraldeep.stdio-bridge")
        private let lock = NSLock()
        private var listener: NWListener?
        private var pending: [String: NWConnection] = [:]
        private var open: [ObjectIdentifier: NWConnection] = [:]
        private var stopped = false

        init(bearer: String, channel: any MacStdioChannel, replyTimeout: TimeInterval = 120) {
            self.bearer = bearer
            self.channel = channel
            self.replyTimeout = replyTimeout
        }

        func start() throws -> UInt16 {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let made = try NWListener(using: parameters)
            let gate = DispatchSemaphore(value: 0)
            let box = PortBox()
            made.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.port = made.port?.rawValue
                    gate.signal()
                case .failed, .cancelled:
                    gate.signal()
                default: break
                }
            }
            made.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            made.start(queue: queue)
            _ = gate.wait(timeout: .now() + 5)
            guard let port = box.port, port != 0 else {
                made.cancel()
                throw MacStdioBridgeError.listenFailed
            }
            lock.withLock { listener = made }
            return port
        }

        func stop() {
            let (held, waiting) = lock.withLock { () -> ([NWConnection], [NWConnection]) in
                stopped = true
                let all = (Array(open.values), Array(pending.values))
                open = [:]
                pending = [:]
                listener?.cancel()
                listener = nil
                return all
            }
            for connection in held + waiting { connection.cancel() }
        }

        func receive(line: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["method"] == nil, let key = Self.key(object["id"])
            else { return }
            guard let connection = lock.withLock({ pending.removeValue(forKey: key) }) else { return }
            Self.reply(connection, status: "200 OK", body: line)
        }

        private func accept(_ connection: NWConnection) {
            let refused: Bool = lock.withLock {
                if stopped { return true }
                open[ObjectIdentifier(connection)] = connection
                return false
            }
            if refused {
                connection.cancel()
                return
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard case .cancelled = state else { return }
                self?.lock.withLock { _ = self?.open.removeValue(forKey: ObjectIdentifier(connection)) }
            }
            connection.start(queue: queue)
            readHead(connection, buffer: Data())
        }

        private func readHead(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                var next = buffer
                if let data { next.append(data) }
                if let end = next.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: next[next.startIndex..<end.lowerBound], as: UTF8.self)
                    handle(connection, head: head, body: Data(next[end.upperBound...]))
                } else if error != nil || done || next.count > Self.headLimit {
                    Self.reply(connection, status: "400 Bad Request", body: Data())
                } else {
                    readHead(connection, buffer: next)
                }
            }
        }

        private func handle(_ connection: NWConnection, head: String, body: Data) {
            let lines = head.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ").map(String.init)
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[line[..<colon].lowercased()] = value
            }
            guard Self.authorized(headers["authorization"], bearer: bearer) else {
                return Self.reply(connection, status: "401 Unauthorized", body: Data())
            }
            guard first.count >= 2, first[0] == "POST", first[1] == Self.path else {
                let status = first.first == "POST" ? "404 Not Found" : "405 Method Not Allowed"
                return Self.reply(connection, status: status, body: Data())
            }
            let declared: Int? = headers["content-length"].flatMap { Int($0) }
            guard let length = declared, length > 0, length <= Self.bodyLimit else {
                return Self.reply(connection, status: "400 Bad Request", body: Data())
            }
            readBody(connection, body: body, length: length)
        }

        private func readBody(_ connection: NWConnection, body: Data, length: Int) {
            if body.count >= length { return dispatch(connection, message: Data(body.prefix(length))) }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                var next = body
                if let data { next.append(data) }
                if next.count >= length || error != nil || done {
                    if next.count >= length { return dispatch(connection, message: Data(next.prefix(length))) }
                    return Self.reply(connection, status: "400 Bad Request", body: Data())
                }
                readBody(connection, body: next, length: length)
            }
        }

        private func dispatch(_ connection: NWConnection, message: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                object["jsonrpc"] as? String == "2.0"
            else { return Self.reply(connection, status: "400 Bad Request", body: Data()) }
            let compact = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? message
            guard object["method"] != nil, let key = Self.key(object["id"]) else {
                guard channel.send(compact) else {
                    return Self.reply(connection, status: "502 Bad Gateway", body: Data())
                }
                return Self.reply(connection, status: "202 Accepted", body: Data())
            }
            let registered: Bool = lock.withLock {
                guard !stopped, pending[key] == nil else { return false }
                pending[key] = connection
                return true
            }
            guard registered else { return Self.reply(connection, status: "409 Conflict", body: Data()) }
            guard channel.send(compact) else {
                lock.withLock { _ = pending.removeValue(forKey: key) }
                return Self.reply(connection, status: "502 Bad Gateway", body: Data())
            }
            queue.asyncAfter(deadline: .now() + replyTimeout) { [weak self] in
                guard let late = self?.lock.withLock({ self?.pending.removeValue(forKey: key) }) else { return }
                Self.reply(late, status: "504 Gateway Timeout", body: Data())
            }
        }

        static func authorized(_ header: String?, bearer: String) -> Bool {
            guard let header, !bearer.isEmpty else { return false }
            let expected = SHA256.hash(data: Data(("Bearer " + bearer).utf8))
            let given = SHA256.hash(data: Data(header.utf8))
            return zip(expected, given).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        }

        static func key(_ id: Any?) -> String? {
            switch id {
            case let text as String: return "s:" + text
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                return "n:" + number.stringValue
            default: return nil
            }
        }

        private static func reply(_ connection: NWConnection, status: String, body: Data) {
            let type = body.isEmpty ? "" : "Content-Type: application/json\r\n"
            let head = "HTTP/1.1 \(status)\r\n\(type)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data(head.utf8) + body,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private final class PortBox: @unchecked Sendable {
        var port: UInt16?
    }

    enum MacStdioBridgeError: Error { case listenFailed }
#endif
