import XCTest

@testable import AstralCore

final class ChatHistory088Tests: XCTestCase {
    func testHistoryPreservesPlainPreviewAndStrictSavedFlag() throws {
        let chat = try XCTUnwrap(
            ChatSummary(
                json: .object([
                    "id": .string("one"), "title": .string("New Chat"),
                    "preview": .string("<script>plain text</script>"),
                    "updated_at": .number(1_700_000_000_000), "has_saved_components": .bool(true),
                ])))
        XCTAssertEqual(chat.preview, "<script>plain text</script>")
        XCTAssertTrue(chat.hasSavedComponents)
        XCTAssertEqual(chat.relativeTime(now: Date(timeIntervalSince1970: 1_700_000_120)), "2m")
        let old = try XCTUnwrap(ChatSummary(json: .object(["chat_id": .string("old")])))
        XCTAssertEqual(old.preview, "")
        XCTAssertFalse(old.hasSavedComponents)
        XCTAssertNil(ChatSummary(json: .object([:])))
        let bad = try XCTUnwrap(
            ChatSummary(
                json: .object([
                    "id": .string("bad"), "preview": .object([:]), "has_saved_components": .string("true"),
                ])))
        XCTAssertEqual(bad.preview, "")
        XCTAssertFalse(bad.hasSavedComponents)
    }

    func testCanonicalHistoryKeepsServerEnrichmentAndNormalizesOnlyDisplayWhitespace() throws {
        let chat = try XCTUnwrap(
            ChatSummary(
                historyItem: .object([
                    "chat_id": .string("second"), "title": .string(" \n\t"),
                    "preview": .string("\n\nAlpha = 2\nBeta\t= 5 <b>plain</b>\u{00A0}end "),
                    "time": .string("3w"), "icon": .string("🎲"), "saved": .bool(true),
                ])))
        XCTAssertEqual(chat.id, "second")
        XCTAssertEqual(chat.displayTitle, "Untitled chat")
        XCTAssertEqual(chat.displayPreview, "Alpha = 2 Beta = 5 <b>plain</b>\u{00A0}end")
        XCTAssertTrue(chat.preview.hasPrefix("\n\n"))
        XCTAssertEqual(chat.relativeTime(now: Date.distantFuture), "3w")
        XCTAssertEqual(chat.icon, "🎲")
        XCTAssertTrue(chat.hasSavedComponents)
        for id in [JSONValue.null, .number(1), .object([:]), .string(" \n")] {
            XCTAssertNil(ChatSummary(historyItem: .object(["chat_id": id])))
        }
        let malformed = try XCTUnwrap(
            ChatSummary(
                historyItem: .object([
                    "id": .string("legacy"), "icon": .object([:]), "time": .bool(true),
                    "saved": .string("true"), "preview": .number(3),
                ])))
        XCTAssertEqual(malformed.icon, "")
        XCTAssertEqual(malformed.relativeTime(), "")
        XCTAssertEqual(malformed.displayPreview, "")
        XCTAssertFalse(malformed.hasSavedComponents)
    }

    func testRelativeLabelsMatchWebUnitsAndInvalidDates() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(Double, String)] = [
            (-60, "just now"), (44, "just now"), (120, "2m"), (7200, "2h"),
            (172800, "2d"), (1_209_600, "2w"), (5_259_600, "2mo"), (63_115_200, "2y"),
        ]
        for (age, expected) in cases {
            for scale in [1.0, 1000.0] {
                let chat = try XCTUnwrap(
                    ChatSummary(
                        json: .object([
                            "id": .string("c"),
                            "updated_at": .string(String((now.timeIntervalSince1970 - age) * scale)),
                        ])))
                XCTAssertEqual(chat.relativeTime(now: now), expected)
            }
        }
        for timestamp in ["", "not a timestamp", "NaN", "Infinity", "-1e308"] {
            let chat = try XCTUnwrap(
                ChatSummary(
                    json: .object([
                        "id": .string("c"), "updated_at": .string(timestamp),
                    ])))
            XCTAssertEqual(chat.relativeTime(now: now), "")
        }
    }
}
