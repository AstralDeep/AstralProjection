// Qualifies optional watch availability and the bounded console introduction request vocabulary.
// Malformed additions cannot turn a handoff into a native action or bypass notes and Work gates.

import XCTest

@testable import AstralCore

final class ConsoleWatchContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/console/\(name).json")))
    }

    func testClosedAvailabilityVariantsAndMalformedAdditions() throws {
        let native = JSONValue.object(["mode": .string("native")])
        let handoff = JSONValue.object([
            "mode": .string("handoff"), "message": .string("Continue on your phone or desktop."),
        ])
        XCTAssertEqual(ChromeAvailability(json: native)?.mode, .native)
        XCTAssertNil(ChromeAvailability(json: native)?.message)
        XCTAssertEqual(ChromeAvailability(json: handoff)?.mode, .handoff)
        XCTAssertEqual(ChromeAvailability(json: handoff)?.message, "Continue on your phone or desktop.")
        for raw in [
            JSONValue.null, .array([]), .object([:]), .object(["mode": .number(1)]),
            .object(["mode": .string("future")]), .object(["mode": .string("handoff")]),
            .object(["mode": .string("native"), "message": .string("unexpected")]),
            .object(["mode": .string("handoff"), "message": .string(" ")]),
            .object(["mode": .string("handoff"), "message": .string(String(repeating: "x", count: 501))]),
            .object(["mode": .string("handoff"), "message": .string("\0")]),
        ] { XCTAssertNil(ChromeAvailability(json: raw)) }
        let original = try fixture("chrome-console").objectValue!
        for availability in [native, handoff, .string("invalid")] {
            var root = original
            var console = root["console"]!.objectValue!
            var actions = console["composer_actions"]!.arrayValue!
            var first = actions[0].objectValue!
            first["availability"] = availability
            actions[0] = .object(first)
            console["composer_actions"] = .array(actions)
            root["console"] = .object(console)
            let parsed = ChromeMenuModel.fromJSON(.object(root))
            XCTAssertNotNil(parsed)
            XCTAssertFalse(parsed!.menu.isEmpty)
            if availability == .string("invalid") {
                XCTAssertNil(parsed?.console)
            } else {
                XCTAssertEqual(parsed?.console?.composerActions[0].availability, ChromeAvailability(json: availability))
            }
            console = original["console"]!.objectValue!
            var catalog = console["catalog"]!.objectValue!
            var agents = catalog["agents"]!.arrayValue!
            var agent = agents[0].objectValue!
            agent["availability"] = availability
            agents[0] = .object(agent)
            catalog["agents"] = .array(agents)
            console["catalog"] = .object(catalog)
            root["console"] = .object(console)
            if availability == .string("invalid") {
                XCTAssertNil(ChromeMenuModel.fromJSON(.object(root))?.console)
            } else {
                XCTAssertEqual(
                    ChromeMenuModel.fromJSON(.object(root))?.console?.catalog.agents[0].availability,
                    ChromeAvailability(json: availability))
            }
            root = original
            root["menu"] = .array([
                .object([
                    "key": .string("account"),
                    "items": .array([
                        .object(["key": .string("agents"), "surface": .string("agents"), "availability": availability])
                    ]),
                ])
            ])
            let items = ChromeMenuModel.fromJSON(.object(root))!.allItems
            XCTAssertEqual(items.count, availability == .string("invalid") ? 0 : 1)
            XCTAssertEqual(items.first?.availability, ChromeAvailability(json: availability))
            root["topbar"] = .array([
                .object([
                    "key": .string("guidance"), "kind": .string("action"),
                    "availability": availability,
                ])
            ])
            let controls = ChromeMenuModel.fromJSON(.object(root))!.topbar
            XCTAssertEqual(controls.count, availability == .string("invalid") ? 0 : 1)
            XCTAssertEqual(controls.first?.availability, ChromeAvailability(json: availability))
        }
    }

    func testSelectionSummaryUsesOnlySharedCopyAndCounts() throws {
        var raw = try fixture("chrome-console")["console"]!.objectValue!
        let model = try XCTUnwrap(ConsoleModel(json: .object(raw)))
        XCTAssertNil(model.selectionSummary(.empty))
        let id = "11111111-1111-4111-8111-111111111111"
        let other = "22222222-2222-4222-8222-222222222222"
        let selected = try XCTUnwrap(
            TurnSelection(
                json: .object([
                    "version": .number(1), "agent": .object(["agent_id": .string(id), "revision_id": .string(other)]),
                    "skills": .array([
                        .object(["skill_id": .string(id), "revision": .number(1)]),
                        .object(["skill_id": .string(other), "revision": .number(2)]),
                    ]),
                    "notes": .array([.object(["note_id": .string(id), "revision": .number(3)])]),
                ])))
        XCTAssertEqual(model.selectionSummary(selected), "Using 1 agent, 2 skills, 1 note for this chat")
        var labels = raw["labels"]!.objectValue!
        labels["selection_skill_plural"] = nil
        raw["labels"] = .object(labels)
        XCTAssertNil(ConsoleModel(json: .object(raw))?.selectionSummary(selected))
        labels["selection_summary"] = nil
        raw["labels"] = .object(labels)
        XCTAssertNil(ConsoleModel(json: .object(raw))?.selectionSummary(selected))
    }

    func testServerWatchPresentationAndBoundedGeometry() throws {
        let cases = try XCTUnwrap(try fixture("rote-console")["cases"]?.arrayValue)
        let watch = try XCTUnwrap(cases.first { $0["presentation"]?["navigation_mode"]?.stringValue == "stack" })
        var raw = try XCTUnwrap(watch["presentation"]?.objectValue)
        let presentation = try XCTUnwrap(ConsolePresentation(json: .object(raw)))
        XCTAssertEqual(presentation.navigationMode, .stack)
        XCTAssertEqual(presentation.settingsPresentation, .push)
        XCTAssertEqual(presentation.sidebarWidth, 0)
        XCTAssertEqual(presentation.scenarioColumns, 1)
        XCTAssertEqual(presentation.minimumControlHeight, 44)
        XCTAssertEqual(presentation.dialogWidth, watch["viewport"]?.arrayValue?.first?.numberValue)
        for value in [JSONValue.null, .number(0), .number(-1), .number(16385), .string("240")] {
            raw["dialog_width"] = value
            XCTAssertNil(ConsolePresentation(json: .object(raw)))
        }
        raw = watch["presentation"]!.objectValue!
        raw["sidebar_width"] = .number(1)
        XCTAssertNil(ConsolePresentation(json: .object(raw)))
    }

    func testConsoleReadAndCloseAreExactAndSeparateFromOtherOwnerSurfaces() {
        func wire(_ payload: JSONValue, action: String = "chrome_open", chat: String? = nil) -> String {
            Outbound.uiEvent(action: action, sessionId: chat, payload: payload)
        }
        let open = JSONValue.object([
            "surface": .string("agent_intro"), "params": .object(["agent_id": .string("dice")]),
        ])
        XCTAssertEqual(ConsoleSurfaceRequest(frameText: wire(open))?.agentID, "dice")
        XCTAssertEqual(ConsoleSurfaceRequest(frameText: wire(open))?.action, "chrome_open")
        let close = wire(.object(["surface": .string("agent_intro")]), action: "chrome_close")
        XCTAssertEqual(ConsoleSurfaceRequest(frameText: close)?.action, "chrome_close")
        XCTAssertNil(ConsoleSurfaceRequest(frameText: close)?.agentID)
        for raw in [
            "{}", String(repeating: "x", count: 16385), wire(open, action: "chat_message"),
            wire(open, chat: UUID().uuidString.lowercased()), wire(open, action: "chrome_close"),
            wire(.object(["surface": .string("agent_intro")])),
            wire(.object(["surface": .string("guidance"), "params": .object([:])])),
            wire(.object(["surface": .string("agent_intro"), "params": .string("bad")])),
            wire(.object(["surface": .string("agent_intro"), "params": .object(["agent_id": .string("")])])),
            wire(
                .object([
                    "surface": .string("agent_intro"),
                    "params": .object(["agent_id": .string("dice"), "extra": .bool(true)]),
                ])),
        ] { XCTAssertNil(ConsoleSurfaceRequest(frameText: raw)) }
    }
}
