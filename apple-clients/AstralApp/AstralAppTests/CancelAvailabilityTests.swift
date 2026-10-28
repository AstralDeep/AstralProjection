// Checks that Cancel turn follows every busy signal the server already sends, not just the chat status.
// Approval continuations, running tool rows, computer requests in flight and per-chat status frames are covered.

#if os(macOS)
    import AstralCore
    import Foundation
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class CancelAvailabilityTests: XCTestCase {
        private let chat = "11111111-1111-4111-8111-111111111111"
        private let other = "55555555-5555-4555-8555-555555555555"
        private let connection = "22222222-2222-4222-8222-222222222222"
        private let operation = "44444444-4444-4444-8444-444444444444"

        private func model(host: MacComputerHost? = nil) throws -> (AppModel, () -> [JSONValue]) {
            let suite = "CancelAvailabilityTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults), tokenStore: InMemoryTokenStore(),
                defaults: defaults, computerHost: host, processActivity: RecordingActivityScheduler())
            model.signedIn = true
            model.connected = true
            XCTAssertTrue(model.beginConversationConnection(connection))
            model.activeChatId = chat
            var sent: [JSONValue] = []
            model.outboundTap = { text in if let frame = try? JSONValue.parse(Data(text.utf8)) { sent.append(frame) } }
            return (model, { sent })
        }

        private func status(
            _ request: String, action: String, state: String, terminal: Bool, sequence: Int, chat: String? = nil
        ) throws -> InboundFrame {
            let chatField = chat.map { "\"\($0)\"" } ?? "null"
            return try XCTUnwrap(
                InboundFrame.parse(
                    """
                    {"type":"operation_status","operation_id":"\(operation)","action":"\(action)",
                     "surface":"operation","chat_id":\(chatField),"connection_generation":"\(connection)",
                     "request_generation":"\(request)","sequence":\(sequence),"state":"\(state)","phase":"\(state)",
                     "label":"\(state)","terminal":\(terminal),"retryable":false,"error":null,"retry_after_ms":null,
                     "updated_at":"2026-10-27T12:00:0\(sequence)Z"}
                    """))
        }

        private func cancels(_ frames: [JSONValue]) -> [JSONValue] {
            frames.filter { $0["action"] == .string("cancel_task") }
        }

        func testAnApprovalContinuationKeepsCancelAvailableUntilItSettles() throws {
            let (model, sent) = try model()
            XCTAssertFalse(model.canCancelTurn)
            model.emit(
                "remote_op_decision",
                payload: ["proposal_id": .string(String(repeating: "a", count: 32)), "decision": .string("approve")])
            let decision = try XCTUnwrap(sent().last)
            let request = try XCTUnwrap(decision["request_generation"]?.stringValue)
            XCTAssertFalse(model.turnActive)
            model.handleFrame(
                try status(request, action: "remote_op_decision", state: "running", terminal: false, sequence: 1))
            XCTAssertTrue(model.canCancelTurn)
            XCTAssertTrue(model.cancelCurrentTurn())
            let cancel = try XCTUnwrap(cancels(sent()).last)
            XCTAssertEqual(cancel["session_id"], .string(chat))
            model.handleFrame(
                try status(request, action: "remote_op_decision", state: "completed", terminal: true, sequence: 2))
            XCTAssertFalse(model.canCancelTurn)
            XCTAssertFalse(model.cancelCurrentTurn())
            XCTAssertEqual(cancels(sent()).count, 1)
        }

        func testRunningToolRowsAreCancellableButAWaitingApprovalIsNot() throws {
            let (model, sent) = try model()
            model.handleFrame(ActivityFrames.step("s1", chat: chat, status: "in_progress", arguments: #"{"x":1}"#))
            XCTAssertFalse(model.turnActive)
            XCTAssertTrue(model.canCancelTurn)
            model.handleFrame(
                ActivityFrames.step(
                    "s1", chat: chat, status: "completed", result: #"{"_data":{"status":"confirmation_required"}}"#))
            XCTAssertEqual(model.activity.first?.approval, .waiting)
            XCTAssertFalse(model.canCancelTurn)
            model.emit(
                "authorize_action", payload: ["hitl_request_id": .string("hitl-1"), "decision": .string("approve")])
            XCTAssertEqual(model.activity.first?.approval, .approved)
            XCTAssertTrue(model.canCancelTurn)
            XCTAssertTrue(model.cancelCurrentTurn())
            XCTAssertEqual(cancels(sent()).count, 1)
            XCTAssertFalse(model.canCancelTurn)
        }

        func testStatusFramesForAnotherConversationLeaveTheActiveTurnAlone() throws {
            let (model, _) = try model()
            model.handleFrame(
                InboundFrame(
                    name: "chat_status",
                    payload: .object([
                        "type": .string("chat_status"), "status": .string("executing"), "chat_id": .string(other),
                    ])))
            XCTAssertFalse(model.turnActive)
            XCTAssertFalse(model.canCancelTurn)
            model.handleFrame(
                InboundFrame(
                    name: "chat_status",
                    payload: .object([
                        "type": .string("chat_status"), "status": .string("executing"), "chat_id": .string(chat),
                    ])))
            XCTAssertTrue(model.canCancelTurn)
            model.handleFrame(ActivityFrames.status("done"))
            XCTAssertFalse(model.canCancelTurn)
            model.handleFrame(ActivityFrames.status("thinking"))
            XCTAssertTrue(model.canCancelTurn)
        }

        func testComputerRequestsInFlightMakeTheTurnCancellable() async throws {
            let driver = GatedComputerDriver()
            let suite = "CancelAvailabilityHost.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
            let host = MacComputerHost(
                available: true, defaults: defaults, driver: driver, monitor: MacComputerTaskMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { _ in })
            host.bind(owner: "cancel-owner") { _ in true }
            host.setEnabled(true)
            addTeardownBlock { host.applicationWillTerminate() }
            let (model, _) = try model(host: host)
            let hostId = try XCTUnwrap(host.descriptor).hostId
            let session = UUID().uuidString.lowercased()
            host.consume(
                InboundFrame(
                    name: "computer_session",
                    payload: .object([
                        "type": .string("computer_session"), "host_id": .string(hostId),
                        "session_id": .string(session), "state": .string("active"),
                        "controller_label": .string("Cancel test"),
                    ])))
            XCTAssertFalse(host.working)
            XCTAssertFalse(model.canCancelTurn)
            host.consume(
                InboundFrame(
                    name: "computer_request",
                    payload: .object([
                        "type": .string("computer_request"),
                        "request_id": .string("creq_" + String(repeating: "1", count: 32)),
                        "session_id": .string(session), "verb": .string("click"),
                        "args": .object(["x": .number(1), "y": .number(1)]), "deadline_ms": .number(30000),
                    ])))
            XCTAssertTrue(host.working)
            XCTAssertTrue(model.canCancelTurn)
            await driver.release()
            let deadline = Date().addingTimeInterval(5)
            while host.working, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertFalse(host.working)
            XCTAssertFalse(model.canCancelTurn)
        }
    }

    actor GatedComputerDriver: MacComputerDriving {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func execute(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try authorize()
            if !open { await withCheckedContinuation { waiters.append($0) } }
            return ["attempted": .bool(true)]
        }

        func release() {
            open = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }

        func reset() {}
    }
#endif
