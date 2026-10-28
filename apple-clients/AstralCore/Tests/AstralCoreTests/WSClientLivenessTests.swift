// Drives WSClient against a loopback WebSocket peer that can stop answering without closing.
// Covers the pre-send probe, the idle keepalive, replay of queued frames on the next connection and the replay fence.

#if os(macOS)
    import Foundation
    import Network
    import XCTest

    @testable import AstralCore

    final class WSClientLivenessTests: XCTestCase {
        private let quick = LivenessPolicy(interval: 3600, timeout: 0.3, freshness: 0)

        private func frame(_ message: String = "hello") -> String {
            Outbound.uiEvent(
                action: "chat_message", sessionId: nil, payload: .object(["message": .string(message)]),
                snapshotPurpose: .commit)
        }

        private func start(
            _ peer: LivenessPeer, policy: LivenessPolicy?, fence: @escaping @Sendable (QueuedOperationReplay) -> Bool
        ) async throws -> (WSClient, EventLog) {
            let client = WSClient(url: try peer.url(), liveness: policy)
            let log = EventLog()
            let events = await client.events()
            Task { for await event in events { await log.append(event) } }
            await client.start(onConnect: { #"{"type":"register_ui"}"# }, onReplay: { fence($0) })
            addTeardownBlock { await client.stop() }
            return (client, log)
        }

        private func until(_ condition: () async -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while await !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            let met = await condition()
            XCTAssertTrue(met)
        }

        func testASilentSocketIsAbandonedBeforeSendingAndTheFrameReplaysOnTheNextConnection() async throws {
            let peer = try LivenessPeer()
            try await peer.start()
            defer { peer.stop() }
            let replays = Counter()
            let (client, log) = try await start(peer, policy: quick) { _ in
                replays.increment()
                return true
            }
            try await until { await log.connections == 1 }
            let live = await client.confirmLive()
            XCTAssertTrue(live)
            peer.silence(connection: 0)
            let silent = await client.confirmLive()
            XCTAssertFalse(silent)
            try await until { await log.disconnections == 1 }
            let message = frame("sent after the socket went quiet")
            await client.send(message)
            try await until { peer.texts(on: 1).contains(message) }
            let connections = await log.connections
            XCTAssertEqual(connections, 2)
            XCTAssertFalse(peer.texts(on: 0).contains(message))
            XCTAssertEqual(replays.value, 1)
        }

        func testTheKeepaliveNoticesASilentSocketWithoutASend() async throws {
            let peer = try LivenessPeer()
            try await peer.start()
            defer { peer.stop() }
            let (_, log) = try await start(
                peer, policy: LivenessPolicy(interval: 0.2, timeout: 0.3, freshness: 0.1)
            ) { _ in true }
            try await until { await log.connections == 1 }
            peer.silence(connection: 0)
            try await until { await log.disconnections == 1 }
            try await until { await log.connections == 2 }
            try await until { peer.pings(on: 1) > 0 }
        }

        func testRecentTrafficSkipsTheProbeAndAnAnsweredPingKeepsTheSocket() async throws {
            let peer = try LivenessPeer()
            try await peer.start()
            defer { peer.stop() }
            let (client, log) = try await start(
                peer, policy: LivenessPolicy(interval: 3600, timeout: 0.3, freshness: 3600)
            ) { _ in true }
            try await until { await log.connections == 1 }
            peer.silence(connection: 0)
            let fresh = await client.confirmLive()
            XCTAssertTrue(fresh)
            XCTAssertEqual(peer.pings(on: 0), 0)
            let disconnections = await log.disconnections
            XCTAssertEqual(disconnections, 0)
            let unstarted = WSClient(url: try peer.url(), liveness: quick)
            let idle = await unstarted.confirmLive()
            XCTAssertFalse(idle)
        }

        func testReplayedSendRunsTheFenceOnTheCurrentConnectionAndDropsWhatItRefuses() async throws {
            let peer = try LivenessPeer()
            try await peer.start()
            defer { peer.stop() }
            let allowed = Counter()
            let (client, log) = try await start(peer, policy: quick) { replay in
                allowed.increment()
                return replay.chatId == nil && allowed.value == 1
            }
            try await until { await log.connections == 1 }
            let accepted = frame("accepted through the fence")
            await client.sendThroughReplay(accepted)
            try await until { peer.texts(on: 0).contains(accepted) }
            let refused = frame("refused by the fence")
            await client.sendThroughReplay(refused)
            try await until { await log.dropped == 1 }
            XCTAssertFalse(peer.texts(on: 0).contains(refused))
            await client.sendThroughReplay(#"{"type":"ui_event","action":"chat_message"}"#)
            try await until { await log.rejected == 1 }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private actor EventLog {
        private(set) var connections = 0
        private(set) var disconnections = 0
        private(set) var dropped = 0
        private(set) var rejected = 0

        func append(_ event: WSEvent) {
            switch event {
            case .connected: connections += 1
            case .disconnected: disconnections += 1
            case .queuedOperationDropped: dropped += 1
            case .sendRejected: rejected += 1
            case .frame, .sendDropped: break
            }
        }
    }

    private final class LivenessPeer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "astral.liveness-peer")
        private var connections: [NWConnection] = []
        private var silent: Set<Int> = []
        private var received: [Int: [String]] = [:]
        private var pinged: [Int: Int] = [:]

        init() throws {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = false
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            listener = try NWListener(using: parameters, on: .any)
        }

        func url() throws -> URL {
            let port = try XCTUnwrap(queue.sync { listener.port }).rawValue
            return try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/ws"))
        }

        func start() async throws {
            let ready = AsyncStream<Void> { continuation in
                listener.stateUpdateHandler = { state in
                    if case .ready = state { continuation.finish() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                let index = self.connections.count
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, index: index)
            }
            listener.start(queue: queue)
            for await _ in ready {}
        }

        func silence(connection index: Int) { queue.sync { _ = silent.insert(index) } }
        func texts(on index: Int) -> [String] { queue.sync { received[index] ?? [] } }
        func pings(on index: Int) -> Int { queue.sync { pinged[index] ?? 0 } }

        func stop() {
            queue.sync {
                listener.cancel()
                for connection in connections { connection.cancel() }
            }
        }

        private func receive(_ connection: NWConnection, index: Int) {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self, error == nil else { return }
                let metadata =
                    context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if !self.silent.contains(index), let metadata {
                    switch metadata.opcode {
                    case .ping:
                        self.pinged[index, default: 0] += 1
                        self.write(data ?? Data(), opcode: .pong, to: connection)
                    case .text:
                        let text = String(decoding: data ?? Data(), as: UTF8.self)
                        if text.contains("\"register_ui\"") {
                            self.write(Data(#"{"type":"ready"}"#.utf8), opcode: .text, to: connection)
                        } else {
                            self.received[index, default: []].append(text)
                        }
                    default: break
                    }
                }
                self.receive(connection, index: index)
            }
        }

        private func write(_ data: Data, opcode: NWProtocolWebSocket.Opcode, to connection: NWConnection) {
            let context = NWConnection.ContentContext(
                identifier: "astral.liveness", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
#endif
