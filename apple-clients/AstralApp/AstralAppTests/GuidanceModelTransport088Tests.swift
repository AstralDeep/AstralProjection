// Tests for the notes-surface transport (Chrome/GuidanceSurface.swift): reads, navigation, and close stay on
// one socket without queueing, and connection or ownership changes before a send cannot leak or replay an old
// read.

import AstralCore
import Foundation
import Network
import XCTest

#if os(watchOS)
    @testable import AstralWatch
    private typealias GuidanceTestModel = WatchModel
#else
    @testable import AstralDeep
    private typealias GuidanceTestModel = AppModel
#endif

@MainActor
final class GuidanceModelTransport088Tests: XCTestCase {
    private let connection = "55555555-5555-4555-8555-555555555555"
    private let operation = "66666666-6666-4666-8666-666666666666"
    private let menu = InboundFrame.parse(
        #"{"type":"chrome_menu","model":{"version":2,"topbar":[{"key":"guidance","kind":"action","label":"Private notes","action":{"surface":"guidance","params":{"mode":"list"}}}],"menu":[]}}"#
    )!

    private func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), label)
    }

    private func open(_ model: GuidanceTestModel) {
        #if os(watchOS)
            model.openGuidance(model.guidanceControls.first!)
        #else
            model.openSurface("guidance", params: .object(["mode": .string("list")]))
        #endif
    }

    private func close(_ model: GuidanceTestModel) {
        #if os(watchOS)
            model.closeGuidance()
        #else
            model.closeSurface()
        #endif
    }

    private func displayed(_ model: GuidanceTestModel) -> Bool {
        #if os(watchOS)
            model.guidanceUpdate != nil
        #else
            model.guidanceUpdate != nil
        #endif
    }

    private func response(_ generation: String, components: [JSONValue]? = nil) -> String {
        var fields: [String: JSONValue] = [
            "type": .string("chrome_surface"), "surface_key": .string("guidance"),
            "region": .string("modal"), "title": .string("Evidence"), "mode": .string("replace"),
            "admin_only": .bool(false), "request_generation": .string(generation),
        ]
        fields["components"] = .array(
            components ?? [
                .object([
                    "type": .string("text"), "content": .string("Exact retained source"), "variant": .string("body"),
                ]), button.raw,
            ])
        return String(decoding: try! JSONValue.object(fields).encoded(), as: UTF8.self)
    }

    private var button: AstralComponent {
        AstralComponent(
            json: .object([
                "type": .string("button"), "variant": .string("secondary"), "label": .string("View detail"),
                "disabled": .bool(false), "local": .bool(false), "action": .string("chrome_open"),
                "payload": .object([
                    "surface": .string("guidance"),
                    "params": .object([
                        "mode": .string("edit"), "note_id": .string(operation), "expected_revision": .number(1),
                    ]),
                ]),
            ]))!
    }

    private func connected(_ body: (GuidanceTestModel, WSClient, GuidanceModelPeer) async throws -> Void) async throws {
        let peer = try GuidanceModelPeer()
        peer.start()
        defer { peer.stop() }
        await fulfillment(of: [peer.ready], timeout: 3)
        let port = try XCTUnwrap(peer.listener.port)
        let socket = WSClient(url: URL(string: "ws://127.0.0.1:\(port.rawValue)/ws")!)
        let suite = "GuidanceModelTransport088Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #if os(watchOS)
            let model = WatchModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults), webSocket: socket)
        #else
            let model = AppModel(tokenStore: InMemoryTokenStore(), defaults: defaults, webSocket: socket)
            model.signedIn = true
        #endif
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
        XCTAssertTrue(model.beginConversationConnection(connection))
        let ready = expectation(description: "synthetic physical socket registered")
        let events = await socket.events()
        let consume = Task {
            for await event in events {
                if case .connected = event { ready.fulfill() }
                if case .frame(let frame) = event { model.handleFrame(frame) }
            }
        }
        await socket.start(onConnect: { #"{"type":"register_ui","token":"synthetic-local-only"}"# })
        await fulfillment(of: [ready], timeout: 3)
        model.connected = true
        model.handleFrame(menu)
        do { try await body(model, socket, peer) } catch {
            await socket.stop()
            consume.cancel()
            throw error
        }
        close(model)
        await socket.stop()
        consume.cancel()
    }

    func testActualReadResponseNavigationAndCloseStayOnOneSocketAndNeverQueue() async throws {
        try await connected { model, _, peer in
            open(model)
            try await waitUntil("first physical read") { peer.reads.count == 1 }
            let first = try XCTUnwrap(model.guidanceState.generation)
            peer.send(response(first))
            try await waitUntil("first response displayed") { displayed(model) }
            XCTAssertNil(model.guidanceState.generation)
            #if os(watchOS)
                _ = model.sendGuidanceRequest(action: "chrome_open", payload: button.raw["payload"]!)
            #else
                model.sendEvent("chrome_open", button.raw["payload"]!)
            #endif
            try await waitUntil("detail read") { peer.reads.count == 2 }
            let second = try XCTUnwrap(model.guidanceState.generation)
            XCTAssertNotEqual(first, second)
            peer.send(response(first))
            peer.send(response(second))
            try await waitUntil("detail response displayed") { displayed(model) }
            close(model)
            try await waitUntil("physical close") { peer.reads.count == 3 }
            XCTAssertEqual(
                peer.reads.compactMap { InboundFrame.parse($0)?.payload["action"]?.stringValue },
                ["chrome_open", "chrome_open", "chrome_close"])
            XCTAssertTrue(model.localOperationSubmissions.isEmpty)
        }
    }

    func testOwnerAndConnectionRetirementBeforeSendCannotLeakOldRead() async throws {
        for mode in ["owner", "connection"] {
            try await connected { model, socket, peer in
                open(model)
                let old = try XCTUnwrap(model.guidanceState.generation)
                if mode == "owner" {
                    model.bindConversationAccount(
                        ConversationAccount(issuer: "https://iam.example.test", subject: "other")!)
                } else {
                    XCTAssertTrue(model.beginConversationConnection(operation))
                }
                let barrier = Outbound.uiEvent(
                    action: "chrome_close", sessionId: nil,
                    payload: .object(["surface": .string("guidance")]), requestGeneration: operation)
                let sent = await socket.sendCurrentGuidanceEvent(barrier) { true }
                XCTAssertTrue(sent)
                try await waitUntil("post-retirement physical barrier") { !peer.reads.isEmpty }
                XCTAssertEqual(peer.reads, [barrier])
                peer.send(response(old))
                XCTAssertNil(model.guidanceState.generation)
                XCTAssertFalse(displayed(model))
                XCTAssertTrue(model.localOperationSubmissions.isEmpty)
            }
        }
    }

    func testStoppedActorSendFailureRetiresTicketWithoutReconnectReplay() async throws {
        try await connected { model, socket, peer in
            await socket.stop()
            open(model)
            try await waitUntil("closed socket refusal") { model.guidanceFailed }
            XCTAssertNil(model.guidanceState.generation)
            XCTAssertFalse(displayed(model))
            XCTAssertTrue(peer.reads.isEmpty)
            XCTAssertTrue(model.localOperationSubmissions.isEmpty)
        }
    }

    func testActualMatchingFailureAndEmptyResponseRetirePendingRead() async throws {
        for failure in [true, false] {
            try await connected { model, _, peer in
                open(model)
                try await waitUntil("physical read") { peer.reads.count == 1 }
                let generation = try XCTUnwrap(model.guidanceState.generation)
                if failure {
                    peer.send(
                        """
                        {"type":"operation_status","operation_id":"\(operation)","action":"chrome_open","surface":"guidance","chat_id":null,
                         "connection_generation":"\(connection)","request_generation":"\(generation)","sequence":1,"state":"failed",
                         "phase":"failed","label":"Unavailable","terminal":true,"retryable":false,
                         "error":{"code":"operation_failed","message":"Unavailable"},"retry_after_ms":null,"updated_at":"2026-09-13T00:00:00Z"}
                        """)
                } else {
                    peer.send(response(generation, components: []))
                }
                try await waitUntil("ticket retired") { model.guidanceState.generation == nil }
                XCTAssertEqual(model.guidanceFailed, failure)
                XCTAssertFalse(displayed(model))
            }
        }
    }
    private func formResponse(_ generation: String) -> String {
        var fields = try! JSONValue.parse(Data(Self.editFrame.utf8)).objectValue!
        fields["request_generation"] = .string(generation)
        return String(decoding: try! JSONValue.object(fields).encoded(), as: UTF8.self)
    }
    private static let editFrame =
        #"{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Back to notes","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"text","content":"Current note","variant":"h3"},{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"},{"type":"param_picker","title":"Edit note","description":"","fields":[{"name":"category","label":"Category","kind":"select","default":"Preference","options":["Profession","Goal","Preference","Workflow tag","Context"]},{"name":"value","label":"Note","kind":"textarea","default":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","help":"Describe your preferences or context. Do not include patient information."},{"name":"enabled","label":"Enabled","kind":"boolean","default":true},{"name":"expiry","label":"Expiry","kind":"select","default":"Keep current expiry","options":["Keep current expiry","No expiry","Set a date"]},{"name":"expiry_date","label":"Expiry date (UTC)","kind":"text","default":"","help":"Use a UTC date and time, for example 2026-12-31T23:59:00Z.","visible_when":{"expiry":"Set a date"}}],"submit_label":"Save note","submit_action":"chrome_note_save","submit_payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"}"#

    func testActualSaveFailureCannotReplayPrivateFieldsAndRetryIsNewListRead() async throws {
        try await connected { model, _, peer in
            open(model)
            try await waitUntil("physical initial list") { peer.reads.count == 1 }
            peer.send(formResponse(try XCTUnwrap(model.guidanceState.generation)))
            try await waitUntil("current editor") { model.guidanceUpdate != nil }
            let form = try XCTUnwrap(model.guidanceUpdate?.components.compactMap(GuidanceForm.init(component:)).first)
            let request = try XCTUnwrap(
                form.request(values: [
                    "value": .string("**literal** [private](https://example.test)\nsecond line"),
                    "category": .string("Goal"), "enabled": .bool(false),
                    "expiry": .string("Set a date"), "expiry_date": .string("2027-01-01T00:00:00Z"),
                ]))
            XCTAssertTrue(model.sendGuidanceRequest(action: request.action, payload: request.payload))
            try await waitUntil("physical save once") { peer.reads.count == 2 }
            let save = peer.reads[1]
            XCTAssertEqual(GuidanceRequest(frameText: save), request)
            let generation = try XCTUnwrap(model.guidanceState.generation)
            let submission = try XCTUnwrap(model.guidanceState.submissionId)
            XCTAssertNil(model.guidanceUpdate)
            peer.send(
                """
                {"type":"error","submission_id":"\(submission)","accepted":false,"code":"capacity_exceeded","message":"Try later","retryable":true,"retry_after_ms":null}
                """)
            try await waitUntil("uncertain save retired") { model.guidanceFailed }
            XCTAssertNil(model.guidanceState.generation)
            model.retryGuidance()
            try await waitUntil("fresh list only") { peer.reads.count == 3 }
            XCTAssertEqual(GuidanceRequest(frameText: peer.reads[2]), .list)
            XCTAssertNotEqual(model.guidanceState.generation, generation)
            XCTAssertFalse(peer.reads[2].contains("literal"))
            peer.send(formResponse(generation))
            XCTAssertNil(model.guidanceUpdate)
            peer.send(response(try XCTUnwrap(model.guidanceState.generation)))
            try await waitUntil("fresh list response") { model.guidanceUpdate != nil }
            XCTAssertFalse(model.sendGuidanceRequest(action: request.action, payload: request.payload))
            XCTAssertEqual(peer.reads.count, 3)
            XCTAssertTrue(model.localOperationSubmissions.isEmpty)
        }
    }

    func testNotesOnlyMenuDoesNotRetireCurrentNotesWhenWorkIsUnavailable() async throws {
        try await connected { model, _, peer in
            open(model)
            try await waitUntil("physical notes read") { peer.reads.count == 1 }
            let generation = try XCTUnwrap(model.guidanceState.generation)
            model.handleFrame(menu)
            XCTAssertEqual(model.guidanceState.generation, generation)
            peer.send(response(generation))
            try await waitUntil("notes-only menu response") { model.guidanceUpdate != nil }
            model.handleFrame(menu)
            XCTAssertNotNil(model.guidanceUpdate)
        }
    }

}

private final class GuidanceModelPeer: @unchecked Sendable {
    let ready = XCTestExpectation(description: "loopback listener")
    let listener: NWListener
    private let queue = DispatchQueue(label: "astral.work-model.test")
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
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready.fulfill() } }
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
    private func send(_ text: String, to connection: NWConnection) {
        let context = NWConnection.ContentContext(
            identifier: "guidance", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(
            content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
    func send(_ text: String) { queue.async { if let first = self.connections.first { self.send(text, to: first) } } }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count <= 16384 else {
                connection.cancel()
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            if InboundFrame.parse(text)?.name == "register_ui" {
                self.send(#"{"type":"ready"}"#, to: connection)
            } else {
                self.received.append(text)
            }
            self.receive(connection)
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
