// AppModel tests for turn_steer_v1: capability gating exactly at the rote_config acknowledgement,
// Return/Option-Return steering and queue semantics with their stable client message ids, refusal
// restore, queue snapshot hydration and edit conflicts, Esc cancel-and-restore, approval isolation,
// and the side-question sheet's transcript isolation.

#if os(macOS)
    import AstralCore
    import Foundation
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
                    {"type":"rote_config","device_profile":{"console":{"turn_steer":{"version":1,"queue_capable":\(queueCapable)}}}}
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
            let (model, _) = try makeModel()
            negotiate(model)
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
            let (model, _) = try makeModel()
            negotiate(model)
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
            model.handleFrame(
                queueSnapshot(
                    3,
                    #"{"queue_id":"\#(queueId)","message":"update the changelog","revision":1},"#
                        + #"{"queue_id":"88888888-8888-4888-8888-888888888888","message":"ping the cluster","revision":1}"#))
            XCTAssertTrue(model.cancelTurnRestoringQueue())
            XCTAssertEqual(model.composerDraft, "update the changelog\n\nping the cluster")
            XCTAssertTrue(actions(sent()).contains("cancel_task"))
            XCTAssertEqual(actions(sent()).filter { $0 == "chat_queue_remove" }.count, 2)
            XCTAssertTrue(model.queuedFollowUps.isEmpty)
        }

        func testASteerCannotAnswerAnApprovalBanner() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            armTurn(model)
            let proposal = String(repeating: "ab", count: 16)
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"ui_upsert","ops":[{"op":"upsert","component_id":"approval",
                     "component":{"type":"card","id":"au_approval_\(proposal)","title":"Confirm an action",
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

        func testQueueIncapableServerHidesQueueActionsButSteersWork() throws {
            let (model, sent) = try makeModel()
            negotiate(model, queueCapable: false)
            armTurn(model)
            XCTAssertFalse(model.composerQueueApplies)
            XCTAssertTrue(model.composerSteeringApplies)
            model.sendComposerText("steer only")
            XCTAssertEqual(actions(sent()).last, "chat_steer")
            model.composerOptionReturn("try to queue")
            XCTAssertEqual(actions(sent()).last, "chat_steer")
        }

        func testSteerAppliesOnlyWhileATurnRuns() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            XCTAssertFalse(model.composerSteeringApplies)
            model.sendComposerText("ordinary message")
            XCTAssertEqual(actions(sent()).last, "chat_message")
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
