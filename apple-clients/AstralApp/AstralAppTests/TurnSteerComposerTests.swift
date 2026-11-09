// Qualifies AppModel's negotiated Mac steering, queue, side-question, and composer accessibility behavior.
// Mounted InputBar views and captured protocol frames exercise the same model and controls used by the app.

#if os(macOS)
    import AstralCore
    import Foundation
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class TurnSteerComposerTests: XCTestCase {
        private let chat = "11111111-1111-4111-8111-111111111111"
        private let connection = "22222222-2222-4222-8222-222222222222"
        private let queueId = "44444444-4444-4444-8444-444444444444"

        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func makeModel() throws -> (AppModel, () -> [JSONValue]) {
            let suite = "TurnSteerComposerTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            suites.append(suite)
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults,
                processActivity: RecordingActivityScheduler())
            model.signedIn = true
            model.connected = true
            XCTAssertTrue(model.beginConversationConnection(connection))
            model.activeChatId = chat
            var sent: [JSONValue] = []
            model.outboundTap = { text in
                if let frame = try? JSONValue.parse(Data(text.utf8)) { sent.append(frame) }
            }
            return (model, { sent })
        }

        private func negotiate(_ model: AppModel, queueCapable: Bool = true) {
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"rote_config","device_profile":{"console":
                        {"turn_steer":{"version":1,"queue_capable":\(queueCapable)}}}}
                    """)!)
        }

        private func armTurn(_ model: AppModel) {
            model.sendChat("start the deployment task")
            XCTAssertTrue(model.turnActive)
        }

        private func actions(_ frames: [JSONValue]) -> [String] {
            frames.compactMap { $0["action"]?.stringValue }
        }

        private func queueSnapshot(_ revision: Int, _ items: String) -> InboundFrame {
            InboundFrame.parse(
                """
                {"type":"chat_queue_updated","chat_id":"\(chat)","revision":\(revision),"items":[\(items)]}
                """)!
        }

        func testRegistrationAdvertisesBothSteeringAndConversationBranches() throws {
            let (model, _) = try makeModel()
            let registration = try JSONValue.parse(Data(model.registrationFrame(token: "token", resumed: false).utf8))
            let capabilities = Set(try XCTUnwrap(registration["capabilities"]?.arrayValue).compactMap(\.stringValue))

            XCTAssertEqual(registration["device"]?["turn_steer_v1"], .bool(true))
            XCTAssertTrue(capabilities.contains("turn_steer_v1"))
            XCTAssertTrue(capabilities.contains("chat_branches_v1"))
        }

        func testMountedComposerPreservesNativeDraftValueAndDescribesReturnWithHints() async throws {
            let (model, _) = try makeModel()
            let mount = SurfaceMount(
                InputBar(
                    input: Binding(get: { model.composerDraft }, set: { model.composerDraft = $0 }),
                    framed: false, workbenchStyle: true),
                model: model, size: CGSize(width: 640, height: 300))
            defer { mount.close() }

            for mode in ["message", "steer", "queue"] {
                let hint: String
                switch mode {
                case "steer":
                    negotiate(model)
                    armTurn(model)
                    model.composerReturnBinding = .steer
                    hint = "Return sends a steer"
                case "queue":
                    model.composerReturnBinding = .queue
                    hint = "Return queues a follow-up"
                default:
                    hint = "Return sends the message"
                }
                let draft = "\(mode) first line\nSecond line"
                model.composerDraft = draft
                try await mount.settle()
                let field = try XCTUnwrap(
                    try mount.accessibility.first { $0.identifier == "chat-composer-input" })

                XCTAssertEqual(field.label, "Message AstralDeep", mode)
                XCTAssertEqual(field.value, draft, mode)
                XCTAssertEqual(field.help, hint, mode)
            }
        }

        func testWithoutNegotiationTheComposerSendsAnOrdinaryMessage() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.handleFrame(
                InboundFrame.parse(#"{"type":"rote_config","device_profile":{"console":{}}}"#)!)
            XCTAssertFalse(model.turnSteerNegotiated)
            armTurn(model)
            model.sendComposerText("check the logs")
            XCTAssertEqual(actions(sent()), ["chat_message", "chat_message"])
            XCTAssertFalse(actions(sent()).contains("chat_steer"))
        }

        func testReturnSendsASteerWithStableClientMessageIdWhileTurnRuns() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.composerReturnBinding = .steer
            armTurn(model)
            model.sendComposerText("switch to the staging cluster")
            let steer = try XCTUnwrap(sent().last { $0["action"] == .string("chat_steer") })
            let payload = try XCTUnwrap(steer["payload"]?.objectValue)
            XCTAssertEqual(payload["message"], .string("switch to the staging cluster"))
            let clientMessageId = try XCTUnwrap(payload["client_message_id"]?.stringValue)
            XCTAssertEqual(continuityUUID4Value(clientMessageId), clientMessageId)
            XCTAssertNotNil(steer["submission_id"]?.stringValue)
            XCTAssertNotNil(steer["request_generation"]?.stringValue)
        }

        func testSteerRecordingAppendsASteerTurnAndSkippedTrailEntries() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.composerReturnBinding = .steer
            armTurn(model)
            model.sendComposerText("skip the screenshot")
            let steer = try XCTUnwrap(sent().last { $0["action"] == .string("chat_steer") })
            let clientMessageId = try XCTUnwrap(steer["payload"]?["client_message_id"]?.stringValue)
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"chat_steer_recorded","chat_id":"\(chat)","client_message_id":"\(clientMessageId)",
                     "skipped_calls":[{"name":"screenshot","reason":"superseded by the steer"}]}
                    """)!)
            XCTAssertEqual(model.visibleTurns.last?.role, "steer")
            XCTAssertEqual(model.visibleTurns.last?.text, "skip the screenshot")
            XCTAssertTrue(model.stepTrail.contains { $0.contains("screenshot") && $0.contains("superseded") })
        }

        func testRefusedSteerRestoresTheComposerTextWithANotice() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.composerReturnBinding = .steer
            armTurn(model)
            model.sendComposerText("hold the deploy")
            let steer = try XCTUnwrap(sent().last { $0["action"] == .string("chat_steer") })
            let clientMessageId = try XCTUnwrap(steer["payload"]?["client_message_id"]?.stringValue)
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"chat_steer_refused","chat_id":"\(chat)","client_message_id":"\(clientMessageId)",
                     "code":"stale_turn","message":"The task already moved on."}
                    """)!)
            XCTAssertEqual(model.composerDraft, "hold the deploy")
            XCTAssertEqual(model.steerNotice, "The task moved on, so this steer was not applied.")
            XCTAssertFalse(model.visibleTurns.contains { $0.id == "pending-steer-\(clientMessageId)" })
        }

        func testOptionReturnQueuesAndSnapshotHydratesChips() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.composerReturnBinding = .steer
            armTurn(model)
            model.composerOptionReturn("then update the changelog")
            XCTAssertEqual(actions(sent()).last, "chat_queue_put")
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            model.handleFrame(
                queueSnapshot(
                    1, #"{"queue_id":"\#(queueId)","message":"then update the changelog","revision":1}"#))
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["then update the changelog"])
        }

        func testQueueEditConflictShowsNoticeAndKeepsTheNewerText() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            armTurn(model)
            model.handleFrame(
                queueSnapshot(
                    1, #"{"queue_id":"\#(queueId)","message":"draft the notes","revision":1}"#))
            let item = try XCTUnwrap(model.queuedFollowUps.first)
            model.editQueuedFollowUp(item, text: "draft the release notes")
            let edit = try XCTUnwrap(sent().last { $0["action"] == .string("chat_queue_edit") })
            XCTAssertEqual(edit["payload"]?["expected_revision"], .number(1))
            model.handleFrame(
                queueSnapshot(
                    2, #"{"queue_id":"\#(queueId)","message":"draft the notes for review","revision":2}"#))
            XCTAssertEqual(model.queueConflictNotice, "This follow-up changed on another device.")
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["draft the notes for review"])
        }

        func testEscapeCancelsTheTurnAndRestoresQueuedTextToTheComposer() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            armTurn(model)
            let items =
                #"{"queue_id":"\#(queueId)","message":"update the changelog","revision":1},"#
                + #"{"queue_id":"88888888-8888-4888-8888-888888888888","message":"ping the cluster","revision":1}"#
            model.handleFrame(queueSnapshot(3, items))
            XCTAssertTrue(model.cancelTurnRestoringQueue())
            XCTAssertEqual(model.composerDraft, "update the changelog\n\nping the cluster")
            XCTAssertTrue(actions(sent()).contains("cancel_task"))
            XCTAssertEqual(actions(sent()).filter { $0 == "chat_queue_remove" }.count, 2)
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
        }

        func testASteerCannotAnswerAnApprovalBanner() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.composerReturnBinding = .steer
            armTurn(model)
            let proposal = String(repeating: "ab", count: 16)
            let request = try XCTUnwrap(sent().last { $0["action"] == .string("chat_message") })
            let generation = try XCTUnwrap(request["request_generation"]?.stringValue)
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"ui_upsert","chat_id":"\(chat)","connection_generation":"\(connection)",
                     "request_generation":"\(generation)","base_render_revision":0,"frame_sequence":1,
                     "ops":[{"op":"upsert","component_id":"approval",
                     "component":{"type":"card","id":"au_approval_\(proposal)",
                      "title":"Confirm an action on Test Mac",
                      "content":[{"type":"text","variant":"body","content":"Open a site"},
                       {"type":"button","label":"Approve","action":"remote_op_decision",
                        "payload":{"proposal_id":"\(proposal)","decision":"approve"}},
                       {"type":"button","label":"Decline","action":"remote_op_decision",
                        "payload":{"proposal_id":"\(proposal)","decision":"decline"}}]}}]}
                    """)!)
            XCTAssertFalse(model.approvalPrompts.isEmpty)
            let before = model.approvalPrompts
            model.sendComposerText("the answer is yes, go ahead")
            let sentActions = actions(sent())
            XCTAssertTrue(sentActions.contains("chat_steer"))
            XCTAssertFalse(sentActions.contains("remote_op_decision"))
            XCTAssertFalse(sentActions.contains("authorize_action"))
            XCTAssertEqual(model.approvalPrompts, before)
            XCTAssertEqual(model.waitingApprovals, 1)
        }

        func testSideQuestionAnswerStaysOutOfTheTranscript() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            armTurn(model)
            model.openSideQuestionSheet()
            XCTAssertTrue(model.sideQuestionSheetVisible)
            let turnsBefore = model.visibleTurns
            let canvasBefore = model.visibleCanvas
            model.askSideQuestion("is the lint pass clean?")
            XCTAssertEqual(actions(sent()).last, "side_question")
            let frame = try XCTUnwrap(sent().last { $0["action"] == .string("side_question") })
            let clientMessageId = try XCTUnwrap(frame["payload"]?["client_message_id"]?.stringValue)
            XCTAssertTrue(model.sideQuestionPending)
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"side_question_result","client_message_id":"\(clientMessageId)","answer":"Yes, clean."}
                    """)!)
            XCTAssertEqual(model.sideQuestionAnswer, "Yes, clean.")
            XCTAssertFalse(model.sideQuestionPending)
            XCTAssertEqual(model.visibleTurns, turnsBefore)
            XCTAssertEqual(model.visibleCanvas, canvasBefore)
        }

        func testSwappedBindingPersistsAndSwapsReturnAndOptionReturn() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.composerReturnBinding = .queue
            armTurn(model)
            model.sendComposerText("queue me")
            XCTAssertEqual(actions(sent()).last, "chat_queue_put")
            model.composerOptionReturn("steer me instead")
            XCTAssertEqual(actions(sent()).last, "chat_steer")

            let suite = try XCTUnwrap(UserDefaults(suiteName: suites[0]))
            XCTAssertEqual(
                suite.string(forKey: AppModel.composerReturnBindingKey),
                AppModel.ComposerReturnBinding.queue.rawValue)
        }

        func testReturnQueuesByDefaultAndAQueueIncapableServerGetsAnAppQueue() throws {
            let (model, sent) = try makeModel()
            XCTAssertEqual(model.composerReturnBinding, .queue)
            negotiate(model, queueCapable: false)
            armTurn(model)
            XCTAssertTrue(model.composerQueueApplies)
            model.sendComposerText("  update the changelog  ")
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["update the changelog"])
            XCTAssertEqual(actions(sent()), ["chat_message"])
            model.composerOptionReturn("steer instead")
            XCTAssertEqual(actions(sent()).last, "chat_steer")
        }

        func testSteerAppliesOnlyWhileATurnRuns() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            XCTAssertFalse(model.composerSteeringApplies)
            model.sendComposerText("ordinary message")
            XCTAssertEqual(actions(sent()).last, "chat_message")
        }

        private func status(_ request: String, operation: String, state: String, sequence: Int) -> InboundFrame {
            let terminal = ["completed", "failed", "cancelled", "retryable"].contains(state)
            let error =
                ["failed", "cancelled", "retryable"].contains(state)
                ? #"{"code":"operation_failed","message":"The task failed."}"# : "null"
            return InboundFrame.parse(
                """
                {"type":"operation_status","operation_id":"\(operation)",
                 "action":"chat_message","surface":"chat","chat_id":"\(chat)","connection_generation":"\(connection)",
                 "request_generation":"\(request)","sequence":\(sequence),"state":"\(state)","phase":"\(state)",
                 "label":"\(state)","terminal":\(terminal),"retryable":\(state == "retryable"),"error":\(error),
                 "retry_after_ms":null,"updated_at":"2026-11-09T12:00:0\(sequence)Z"}
                """)!
        }

        private func lastMessage(_ frames: [JSONValue]) throws -> JSONValue {
            try XCTUnwrap(frames.last { $0["action"] == .string("chat_message") })
        }

        private func finishTurn(_ model: AppModel, _ frames: [JSONValue], state: String = "completed") throws {
            let request = try XCTUnwrap(try lastMessage(frames)["request_generation"]?.stringValue)
            let operation = UUID().uuidString.lowercased()
            model.handleFrame(status(request, operation: operation, state: "running", sequence: 1))
            model.handleFrame(status(request, operation: operation, state: state, sequence: 2))
        }

        private func appQueueModel() throws -> (AppModel, () -> [JSONValue]) {
            let (model, sent) = try makeModel()
            negotiate(model, queueCapable: false)
            armTurn(model)
            return (model, sent)
        }

        func testACompletedTaskSendsTheNextAppQueuedFollowUpOneAtATime() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("first follow-up")
            model.sendComposerText("second follow-up")
            try finishTurn(model, sent())
            XCTAssertEqual(try lastMessage(sent())["payload"]?["message"], .string("first follow-up"))
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["second follow-up"])
            XCTAssertTrue(model.turnActive)
            try finishTurn(model, sent())
            XCTAssertEqual(try lastMessage(sent())["payload"]?["message"], .string("second follow-up"))
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertFalse(actions(sent()).contains { $0.hasPrefix("chat_queue") })
        }

        func testATaskThatDoesNotFinishPutsTheAppQueueBackInTheComposer() throws {
            for state in ["failed", "cancelled", "retryable"] {
                let (model, sent) = try appQueueModel()
                model.sendComposerText("queued one")
                model.sendComposerText("queued two")
                model.composerDraft = "still typing"
                try finishTurn(model, sent(), state: state)
                XCTAssertTrue(model.queuedFollowUps.isEmpty, state)
                XCTAssertTrue(model.composerDraft.hasPrefix("queued one\n\nqueued two"), state)
                XCTAssertTrue(model.composerDraft.contains("still typing"), state)
                XCTAssertEqual(actions(sent()).filter { $0 == "chat_message" }.count, 1, state)
            }
        }

        func testInterruptSendsTheQueuedFollowUpAsASteer() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("use metric units")
            let item = try XCTUnwrap(model.queuedFollowUps.first)
            model.interruptWithQueuedFollowUp(item)
            let steer = try XCTUnwrap(sent().last { $0["action"] == .string("chat_steer") })
            XCTAssertEqual(steer["payload"]?["message"], .string("use metric units"))
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            try finishTurn(model, sent())
            XCTAssertEqual(actions(sent()).filter { $0 == "chat_message" }.count, 1)
        }

        func testInterruptDoesNothingOnceTheTaskEnded() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("too late")
            let item = try XCTUnwrap(model.queuedFollowUps.first)
            try finishTurn(model, sent())
            model.interruptWithQueuedFollowUp(item)
            XCTAssertFalse(actions(sent()).contains("chat_steer"))
        }

        func testAppQueuedFollowUpsAreEditedRemovedAndReorderedLocally() throws {
            let (model, sent) = try appQueueModel()
            for text in ["alpha", "bravo", "charlie"] { model.sendComposerText(text) }
            let items = model.queuedFollowUps
            model.editQueuedFollowUp(items[0], text: "alpha edited")
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["alpha edited", "bravo", "charlie"])
            model.moveQueuedFollowUp(items[2], before: model.queuedFollowUps[0])
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["charlie", "alpha edited", "bravo"])
            model.removeQueuedFollowUp(items[1])
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["charlie", "alpha edited"])
            model.editQueuedFollowUp(model.queuedFollowUps[1], text: "   ")
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["charlie"])
            XCTAssertFalse(actions(sent()).contains { $0.hasPrefix("chat_queue") })
        }

        func testAFollowUpBeingEditedWaitsAndIsSentAsSaved() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("before edit")
            let item = try XCTUnwrap(model.queuedFollowUps.first)
            model.beginEditingQueuedFollowUp(item)
            try finishTurn(model, sent())
            XCTAssertEqual(actions(sent()).filter { $0 == "chat_message" }.count, 1)
            model.editQueuedFollowUp(item, text: "after edit")
            model.endEditingQueuedFollowUp()
            XCTAssertEqual(try lastMessage(sent())["payload"]?["message"], .string("after edit"))
        }

        func testADroppedConnectionPutsTheAppQueueBackInTheComposer() async throws {
            let (model, _) = try appQueueModel()
            model.sendComposerText("queued before the drop")
            await model.handle(.disconnected(reason: "test"))
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertTrue(model.composerDraft.contains("queued before the drop"))
            XCTAssertEqual(
                model.steerNotice, "The connection dropped, so your queued follow-ups are back in the composer.")
        }

        func testNewChatKeepsASavedChatsQueueAndClearsAnUnsavedOne() throws {
            let (model, _) = try appQueueModel()
            model.sendComposerText("for the saved chat")
            model.newChat()
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertNil(model.steerNotice)
            model.activeChatId = chat
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["for the saved chat"])

            model.activeChatId = nil
            armTurn(model)
            model.sendComposerText("for the unsaved chat")
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["for the unsaved chat"])
            model.newChat()
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertEqual(model.steerNotice, "Queued follow-ups were cleared for the new chat.")
        }

        func testANewChatsQueueFollowsItWhenTheServerNamesIt() throws {
            let (model, _) = try makeModel()
            model.activeChatId = nil
            negotiate(model, queueCapable: false)
            armTurn(model)
            model.sendComposerText("follows the chat")
            model.handleFrame(
                InboundFrame.parse(#"{"type":"chat_created","payload":{"chat_id":"\#(chat)"}}"#)!)
            XCTAssertEqual(model.activeChatId, chat)
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["follows the chat"])
        }

        func testTheAppQueueHoldsSixteenFollowUpsAndKeepsTheRestInTheComposer() throws {
            let (model, _) = try appQueueModel()
            for index in 1...16 { model.sendComposerText("queued \(index)") }
            model.sendComposerText("one too many")
            XCTAssertEqual(model.queuedFollowUps.count, 16)
            XCTAssertEqual(model.composerDraft, "one too many")
            XCTAssertEqual(model.steerNotice, "Up to 16 follow-ups can wait at once.")
        }

        func testMountedChipsOfferInterruptOnlyWhileATaskRuns() async throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("interrupt with me")
            let mount = SurfaceMount(QueueChipsRow(), model: model, size: CGSize(width: 640, height: 120))
            defer { mount.close() }
            try await mount.settle()
            let interrupt = try XCTUnwrap(
                try mount.accessibility.first { $0.identifier == "composer-queue-chip-interrupt" })
            XCTAssertEqual(interrupt.label, "Interrupt with follow-up")
            XCTAssertTrue(interrupt.enabled)
            model.stopTurn()
            XCTAssertEqual(actions(sent()).last, "cancel_task")
        }

        private func continuityUUID4Value(_ text: String) -> String? {
            guard
                text.range(
                    of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                    options: .regularExpression) != nil
            else { return nil }
            return text
        }
    }
#endif
