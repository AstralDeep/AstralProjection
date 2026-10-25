// Verifies adaptive workbench panes and searches of the server-owned command menu.

import XCTest

@testable import AstralCore

final class MacWorkbenchPresentationTests: XCTestCase {
    func testConversationRetainsAllSpaceUntilThereIsGeneratedWork() {
        let layout = MacWorkbenchLayout.resolve(
            width: 1_200, pane: geometry(split: true), hasCanvas: false, selectedPane: .canvas, expandedCanvas: true)
        XCTAssertTrue(layout.conversationVisible)
        XCTAssertFalse(layout.canvasVisible)
        XCTAssertEqual(layout.conversationWidth, 1_200)
        XCTAssertEqual(layout.canvasWidth, 0)
    }

    func testWideWorkbenchKeepsConversationAndCanvasInteractiveTogether() {
        let layout = MacWorkbenchLayout.resolve(
            width: 1_000, pane: geometry(split: true), hasCanvas: true, selectedPane: .conversation,
            expandedCanvas: false)
        XCTAssertTrue(layout.conversationVisible)
        XCTAssertTrue(layout.canvasVisible)
        XCTAssertEqual(layout.conversationWidth, 430)
        XCTAssertEqual(layout.canvasWidth, 570)
    }

    func testCompactWorkbenchUsesExplicitPaneSelectionWithoutOverflow() {
        for pane in [MacWorkbenchPane.conversation, .canvas] {
            let layout = MacWorkbenchLayout.resolve(
                width: 390, pane: geometry(split: false), hasCanvas: true, selectedPane: pane, expandedCanvas: false)
            XCTAssertEqual(layout.conversationVisible, pane == .conversation)
            XCTAssertEqual(layout.canvasVisible, pane == .canvas)
            XCTAssertEqual(layout.conversationWidth + layout.canvasWidth, 390)
        }
    }

    func testExpandedCanvasUsesAvailableSpaceAndCanReturnToConversation() {
        let expanded = MacWorkbenchLayout.resolve(
            width: 1_000, pane: geometry(split: true), hasCanvas: true, selectedPane: .conversation,
            expandedCanvas: true)
        XCTAssertFalse(expanded.conversationVisible)
        XCTAssertEqual(expanded.canvasWidth, 1_000)
        let restored = MacWorkbenchLayout.resolve(
            width: 1_000, pane: geometry(split: true), hasCanvas: true, selectedPane: .conversation,
            expandedCanvas: false)
        XCTAssertTrue(restored.conversationVisible)
        XCTAssertTrue(restored.canvasVisible)
    }

    func testInvalidGeometryCannotProduceNegativeOrNonfinitePaneSizes() {
        for width in [-1.0, .nan, .infinity, 0] {
            let layout = MacWorkbenchLayout.resolve(
                width: width, pane: geometry(split: true), hasCanvas: true, selectedPane: .canvas, expandedCanvas: false
            )
            XCTAssertEqual(layout.conversationWidth, 0)
            XCTAssertEqual(layout.canvasWidth, 0)
        }
    }

    func testCommandSearchPreservesServerOrderingLabelsParametersAndAvailability() throws {
        let menu = try menu()
        let commands = MacWorkbenchCommand.search(menu: menu, query: "")
        XCTAssertEqual(commands.map(\.item.key), ["profile", "tools", "logs"])
        XCTAssertEqual(commands.map(\.groupLabel), ["Account", "Developer", "Developer"])
        XCTAssertEqual(commands[1].item.params, .object(["view": .string("tools")]))
        XCTAssertEqual(commands[2].item.availability, menu.menu[1].items[1].availability)
        XCTAssertEqual(commands[2].item.label, "Event logs")
    }

    func testCommandSearchMatchesEveryQueryWordAcrossGroupAndLabel() throws {
        let menu = try menu()
        XCTAssertEqual(MacWorkbenchCommand.search(menu: menu, query: "  DÉVELOPER tools ").map(\.item.key), ["tools"])
        XCTAssertEqual(MacWorkbenchCommand.search(menu: menu, query: "event").map(\.item.key), ["logs"])
        XCTAssertTrue(MacWorkbenchCommand.search(menu: menu, query: "missing").isEmpty)
        XCTAssertTrue(MacWorkbenchCommand.search(menu: nil, query: "").isEmpty)
    }

    func testPaneGeometryIsConsumedWithoutDerivingClientBreakpoints() {
        let narrow = MacWorkbenchLayout.resolve(
            width: 500, pane: geometry(split: true, width: 123), hasCanvas: true,
            selectedPane: .conversation, expandedCanvas: false)
        XCTAssertEqual(narrow.conversationWidth, 123)
        XCTAssertEqual(narrow.canvasWidth, 377)
        let wide = MacWorkbenchLayout.resolve(
            width: 2_000, pane: geometry(split: false), hasCanvas: true,
            selectedPane: .canvas, expandedCanvas: false)
        XCTAssertFalse(wide.conversationVisible)
        XCTAssertEqual(wide.canvasWidth, 2_000)
    }

    func testOptionalGeometryRejectsMalformedValuesWithoutDestroyingConsoleFallback() throws {
        let fixture = try JSONValue.parse(
            Data(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("contracts/fixtures/console/mac-workbench.json")))
        let valid = try XCTUnwrap(fixture["cases"]?.arrayValue?.first?["presentation"])
        XCTAssertNotNil(ConsolePresentation(json: valid)?.workbench)
        for bad in [
            JSONValue.null, .string("true"), .object(["version": .number(2)]),
            .object(["version": .number(1), "with_sidebar": .object(["split": .number(1)])]),
        ] {
            var object = try XCTUnwrap(valid.objectValue)
            object["mac_workbench"] = bad
            let fallback = try XCTUnwrap(ConsolePresentation(json: .object(object)))
            XCTAssertNil(fallback.workbench)
        }
    }

    private func geometry(split: Bool, width: Double = 430) -> ConsoleWorkbenchPane {
        ConsoleWorkbenchPane(
            json: .object([
                "split": .bool(split), "conversation_width": .number(width), "compact_toolbar": .bool(false),
            ]))!
    }

    private func menu() throws -> ChromeMenuModel {
        let source: JSONValue = .object([
            "menu": .array([
                .object([
                    "key": .string("account"), "label": .string("Account"),
                    "items": .array([
                        .object(["key": .string("profile"), "label": .string("Profile"), "surface": .string("profile")])
                    ]),
                ]),
                .object([
                    "key": .string("developer"), "label": .string("Developer"),
                    "items": .array([
                        .object([
                            "key": .string("tools"), "label": .string("Tools"), "surface": .string("guidance"),
                            "params": .object(["view": .string("tools")]),
                        ]),
                        .object(["key": .string("logs"), "label": .string("Event logs"), "surface": .string("audit")]),
                    ]),
                ]),
            ])
        ])
        return try XCTUnwrap(ChromeMenuModel.fromJSON(source))
    }
}
