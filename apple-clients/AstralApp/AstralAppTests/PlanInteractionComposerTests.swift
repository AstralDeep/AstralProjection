// Qualifies AppModel's negotiated plan interaction: the owner Plan toggle, plan decisions, the docked
// question panel with numbered options, cross-chat routing, and the timeout blocked state, using the same
// mounted InputBar and panel views the Mac workbench renders.

#if os(macOS)
    import AstralCore
    import Foundation
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class PlanInteractionComposerTests: XCTestCase {
        private let chat = "33333333-3333-4333-8333-333333333333"
        private let otherChat = "44444444-4444-4444-8444-444444444444"
        private let planId = "55555555-5555-4555-8555-555555555555"
        private let questionId = "66666666-6666-4666-8666-666666666666"
        private let promptId = "77777777-7777-4777-8777-777777777777"
        private let connection = "88888888-8888-4888-8888-888888888888"

        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func makeModel() throws -> (AppModel, () -> [JSONValue]) {
            let suite = "PlanInteractionComposerTests.\(UUID().uuidString)"
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

        private func negotiate(_ model: AppModel) {
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"rote_config","device_profile":{"console":{
                        "turn_steer":{"version":1,"queue_capable":true},
                        "plan_interaction":{"version":1}}}}
                    """)!)
        }

        private func planState(_ mode: String, status: String, version: Int?, review: String) -> InboundFrame {
            InboundFrame.parse(
                """
                {"type":"plan_mode_state","chat_id":"\(chat)","mode":"\(mode)",
                 "plan_status":"\(status)","plan_version":\(version.map(String.init) ?? "null"),
                 "review":"\(review)"}
                """)!
        }

        private func proposal(_ version: Int) -> InboundFrame {
            InboundFrame.parse(
                """
                {"type":"plan_proposal","chat_id":"\(chat)","plan_id":"\(planId)","version":\(version),
                 "steps":["Snapshot the database","Switch the read path"],
                 "assumptions":["Staging mirrors production"],
                 "files":["db/0042.sql"],"apps":["pgAdmin"]}
                """)!
        }

        private func questionRequest(chatId: String = "33333333-3333-4333-8333-333333333333") -> InboundFrame {
            InboundFrame.parse(
                """
                {"type":"question_request","chat_id":"\(chatId)","question_id":"\(questionId)",
                 "questions":[{"id":"\(promptId)","prompt":"Which cluster?","options":["Cluster A","Cluster B","Defer"]}],
                 "timeout_ms":120000}
                """)!
        }

        private func actions(_ frames: [JSONValue]) -> [String] {
            frames.compactMap { $0["action"]?.stringValue }
        }

        func testRegistrationAdvertisesPlanInteractionOnMacOS() throws {
            let (model, _) = try makeModel()
            let registration = try JSONValue.parse(Data(model.registrationFrame(token: "token", resumed: false).utf8))
            XCTAssertEqual(registration["device"]?["plan_interaction_v1"], .bool(true))
            let capabilities = Set(try XCTUnwrap(registration["capabilities"]?.arrayValue).compactMap(\.stringValue))
            XCTAssertTrue(capabilities.contains("plan_interaction_v1"))
        }

        func testToggleSendsOwnerEventAndBadgeFollowsServerStateOnly() throws {
            let (model, sent) = try makeModel()
            XCTAssertFalse(model.planInteractionNegotiated)
            XCTAssertFalse(model.planInteractionAvailable)
            negotiate(model)
            XCTAssertTrue(model.planInteractionNegotiated)
            XCTAssertTrue(model.planInteractionAvailable)
            XCTAssertFalse(model.planModeActive)

            model.togglePlanMode()
            XCTAssertEqual(actions(sent()), ["plan_mode_set"])
            let event = sent()[0]
            XCTAssertEqual(event["payload"]?["enabled"], .bool(true))
            XCTAssertFalse(model.planModeActive, "the mode is never inferred locally")

            model.handleFrame(planState("plan", status: "proposed", version: 1, review: "auto"))
            XCTAssertTrue(model.planModeActive)
            XCTAssertEqual(model.activePlanInteraction?.status, .proposed)
            XCTAssertEqual(model.activePlanInteraction?.planVersion, 1)

            model.togglePlanMode()
            XCTAssertEqual(actions(sent()), ["plan_mode_set", "plan_mode_set"])
            XCTAssertEqual(sent()[1]["payload"]?["enabled"], .bool(false))
            XCTAssertTrue(model.planModeActive, "still plan mode until the server confirms")
            model.handleFrame(planState("execute", status: "none", version: nil, review: "auto"))
            XCTAssertFalse(model.planModeActive)
        }

        func testPlanDecisionsSendExactActionsAndRevisionField() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.approvePlan()
            XCTAssertEqual(actions(sent()), [], "no decision without a proposal")

            model.handleFrame(proposal(1))
            XCTAssertEqual(model.activePlanInteraction?.proposal?.planId, planId)

            model.approvePlan()
            XCTAssertEqual(actions(sent()), ["plan_approve"])
            model.approvePlanWithReview()
            XCTAssertEqual(actions(sent()), ["plan_approve", "plan_approve_review"])

            model.beginPlanRevision()
            XCTAssertTrue(model.activePlanInteraction?.reviseActive == true)
            model.setPlanReviseDraft("  Move the rollback earlier  ")
            model.sendPlanRevision()
            XCTAssertEqual(actions(sent()), ["plan_approve", "plan_approve_review", "plan_revise"])
            XCTAssertEqual(sent()[2]["action"], .string("plan_revise"))
            XCTAssertEqual(sent()[2]["payload"]?["feedback"], .string("Move the rollback earlier"))
            XCTAssertEqual(sent()[2]["payload"]?["version"], .number(1))
            XCTAssertFalse(model.activePlanInteraction?.reviseActive ?? true)

            model.handleFrame(proposal(2))
            XCTAssertEqual(model.activePlanInteraction?.proposal?.version, 2)
        }

        func testPlanNoticeRendersAsNoticeAndNeverAsErrorBanner() throws {
            let (model, _) = try makeModel()
            negotiate(model)
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"plan_mode_notice","chat_id":"\(chat)","code":"plan_mode_active",
                     "message":"Plan mode is on, so that change was not applied."}
                    """)!)
            XCTAssertEqual(model.activePlanInteraction?.notice, "Plan mode is on, so that change was not applied.")
            XCTAssertNil(model.errorBanner)

            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"plan_mode_notice","chat_id":"\(otherChat)","code":"plan_mode_active","message":"other chat"}
                    """)!)
            XCTAssertEqual(model.activePlanInteraction?.notice, "Plan mode is on, so that change was not applied.")
        }

        func testQuestionPanelRoutesByChatAndNeverShowsAnotherChatsPanel() throws {
            let (model, _) = try makeModel()
            negotiate(model)
            model.handleFrame(questionRequest(chatId: otherChat))
            XCTAssertNil(model.activePlanInteraction?.question, "another chat's panel must not show here")
            XCTAssertNotNil(model.planInteractionByChat[otherChat]?.question, "the request is stored for its own chat")

            model.handleFrame(questionRequest())
            XCTAssertNotNil(model.activePlanInteraction?.question)
            XCTAssertTrue(model.activePlanInteraction?.question?.questionId == questionId)
            XCTAssertFalse(model.activeQuestionComplete)
        }

        func testQuestionSubmitRequiresEveryAnswerAndSendsKeyedAnswers() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.handleFrame(questionRequest())
            guard let prompt = model.activePlanInteraction?.question?.prompts.first else {
                return XCTFail("question request must decode")
            }

            model.submitQuestionAnswers()
            XCTAssertEqual(actions(sent()), [], "Return must not submit before every question has an answer")

            model.selectQuestionOption(prompt, optionIndex: 1)
            XCTAssertEqual(model.questionAnswer(for: prompt), "Cluster B")
            XCTAssertTrue(model.activeQuestionComplete)

            model.submitQuestionAnswers()
            XCTAssertEqual(actions(sent()), ["question_submit"])
            let event = sent()[0]
            XCTAssertEqual(event["action"], .string("question_submit"))
            XCTAssertEqual(event["payload"]?["question_id"], .string(questionId))
            XCTAssertEqual(event["payload"]?["answers"]?[promptId], .string("Cluster B"))
            XCTAssertTrue(model.activePlanInteraction?.questionSubmitted == true)

            model.submitQuestionAnswers()
            XCTAssertEqual(actions(sent()).count, 1, "double submit is suppressed")

            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"question_resolved","chat_id":"\(chat)","question_id":"\(questionId)",
                     "disposition":"answered"}
                    """)!)
            XCTAssertNil(model.activePlanInteraction?.question)
            XCTAssertNil(model.activePlanInteraction?.blocked, "answered closes without a blocked state")
        }

        func testQuestionFreeTextIsAnAnswerAndOptionsOverrideIt() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.handleFrame(questionRequest())
            guard let prompt = model.activePlanInteraction?.question?.prompts.first else {
                return XCTFail("question request must decode")
            }
            model.setQuestionFreeText(prompt, "Cluster B, but only after the backup window")
            XCTAssertTrue(model.activeQuestionComplete)
            model.submitQuestionAnswers()
            XCTAssertEqual(actions(sent()), ["question_submit"])
            XCTAssertEqual(
                sent()[0]["payload"]?["answers"]?[promptId],
                .string("Cluster B, but only after the backup window"))
        }

        func testServerTimeoutClosesPanelWithBlockedState() throws {
            let (model, _) = try makeModel()
            negotiate(model)
            model.handleFrame(questionRequest())
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"question_resolved","chat_id":"\(chat)","question_id":"\(questionId)",
                     "disposition":"timed_out"}
                    """)!)
            XCTAssertNil(model.activePlanInteraction?.question, "the panel closes after a server timeout")
            XCTAssertNotNil(model.activePlanInteraction?.blocked)

            model.handleFrame(questionRequest())
            XCTAssertNil(model.activePlanInteraction?.blocked, "a fresh request clears the blocked state")
        }

        func testSkipSendsQuestionSkipAndClearsPanel() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.handleFrame(questionRequest())
            model.skipQuestions()
            XCTAssertEqual(actions(sent()), ["question_skip"])
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"question_resolved","chat_id":"\(chat)","question_id":"\(questionId)",
                     "disposition":"skipped"}
                    """)!)
            XCTAssertNil(model.activePlanInteraction?.question)
            XCTAssertNil(model.activePlanInteraction?.blocked)
        }

        func testQuestionPanelKeyRouterMatchesTheContract() {
            typealias Keys = QuestionPanelKeys
            XCTAssertEqual(Keys.route(key: "1", complete: false, editingInPanel: false), .option(0))
            XCTAssertEqual(Keys.route(key: "3", complete: false, editingInPanel: false), .option(2))
            XCTAssertEqual(Keys.route(key: "9", complete: false, editingInPanel: false), .option(8))
            XCTAssertEqual(Keys.route(key: "0", complete: false, editingInPanel: false), .ignored)
            XCTAssertEqual(Keys.route(key: "1", complete: false, editingInPanel: true), .ignored)
            XCTAssertEqual(Keys.route(key: "\r", complete: false, editingInPanel: false), .ignored)
            XCTAssertEqual(Keys.route(key: "\r", complete: true, editingInPanel: false), .submit)
            XCTAssertEqual(Keys.route(key: "\r", complete: true, editingInPanel: true), .ignored)
            XCTAssertEqual(Keys.route(key: "a", complete: true, editingInPanel: false), .ignored)
        }

        func testMountedComposerShowsToggleOnlyAfterNegotiation() async throws {
            let (model, _) = try makeModel()
            let mount = SurfaceMount(
                InputBar(
                    input: Binding(get: { model.composerDraft }, set: { model.composerDraft = $0 }),
                    framed: false, workbenchStyle: true),
                model: model, size: CGSize(width: 640, height: 300))
            defer { mount.close() }
            try await mount.settle()
            XCTAssertFalse(try mount.accessibility.contains { $0.identifier == "composer-plan-toggle" })

            negotiate(model)
            try await mount.settle()
            let toggle = try XCTUnwrap(
                mount.accessibility.first { $0.identifier == "composer-plan-toggle" })
            XCTAssertEqual(toggle.label, "Plan mode")
            XCTAssertEqual(toggle.value, "Off")

            model.handleFrame(planState("plan", status: "proposed", version: 1, review: "auto"))
            try await mount.settle()
            let armed = try XCTUnwrap(
                mount.accessibility.first { $0.identifier == "composer-plan-toggle" })
            XCTAssertEqual(armed.value, "On")
        }

        func testMountedPanelSelectsOptionsAndBlocksIncompleteSubmit() async throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.handleFrame(questionRequest())
            let mount = SurfaceMount(
                VStack {
                    QuestionPanel()
                }, model: model, size: CGSize(width: 640, height: 360))
            defer { mount.close() }
            try await mount.settle()

            let elements = try mount.accessibility
            XCTAssertTrue(elements.contains { $0.identifier == "question-panel" })
            XCTAssertTrue(elements.contains { $0.identifier == "question-option-1-1" })
            XCTAssertTrue(elements.contains { $0.identifier == "question-free-text-1" })
            let submit = try XCTUnwrap(elements.first { $0.identifier == "question-submit" })
            XCTAssertFalse(submit.enabled)

            guard let prompt = model.activePlanInteraction?.question?.prompts.first else {
                return XCTFail("question request must decode")
            }
            model.selectQuestionOption(prompt, optionIndex: 0)
            try await mount.settle()
            let selected = try XCTUnwrap(
                (try mount.accessibility).first { $0.identifier == "question-option-1-1" })
            XCTAssertTrue(selected.selected)
            XCTAssertTrue((try mount.accessibility).first { $0.identifier == "question-submit" }!.enabled)

            model.submitQuestionAnswers()
            XCTAssertEqual(actions(sent()), ["question_submit"])
            try await mount.settle()
        }

        func testMountedPlanCardExposesThreeOwnerDecisions() async throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.handleFrame(proposal(1))
            let mount = SurfaceMount(
                VStack {
                    PlanProposalCard()
                }, model: model, size: CGSize(width: 640, height: 520))
            defer { mount.close() }
            try await mount.settle()

            let elements = try mount.accessibility
            XCTAssertTrue(elements.contains { $0.identifier == "plan-proposal-card" })
            for identifier in ["plan-approve", "plan-revise", "plan-approve-review"] {
                XCTAssertTrue(elements.contains { $0.identifier == identifier }, identifier)
            }
            XCTAssertTrue(elements.contains { $0.label == "Snapshot the database" })
            XCTAssertTrue(elements.contains { $0.label == "db/0042.sql" })

            model.approvePlan()
            XCTAssertEqual(actions(sent()), ["plan_approve"])
            model.handleFrame(planState("execute", status: "approved", version: 1, review: "manual"))
            try await mount.settle()
            XCTAssertTrue((try mount.accessibility).contains { $0.identifier == "plan-status-approved" })
        }
    }
#endif
