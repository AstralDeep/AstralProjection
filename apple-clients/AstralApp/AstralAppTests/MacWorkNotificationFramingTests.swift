// Covers the Mac work-notification framing in AppModel: question alerts from notification frames,
// finished and failed alerts from turn frames, tap-to-open reveal state, and approval-card lookup.
#if os(macOS)
    import AstralCore
    import Foundation
    import UserNotifications
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacWorkNotificationFramingTests: XCTestCase {
        private final class Recorder {
            var active = false
            var requests: [UNNotificationRequest] = []

            func system() -> MacWorkNotificationSystem {
                MacWorkNotificationSystem(
                    authorization: { .authorized },
                    requestAuthorization: { true },
                    deliver: { self.requests.append($0) },
                    setBadge: { _ in },
                    removeAllDelivered: {},
                    removeAllPending: {},
                    setDelegate: { _ in },
                    appIsActive: { self.active })
            }
        }

        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func reduce(_ model: AppModel, _ json: String) {
            model.handleFrame(InboundFrame.parse(json)!)
        }

        private func recorderModel() throws -> (AppModel, Recorder) {
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            let recorder = Recorder()
            model.macWorkNotificationService = MacWorkNotificationService(system: recorder.system(), defaults: nil)
            model.activeChatId = "44444444-4444-4444-8444-444444444444"
            return (model, recorder)
        }

        private func waitFor(_ condition: @autoclosure () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTFail("the expected notification was not delivered")
        }

        private func approvalCard(requestId: String) -> AstralComponent {
            func button(_ label: String, _ decision: String) -> JSONValue {
                .object([
                    "type": .string("button"), "label": .string(label), "action": .string("remote_op_decision"),
                    "payload": .object(["proposal_id": .string(requestId), "decision": .string(decision)]),
                ])
            }
            return AstralComponent(
                type: "card",
                raw: .object([
                    "type": .string("card"), "id": .string("au_approval_\(requestId)"),
                    "title": .string("Confirm an action on Studio Mac"),
                    "content": .array([
                        .object([
                            "type": .string("text"), "variant": .string("body"),
                            "content": .string("Run the review step on Studio Mac."),
                        ]),
                        button("Approve", "approve"), button("Decline", "decline"),
                    ]),
                ]))
        }

        private static let notificationFrame =
            #"{"type":"notification","level":"info","chat_id":"chat-notify-1","title":"Which mailbox?",""#
                + #"body":"Pick one to continue."}"#

        func testNotificationFrameRaisesOnePrivacySafeQuestionAlert() async throws {
            let (model, recorder) = try recorderModel()
            reduce(model, Self.notificationFrame)
            try await waitFor(recorder.requests.count == 1)
            let content = recorder.requests[0].content
            XCTAssertEqual(content.title, "AstralDeep has a question")
            XCTAssertEqual(content.body, "Open AstralDeep to read and answer it.")
            XCTAssertEqual(content.userInfo["chat_id"] as? String, "chat-notify-1")
            XCTAssertFalse(content.title.contains("mailbox"))
            XCTAssertFalse(content.body.contains("mailbox"))

            reduce(model, Self.notificationFrame)
            try await waitFor(recorder.requests.count == 1)
        }

        func testEmptyNotificationFrameRaisesNoAlert() async throws {
            let (model, recorder) = try recorderModel()
            reduce(model, #"{"type":"notification","level":"info"}"#)
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertTrue(recorder.requests.isEmpty)
        }

        func testFinishedTurnAlertsOnceAndCarriesTheChatId() async throws {
            let (model, recorder) = try recorderModel()
            reduce(model, #"{"type":"user_message_acked","chat_id":"44444444-4444-4444-8444-444444444444"}"#)
            reduce(model, #"{"type":"chat_status","status":"done","chat_id":"44444444-4444-4444-8444-444444444444"}"#)
            try await waitFor(recorder.requests.count == 1)
            XCTAssertEqual(recorder.requests[0].content.title, "Chat turn finished")
            XCTAssertEqual(
                recorder.requests[0].content.userInfo["chat_id"] as? String, "44444444-4444-4444-8444-444444444444")

            reduce(model, #"{"type":"chat_status","status":"done","chat_id":"44444444-4444-4444-8444-444444444444"}"#)
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(recorder.requests.count, 1)
        }

        func testFailedTurnAlertsAndSuppressesTheLaterFinishedAlert() async throws {
            let (model, recorder) = try recorderModel()
            XCTAssertTrue(model.beginConversationConnection(UUID().uuidString.lowercased()))
            reduce(model, #"{"type":"user_message_acked","chat_id":"44444444-4444-4444-8444-444444444444"}"#)
            XCTAssertTrue(model.turnActive)
            reduce(model, #"{"type":"stream_error","message":"The model provider dropped the stream."}"#)
            try await waitFor(recorder.requests.count == 1)
            XCTAssertEqual(recorder.requests[0].content.title, "Chat turn failed")

            reduce(model, #"{"type":"chat_status","status":"done","chat_id":"44444444-4444-4444-8444-444444444444"}"#)
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(recorder.requests.count, 1)
        }

        func testErrorFrameDuringATurnAlertsFailed() async throws {
            let (model, recorder) = try recorderModel()
            reduce(model, #"{"type":"user_message_acked","chat_id":"44444444-4444-4444-8444-444444444444"}"#)
            reduce(
                model,
                #"{"type":"error","code":"provider_unavailable","message":"The provider is unavailable."}"#)
            try await waitFor(recorder.requests.count == 1)
            XCTAssertEqual(recorder.requests[0].content.title, "Chat turn failed")
        }

        func testTapOpensTheChatAndSetsTheRevealWithoutStaleCards() throws {
            let (model, recorder) = try recorderModel()
            let tapChat = "44444444-4444-4444-8444-444444444445"
            model.openMacWorkNotification(chatId: tapChat, requestId: "approval-1")
            XCTAssertEqual(model.activeChatId, tapChat)
            XCTAssertEqual(model.macNotificationReveal?.requestId, "approval-1")

            let currentChat = "44444444-4444-4444-8444-444444444444"
            model.openMacWorkNotification(chatId: currentChat, requestId: nil)
            XCTAssertEqual(model.activeChatId, currentChat)
            XCTAssertNil(model.macNotificationReveal)
            XCTAssertTrue(recorder.requests.isEmpty)
        }

        func testApprovalCardLookupFollowsTheVisibleTurnsOnly() throws {
            let (model, _) = try recorderModel()
            let requestId = String(repeating: "ab", count: 16)
            XCTAssertNil(model.turnIdForApprovalCard(requestId))

            model.transientTurns = [
                AppModel.ChatTurn(
                    id: "assistant-0", role: "assistant", text: "",
                    components: [approvalCard(requestId: requestId)]),
            ]
            XCTAssertEqual(model.turnIdForApprovalCard(requestId), "assistant-0")

            model.transientTurns = []
            XCTAssertNil(model.turnIdForApprovalCard(requestId))
        }

        func testSettingsRoundTripThroughTheModel() throws {
            let (model, _) = try recorderModel()
            var settings = model.macWorkNotificationSettings
            XCTAssertEqual(settings.mode, .onlyInBackground)
            settings.mode = .always
            settings.enabledKinds.remove(.finished)
            model.macWorkNotificationSettings = settings
            XCTAssertEqual(model.macWorkNotificationService.settings.mode, .always)
            XCTAssertFalse(model.macWorkNotificationService.settings.isEnabled(.finished))
            XCTAssertTrue(model.macWorkNotificationService.settings.isEnabled(.approval))
        }
    }
#endif
