// Verifies that chat summaries carry the owner's pinned and archived flags from history_list and history items.

import XCTest

@testable import AstralCore

final class ChatOrganizationTests: XCTestCase {
    func testHistoryListChatsCarryPinnedAndArchivedFlags() throws {
        let pinned = try XCTUnwrap(
            ChatSummary(
                json: .object([
                    "id": .string("c1"), "title": .string("Kept"), "pinned": .bool(true), "archived": .bool(false),
                ])))
        XCTAssertTrue(pinned.pinned)
        XCTAssertFalse(pinned.archived)
        let archived = try XCTUnwrap(
            ChatSummary(json: .object(["id": .string("c2"), "archived": .bool(true)])))
        XCTAssertFalse(archived.pinned)
        XCTAssertTrue(archived.archived)
    }

    func testMissingOrMalformedFlagsReadAsFalse() throws {
        let plain = try XCTUnwrap(ChatSummary(json: .object(["id": .string("c3")])))
        XCTAssertFalse(plain.pinned)
        XCTAssertFalse(plain.archived)
        let malformed = try XCTUnwrap(
            ChatSummary(
                json: .object(["id": .string("c4"), "pinned": .string("true"), "archived": .number(1)])))
        XCTAssertFalse(malformed.pinned)
        XCTAssertFalse(malformed.archived)
    }

    func testHistoryItemsKeepTheirFlags() throws {
        let item = try XCTUnwrap(
            ChatSummary(
                historyItem: .object([
                    "chat_id": .string("c5"), "title": .string("Pinned work"), "pinned": .bool(true),
                    "archived": .bool(true),
                ])))
        XCTAssertEqual(item.id, "c5")
        XCTAssertTrue(item.pinned)
        XCTAssertTrue(item.archived)
    }
}
