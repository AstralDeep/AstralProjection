// Runs one job's host-side loopback egress proxy on Network.framework: it applies the job's domain list and
// destination classification to every CONNECT or absolute-form request, swaps bound placeholder tokens for
// Keychain secrets on allowed upstreams, and reports every decision without ever recording bodies.

#if os(macOS)
    import AstralCore
    import Darwin
    import Foundation
    import Network

    nonisolated final class MacComputerEgressProxy: MacComputerEgressProxying, @unchecked Sendable {
        private let request: MacComputerEgressProxyRequest
        private let queue: DispatchQueue
        private let listener: NWListener
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var tracked: [ObjectIdentifier: NWConnection] = [:]
        private var ready = false
        private var failure: String?
        private var bound: UInt16 = 0
        private var stopped = false

        init(request: MacComputerEgressProxyRequest) throws {
            self.request = request
            queue = DispatchQueue(label: "com.personalailabs.astraldeep.egress." + request.jobId)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            do {
                listener = try NWListener(using: parameters)
            } catch {
                throw ComputerHostError(
                    "sandbox_refused", "The command egress proxy listener could not be created.")
            }
        }

        var port: UInt16 { lock.withLock { bound } }

        func start() throws {
            lock.withLock {
                ready = false
                failure = nil
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.withLock {
                        self.bound = self.listener.port?.rawValue ?? 0
                        self.ready = true
                    }
                    self.gate.signal()
                case .failed(let error):
                    self.lock.withLock {
                        self.failure = String(describing: error)
                    }
                    self.gate.signal()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            _ = gate.wait(timeout: .now() + 5)
            let (ready, failure, bound) = lock.withLock { (self.ready, self.failure, self.bound) }
            guard ready, failure == nil, bound != 0 else {
                stop()
                throw ComputerHostError(
                    "sandbox_refused", "The command egress proxy did not start\(failure.map { ": \($0)" } ?? ".").")
            }
        }

        func stop() {
            let open: [NWConnection] = lock.withLock {
                guard !stopped else { return [] }
                stopped = true
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
                let all = Array(tracked.values)
                tracked.removeAll()
                return all
            }
            for connection in open { connection.cancel() }
        }

        private func accept(_ connection: NWConnection) {
            lock.withLock {
                if stopped {
                    connection.cancel()
                    return
                }
                tracked[ObjectIdentifier(connection)] = connection
            }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let connection else { return }
                switch state {
                case .ready: self?.readHead(connection, buffer: Data())
                case .failed, .cancelled: self?.untrack(connection)
                default: break
                }
            }
            connection.start(queue: queue)
        }

        private func untrack(_ connection: NWConnection) {
            _ = lock.withLock { tracked.removeValue(forKey: ObjectIdentifier(connection)) }
        }

        private func readHead(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
                [weak self] data, _, complete, error in
                guard let self else { return }
                var accumulated = buffer
                if let data { accumulated.append(data) }
                if let range = accumulated.range(of: Data([13, 10, 13, 10])) {
                    let head = String(
                        decoding: accumulated.subdata(in: accumulated.startIndex..<range.lowerBound), as: UTF8.self)
                    let body = accumulated.subdata(in: range.upperBound..<accumulated.endIndex)
                    self.route(connection, head: head, body: body)
                    return
                }
                if accumulated.count > ComputerEgressRequest.maximumHeadBytes || error != nil || complete {
                    self.reply(connection, status: "400 Bad Request")
                    return
                }
                self.readHead(connection, buffer: accumulated)
            }
        }

        private func route(_ connection: NWConnection, head: String, body: Data) {
            let parsed = ComputerEgressRequest.parse(head)
            guard let parsed, let target = parsed.target else {
                reply(connection, status: "400 Bad Request")
                guard let unknown = ComputerEgressTarget(host: "unknown", port: 0) else { return }
                record(
                    ComputerEgressDecision(
                        target: unknown, verdict: .refuse(.malformedRequest), forwarded: false, placeholders: []))
                return
            }
            let resolved = ComputerIPAddress.parse(target.host).map { [$0] } ?? Self.resolve(target.host)
            let evaluation = request.policy.evaluate(request: parsed, resolved: resolved)
            switch evaluation.verdict {
            case .allow:
                forward(
                    connection, parsed: parsed, target: target, evaluation: evaluation, resolved: resolved,
                    body: body)
            case .refuse(let reason):
                let forwarding = request.policy.mode == .shadow && !resolved.isEmpty
                record(
                    ComputerEgressDecision(
                        target: target, verdict: .refuse(reason), forwarded: forwarding,
                        placeholders: evaluation.placeholders))
                if forwarding {
                    forward(
                        connection, parsed: parsed, target: target, evaluation: evaluation, resolved: resolved,
                        body: body)
                } else {
                    reply(connection, status: parsed.form == .connect ? "403 Forbidden" : "502 Bad Gateway")
                }
            }
        }

        private func forward(
            _ connection: NWConnection, parsed: ComputerEgressRequest, target: ComputerEgressTarget,
            evaluation: ComputerEgressEvaluation, resolved: [ComputerIPAddress], body: Data
        ) {
            var head = parsed.head
            if !evaluation.placeholders.isEmpty {
                let swapped = ComputerSandboxPolicy.swapPlaceholders(
                    in: head, bindings: request.policy.bindings(for: target.host), resolving: request.secrets)
                if !swapped.missing.isEmpty {
                    record(
                        ComputerEgressDecision(
                            target: target, verdict: .refuse(.secretUnavailable), forwarded: false,
                            placeholders: evaluation.placeholders))
                    reply(connection, status: parsed.form == .connect ? "403 Forbidden" : "502 Bad Gateway")
                    return
                }
                head = swapped.head
            }
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: target.port)), let address = resolved.first
            else {
                reply(connection, status: "502 Bad Gateway")
                return
            }
            let payload: Data?
            if parsed.form == .connect {
                payload = body.isEmpty ? nil : body
            } else {
                var forwardedHead = head
                if let requestLine = parsed.originFormRequestLine {
                    forwardedHead = requestLine + (Self.afterFirstLine(head).map { "\r\n" + $0 } ?? "")
                }
                payload = Data((forwardedHead + "\r\n\r\n").utf8) + body
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(address.text), port: port)
            connect(connection, endpoint: endpoint, initialPayload: payload, tunnel: parsed.form == .connect)
        }

        static func afterFirstLine(_ head: String) -> String? {
            guard let newline = head.firstIndex(of: "\n") else { return nil }
            let remainder = head[head.index(after: newline)...]
            return remainder.hasSuffix("\r") ? String(remainder.dropLast()) : String(remainder)
        }

        private func connect(
            _ client: NWConnection, endpoint: NWEndpoint, initialPayload: Data?, tunnel: Bool
        ) {
            let outgoing = NWConnection(to: endpoint, using: .tcp)
            lock.withLock {
                if stopped {
                    outgoing.cancel()
                    client.cancel()
                    return
                }
                tracked[ObjectIdentifier(outgoing)] = outgoing
            }
            outgoing.stateUpdateHandler = { [weak self, weak outgoing] state in
                guard let outgoing else { return }
                switch state {
                case .ready:
                    if tunnel {
                        client.send(
                            content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8),
                            completion: .contentProcessed { [weak self] error in
                                if error != nil {
                                    self?.closePair(client, outgoing)
                                    return
                                }
                                self?.relay(client, outgoing, initialPayload: initialPayload)
                            })
                    } else {
                        self?.relay(client, outgoing, initialPayload: initialPayload)
                    }
                case .failed, .cancelled:
                    client.cancel()
                    self?.untrack(outgoing)
                default: break
                }
            }
            outgoing.start(queue: queue)
        }

        private func relay(_ client: NWConnection, _ outgoing: NWConnection, initialPayload: Data?) {
            guard let initialPayload, !initialPayload.isEmpty else {
                pump(client, outgoing)
                pump(outgoing, client)
                return
            }
            outgoing.send(
                content: initialPayload,
                completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.closePair(client, outgoing)
                        return
                    }
                    self?.pump(client, outgoing)
                    self?.pump(outgoing, client)
                })
        }

        private func pump(_ source: NWConnection, _ destination: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] data, _, complete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    destination.send(
                        content: data,
                        completion: .contentProcessed { [weak self] sendError in
                            if sendError != nil {
                                self?.closePair(source, destination)
                                return
                            }
                            self?.pump(source, destination)
                        })
                    return
                }
                if error == nil, !complete {
                    self.pump(source, destination)
                    return
                }
                self.closePair(source, destination)
            }
        }

        private func closePair(_ source: NWConnection, _ destination: NWConnection) {
            source.cancel()
            destination.cancel()
            untrack(source)
            untrack(destination)
        }

        private func reply(_ connection: NWConnection, status: String) {
            connection.send(
                content: Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
                completion: .contentProcessed { [weak self, weak connection] _ in
                    connection?.cancel()
                    if let connection { self?.untrack(connection) }
                })
        }

        private func record(_ decision: ComputerEgressDecision) {
            request.sink.send(decision)
        }

        static func resolve(_ host: String) -> [ComputerIPAddress] {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "0", &hints, &info) == 0, let first = info else { return [] }
            defer { freeaddrinfo(first) }
            var addresses: [ComputerIPAddress] = []
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let node = current, addresses.count < 16 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    node.pointee.ai_addr, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
                    NI_NUMERICHOST) == 0
                {
                    if let address = ComputerIPAddress.parse(String(cString: buffer)), !addresses.contains(address) {
                        addresses.append(address)
                    }
                }
                current = node.pointee.ai_next
            }
            return addresses
        }
    }
#endif
