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

        private func status(
            _ request: String, operation: String, state: String, sequence: Int, action: String = "chat_message"
        ) -> InboundFrame {
            let terminal = ["completed", "failed", "cancelled", "retryable"].contains(state)
            let error =
                ["failed", "cancelled", "retryable"].contains(state)
                ? #"{"code":"operation_failed","message":"The task failed."}"# : "null"
            return InboundFrame.parse(
                """
                {"type":"operation_status","operation_id":"\(operation)",
                 "action":"\(action)","surface":"chat","chat_id":"\(chat)","connection_generation":"\(connection)",
                 "request_generation":"\(request)","sequence":\(sequence),"state":"\(state)","phase":"\(state)",
                 "label":"\(state)","terminal":\(terminal),"retryable":\(state == "retryable"),"error":\(error),
                 "retry_after_ms":null,"updated_at":"2026-11-09T12:00:0\(sequence)Z"}
                """)!
        }

        private func lastMessage(_ frames: [JSONValue]) throws -> JSONValue {
            try XCTUnwrap(frames.last { $0["action"] == .string("chat_message") })
        }

        private let done = InboundFrame.parse(#"{"type":"chat_status","status":"done"}"#)!

        // The server sends chat_status done, then any stale_turn refusals, then the final operation_status.
        private func finishTurn(
            _ model: AppModel, _ frames: [JSONValue], state: String = "completed", doneFirst: Bool = true,
            beforeFinal: () throws -> Void = {}
        ) throws {
            let request = try XCTUnwrap(try lastMessage(frames)["request_generation"]?.stringValue)
            let operation = UUID().uuidString.lowercased()
            model.handleFrame(status(request, operation: operation, state: "running", sequence: 1))
            if doneFirst { model.handleFrame(done) }
            try beforeFinal()
            model.handleFrame(status(request, operation: operation, state: state, sequence: 2))
            if !doneFirst { model.handleFrame(done) }
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

        private let otherChat = "33333333-3333-4333-8333-333333333333"

        private func refuseSteer(_ model: AppModel, _ frames: [JSONValue], code: String) throws {
            let steer = try XCTUnwrap(frames.last { $0["action"] == .string("chat_steer") })
            let clientMessageId = try XCTUnwrap(steer["payload"]?["client_message_id"]?.stringValue)
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"chat_steer_refused","chat_id":"\(chat)","client_message_id":"\(clientMessageId)",
                     "code":"\(code)","message":"refused"}
                    """)!)
        }

        private func messages(_ frames: [JSONValue]) -> [String] {
            frames.filter { $0["action"] == .string("chat_message") }.compactMap {
                $0["payload"]?["message"]?.stringValue
            }
        }

        func testAnAutoSentFollowUpLeavesTheDraftsFilesAlone() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("queued follow-up")
            model.composerDraft = "see the attached report"
            model.staged = [
                .init(
                    uid: 1, filename: "report.csv", category: "data",
                    attachmentId: "55555555-5555-4555-8555-555555555555", state: "ready")
            ]
            try finishTurn(model, sent())
            let auto = try lastMessage(sent())
            XCTAssertEqual(auto["payload"]?["message"], .string("queued follow-up"))
            XCTAssertNil(auto["payload"]?["attachments"], "the draft's attachment rode along with the queued follow-up")
            XCTAssertEqual(model.staged.map(\.filename), ["report.csv"], "the draft lost its staged attachment")
        }

        func testAFollowUpThatCannotBeSentInHistoryViewReturnsToTheComposer() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("do not lose me")
            model.handleFrame(InboundFrame.parse(#"{"type":"workspace_timeline_mode","active":true}"#)!)
            try finishTurn(model, sent())
            XCTAssertEqual(messages(sent()), ["start the deployment task"])
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertEqual(model.composerDraft, "do not lose me")
        }

        func testAMandatorySurfaceKeepsTheDraftAndGetsTheQueueBack() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("queued follow-up")
            model.composerDraft = "half-written thought"
            model.mandatorySurface = true
            try finishTurn(model, sent())
            XCTAssertTrue(
                model.composerDraft.contains("half-written thought"), "draft was replaced: \(model.composerDraft)")
        }

        func testARefusedInterruptKeepsTheDraft() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("interrupt with me")
            model.composerDraft = "my unsent notes"
            model.interruptWithQueuedFollowUp(try XCTUnwrap(model.queuedFollowUps.first))
            try refuseSteer(model, sent(), code: "approval_pending")
            XCTAssertTrue(model.composerDraft.contains("my unsent notes"), "draft was replaced: \(model.composerDraft)")
            XCTAssertTrue(model.composerDraft.contains("interrupt with me"))
        }

        func testALateInterruptIsSentBeforeTheLaterQueuedFollowUp() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("first: use metric")
            model.sendComposerText("second: then summarize")
            model.interruptWithQueuedFollowUp(try XCTUnwrap(model.queuedFollowUps.first))
            // The turn closes before the next tool boundary: stale_turn arrives before the final status.
            try refuseSteer(model, sent(), code: "stale_turn")
            try finishTurn(model, sent())
            XCTAssertEqual(
                messages(sent()).dropFirst().first, "first: use metric",
                "the later queued follow-up was sent while the earlier interrupt sat in the composer")
        }

        func testLeavingAndReturningWhileTheTaskRunsStillSettlesTheQueue() throws {
            let (model, sent) = try appQueueModel()
            let request = try XCTUnwrap(try lastMessage(sent())["request_generation"]?.stringValue)
            model.sendComposerText("queued before leaving")
            model.openChat(otherChat)
            model.openChat(chat)
            let operation = UUID().uuidString.lowercased()
            model.handleFrame(status(request, operation: operation, state: "running", sequence: 1))
            model.handleFrame(done)
            model.handleFrame(status(request, operation: operation, state: "completed", sequence: 2))
            // The reopened chat is still loading, so the queue comes back rather than racing the load.
            XCTAssertEqual(messages(sent()), ["start the deployment task"])
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertEqual(model.composerDraft, "queued before leaving")
        }

        func testATaskNotStartedByChatMessageStillSettlesTheAppQueue() throws {
            let (model, sent) = try makeModel()
            negotiate(model, queueCapable: false)
            model.handleFrame(InboundFrame.parse(#"{"type":"chat_status","status":"thinking"}"#)!)
            XCTAssertTrue(model.composerQueueApplies)
            model.sendComposerText("after the regenerate")
            XCTAssertEqual(model.queuedFollowUps.count, 1)
            model.handleFrame(done)
            XCTAssertFalse(model.turnActive)
            XCTAssertTrue(messages(sent()).isEmpty)
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertEqual(model.composerDraft, "after the regenerate")
        }

        func testAServerTurningQueueCapableReturnsTheAppQueue() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("held by the app")
            negotiate(model, queueCapable: true)
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertEqual(model.composerDraft, "held by the app")
            try finishTurn(model, sent())
            XCTAssertEqual(messages(sent()), ["start the deployment task"])
            XCTAssertFalse(actions(sent()).contains("chat_queue_put"))
        }

        func testATooLongFollowUpStaysInTheComposer() throws {
            let (model, sent) = try appQueueModel()
            let long = String(repeating: "log line\n", count: 2_300)  // 20,700 characters
            model.sendComposerText(long)
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertEqual(model.composerDraft, long)
            XCTAssertEqual(actions(sent()), ["chat_message"])
            XCTAssertEqual(
                model.steerNotice,
                "A follow-up can be at most 20,000 characters, so this one is still in the composer.")
        }

        func testAnOverLongEditKeepsTheFollowUp() throws {
            let (model, _) = try appQueueModel()
            model.sendComposerText("short")
            let item = try XCTUnwrap(model.queuedFollowUps.first)
            model.editQueuedFollowUp(item, text: String(repeating: "x", count: 20_001))
            XCTAssertFalse(model.queuedFollowUps.isEmpty, "an over-long edit deleted the follow-up and the edit")
        }

        func testTheServersFrameOrderSendsTheNextFollowUpInsteadOfHandingTheQueueBack() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("B")
            model.sendComposerText("C")
            try finishTurn(model, sent())
            XCTAssertEqual(messages(sent()), ["start the deployment task", "B"])
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["C"])
            XCTAssertEqual(model.composerDraft, "")
            XCTAssertTrue(model.turnActive)
        }

        func testALateDoneDoesNotEndTheTurnTheQueueJustStarted() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("B")
            model.sendComposerText("C")
            try finishTurn(model, sent(), doneFirst: false)
            XCTAssertEqual(messages(sent()), ["start the deployment task", "B"])
            XCTAssertTrue(model.turnActive, "the earlier turn's done ended the turn that sends B")
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["C"])
            XCTAssertEqual(model.composerDraft, "")
            try finishTurn(model, sent())
            XCTAssertEqual(messages(sent()), ["start the deployment task", "B", "C"])
        }

        func testALateInterruptRefusedAfterDoneIsSentNext() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("first: use metric")
            model.sendComposerText("second: then summarize")
            model.interruptWithQueuedFollowUp(try XCTUnwrap(model.queuedFollowUps.first))
            try finishTurn(model, sent()) { try self.refuseSteer(model, sent(), code: "stale_turn") }
            XCTAssertEqual(messages(sent()), ["start the deployment task", "first: use metric"])
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["second: then summarize"])
            XCTAssertEqual(model.composerDraft, "")
        }

        func testChipsQueuedAfterTheRowMountsAreDrawnAndRedrawn() async throws {
            let (model, _) = try appQueueModel()
            let mount = SurfaceMount(QueueChipsRow(), model: model, size: CGSize(width: 640, height: 120))
            defer { mount.close() }
            try await mount.settle()
            func chips() throws -> [String?] {
                try mount.accessibility.filter { $0.identifier == "composer-queue-chip-remove" }.map(\.value)
            }
            XCTAssertEqual(try chips(), [])
            model.sendComposerText("alpha")
            model.sendComposerText("bravo")
            try await mount.settle()
            XCTAssertEqual(try chips(), ["alpha", "bravo"])
            model.editQueuedFollowUp(model.queuedFollowUps[0], text: "alpha edited")
            try await mount.settle()
            XCTAssertEqual(try chips(), ["alpha edited", "bravo"])
            model.moveQueuedFollowUp(model.queuedFollowUps[1], before: model.queuedFollowUps[0])
            try await mount.settle()
            XCTAssertEqual(try chips(), ["bravo", "alpha edited"])
            model.removeQueuedFollowUp(model.queuedFollowUps[0])
            try await mount.settle()
            XCTAssertEqual(try chips(), ["alpha edited"])
        }

        func testOptionReturnButtonNamesWhatItDoes() async throws {
            for binding in [AppModel.ComposerReturnBinding.queue, .steer] {
                let (model, _) = try appQueueModel()
                model.composerReturnBinding = binding
                let mount = SurfaceMount(
                    InputBar(
                        input: Binding(get: { model.composerDraft }, set: { model.composerDraft = $0 }),
                        framed: false, workbenchStyle: true),
                    model: model, size: CGSize(width: 640, height: 300))
                defer { mount.close() }
                model.composerDraft = "draft"
                try await mount.settle()
                let button = try XCTUnwrap(
                    try mount.accessibility.first { $0.identifier == "composer-option-return" })
                XCTAssertEqual(button.label, binding == .queue ? "Send steer" : "Queue follow-up")
                XCTAssertEqual(
                    button.help,
                    binding == .queue ? "Send steer (Option-Return)" : "Queue follow-up (Option-Return)")
            }
        }

        func testClickingAwayFromAChipEditLetsTheQueueGo() async throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("edit me")
            let mount = SurfaceMount(QueueChipsRow(), model: model, size: CGSize(width: 640, height: 120))
            defer { mount.close() }
            try await mount.settle()
            try mount.click(text: "edit me")
            try await mount.settle()
            XCTAssertTrue(
                try mount.accessibility.contains { $0.identifier == "composer-queue-chip-editor" },
                "the chip editor did not open")
            try finishTurn(model, sent())
            XCTAssertEqual(messages(sent()), ["start the deployment task"])
            mount.window.makeFirstResponder(nil)
            try await mount.settle()
            XCTAssertEqual(messages(sent()), ["start the deployment task", "edit me"])
        }

        func testNewChatInAProjectKeepsTheOtherChatsQueues() async throws {
            let project = "12345678-1234-1234-9234-123456789abc"
            let server = ProjectCatalogServer(project: project)
            await server.succeedCreations()
            let (model, _) = try makeModel()
            negotiate(model, queueCapable: false)
            model.projects.bind(
                scope: "owner/server/device",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { try await server.respond($0) }))
            model.projects.negotiate(true)
            await model.projects.refresh()
            model.projects.select(project)
            model.activeChatId = chat
            model.handleFrame(InboundFrame.parse(#"{"type":"chat_status","status":"thinking"}"#)!)
            model.sendComposerText("for the first chat")
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["for the first chat"])
            model.newChat()
            for _ in 0..<2000 where model.activeChatId == chat || model.activeChatId == nil { await Task.yield() }
            XCTAssertNotEqual(model.activeChatId, chat)
            model.activeChatId = chat
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["for the first chat"])
        }

        func testAQueueModeChangeReturnsAnotherChatsQueueWhenItOpens() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("held for the first chat")
            model.newChat()
            model.activeChatId = otherChat
            negotiate(model, queueCapable: true)
            XCTAssertEqual(model.composerDraft, "")
            model.openChat(chat)
            XCTAssertEqual(model.composerDraft, "held for the first chat")
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertFalse(actions(sent()).contains("chat_queue_put"))
        }

        func testTwoEqualInterruptsAreBothSentNextWhenTheTaskMovedOn() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("same")
            model.sendComposerText("same")
            model.interruptWithQueuedFollowUp(model.queuedFollowUps[0])
            model.interruptWithQueuedFollowUp(model.queuedFollowUps[0])
            let steers = sent().filter { $0["action"] == .string("chat_steer") }
            XCTAssertEqual(steers.count, 2)
            for steer in steers {
                let id = try XCTUnwrap(steer["payload"]?["client_message_id"]?.stringValue)
                model.handleFrame(
                    InboundFrame.parse(
                        """
                        {"type":"chat_steer_refused","chat_id":"\(chat)","client_message_id":"\(id)",
                         "code":"stale_turn","message":"refused"}
                        """)!)
            }
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["same", "same"])
            XCTAssertEqual(model.composerDraft, "")
        }

        func testAnInterruptCutOffByADropIsNotRequeuedAfterReconnect() async throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("interrupt me")
            model.interruptWithQueuedFollowUp(try XCTUnwrap(model.queuedFollowUps.first))
            await model.handle(.disconnected(reason: "test"))
            model.connected = true
            XCTAssertTrue(model.beginConversationConnection("66666666-6666-4666-8666-666666666666"))
            negotiate(model, queueCapable: false)
            armTurn(model)
            try refuseSteer(model, sent(), code: "stale_turn")
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertEqual(model.composerDraft, "interrupt me")
        }

        private func showApprovalCard(_ model: AppModel, _ frames: [JSONValue]) throws {
            let proposal = String(repeating: "cd", count: 16)
            let generation = try XCTUnwrap(try lastMessage(frames)["request_generation"]?.stringValue)
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
        }

        func testTheAppQueueWaitsForAnApprovalAndGoesAfterTheResumedTurn() throws {
            let (model, sent) = try appQueueModel()
            model.currentApprovalDecisionSendOverride = { _, _ in true }
            model.sendComposerText("after the approval")
            try showApprovalCard(model, sent())
            try finishTurn(model, sent())
            XCTAssertEqual(messages(sent()), ["start the deployment task"], "a new turn would make the card stale")
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["after the approval"])
            XCTAssertEqual(model.composerDraft, "")

            model.decideApproval(try XCTUnwrap(model.approvalPrompts.first), allow: true)
            let decision = try XCTUnwrap(sent().last { $0["action"] == .string("remote_op_decision") })
            let request = try XCTUnwrap(decision["request_generation"]?.stringValue)
            let operation = UUID().uuidString.lowercased()
            XCTAssertEqual(messages(sent()), ["start the deployment task"], "sent before the resumed turn ran")
            model.handleFrame(InboundFrame.parse(#"{"type":"chat_status","status":"thinking"}"#)!)
            model.handleFrame(
                status(request, operation: operation, state: "running", sequence: 1, action: "remote_op_decision"))
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["after the approval"])
            // Without decision receipts the resumed turn's done is what settles the decision.
            model.handleFrame(done)
            XCTAssertEqual(messages(sent()), ["start the deployment task", "after the approval"])
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
            XCTAssertEqual(model.composerDraft, "")
            model.handleFrame(
                status(request, operation: operation, state: "completed", sequence: 2, action: "remote_op_decision"))
            XCTAssertEqual(messages(sent()), ["start the deployment task", "after the approval"])
        }

        func testWithDecisionReceiptsTheQueueWaitsForTheDecisionToFinish() async throws {
            let (model, sent) = try appQueueModel()
            model.currentApprovalDecisionSendOverride = { _, _ in true }
            model.sendComposerText("after the decision")
            try showApprovalCard(model, sent())
            let server = ProjectCatalogServer(project: "12345678-1234-1234-9234-123456789abc")
            await server.setChatSnapshot([chat: "100"])
            model.projects.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { try await server.respond($0) }))
            model.projects.negotiate(true)
            await model.projects.refresh()
            XCTAssertNotNil(model.projects.project(for: chat))
            try finishTurn(model, sent())
            model.decideApproval(try XCTUnwrap(model.approvalPrompts.first), allow: true)
            let decision = try XCTUnwrap(sent().last { $0["action"] == .string("remote_op_decision") })
            let request = try XCTUnwrap(decision["request_generation"]?.stringValue)
            let operation = UUID().uuidString.lowercased()
            model.handleFrame(InboundFrame.parse(#"{"type":"chat_status","status":"thinking"}"#)!)
            model.handleFrame(
                status(request, operation: operation, state: "running", sequence: 1, action: "remote_op_decision"))
            model.handleFrame(done)
            XCTAssertEqual(messages(sent()), ["start the deployment task"], "sent while the decision was still open")
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["after the decision"])
            XCTAssertEqual(model.composerDraft, "")
            model.handleFrame(
                status(request, operation: operation, state: "completed", sequence: 2, action: "remote_op_decision"))
            XCTAssertEqual(messages(sent()), ["start the deployment task", "after the decision"])
        }

        func testAnApprovalCardRetiredWithoutAResumedTurnReleasesTheQueue() throws {
            let (model, sent) = try appQueueModel()
            model.sendComposerText("after the card")
            try showApprovalCard(model, sent())
            try finishTurn(model, sent())
            XCTAssertEqual(model.queuedFollowUps.map(\.message), ["after the card"])
            model.canvas = []
            model.transientCanvas = nil
            XCTAssertTrue(model.approvalPrompts.isEmpty)
            XCTAssertEqual(messages(sent()), ["start the deployment task", "after the card"])
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
