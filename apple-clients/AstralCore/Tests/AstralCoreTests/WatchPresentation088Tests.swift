import XCTest

@testable import AstralCore

final class WatchPresentation088Tests: XCTestCase {
    private func fixture() throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONValue.parse(
            Data(
                contentsOf:
                    root.appendingPathComponent("contracts/fixtures/workspace_088/watch_history.json")))
    }

    private func frame(_ state: String) throws -> InboundFrame {
        let payload = try XCTUnwrap(try fixture()["frames"]?[state])
        return InboundFrame(name: "ui_render", payload: payload)
    }

    func testAdvertisedActualDescriptorMatchesRealROTEFixture() throws {
        XCTAssertEqual(
            DeviceDescriptor.watch(viewportWidth: 200, viewportHeight: 240).json,
            try fixture()["device"])
        XCTAssertEqual(ClientDispositions.watch.components["chat_history"], .native)
        XCTAssertEqual(ClientDispositions.watch.components["skeleton"], .native)
        for unsupported in ["table", "file_download", "file_upload", "plotly_chart"] {
            XCTAssertFalse(ClientDispositions.watch.nativeComponentTypes.contains(unsupported))
        }
    }

    func testRealROTEFramesProduceLoadingEnrichedHistoryAndCanonicalEmpty() throws {
        XCTAssertEqual(WatchHistoryUpdate(frame: try frame("loading")), .loading)
        guard case .content(let title, let chats) = WatchHistoryUpdate(frame: try frame("populated")) else {
            return XCTFail("Actual ROTE output must reach the canonical history decoder")
        }
        XCTAssertEqual(title, "Recent chats")
        XCTAssertEqual(chats.map(\.id), (0..<4).map { "watch-fixture-\($0)" })
        XCTAssertEqual(chats[0].title, "Synthetic conversation 0")
        XCTAssertTrue(chats[0].hasSavedComponents)
        XCTAssertEqual(chats[0].icon, "🌤️")
        XCTAssertEqual(chats[0].timeLabel, "just now")
        XCTAssertEqual(chats[1].timeLabel, "2m")
        XCTAssertTrue(chats.allSatisfy { $0.preview.isEmpty })
        XCTAssertEqual(WatchHistoryUpdate(frame: try frame("empty")), .content(title: "Recent chats", chats: []))
    }

    func testConversationScopedHistoryCannotEnterOwnerChrome() throws {
        let original = try XCTUnwrap(try frame("populated").payload.objectValue)
        for key in [
            "chat_id", "chatId", "connection_generation", "request_generation",
            "base_render_revision", "frame_sequence",
        ] {
            for value in [JSONValue.null, .number(1), .string("other-conversation")] {
                var payload = original
                payload[key] = value
                XCTAssertNil(WatchHistoryUpdate(frame: InboundFrame(name: "ui_render", payload: .object(payload))))
            }
        }
        XCTAssertNil(WatchHistoryUpdate(frame: InboundFrame(name: "ui_update", payload: .object(original))))
        var canvas = original
        canvas["target"] = .string("canvas")
        XCTAssertNil(WatchHistoryUpdate(frame: InboundFrame(name: "ui_render", payload: .object(canvas))))
    }

    func testMalformedOrDegradedHistoryDoesNotEraseCanonicalState() {
        for components in [
            JSONValue.null, .array([]),
            .array([
                .object([
                    "type": .string("text"),
                    "content": .string("Degraded"),
                ])
            ]),
            .array([.object(["type": .string("chat_history"), "items": .string("invalid")])]),
        ] {
            XCTAssertNil(
                WatchHistoryUpdate(
                    frame: InboundFrame(
                        name: "ui_render",
                        payload: .object([
                            "target": .string("history"), "components": components,
                        ]))))
        }
        let list: JSONValue = .object([
            "type": .string("chat_history"), "title": .string(""),
            "items": .array([
                .null, .object(["chat_id": .string(" ")]), .object(["chat_id": .string("valid")]),
            ]),
        ])
        let payload: JSONValue = .object([
            "target": .string("history"),
            "components": .array([
                .object(["type": .string("skeleton")]), list,
            ]),
        ])
        guard
            case .content(let title, let chats) = WatchHistoryUpdate(
                frame: InboundFrame(name: "ui_render", payload: payload))
        else {
            return XCTFail("Canonical list must retain existing precedence over a skeleton")
        }
        XCTAssertEqual(title, "Recent chats")
        XCTAssertEqual(chats.map(\.id), ["valid"])
    }

    func testKeyValueHintAndBothDetailedListFieldsRemainPassiveText() throws {
        let keyvalue = try XCTUnwrap(
            AstralComponent(
                json: .object([
                    "type": .string("keyvalue"),
                    "items": .array([
                        .object([
                            "label": .string("State"), "value": .string("Ready"), "hint": .string("After **review**"),
                            "action": .string("hidden-action"),
                        ]), .string("ignored"),
                    ]),
                ])))
        let rows = WatchComponentText.keyValueRows(in: keyvalue)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "State")
        XCTAssertEqual(rows[0].value, "Ready")
        XCTAssertEqual(rows[0].hint, "After **review**")
        let list = try XCTUnwrap(
            AstralComponent(
                json: .object([
                    "type": .string("list"), "variant": .string("detailed"),
                    "items": .array([
                        .object([
                            "title": .string("Evidence"), "subtitle": .string("Today"),
                            "description": .string("Full description"), "payload": .string("not displayed"),
                        ]),
                        .string("Literal item"), .object([:]),
                        .object(["text": .string("Legacy text")]), .object(["label": .string("Legacy label")]),
                    ]),
                ])))
        XCTAssertEqual(
            WatchComponentText.listItems(in: list),
            ["Evidence\nToday\nFull description", "Literal item", "", "Legacy text", "Legacy label"])
        let plain = AstralComponent(type: "list", raw: .object(["items": .array([.string("Plain")])]))
        XCTAssertEqual(WatchComponentText.listItems(in: plain), ["Plain"])
        XCTAssertEqual(
            WatchComponentText.listItems(
                in: AstralComponent(
                    type: "list",
                    raw: .object([
                        "variant": .string("detailed")
                    ]))), [])
        let legacy = AstralComponent(
            type: "keyvalue",
            raw: .object([
                "pairs": .array([
                    .object([
                        "key": .string("Legacy"), "value": .number(2), "hint": .object(["secret": .string("hidden")]),
                    ]),
                    .object([:]),
                ])
            ]))
        let legacyRows = WatchComponentText.keyValueRows(in: legacy)
        XCTAssertEqual(legacyRows[0].label, "Legacy")
        XCTAssertEqual(legacyRows[0].value, "2")
        XCTAssertEqual(legacyRows[0].hint, "")
        XCTAssertEqual(legacyRows[1].label, "")
        XCTAssertEqual(WatchComponentText.keyValueRows(in: plain), [])
    }
}
