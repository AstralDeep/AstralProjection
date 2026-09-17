import Foundation
import Network
import XCTest

@testable import AstralCore

final class WorkReadTransport088Tests: XCTestCase {
    private let generation = "33333333-3333-4333-8333-333333333333"

    private func connected(
        _ body: (WSClient, WorkReadLoopback) async throws -> Void
    ) async throws {
        let peer = try WorkReadLoopback()
        peer.start()
        defer { peer.stop() }
        await fulfillment(of: [peer.ready], timeout: 3)
        let port = try XCTUnwrap(peer.listener.port)
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port.rawValue)/ws")!)
        let ready = expectation(description: "registered current socket")
        let events = await client.events()
        let consume = Task {
            for await event in events {
                if case .connected = event { ready.fulfill() }
            }
        }
        // This local peer tests physical transport only; it is not an IAM server.
        await client.start(onConnect: { #"{"type":"register_ui","token":"synthetic-local-only"}"# })
        await fulfillment(of: [ready], timeout: 3)
        do { try await body(client, peer) } catch {
            await client.stop()
            consume.cancel()
            throw error
        }
        await client.stop()
        consume.cancel()
    }

    func testOnlyClosedReadAndCloseReachRegisteredLoopbackOnce() async throws {
        try await connected { client, peer in
            let request = WorkReadRequest(
                payload: .object([
                    "surface": .string("work"), "params": .object(["mode": .string("list")]),
                ]))!
            let open = request.frameText(requestGeneration: generation)
            let close = Outbound.uiEvent(
                action: "chrome_close", sessionId: nil,
                payload: .object(["surface": .string("work")]), requestGeneration: generation)
            let effect = Outbound.uiEvent(
                action: "work_cancel", sessionId: nil,
                payload: .object(["surface": .string("work")]), requestGeneration: generation)
            let denied = await client.sendCurrentWorkEvent(effect) { true }
            XCTAssertFalse(denied)
            let opened = await client.sendCurrentWorkEvent(open) { true }
            let closed = await client.sendCurrentWorkEvent(close) { true }
            XCTAssertTrue(opened)
            XCTAssertTrue(closed)
            await fulfillment(of: [peer.twoReads], timeout: 3)
            XCTAssertEqual(peer.reads, [open, close])
        }
    }

    func testCurrentViewRefusalCancellationAndStoppedSocketNeverSendOrQueue() async throws {
        for mode in ["stale", "cancelled", "stopped"] {
            try await connected { client, peer in
                let request = WorkReadRequest(
                    payload: .object([
                        "surface": .string("work"), "params": .object(["mode": .string("list")]),
                    ]))!
                let wire = request.frameText(requestGeneration: generation)
                let entered = expectation(description: "view check entered \(mode)")
                let gate = WorkReadGate()
                let pending = Task {
                    await client.sendCurrentWorkEvent(wire) {
                        entered.fulfill()
                        await gate.wait()
                        return mode != "stale"
                    }
                }
                await fulfillment(of: [entered], timeout: 3)
                if mode == "cancelled" { pending.cancel() }
                if mode == "stopped" { await client.stop() }
                await gate.release()
                let sent = await pending.value
                XCTAssertFalse(sent, mode)
                // A post-refusal close is a delivery barrier on the same socket.
                // If the denied read were sent, it would precede this exact frame.
                if mode != "stopped" {
                    peer.expectSingleRead()
                    let close = Outbound.uiEvent(
                        action: "chrome_close", sessionId: nil,
                        payload: .object(["surface": .string("work")]), requestGeneration: generation)
                    let closed = await client.sendCurrentWorkEvent(close) { true }
                    XCTAssertTrue(closed)
                    await fulfillment(of: [peer.twoReads], timeout: 3)
                    XCTAssertEqual(peer.reads, [close])
                } else {
                    XCTAssertTrue(peer.reads.isEmpty)
                    let rejected = await client.sendCurrentWorkEvent(wire) { true }
                    XCTAssertFalse(rejected)
                }
            }
        }
    }
    func testGenericGuidanceOpenNeverReachesCurrentSocketOrReplayQueue() async throws {
        try await connected { client, peer in
            let note = Outbound.uiEvent(
                action: "chrome_open", sessionId: nil,
                payload: .object(["surface": .string("guidance"), "params": .object(["mode": .string("list")])]),
                requestGeneration: generation)
            await client.send(note)
            let barrier = component("component_restore")
            let sent = await client.sendCurrentComponentEvent(barrier) { true }
            XCTAssertTrue(sent)
            let deadline = Date().addingTimeInterval(3)
            while !peer.reads.contains(barrier) && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(peer.reads, [barrier])
        }
    }

    func testCurrentNotesCommandNeverCrossesCancellationOrChangedSocketAndCannotReplay() async throws {
        try await connected { client, peer in
            let request = GuidanceRequest(
                action: "chrome_note_forget",
                payload: .object([
                    "note_id": .string(generation), "expected_revision": .number(3),
                ]))!
            let wire = request.frameText(requestGeneration: generation)
            let entered = expectation(description: "notes current-view check")
            let gate = WorkReadGate()
            let pending = Task {
                await client.sendCurrentGuidanceEvent(wire) {
                    entered.fulfill()
                    await gate.wait()
                    return true
                }
            }
            await fulfillment(of: [entered], timeout: 3)
            pending.cancel()
            await gate.release()
            let sent = await pending.value
            XCTAssertFalse(sent)
            let opened = await client.sendCurrentGuidanceEvent(
                GuidanceRequest.list.frameText(requestGeneration: generation)
            ) { true }
            XCTAssertTrue(opened)
            let forgotten = await client.sendCurrentGuidanceEvent(wire) { true }
            XCTAssertTrue(forgotten)
            await fulfillment(of: [peer.twoReads], timeout: 3)
            XCTAssertEqual(peer.reads.count, 2)
            XCTAssertEqual(GuidanceRequest(frameText: peer.reads[0]), .list)
            XCTAssertEqual(peer.reads[1], wire)
        }
    }

    private func component(_ action: String) -> String {
        let identity = ClientOperationIdentity.fresh()
        return Outbound.uiEvent(
            action: action, sessionId: "11111111-1111-4111-8111-111111111111",
            payload: .object(["component_id": .string("saved")]),
            submissionId: identity.submissionId, requestGeneration: identity.requestGeneration)
    }

    func testOrdinaryComponentSendsRemainSeparateFromCurrentWorkReads() async throws {
        try await connected { client, peer in
            let refine = component("component_refine")
            let restore = component("component_restore")
            let deniedWork = await client.sendCurrentWorkEvent(refine) { true }
            XCTAssertFalse(deniedWork)
            let refined = await client.sendCurrentComponentEvent(refine) { true }
            let restored = await client.sendCurrentComponentEvent(restore) { true }
            XCTAssertTrue(refined)
            XCTAssertTrue(restored)
            await fulfillment(of: [peer.twoReads], timeout: 3)
            XCTAssertEqual(peer.reads, [refine, restore])
        }
    }

    func testOrdinaryQueuedChatFlushesButDisconnectedComponentAndWorkReadsDoNot() async throws {
        let peer = try WorkReadLoopback()
        peer.start()
        defer { peer.stop() }
        await fulfillment(of: [peer.ready], timeout: 3)
        let port = try XCTUnwrap(peer.listener.port)
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port.rawValue)/ws")!)
        let restore = component("component_restore")
        let rejected = await client.sendCurrentComponentEvent(restore) {
            XCTFail("Disconnected edit must not ask for a current view")
            return true
        }
        XCTAssertFalse(rejected)
        let work = WorkReadRequest(
            payload: .object(["surface": .string("work"), "params": .object(["mode": .string("list")])]))!
        await client.send(work.frameText(requestGeneration: generation))
        for action in ["chrome_open", "chrome_close"] {
            await client.send(
                Outbound.uiEvent(
                    action: action, sessionId: nil,
                    payload: .object(["surface": .string("work"), "params": .string("malformed")]),
                    requestGeneration: generation))
        }
        await client.send(GuidanceRequest.list.frameText(requestGeneration: generation))
        for action in ["chrome_note_save", "chrome_note_forget", "chrome_note_unknown", "chrome_open", "chrome_close"] {
            await client.send(
                Outbound.uiEvent(
                    action: action, sessionId: nil,
                    payload: .object([
                        "surface": .string("guidance"), "fields": .string("synthetic-private-never-queued"),
                    ]),
                    requestGeneration: generation))
        }
        let queued = Outbound.chatMessage("synthetic queued text", sessionId: "11111111-1111-4111-8111-111111111111")
        await client.send(queued)
        let ready = expectation(description: "registered before ordinary queue flush")
        let stream = await client.events()
        let consume = Task {
            for await event in stream { if case .connected = event { ready.fulfill() } }
        }
        await client.start(onConnect: { #"{"type":"register_ui","token":"synthetic-local-only"}"# })
        await fulfillment(of: [ready], timeout: 3)
        let flushDeadline = Date().addingTimeInterval(3)
        while peer.reads.isEmpty && Date() < flushDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(peer.reads, [queued])
        let restored = await client.sendCurrentComponentEvent(restore) { true }
        XCTAssertTrue(restored)
        await fulfillment(of: [peer.twoReads], timeout: 3)
        XCTAssertEqual(peer.reads, [queued, restore])
        await client.stop()
        consume.cancel()
    }

    func testPeerCloseDuringReplayValidationRefusesCurrentSurfacePhysicalSend() async throws {
        for notes in [false, true] {
            let peer = try WorkReadLoopback()
            peer.start()
            await fulfillment(of: [peer.ready], timeout: 3)
            let port = try XCTUnwrap(peer.listener.port)
            let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port.rawValue)/ws")!)
            let gate = WorkReadGate()
            let reconnected = expectation(description: "registered replacement socket")
            let events = await client.events()
            let consume = Task {
                var connections = 0
                for await event in events {
                    if case .connected = event {
                        connections += 1
                        if connections == 2 { reconnected.fulfill() }
                    }
                }
            }
            let validating = expectation(description: "ordinary replay validation in flight")
            await client.send(Outbound.chatMessage("synthetic queued text", sessionId: generation))
            await client.start(
                onConnect: { #"{"type":"register_ui","token":"synthetic-local-only"}"# },
                onReplay: { _ in
                    validating.fulfill()
                    await gate.wait()
                    return false
                })
            await fulfillment(of: [validating], timeout: 3)
            await peer.closeTransport()
            await fulfillment(of: [peer.remoteClosed], timeout: 3)
            let sent: Bool
            if notes {
                sent = await client.sendCurrentGuidanceEvent(
                    GuidanceRequest.list.frameText(requestGeneration: generation)
                ) { true }
            } else {
                let work = WorkReadRequest(
                    payload: .object(["surface": .string("work"), "params": .object(["mode": .string("list")])]))!
                sent = await client.sendCurrentWorkEvent(work.frameText(requestGeneration: generation)) { true }
            }
            XCTAssertFalse(sent)
            XCTAssertTrue(peer.reads.isEmpty)
            await gate.release()
            await fulfillment(of: [reconnected], timeout: 5)
            let barrier = component("component_restore")
            peer.expectSingleRead()
            let delivered = await client.sendCurrentComponentEvent(barrier) { true }
            XCTAssertTrue(delivered)
            await fulfillment(of: [peer.twoReads], timeout: 3)
            XCTAssertEqual(peer.reads, [barrier], "Refused private send must never replay on the new connection")
            await client.stop()
            consume.cancel()
            peer.stop()
        }
    }

    func testAwaitingOwnerSurfaceReadCannotMoveToARegisteredReplacementSocket() async throws {
        for notes in [false, true] {
            let peer = try WorkReadLoopback()
            peer.start()
            await fulfillment(of: [peer.ready], timeout: 3)
            let port = try XCTUnwrap(peer.listener.port)
            let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port.rawValue)/ws")!)
            let first = expectation(description: "first registered socket")
            let replacement = expectation(description: "replacement registered socket")
            let events = await client.events()
            let consume = Task {
                var connections = 0
                for await event in events {
                    if case .connected = event {
                        connections += 1
                        (connections == 1 ? first : replacement).fulfill()
                    }
                }
            }
            await client.start(onConnect: { #"{"type":"register_ui","token":"synthetic-local-only"}"# })
            await fulfillment(of: [first], timeout: 3)
            let gate = WorkReadGate()
            let entered = expectation(description: "original view validation awaits")
            let pending = Task {
                let current: @Sendable () async -> Bool = {
                    entered.fulfill()
                    await gate.wait()
                    return true
                }
                if notes {
                    return await client.sendCurrentGuidanceEvent(
                        GuidanceRequest.list.frameText(requestGeneration: generation), isCurrent: current)
                }
                let work = WorkReadRequest(
                    payload: .object(["surface": .string("work"), "params": .object(["mode": .string("list")])]))!
                return await client.sendCurrentWorkEvent(
                    work.frameText(requestGeneration: generation), isCurrent: current)
            }
            await fulfillment(of: [entered], timeout: 3)
            await peer.closeTransport()
            await fulfillment(of: [replacement], timeout: 5)
            await gate.release()
            let sent = await pending.value
            XCTAssertFalse(sent)
            peer.expectSingleRead()
            let barrier = component("component_restore")
            let delivered = await client.sendCurrentComponentEvent(barrier) { true }
            XCTAssertTrue(delivered)
            await fulfillment(of: [peer.twoReads], timeout: 3)
            XCTAssertEqual(peer.reads, [barrier])
            await client.stop()
            consume.cancel()
            peer.stop()
        }
    }

}

private actor WorkReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class WorkReadLoopback: @unchecked Sendable {
    let ready = XCTestExpectation(description: "loopback listening")
    let twoReads = XCTestExpectation(description: "expected read frames received")
    let remoteClosed = XCTestExpectation(description: "client acknowledged server WebSocket close")
    let listener: NWListener
    private let queue = DispatchQueue(label: "astral.work-read.test")
    private var connections: [NWConnection] = []
    private var received: [String] = []
    var reads: [String] { queue.sync { received } }

    init() throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
        twoReads.expectedFulfillmentCount = 2
    }

    func expectSingleRead() { twoReads.expectedFulfillmentCount = 1 }

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
            self.receive(connection)
        }
        listener.start(queue: queue)
    }

    func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .close
            {
                self?.remoteClosed.fulfill()
                return
            }
            guard let self, error == nil, let data, data.count <= 16384 else {
                connection.cancel()
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            if InboundFrame.parse(text)?.name == "register_ui" {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "ready", metadata: [metadata])
                connection.send(
                    content: Data(#"{"type":"ready"}"#.utf8), contentContext: context,
                    isComplete: true, completion: .contentProcessed { _ in })
            } else {
                self.received.append(text)
                self.twoReads.fulfill()
            }
            self.receive(connection)
        }
    }

    func closeTransport() async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let connection = self.connections.first else {
                    continuation.resume()
                    return
                }
                let context = NWConnection.ContentContext(
                    identifier: "server-close", metadata: [NWProtocolWebSocket.Metadata(opcode: .close)])
                connection.send(
                    content: Data([0x03, 0xe8]), contentContext: context, isComplete: true,
                    completion: .contentProcessed { _ in continuation.resume() })
            }
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}
