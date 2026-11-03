// Verifies the optional per-message branch snapshot: closed shape, exact sibling bounds, neighbor lookup, and
// fail-closed rejection so unbranched conversations keep parsing byte for byte.

import XCTest

@testable import AstralCore

final class ConversationBranchSnapshotTests: XCTestCase {
    private let turn = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let older = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let newer = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let group = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

    private func branchJSON(
        groupId: String = "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        index: Int = 2,
        count: Int? = nil,
        siblings: [String]? = nil,
        extraField: Bool = false
    ) -> String {
        let members = siblings ?? [older, turn, newer]
        let total = count ?? members.count
        let extra = extraField ? ",\"source\":\"fork\"" : ""
        let quoted = members.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"group_id":"\(groupId)","index":\(index),"count":\(total),"siblings":[\(quoted)]\(extra)}
        """
    }

    private func messageJSON(branch: String?) -> String {
        let field = branch.map { ",\"branch\":\($0)" } ?? ""
        return """
        {"message_id":"\(turn)","role":"user","created_at":"2026-11-03T10:00:00Z","parts":[{"type":"text","text":"Question"}],"attachments":[]\(field)}
        """
    }

    private func decoded(_ json: String) -> ConversationMessage? {
        guard let value = parsedJSON(json) else { return nil }
        return ConversationMessage(json: value)
    }

    private func branch(from json: String) throws -> ConversationMessageBranch {
        try XCTUnwrap(decoded(json)?.branch)
    }

    func testBranchDecodesExactShapeAndNeighbors() throws {
        let value = try branch(from: messageJSON(branch: branchJSON()))

        XCTAssertEqual(value.groupId, group)
        XCTAssertEqual(value.index, 2)
        XCTAssertEqual(value.count, 3)
        XCTAssertEqual(value.siblings, [older, turn, newer])
        XCTAssertEqual(value.neighbor(of: turn, step: -1), older)
        XCTAssertEqual(value.neighbor(of: turn, step: 1), newer)
        XCTAssertNil(value.neighbor(of: older, step: -1))
        XCTAssertNil(value.neighbor(of: newer, step: 1))
        XCTAssertNil(value.neighbor(of: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", step: 1))
    }

    func testMessageWithoutBranchKeepsLegacyShapeAndNilBranch() throws {
        let value = try XCTUnwrap(decoded(messageJSON(branch: nil)))

        XCTAssertEqual(value.visibleText, "Question")
        XCTAssertNil(value.branch)
    }

    func testSingleSiblingBranchIsAccepted() throws {
        let value = try branch(from: messageJSON(branch: branchJSON(index: 1, siblings: [turn])))

        XCTAssertEqual(value.count, 1)
        XCTAssertEqual(value.index, 1)
        XCTAssertNil(value.neighbor(of: turn, step: -1))
        XCTAssertNil(value.neighbor(of: turn, step: 1))
    }

    func testMaximumSiblingCountIsAcceptedAndBeyondIsRejected() throws {
        let members = (0..<50).map { String(format: "%08x-a111-4111-8111-111111111111", $0) }
        XCTAssertNotNil(decoded(messageJSON(branch: branchJSON(index: 17, siblings: members))))
        let overflow = members + ["ffffffff-ffff-4fff-8fff-ffffffffffff"]
        XCTAssertNil(decoded(messageJSON(branch: branchJSON(index: 1, siblings: overflow))))
    }

    func testMalformedBranchesAreRejectedAtomically() {
        let invalid: [String] = [
            branchJSON(extraField: true),
            branchJSON(groupId: "not-a-uuid"),
            branchJSON(groupId: group.uppercased()),
            branchJSON(index: 0),
            branchJSON(index: 4),
            branchJSON(index: -1),
            branchJSON(count: 4),
            branchJSON(count: 2),
            branchJSON(siblings: []),
            branchJSON(siblings: [older, turn, turn]),
            branchJSON(siblings: [older, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"]),
            branchJSON(siblings: [older, turn, newer], extraField: true),
            "{\"group_id\":\"\(group)\",\"index\":2,\"siblings\":[\"\(older)\",\"\(turn)\",\"\(newer)\"]}",
            "null",
            "[1,2,3]",
            "{\"group_id\":\"\(group)\",\"index\":2.5,\"count\":3,\"siblings\":[\"\(older)\",\"\(turn)\",\"\(newer)\"]}",
            "{\"message_id\":\"\(turn)\",\"role\":\"user\",\"created_at\":\"2026-11-03T10:00:00Z\",\"parts\":[{\"type\":\"text\",\"text\":\"Question\"}],\"attachments\":[],\"branch\":\(branchJSON()),\"extra\":true}",
        ]
        for candidate in invalid {
            XCTAssertNil(decoded(messageJSON(branch: candidate)), candidate)
        }
    }

    func testSnapshotTranscriptCarriesBranchesIntoMessages() throws {
        let transcript = """
        [
          {"message_id":"\(older)","role":"user","created_at":"2026-11-03T09:59:00Z","parts":[{"type":"text","text":"Older"}],"attachments":[]},
          {"message_id":"\(turn)","role":"user","created_at":"2026-11-03T10:00:00Z","parts":[{"type":"text","text":"Question"}],"attachments":[],"branch":\(branchJSON())}
        ]
        """
        let frame = try XCTUnwrap(InboundFrame.parse(
            """
            {"type":"conversation_snapshot","schema_version":1,
             "snapshot_id":"55555555-5555-4555-8555-555555555555",
             "chat_id":"11111111-1111-4111-8111-111111111111",
             "connection_generation":"22222222-2222-4222-8222-222222222222",
             "request_generation":"33333333-3333-4333-8333-333333333333",
             "snapshot_purpose":"hydration","render_revision":0,
             "committed_at":"2026-11-03T10:01:00Z",
             "transcript":\(transcript),
             "canvas":{"target":"canvas","components":[]}}
            """))
        let snapshot = try XCTUnwrap(ConversationSnapshot(frame: frame))

        XCTAssertNil(snapshot.messages[0].branch)
        XCTAssertEqual(snapshot.messages[1].branch?.groupId, group)
        XCTAssertEqual(snapshot.messages[1].branch?.index, 2)
        XCTAssertEqual(snapshot.messages[1].branch?.count, 3)
    }
}

private func parsedJSON(_ text: String) -> JSONValue? {
    try? JSONValue.parse(Data(text.utf8))
}
