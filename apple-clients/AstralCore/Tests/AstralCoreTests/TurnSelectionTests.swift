// Verifies revision selection bounds and exact outbound forwarding without retaining conversation state.
// Empty selections clear the picker but never enter an ordinary Work request.

import XCTest

@testable import AstralCore

final class TurnSelectionTests: XCTestCase {
    private let identity = "11111111-1111-4111-8111-111111111111"
    private let revision = "22222222-2222-4222-8222-222222222222"

    private var selection: [String: JSONValue] {
        [
            "version": .number(1),
            "agent": .object(["agent_id": .string("literature_scout"), "revision_id": .string(revision)]),
            "skills": .array([.object(["skill_id": .string(identity), "revision": .number(4)])]),
            "notes": .array([.object(["note_id": .string(identity), "revision": .number(9)])]),
        ]
    }

    func testTypedSelectionPreservesExactReferencesAndCurrentSend() throws {
        let raw = JSONValue.object(selection)
        let value = try XCTUnwrap(TurnSelection(json: raw))
        XCTAssertEqual(value.version, 1)
        XCTAssertEqual(value.agent?.agentId, "literature_scout")
        XCTAssertEqual(value.agent?.revisionId, revision)
        XCTAssertEqual(value.skills.first?.id, identity)
        XCTAssertEqual(value.skills.first?.revision, 4)
        XCTAssertEqual(value.notes.first?.id, identity)
        XCTAssertEqual(value.notes.first?.revision, 9)
        XCTAssertFalse(value.isEmpty)
        XCTAssertEqual(value.json, raw)
        XCTAssertEqual(value, TurnSelection(json: raw))
        let wire = try JSONValue.parse(Data(Outbound.chatMessage("hello", sessionId: "chat", selection: value).utf8))
        XCTAssertEqual(wire["payload"]?["selection"], raw)
        XCTAssertEqual(wire["payload"]?["message"], .string("hello"))
        XCTAssertEqual(wire["action"], .string("chat_message"))
        XCTAssertEqual(wire["session_id"], .string("chat"))
        XCTAssertEqual(wire["payload"]?["snapshot_purpose"], .string("commit"))
    }

    func testEmptyAndAbsentSelectionKeepLegacyMessagePayload() throws {
        XCTAssertTrue(TurnSelection.empty.isEmpty)
        XCTAssertNil(TurnSelection.empty.agent)
        XCTAssertEqual(TurnSelection.empty.skills, [])
        XCTAssertEqual(TurnSelection.empty.notes, [])
        for value in [TurnSelection?.none, .some(.empty)] {
            let wire = try JSONValue.parse(Data(Outbound.chatMessage("hello", sessionId: nil, selection: value).utf8))
            XCTAssertNil(wire["payload"]?["selection"])
        }
        XCTAssertFalse(try XCTUnwrap(TurnSelection(json: .object(selection))).isEmpty)
        XCTAssertTrue(TurnSelection.empty.isEmpty)
    }

    func testClosedShapeUnknownVersionsAndMalformedAgentAreRejected() {
        XCTAssertNil(TurnSelection(json: nil))
        XCTAssertNil(TurnSelection(json: .array([])))
        for key in selection.keys {
            var invalid = selection
            invalid.removeValue(forKey: key)
            XCTAssertNil(TurnSelection(json: .object(invalid)))
        }
        for version in [JSONValue.number(2), .number(1.5), .bool(true), .null] {
            var invalid = selection
            invalid["version"] = version
            XCTAssertNil(TurnSelection(json: .object(invalid)))
        }
        var extra = selection
        extra["owner"] = .string("other")
        XCTAssertNil(TurnSelection(json: .object(extra)))
        var agents: [JSONValue] = [.array([]), .object([:])]
        for bad in [
            JSONValue.string(""), .string(" agent "), .string("a\0b"), .string(String(repeating: "a", count: 256)),
            .number(1),
        ] {
            agents.append(.object(["agent_id": bad, "revision_id": .string(revision)]))
        }
        for bad in [JSONValue.string("not-a-uuid"), .string("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"), .null] {
            agents.append(.object(["agent_id": .string("agent"), "revision_id": bad]))
        }
        agents.append(.object(["agent_id": .string("agent"), "revision_id": .string(revision), "extra": .bool(true)]))
        for agent in agents {
            var invalid = selection
            invalid["agent"] = agent
            XCTAssertNil(TurnSelection(json: .object(invalid)))
        }
    }

    func testReferenceCountsDuplicatesIdentitiesAndRevisionBounds() throws {
        for (kind, key, maximum) in [("skills", "skill_id", 20), ("notes", "note_id", 8)] {
            let rows: [JSONValue] = (0..<maximum).map { index in
                .object([
                    key: .string(String(format: "%08x-1111-4111-8111-111111111111", index)), "revision": .number(1),
                ])
            }
            var raw = selection
            raw[kind] = .array(rows)
            XCTAssertNotNil(TurnSelection(json: .object(raw)))
            for entries in [JSONValue.null, .array(rows + [rows[0]]), .array([rows[0], rows[0]])] {
                raw[kind] = entries
                XCTAssertNil(TurnSelection(json: .object(raw)))
            }
            var badRows: [JSONValue] = [
                .null, .object([:]), .object([key: .string(identity), "revision": .number(1), "extra": .null]),
            ]
            for bad in [
                JSONValue.number(0), .number(-1), .number(1.5), .number(9_007_199_254_740_992), .number(.infinity),
                .bool(true),
            ] {
                badRows.append(.object([key: .string(identity), "revision": bad]))
            }
            badRows.append(.object([key: .string("bad"), "revision": .number(1)]))
            for row in badRows {
                raw[kind] = .array([row])
                XCTAssertNil(TurnSelection(json: .object(raw)))
            }
            raw[kind] = .array([.object([key: .string(identity), "revision": .number(9_007_199_254_740_991)])])
            XCTAssertNotNil(TurnSelection(json: .object(raw)))
        }
        var raw = selection
        raw["agent"] = .null
        XCTAssertNil(try XCTUnwrap(TurnSelection(json: .object(raw))).agent)
        XCTAssertFalse(try XCTUnwrap(TurnSelection(json: .object(raw))).isEmpty)
    }
}
