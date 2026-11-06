// Tests the plan_interaction_v1 decoders and builders against the presentation contract: strict frame
// validation, closed dispositions and codes, bounded payloads, and stable owner action envelopes.

import XCTest

@testable import AstralCore

final class PlanInteractionTests: XCTestCase {
    private let chatId = "33333333-3333-4333-8333-333333333333"
    private let planId = "55555555-5555-4555-8555-555555555555"
    private let questionId = "66666666-6666-4666-8666-666666666666"
    private let promptId = "77777777-7777-4777-8777-777777777777"

    private func frame(_ name: String, _ payload: String) -> InboundFrame {
        InboundFrame.parse(#"{"type":"\#(name)",\#(payload)}"#)!
    }

    func testAcknowledgementRequiresExactVersionOne() {
        let ack = PlanInteractionAcknowledgement.fromRoteConfig(
            InboundFrame.parse(
                #"{"type":"rote_config","device_profile":{"console":{"plan_interaction":{"version":1}}}}"#
            )!.payload)
        XCTAssertNotNil(ack)
        XCTAssertNil(
            PlanInteractionAcknowledgement.fromRoteConfig(
                InboundFrame.parse(
                    #"{"type":"rote_config","device_profile":{"console":{"plan_interaction":{"version":2}}}}"#
                )!.payload))
        XCTAssertNil(
            PlanInteractionAcknowledgement.fromRoteConfig(
                InboundFrame.parse(
                    #"{"type":"rote_config","device_profile":{"console":{"plan_interaction":{"version":1,"queue_capable":true}}}}"#
                )!.payload))
        XCTAssertNil(
            PlanInteractionAcknowledgement.fromRoteConfig(
                InboundFrame.parse(#"{"type":"rote_config","device_profile":{"console":{}}}"#)!.payload))
    }

    func testPlanModeStateDecodesClosedVocabularyAndVersion() {
        let state = PlanModeState(
            frame: frame(
                "plan_mode_state",
                "\"chat_id\":\"\(chatId)\",\"mode\":\"plan\",\"plan_status\":\"proposed\",\"plan_version\":3,\"review\":\"manual\""))
        XCTAssertEqual(state?.chatId, chatId)
        XCTAssertEqual(state?.mode, .plan)
        XCTAssertEqual(state?.status, .proposed)
        XCTAssertEqual(state?.planVersion, 3)
        XCTAssertEqual(state?.review, .manual)

        XCTAssertNil(
            PlanModeState(
                frame: frame(
                    "plan_mode_state",
                    "\"chat_id\":\"\(chatId)\",\"mode\":\"paused\",\"plan_status\":\"proposed\",\"plan_version\":1,\"review\":\"auto\"")))
        XCTAssertNil(
            PlanModeState(
                frame: frame(
                    "plan_mode_state",
                    "\"chat_id\":\"\(chatId)\",\"mode\":\"plan\",\"plan_status\":\"proposed\",\"plan_version\":0,\"review\":\"auto\"")))
        XCTAssertNil(
            PlanModeState(
                frame: frame(
                    "plan_mode_state",
                    "\"chat_id\":\"\(chatId)\",\"mode\":\"plan\",\"plan_status\":\"proposed\",\"plan_version\":null,\"review\":\"server_decides\"")))
        XCTAssertNil(
            PlanModeState(
                frame: frame(
                    "plan_mode_state",
                    "\"chat_id\":\"\(chatId)\",\"mode\":\"plan\",\"plan_status\":\"proposed\",\"review\":\"auto\"")))
    }

    func testPlanProposalValidatesBoundsAndLists() {
        let proposal = PlanProposal(
            frame: frame(
                "plan_proposal",
                "\"chat_id\":\"\(chatId)\",\"plan_id\":\"\(planId)\",\"version\":1,"
                    + "\"steps\":[\"Snapshot the database\"],\"assumptions\":[],\"files\":[\"db/0042.sql\"],\"apps\":[\"pgAdmin\"]"))
        XCTAssertEqual(proposal?.planId, planId)
        XCTAssertEqual(proposal?.version, 1)
        XCTAssertEqual(proposal?.steps, ["Snapshot the database"])
        XCTAssertEqual(proposal?.files, ["db/0042.sql"])

        XCTAssertNil(
            PlanProposal(
                frame: frame(
                    "plan_proposal",
                    "\"chat_id\":\"\(chatId)\",\"plan_id\":\"\(planId)\",\"version\":1,"
                        + "\"steps\":[],\"assumptions\":[],\"files\":[],\"apps\":[]")))
        XCTAssertNil(
            PlanProposal(
                frame: frame(
                    "plan_proposal",
                    "\"chat_id\":\"\(chatId)\",\"plan_id\":\"not-a-uuid\",\"version\":1,"
                        + "\"steps\":[\"Snapshot\"],\"assumptions\":[],\"files\":[],\"apps\":[]")))
        var oversized = "[" + (0..<51).map { _ in "\"step\"" }.joined(separator: ",") + "]"
        XCTAssertNil(
            PlanProposal(
                frame: frame(
                    "plan_proposal",
                    "\"chat_id\":\"\(chatId)\",\"plan_id\":\"\(planId)\",\"version\":1,"
                        + "\"steps\":\(oversized),\"assumptions\":[],\"files\":[],\"apps\":[]")))
        oversized = "[" + (0..<101).map { _ in "\"file\"" }.joined(separator: ",") + "]"
        XCTAssertNil(
            PlanProposal(
                frame: frame(
                    "plan_proposal",
                    "\"chat_id\":\"\(chatId)\",\"plan_id\":\"\(planId)\",\"version\":1,"
                        + "\"steps\":[\"Snapshot\"],\"assumptions\":[],\"files\":\(oversized),\"apps\":[]")))
    }

    func testPlanModeNoticePinsClosedCodes() {
        let notice = PlanModeNotice(
            frame: frame(
                "plan_mode_notice",
                "\"chat_id\":\"\(chatId)\",\"code\":\"plan_mode_active\",\"message\":\"Approve the plan first.\""))
        XCTAssertEqual(notice?.code, .planModeActive)
        XCTAssertEqual(notice?.message, "Approve the plan first.")
        for code in ["plan_not_approved", "plan_stale", "invalid_input"] {
            XCTAssertNotNil(
                PlanModeNotice(
                    frame: frame(
                        "plan_mode_notice", "\"chat_id\":\"\(chatId)\",\"code\":\"\(code)\",\"message\":\"m\"")))
        }
        XCTAssertNil(
            PlanModeNotice(
                frame: frame(
                    "plan_mode_notice", "\"chat_id\":\"\(chatId)\",\"code\":\"exploded\",\"message\":\"m\"")))
    }

    func testQuestionRequestBoundsPromptsOptionsAndTimeout() {
        let request = QuestionRequest(
            frame: frame(
                "question_request",
                "\"chat_id\":\"\(chatId)\",\"question_id\":\"\(questionId)\","
                    + "\"questions\":[{\"id\":\"\(promptId)\",\"prompt\":\"Which cluster?\",\"options\":[\"A\",\"B\"]}],"
                    + "\"timeout_ms\":120000"))
        XCTAssertEqual(request?.questionId, questionId)
        XCTAssertEqual(request?.prompts.count, 1)
        XCTAssertEqual(request?.prompts.first?.options, ["A", "B"])
        XCTAssertEqual(request?.timeoutMs, 120_000)

        XCTAssertNil(
            QuestionRequest(
                frame: frame(
                    "question_request",
                    "\"chat_id\":\"\(chatId)\",\"question_id\":\"\(questionId)\","
                        + "\"questions\":[],\"timeout_ms\":120000")))
        let three = (0..<3).map { _ in
            "{\"id\":\"\(promptId)\",\"prompt\":\"p\",\"options\":[]}"
        }.joined(separator: ",")
        XCTAssertNotNil(
            QuestionRequest(
                frame: frame(
                    "question_request",
                    "\"chat_id\":\"\(chatId)\",\"question_id\":\"\(questionId)\",\"questions\":[\(three)],\"timeout_ms\":120000")))
        let four = (0..<4).map { _ in
            "{\"id\":\"\(promptId)\",\"prompt\":\"p\",\"options\":[]}"
        }.joined(separator: ",")
        XCTAssertNil(
            QuestionRequest(
                frame: frame(
                    "question_request",
                    "\"chat_id\":\"\(chatId)\",\"question_id\":\"\(questionId)\",\"questions\":[\(four)],\"timeout_ms\":120000")))
        XCTAssertNil(
            QuestionRequest(
                frame: frame(
                    "question_request",
                    "\"chat_id\":\"\(chatId)\",\"question_id\":\"\(questionId)\","
                        + "\"questions\":[{\"id\":\"\(promptId)\",\"prompt\":\"Which cluster?\",\"options\":[\"A\",\"B\"]}],"
                        + "\"timeout_ms\":999")))
        XCTAssertNil(
            QuestionRequest(
                frame: frame(
                    "question_request",
                    "\"chat_id\":\"\(chatId)\",\"question_id\":\"\(questionId)\","
                        + "\"questions\":[{\"id\":\"\(promptId)\",\"prompt\":\"Which cluster?\",\"options\":[\"A\",\"B\",\"C\",\"D\",\"E\",\"F\",\"G\",\"H\",\"I\"]}],"
                        + "\"timeout_ms\":120000")))
    }

    func testQuestionResolutionPinsDispositions() {
        for disposition in ["answered", "skipped", "timed_out", "superseded"] {
            XCTAssertNotNil(
                QuestionResolution(
                    frame: frame(
                        "question_resolved",
                        "\"chat_id\":\"\(chatId)\",\"question_id\":\"\(questionId)\",\"disposition\":\"\(disposition)\"")))
        }
        XCTAssertNil(
            QuestionResolution(
                frame: frame(
                    "question_resolved",
                    "\"chat_id\":\"\(chatId)\",\"question_id\":\"\(questionId)\",\"disposition\":\"rejected\"")))
        XCTAssertEqual(
            QuestionResolution(
                frame: frame(
                    "question_resolved",
                    "\"chat_id\":\"\(chatId)\",\"question_id\":\"\(questionId)\",\"disposition\":\"timed_out\""))?
                .disposition,
            .timedOut)
    }

    func testOutboundActionsCarryStableClientMessageIdAndExactFields() throws {
        let sessionId = chatId
        let modeSet = try JSONValue.parse(
            Data(PlanInteractionOutbound.planModeSet(enabled: true, sessionId: sessionId).utf8))
        XCTAssertEqual(modeSet["action"], .string("plan_mode_set"))
        XCTAssertEqual(modeSet["payload"]?["enabled"], .bool(true))
        XCTAssertNotNil(continuityUUID4(modeSet["payload"]?["client_message_id"]?.stringValue))
        XCTAssertNotNil(continuityUUID4(modeSet["submission_id"]?.stringValue))
        XCTAssertNotNil(continuityUUID4(modeSet["request_generation"]?.stringValue))
        XCTAssertEqual(modeSet["session_id"], .string(sessionId))

        let approve = try JSONValue.parse(
            Data(PlanInteractionOutbound.planApprove(planId: planId, version: 2, sessionId: sessionId)!.utf8))
        XCTAssertEqual(approve["action"], .string("plan_approve"))
        XCTAssertEqual(approve["payload"]?["plan_id"], .string(planId))
        XCTAssertEqual(approve["payload"]?["version"], .number(2))

        let review = try JSONValue.parse(
            Data(PlanInteractionOutbound.planApproveReview(planId: planId, version: 2, sessionId: sessionId)!.utf8))
        XCTAssertEqual(review["action"], .string("plan_approve_review"))

        let revise = try JSONValue.parse(
            Data(
                PlanInteractionOutbound.planRevise(
                    planId: planId, version: 2, feedback: "  Move the rollback earlier  ",
                    sessionId: sessionId)!.utf8))
        XCTAssertEqual(revise["action"], .string("plan_revise"))
        XCTAssertEqual(revise["payload"]?["feedback"], .string("Move the rollback earlier"))

        let submit = try JSONValue.parse(
            Data(
                PlanInteractionOutbound.questionSubmit(
                    questionId: questionId, answers: [promptId: "Cluster A"], sessionId: sessionId)!.utf8))
        XCTAssertEqual(submit["action"], .string("question_submit"))
        XCTAssertEqual(submit["payload"]?["answers"]?[promptId], .string("Cluster A"))

        let skip = try JSONValue.parse(
            Data(PlanInteractionOutbound.questionSkip(questionId: questionId, sessionId: sessionId)!.utf8))
        XCTAssertEqual(skip["action"], .string("question_skip"))
        XCTAssertEqual(skip["payload"]?["question_id"], .string(questionId))
    }

    func testOutboundRefusesMalformedOwnerInput() {
        XCTAssertNil(PlanInteractionOutbound.planApprove(planId: "stale", version: 1, sessionId: nil))
        XCTAssertNil(PlanInteractionOutbound.planApprove(planId: planId, version: 0, sessionId: nil))
        XCTAssertNil(PlanInteractionOutbound.planRevise(planId: planId, version: 1, feedback: "   ", sessionId: nil))
        XCTAssertNil(
            PlanInteractionOutbound.planRevise(
                planId: planId, version: 1, feedback: String(repeating: "x", count: 20_001), sessionId: nil))
        XCTAssertNil(PlanInteractionOutbound.questionSubmit(questionId: "stale", answers: ["x": "a"], sessionId: nil))
        XCTAssertNil(
            PlanInteractionOutbound.questionSubmit(questionId: questionId, answers: [promptId: "  "], sessionId: nil))
        XCTAssertNil(
            PlanInteractionOutbound.questionSubmit(
                questionId: questionId, answers: [promptId: String(repeating: "x", count: 2_001)], sessionId: nil))
        XCTAssertNil(PlanInteractionOutbound.questionSkip(questionId: "stale", sessionId: nil))
    }
}
