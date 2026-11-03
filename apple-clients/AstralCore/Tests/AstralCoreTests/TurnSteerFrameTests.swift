// Tests for the turn_steer_v1 wire layer: the rote_config capability acknowledgement, decoding of
// the chat_steer/chat_queue/side_question server frames with their exact-field and bounds rules,
// and the client action builders' stable client_message_id and owner-text validation.

import XCTest

@testable import AstralCore

final class TurnSteerFrameTests: XCTestCase {
    private let chatId = "11111111-1111-4111-8111-111111111111"
    private let queueId = "44444444-4444-4444-8444-444444444444"
    private let messageId = "55555555-5555-4555-8555-555555555555"

    private func frame(_ json: String) throws -> InboundFrame {
        try XCTUnwrap(InboundFrame.parse(json))
    }

    private func frameWithPayload(_ payload: [String: JSONValue]) throws -> InboundFrame {
        var fields = payload
        fields["type"] = .string(fields["type"]?.stringValue ?? "")
        let data = try JSONEncoder().encode(JSONValue.object(fields))
        return try XCTUnwrap(InboundFrame.parse(String(data: data, encoding: .utf8)!))
    }

    private func acknowledgement(_ console: String) -> TurnSteerAcknowledgement? {
        TurnSteerAcknowledgement.fromRoteConfig(
            try! JSONValue.parse(Data("""
            {"device_profile":{"console":{"turn_steer":\(console)}}}
            """.utf8)))
    }

    func testAcknowledgementAcceptsTheExactContractShape() {
        XCTAssertEqual(
            acknowledgement(#"{"version":1,"queue_capable":true}"#),
            TurnSteerAcknowledgement(queueCapable: true))
        XCTAssertEqual(
            acknowledgement(#"{"version":1,"queue_capable":false}"#),
            TurnSteerAcknowledgement(queueCapable: false))
    }

    func testAcknowledgementRefusesUnknownShapesAndVersions() {
        XCTAssertNil(acknowledgement(#"{"version":2,"queue_capable":true}"#))
        XCTAssertNil(acknowledgement(#"{"version":1,"queue_capable":"yes"}"#))
        XCTAssertNil(acknowledgement(#"{"version":1,"queue_capable":true,"extra":1}"#))
        XCTAssertNil(acknowledgement(#"{"queue_capable":true}"#))
        XCTAssertNil(TurnSteerAcknowledgement.fromRoteConfig(.null))
    }

    func testAcknowledgementIsAbsentWithoutTheDeviceProfileKey() {
        let payload = try! JSONValue.parse(
            Data(
                """
                {"device_profile":{"console":{"project_workspaces":
                    {"version":1,"mode":"projects_only"}}}}
                """.utf8))
        XCTAssertNil(TurnSteerAcknowledgement.fromRoteConfig(payload))
    }

    func testChatSteerRecordedDecodesSkippedCalls() throws {
        let recorded = try XCTUnwrap(
            ChatSteerRecorded(
                frame: try frame(
                    """
                    {"type":"chat_steer_recorded","chat_id":"\(chatId)","client_message_id":"\(messageId)",
                     "skipped_calls":[{"name":"read_file","reason":"superseded by the steer"}]}
                    """)))
        XCTAssertEqual(recorded.chatId, chatId)
        XCTAssertEqual(recorded.clientMessageId, messageId)
        XCTAssertEqual(
            recorded.skippedCalls,
            [SkippedToolCall(name: "read_file", reason: "superseded by the steer")])

        XCTAssertNil(
            ChatSteerRecorded(
                frame: try frame(
                    """
                    {"type":"chat_steer_recorded","client_message_id":"\(messageId)",
                     "skipped_calls":[{"name":"read_file"}]}
                    """)))
        let overflowing = ChatSteerRecorded(
            frame: try frameWithPayload([
                "type": .string("chat_steer_recorded"),
                "client_message_id": .string(messageId),
                "skipped_calls": .array(
                    Array(repeating: .object(["name": .string("n"), "reason": .string("r")]), count: 51)),
            ]))
        XCTAssertNil(overflowing)
    }

    func testChatSteerRefusedDecodesOnlyContractCodes() throws {
        let refused = try XCTUnwrap(
            ChatSteerRefused(
                frame: try frame(
                    """
                    {"type":"chat_steer_refused","chat_id":"\(chatId)","client_message_id":"\(messageId)",
                     "code":"stale_turn","message":"The turn already moved past this step."}
                    """)))
        XCTAssertEqual(refused.code, .staleTurn)
        XCTAssertEqual(refused.clientMessageId, messageId)

        XCTAssertNil(
            ChatSteerRefused(
                frame: try frame(
                    """
                    {"type":"chat_steer_refused","client_message_id":"\(messageId)",
                     "code":"mystery","message":"unknown"}
                    """)))
        XCTAssertNil(
            ChatSteerRefused(
                frame: try frame(
                    """
                    {"type":"chat_steer_refused","client_message_id":"\(messageId)",
                     "code":"not_running","message":""}
                    """)))
    }

    func testChatQueueUpdatedHydratesTheWholeSnapshot() throws {
        let updated = try XCTUnwrap(
            ChatQueueUpdated(
                frame: try frame(
                    """
                    {"type":"chat_queue_updated","chat_id":"\(chatId)","revision":3,
                     "items":[{"queue_id":"\(queueId)","message":"Deploy the fix","revision":2}]}
                    """)))
        XCTAssertEqual(updated.revision, 3)
        XCTAssertEqual(updated.items.count, 1)
        XCTAssertEqual(updated.items[0].id, queueId)
        XCTAssertEqual(updated.items[0].message, "Deploy the fix")
        XCTAssertEqual(updated.items[0].revision, 2)

        XCTAssertNil(
            ChatQueueUpdated(
                frame: try frame(
                    """
                    {"type":"chat_queue_updated","chat_id":"\(chatId)","revision":3,
                     "items":[{"queue_id":"\(queueId)","message":"Deploy the fix","revision":0}]}
                    """)))
        XCTAssertNil(
            ChatQueueUpdated(
                frame: try frame(
                    """
                    {"type":"chat_queue_updated","chat_id":"\(chatId)","revision":3,
                     "items":[{"queue_id":"not-a-uuid","message":"Deploy","revision":1}]}
                    """)))
        let crowded = ChatQueueUpdated(
            frame: try frameWithPayload([
                "type": .string("chat_queue_updated"),
                "chat_id": .string(chatId),
                "revision": .number(3),
                "items": .array(
                    Array(
                        repeating: .object(
                            ["queue_id": .string(queueId), "message": .string("m"), "revision": .number(1)]),
                        count: 17)),
            ]))
        XCTAssertNil(crowded)
    }

    func testSideQuestionResultRequiresExactFields() throws {
        let result = try XCTUnwrap(
            SideQuestionResult(
                frame: try frame(
                    """
                    {"type":"side_question_result","client_message_id":"\(messageId)","answer":"Linting passes."}
                    """)))
        XCTAssertEqual(result.answer, "Linting passes.")
        XCTAssertNil(
            SideQuestionResult(
                frame: try frame(
                    """
                    {"type":"side_question_result","client_message_id":"\(messageId)",
                     "answer":"x","chat_id":"\(chatId)"}
                    """)))
        XCTAssertNil(
            SideQuestionResult(
                frame: try frame(
                    #"{"type":"side_question_result","client_message_id":"\#(messageId)","answer":""}"#)))
    }

    private func parse(_ wire: String) throws -> JSONValue {
        try XCTUnwrap(try? JSONValue.parse(Data(wire.utf8)))
    }

    func testClientActionsCarrySubmissionEnvelopeAndStableClientMessageId() throws {
        let submission = "66666666-6666-4666-8666-666666666666"
        let request = "77777777-7777-4777-8777-777777777777"
        let steer = try XCTUnwrap(
            TurnSteerOutbound.chatSteer(
                "  skip the screenshot  ", sessionId: chatId,
                submissionId: submission, requestGeneration: request))
        let decoded = try parse(steer)
        XCTAssertEqual(decoded["type"], .string("ui_event"))
        XCTAssertEqual(decoded["action"], .string("chat_steer"))
        XCTAssertEqual(decoded["payload"]?["message"], .string("skip the screenshot"))
        let clientMessageId = try XCTUnwrap(decoded["payload"]?["client_message_id"]?.stringValue)
        XCTAssertEqual(continuityUUID4(clientMessageId), clientMessageId)
        XCTAssertEqual(decoded["submission_id"], .string(submission))
        XCTAssertEqual(decoded["request_generation"], .string(request))

        let again = try XCTUnwrap(
            TurnSteerOutbound.chatSteer(
                "skip the screenshot", sessionId: chatId,
                submissionId: submission, requestGeneration: request))
        XCTAssertNotEqual(
            try parse(again)["payload"]?["client_message_id"]?.stringValue, clientMessageId)
    }

    func testClientActionsValidateOwnerTextAndIdentifiers() {
        XCTAssertNil(TurnSteerOutbound.chatSteer("   ", sessionId: chatId))
        XCTAssertNil(TurnSteerOutbound.chatQueuePut(String(repeating: "x", count: 20_001), sessionId: chatId))
        XCTAssertNil(TurnSteerOutbound.chatQueueEdit("m", queueId: "bogus", expectedRevision: 1, sessionId: chatId))
        XCTAssertNil(TurnSteerOutbound.chatQueueEdit("m", queueId: queueId, expectedRevision: 0, sessionId: chatId))
        XCTAssertNil(TurnSteerOutbound.chatQueueRemove(queueId: "bogus", sessionId: chatId))
        XCTAssertNil(TurnSteerOutbound.chatQueueMove(queueId: queueId, beforeQueueId: "bogus", sessionId: chatId))
        XCTAssertNil(TurnSteerOutbound.sideQuestion("", sessionId: chatId))
    }

    func testQueueMoveEncodesNullableBeforeId() throws {
        let move = try XCTUnwrap(
            TurnSteerOutbound.chatQueueMove(queueId: queueId, beforeQueueId: nil, sessionId: chatId))
        XCTAssertEqual(try parse(move)["payload"]?["before_queue_id"], .null)

        let before = "88888888-8888-4888-8888-888888888888"
        let ordered = try XCTUnwrap(
            TurnSteerOutbound.chatQueueMove(queueId: queueId, beforeQueueId: before, sessionId: chatId))
        XCTAssertEqual(try parse(ordered)["payload"]?["before_queue_id"], .string(before))
    }

    func testQueuedFollowUpItemRoundTripsThroughJSON() throws {
        let item = try XCTUnwrap(
            QueuedFollowUpItem(
                json: try parse(
                    #"{"queue_id":"\#(queueId)","message":"Run the lint pass","revision":4}"#)))
        XCTAssertEqual(item, QueuedFollowUpItem(json: item.json))
        XCTAssertEqual(item.revision, 4)
    }
}
