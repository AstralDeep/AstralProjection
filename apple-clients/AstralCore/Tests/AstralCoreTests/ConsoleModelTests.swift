// Exercises shared console fixtures, fail-closed decoding, and independently replaced ROTE values.
// Capability and selection tests keep legacy registration and ordinary chat frames compatible.

import XCTest

@testable import AstralCore

final class ConsoleModelTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/console/\(name).json")))
    }

    private func replacing(_ value: JSONValue, _ path: [String], with replacement: JSONValue?) -> JSONValue {
        var object = value.objectValue!
        let key = path[0]
        if path.count == 1 {
            object[key] = replacement
        } else {
            object[key] = replacing(object[key]!, Array(path.dropFirst()), with: replacement)
        }
        return .object(object)
    }

    func testSharedConsoleFixtureDecodesServerCopyCatalogAndActions() throws {
        let source = try fixture("chrome-console")
        let menu = try XCTUnwrap(ChromeMenuModel.fromJSON(source))
        let model = try XCTUnwrap(menu.console)
        XCTAssertEqual(model.version, 2)
        XCTAssertEqual(model.labels["title"], source["console"]?["labels"]?["title"]?.stringValue)
        XCTAssertEqual(model.identity.name, "Operator")
        XCTAssertEqual(model.identity.role, "Member")
        XCTAssertEqual(model.identity.initials, "O")
        XCTAssertEqual(model.catalog.categories, ["Utilities"])
        XCTAssertEqual(model.catalog.scenarios.first?.id, "dice")
        XCTAssertEqual(model.catalog.scenarios.first?.title, "Roll dice")
        XCTAssertEqual(model.catalog.scenarios.first?.description, "Six rolls")
        XCTAssertEqual(model.catalog.scenarios.first?.prompt, "Roll six dice")
        XCTAssertEqual(model.catalog.scenarios.first?.category, "Utilities")
        XCTAssertEqual(model.catalog.agents.first?.id, "dice")
        XCTAssertEqual(model.catalog.agents.first?.name, "Dice Roller")
        XCTAssertEqual(model.catalog.agents.first?.description, "Rolls dice")
        XCTAssertEqual(model.catalog.agents.first?.state, .ready)
        XCTAssertEqual(model.catalog.agents.first?.owned, true)
        XCTAssertEqual(model.composerActions.map(\.id), ["background", "advanced", "timeline", "pulse", "work"])
        XCTAssertEqual(model.composerActions.first?.kind, .toggle)
        XCTAssertEqual(model.composerActions[1].kind, .action)
        XCTAssertEqual(model.composerActions[1].label, model.labels["advanced"])
        XCTAssertEqual(model.composerActions[1].icon, "sliders")
        XCTAssertEqual(
            model.composerActions[1].action,
            SurfaceRef(surface: "guidance", params: .object(["view": .string("selection")])))
        XCTAssertNil(model.composerActions.first?.action)
        XCTAssertFalse(model.showVoiceAvailabilityBanner)
        XCTAssertEqual(model, ConsoleModel(json: source["console"]))
        XCTAssertFalse(menu.allItems.isEmpty)
    }

    func testInvalidConsoleNeverDestroysLegacySettings() throws {
        let source = try fixture("chrome-console")
        let existing = try XCTUnwrap(ChromeMenuModel.fromJSON(source))
        let console = source["console"]!
        var invalid: [JSONValue?] = [nil, .null, .array([]), .string("future")]
        for field in ["version", "labels", "identity", "catalog", "composer_actions", "show_voice_availability_banner"]
        {
            invalid.append(replacing(console, [field], with: nil))
            invalid.append(replacing(console, [field], with: .null))
        }
        for version in [JSONValue.number(1), .number(3), .number(2.5), .bool(true), .string("2")] {
            invalid.append(replacing(console, ["version"], with: version))
        }
        for bad in invalid {
            let menu = try XCTUnwrap(ChromeMenuModel.fromJSON(replacing(source, ["console"], with: bad)))
            XCTAssertNil(menu.console)
            XCTAssertEqual(menu.menu, existing.menu)
            XCTAssertEqual(menu.topbar, existing.topbar)
            XCTAssertEqual(menu.signout, existing.signout)
        }
    }

    func testConsoleTextAndCatalogBoundsAreEnforcedWithoutTruncation() throws {
        let console = try fixture("chrome-console")["console"]!
        for (path, maximum) in [
            (["identity", "name"], 120), (["identity", "role"], 40), (["identity", "initials"], 40),
            (["labels", "title"], 500),
        ] {
            XCTAssertNotNil(
                ConsoleModel(json: replacing(console, path, with: .string(String(repeating: "x", count: maximum)))))
            for bad in [
                JSONValue.string(" \n "), .string("a\0b"), .number(4),
                .string(String(repeating: "x", count: maximum + 1)),
            ] {
                XCTAssertNil(ConsoleModel(json: replacing(console, path, with: bad)))
            }
        }
        XCTAssertNil(ConsoleModel(json: replacing(console, ["labels", "title"], with: nil)))
        var labels = console["labels"]!.objectValue!
        labels[String(repeating: "x", count: 81)] = .string("text")
        XCTAssertNil(ConsoleModel(json: replacing(console, ["labels"], with: .object(labels))))
        labels = Dictionary(uniqueKeysWithValues: (0..<65).map { ("label\($0)", JSONValue.string("text")) })
        XCTAssertNil(ConsoleModel(json: replacing(console, ["labels"], with: .object(labels))))
        XCTAssertNotNil(
            ConsoleModel(json: replacing(console, ["labels", "future_caption"], with: .string("Server addition"))))
        for (kind, maximum) in [("categories", 16), ("scenarios", 64), ("agents", 60)] {
            let row = console["catalog"]![kind]!.arrayValue![0]
            for bad in [
                JSONValue.null, .array([.null]), .array(Array(repeating: row, count: maximum + 1)), .array([row, row]),
            ] {
                XCTAssertNil(ConsoleModel(json: replacing(console, ["catalog", kind], with: bad)))
            }
        }
        for bad in [JSONValue.string(""), .string(String(repeating: "x", count: 81))] {
            XCTAssertNil(ConsoleModel(json: replacing(console, ["catalog", "categories"], with: .array([bad]))))
        }
        for (kind, bounds) in [
            ("scenarios", ["id": 200, "title": 200, "description": 2000, "prompt": 8000, "category": 80]),
            ("agents", ["id": 200, "name": 200, "description": 2000]),
        ] {
            let row = console["catalog"]![kind]!.arrayValue![0]
            for (field, maximum) in bounds {
                for bad in [JSONValue.null, .string(String(repeating: "x", count: maximum + 1))] {
                    let changed = replacing(row, [field], with: bad)
                    XCTAssertNil(ConsoleModel(json: replacing(console, ["catalog", kind], with: .array([changed]))))
                }
            }
            let emptyDescription = replacing(row, ["description"], with: .string(""))
            XCTAssertNotNil(
                ConsoleModel(json: replacing(console, ["catalog", kind], with: .array([emptyDescription]))))
        }
        let scenario = console["catalog"]!["scenarios"]!.arrayValue![0]
        XCTAssertNil(
            ConsoleModel(
                json: replacing(
                    console, ["catalog", "scenarios"],
                    with: .array([replacing(scenario, ["category"], with: .string("Unknown"))]))))
        let agent = console["catalog"]!["agents"]!.arrayValue![0]
        for (field, bad) in [("state", JSONValue.string("starting")), ("owned", .string("true"))] {
            XCTAssertNil(
                ConsoleModel(
                    json: replacing(
                        console, ["catalog", "agents"], with: .array([replacing(agent, [field], with: bad)]))))
        }
        let offline = replacing(agent, ["state"], with: .string("offline"))
        XCTAssertEqual(
            ConsoleModel(json: replacing(console, ["catalog", "agents"], with: .array([offline])))?.catalog.agents
                .first?.state, .offline)
        let empty: JSONValue = .object(["categories": .array([]), "scenarios": .array([]), "agents": .array([])])
        XCTAssertNotNil(ConsoleModel(json: replacing(console, ["catalog"], with: empty)))
    }

    func testComposerActionsRejectMalformedUnknownAndDuplicateOperations() throws {
        let console = try fixture("chrome-console")["console"]!
        let actions = console["composer_actions"]!.arrayValue!
        let toggle = actions[0]
        let action = actions[1]
        var badRows: [JSONValue] = [.null]
        for key in ["key", "kind", "label", "icon", "action"] {
            badRows.append(replacing(action, [key], with: nil))
        }
        badRows += [
            replacing(action, ["kind"], with: .string("script")),
            replacing(toggle, ["key"], with: .string("unrecognized")),
            replacing(toggle, ["action"], with: .null),
            replacing(action, ["action", "surface"], with: .string("javascript:bad")),
            replacing(action, ["action", "params"], with: .array([])),
            replacing(
                action, ["action", "params"], with: .object(["text": .string(String(repeating: "x", count: 16385))])),
        ]
        for row in badRows {
            XCTAssertNil(ConsoleModel(json: replacing(console, ["composer_actions"], with: .array([row]))))
        }
        for bad in [JSONValue.array([toggle, toggle]), .array(Array(repeating: action, count: 17))] {
            XCTAssertNil(ConsoleModel(json: replacing(console, ["composer_actions"], with: bad)))
        }
        XCTAssertNotNil(ConsoleModel(json: replacing(console, ["composer_actions"], with: .array([]))))
    }

    func testEveryROTEFixturePreservesServerGeometry() throws {
        for entry in try fixture("rote-console")["cases"]!.arrayValue! {
            let raw = entry["presentation"]!
            let value = try XCTUnwrap(ConsolePresentation(json: raw))
            let frame = InboundFrame(
                name: "rote_config", payload: .object(["device_profile": .object(["console": raw])]))
            XCTAssertEqual(ConsolePresentation(frame: frame), value)
            XCTAssertEqual(value.version, 2)
            XCTAssertEqual(value.navigationMode.rawValue, raw["navigation_mode"]?.stringValue)
            XCTAssertEqual(value.settingsPresentation.rawValue, raw["settings_presentation"]?.stringValue)
            XCTAssertEqual(value.settingsNavigationAxis.rawValue, raw["settings_navigation_axis"]?.stringValue)
            XCTAssertEqual(value.sidebarWidth, raw["sidebar_width"]?.numberValue)
            XCTAssertEqual(Double(value.scenarioColumns), raw["scenario_columns"]?.numberValue)
            XCTAssertEqual(value.settingsWidth, raw["settings_width"]?.numberValue)
            XCTAssertEqual(value.settingsMaxHeight, raw["settings_max_height"]?.numberValue)
            XCTAssertEqual(value.settingsNavigationWidth, raw["settings_navigation_width"]?.numberValue)
            XCTAssertEqual(value.resultPreviewMaxHeight, raw["result_preview_max_height"]?.numberValue)
            XCTAssertEqual(value.resultBodyMaxHeight, raw["result_body_max_height"]?.numberValue)
            XCTAssertEqual(value.fullscreenInset, raw["fullscreen_inset"]?.numberValue)
            XCTAssertEqual(value.minimumControlHeight, raw["minimum_control_height"]?.numberValue)
            for (insets, key) in [
                (value.contentPadding, "content_padding"), (value.composerPadding, "composer_padding"),
            ] {
                XCTAssertEqual(insets.top, raw[key]?["top"]?.numberValue)
                XCTAssertEqual(insets.right, raw[key]?["right"]?.numberValue)
                XCTAssertEqual(insets.bottom, raw[key]?["bottom"]?.numberValue)
                XCTAssertEqual(insets.left, raw[key]?["left"]?.numberValue)
            }
        }
    }

    func testROTERejectsMissingUnknownNonfiniteAndOutOfBoundValues() throws {
        let raw = try fixture("rote-console")["cases"]!.arrayValue![0]["presentation"]!
        XCTAssertNil(ConsolePresentation(json: nil))
        XCTAssertNil(ConsolePresentation(frame: InboundFrame(name: "chrome_menu", payload: .object([:]))))
        XCTAssertNil(ConsolePresentation(frame: InboundFrame(name: "rote_config", payload: .object([:]))))
        for key in raw.objectValue!.keys {
            XCTAssertNil(ConsolePresentation(json: replacing(raw, [key], with: nil)))
            XCTAssertNil(ConsolePresentation(json: replacing(raw, [key], with: .null)))
        }
        for key in ["navigation_mode", "settings_presentation", "settings_navigation_axis"] {
            XCTAssertNil(ConsolePresentation(json: replacing(raw, [key], with: .string("unknown"))))
        }
        for version in [JSONValue.number(3), .bool(true), .number(2.5)] {
            XCTAssertNil(ConsolePresentation(json: replacing(raw, ["version"], with: version)))
        }
        for key in raw.objectValue!.keys where raw[key]?.numberValue != nil && key != "version" {
            for invalid in [-1, Double.infinity, Double.nan, 16385] {
                XCTAssertNil(ConsolePresentation(json: replacing(raw, [key], with: .number(invalid))))
            }
        }
        for bad in [0.0, 1.5] {
            XCTAssertNil(ConsolePresentation(json: replacing(raw, ["scenario_columns"], with: .number(bad))))
        }
        for key in ["content_padding", "composer_padding"] {
            for edge in ["top", "right", "bottom", "left"] {
                XCTAssertNil(ConsolePresentation(json: replacing(raw, [key, edge], with: .number(-1))))
            }
        }
        let first = ConsolePresentation(json: raw)
        let changed = ConsolePresentation(json: replacing(raw, ["sidebar_width"], with: .number(123)))
        XCTAssertEqual(first?.sidebarWidth, 275.2)
        XCTAssertEqual(changed?.sidebarWidth, 123)
        XCTAssertNotEqual(first, changed)
    }

    func testCapabilityOptInAndActualDeviceValuesPreserveLegacyWatchWire() throws {
        let legacy = DeviceDescriptor(
            deviceType: "ios", viewportWidth: 390, viewportHeight: 844, supportedTypes: [], userAgent: "test")
        let watch = DeviceDescriptor.watch(viewportWidth: 198, viewportHeight: 242)
        for device in [legacy, watch] {
            let wire = try JSONValue.parse(
                Data(Outbound.registerUI(token: "token", sessionId: nil, device: device, resumed: false).utf8))
            XCTAssertNil(wire["device"]?["console_contract"])
            XCTAssertEqual(wire["capabilities"], .array([.string("render"), .string("stream")]))
        }
        XCTAssertEqual(legacy.connectionType, "unknown")
        XCTAssertEqual(watch.json["connection_type"], .string("unknown"))
        XCTAssertEqual(watch.json["has_camera"], .bool(false))
        XCTAssertEqual(watch.json["has_file_system"], .bool(false))
        for original in [
            DeviceDescriptor.ios(viewportWidth: 390, viewportHeight: 844),
            .macos(viewportWidth: 1440, viewportHeight: 900),
        ] {
            var device = original
            XCTAssertEqual(device, original)
            device.hasCamera = true
            XCTAssertNotEqual(device, original)
            device.connectionType = "cellular"
            device.pixelRatio = 3
            let wire = try JSONValue.parse(
                Data(Outbound.registerUI(token: "token", sessionId: nil, device: device, resumed: false).utf8))
            XCTAssertEqual(wire["device"]?["console_contract"], .string("console/v2"))
            XCTAssertEqual(wire["device"]?["has_camera"], .bool(true))
            XCTAssertEqual(wire["device"]?["connection_type"], .string("cellular"))
            XCTAssertEqual(wire["device"]?["pixel_ratio"], .number(3))
            XCTAssertTrue(wire["capabilities"]!.arrayValue!.contains(.string("guidance_selection_v1")))
            let update = try JSONValue.parse(Data(Outbound.updateDevice(sessionId: nil, device: device).utf8))
            XCTAssertEqual(update["payload"]?["device"], wire["device"])
            device.consoleContract = "console/v3"
            let unsupported = try JSONValue.parse(
                Data(Outbound.registerUI(token: "token", sessionId: nil, device: device, resumed: false).utf8))
            XCTAssertNil(unsupported["device"]?["console_contract"])
            XCTAssertFalse(unsupported["capabilities"]!.arrayValue!.contains(.string("guidance_selection_v1")))
        }
    }
}
