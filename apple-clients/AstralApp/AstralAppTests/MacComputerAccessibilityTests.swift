// Exercises accessibility snapshots, element references, menu paths and zoom against a synthetic accessibility tree.
// The real driver and input sequencer run while raw OS calls and native events are recorded, never posted.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerAccessibilityTests: XCTestCase {
        private struct Fixture {
            let io: MacComputerTestSystem
            let driver: MacComputerDriver
            let events: MacComputerInputTestEvents
            let close: AXUIElement
            let save: AXUIElement
            let field: AXUIElement
            let secure: AXUIElement
            let popup: AXUIElement
            let fonts: AXUIElement
            let courier: AXUIElement
            let wrap: AXUIElement
            let delete: AXUIElement
            let saveItem: AXUIElement
            let trashItem: AXUIElement
        }

        private actor CueRecorder {
            var cues: [MacComputerOverlayCue] = []
            func record(_ cue: MacComputerOverlayCue) { cues.append(cue) }
        }

        private func fixture(
            bypass: Bool = false, overlay: (@Sendable (MacComputerOverlayCue) async -> Void)? = nil
        ) -> Fixture {
            let io = MacComputerTestSystem()
            io.configure { $0.bundles[200] = "com.apple.TextEdit" }
            io.set("TextEdit" as CFString, attribute: kAXTitleAttribute, of: io.app)
            io.set("AXApplication" as CFString, attribute: kAXRoleAttribute, of: io.app)
            let close = io.node(
                920, role: "AXButton", description: "close", frame: CGRect(x: 10, y: 10, width: 20, height: 20),
                actions: [kAXPressAction])
            let save = io.node(
                921, role: "AXButton", title: "Save", frame: CGRect(x: 100, y: 10, width: 60, height: 20),
                actions: [kAXPressAction])
            let toolbar = io.node(
                910, role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 640, height: 40), children: [close, save])
            let field = io.node(
                911, role: "AXTextField", value: "Hello" as CFString,
                frame: CGRect(x: 20, y: 60, width: 300, height: 24), focused: true,
                settable: [kAXValueAttribute, kAXFocusedAttribute])
            let secure = io.node(
                912, role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2" as CFString,
                frame: CGRect(x: 20, y: 100, width: 300, height: 24), settable: [kAXValueAttribute])
            let helvetica = io.node(931, role: "AXMenuItem", title: "Helvetica")
            let courier = io.node(932, role: "AXMenuItem", title: "Courier")
            let fonts = io.node(930, role: "AXMenu", children: [helvetica, courier])
            let popup = io.node(
                913, role: "AXPopUpButton", title: "Font", value: "Helvetica" as CFString,
                frame: CGRect(x: 20, y: 140, width: 120, height: 24), children: [fonts], actions: [kAXPressAction])
            let wrap = io.node(
                914, role: "AXCheckBox", title: "Wrap", value: NSNumber(value: 1),
                frame: CGRect(x: 20, y: 180, width: 80, height: 20), actions: [kAXPressAction])
            let status = io.node(
                915, role: "AXStaticText", value: "Status ready" as CFString,
                frame: CGRect(x: 20, y: 220, width: 200, height: 20))
            let delete = io.node(
                916, role: "AXButton", title: "Delete", frame: CGRect(x: 20, y: 260, width: 80, height: 24),
                actions: [kAXPressAction])
            let print = io.node(
                917, role: "AXButton", title: "Print", frame: CGRect(x: 120, y: 260, width: 80, height: 24),
                enabled: false, actions: [kAXPressAction])
            io.set("AXWindow" as CFString, attribute: kAXRoleAttribute, of: io.window)
            io.set(
                [toolbar, field, secure, popup, wrap, status, delete, print] as CFArray,
                attribute: kAXChildrenAttribute, of: io.window)
            let pdf = io.node(946, role: "AXMenuItem", title: "PDF")
            let exportMenu = io.node(945, role: "AXMenu", children: [pdf])
            let saveItem = io.node(943, role: "AXMenuItem", title: "Save…")
            io.set("S" as CFString, attribute: kAXMenuItemCmdCharAttribute, of: saveItem)
            io.set(NSNumber(value: 0), attribute: kAXMenuItemCmdModifiersAttribute, of: saveItem)
            let exportItem = io.node(944, role: "AXMenuItem", title: "Export", children: [exportMenu])
            let separator = io.node(950, role: "AXMenuItem", title: "")
            let wrapItem = io.node(949, role: "AXMenuItem", title: "Wrap Lines")
            io.set("✓" as CFString, attribute: kAXMenuItemMarkCharAttribute, of: wrapItem)
            let trashItem = io.node(947, role: "AXMenuItem", title: "Move to Trash")
            let printItem = io.node(948, role: "AXMenuItem", title: "Print…", enabled: false)
            let fileMenu = io.node(
                942, role: "AXMenu", children: [saveItem, exportItem, separator, wrapItem, trashItem, printItem])
            let file = io.node(
                941, role: "AXMenuBarItem", title: "File", frame: CGRect(x: 50, y: 0, width: 40, height: 22),
                children: [fileMenu], actions: [kAXPressAction])
            let bar = io.node(940, role: "AXMenuBar", children: [file])
            io.set(bar, attribute: kAXMenuBarAttribute, of: io.app)
            let events = MacComputerInputTestEvents()
            let driver = MacComputerDriver(
                marker: 30, system: io, input: MacComputerInput(marker: 30, system: io, events: events),
                overlay: overlay, bypass: { bypass })
            return Fixture(
                io: io, driver: driver, events: events, close: close, save: save, field: field, secure: secure,
                popup: popup, fonts: fonts, courier: courier, wrap: wrap, delete: delete, saveItem: saveItem,
                trashItem: trashItem)
        }

        private func request(_ verb: String, _ args: [String: JSONValue] = [:], source: String? = nil) throws
            -> ComputerHostRequest
        {
            var object: [String: JSONValue] = [
                "type": .string("computer_request"), "request_id": .string("creq_" + String(repeating: "b", count: 32)),
                "session_id": .string("11111111-1111-4111-8111-111111111111"), "verb": .string(verb),
                "args": .object(args), "deadline_ms": .number(8000),
            ]
            if let source { object["approval_source"] = .string(source) }
            return try ComputerHostRequest(json: .object(object))
        }

        private func run(_ fixture: Fixture, _ verb: String, _ args: [String: JSONValue] = [:], source: String? = nil)
            async throws -> [String: JSONValue]
        {
            try await fixture.driver.execute(request(verb, args, source: source), workspaces: [], authorize: {})
        }

        private func refusal(
            _ code: String, _ fixture: Fixture, _ verb: String, _ args: [String: JSONValue] = [:],
            source: String? = nil
        ) async -> String? {
            do {
                _ = try await run(fixture, verb, args, source: source)
                XCTFail("Expected \(code) for \(verb)")
                return nil
            } catch {
                XCTAssertEqual((error as? ComputerHostError)?.code, code, "\(verb): \(error)")
                return (error as? ComputerHostError)?.message
            }
        }

        private func performed(_ fixture: Fixture, _ action: String, on element: AXUIElement) -> Bool {
            fixture.io.configure { $0.performed.contains { $0.action == action && CFEqual($0.element, element) } }
        }

        private func match(_ fixture: Fixture, _ query: String) async throws -> (ref: String, snapshot: String) {
            let found = try await run(fixture, "ax_find", ["query": .string(query)])
            let ref = try XCTUnwrap(found["matches"]?.arrayValue?.first?["ref"]?.stringValue)
            return (ref, try XCTUnwrap(found["snapshot_id"]?.stringValue))
        }

        private func row(pid: Int32, _ bounds: CGRect, name: String? = nil, layer: Int = 0) -> [String: Any] {
            var row: [String: Any] = [
                kCGWindowAlpha as String: NSNumber(value: 1),
                kCGWindowBounds as String: bounds.dictionaryRepresentation,
                kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
            ]
            if let name { row[kCGWindowName as String] = name }
            return row
        }

        func testTreeLinesUseTheLastScreenshotGeometryAndBindTheWindow() async throws {
            let fixture = fixture()
            _ = try await run(fixture, "screenshot", ["max_width": .number(320)])
            let tree = try await run(fixture, "ax_tree")
            XCTAssertEqual(tree["snapshot_id"], .string("x1"))
            XCTAssertEqual(tree["hwnd"], .number(1))
            XCTAssertEqual(tree["pid"], .number(200))
            XCTAssertEqual(tree["bundle_id"], .string("com.apple.TextEdit"))
            XCTAssertEqual(tree["app"], .string("TextEdit"))
            XCTAssertEqual(tree["window"]?["hwnd"], .number(1))
            XCTAssertEqual(tree["window"]?["title"], .string("Synthetic browser"))
            XCTAssertEqual(tree["truncated"], .bool(false))
            XCTAssertEqual(tree["screen_index"], .number(0))
            XCTAssertEqual(
                tree["lines"]?.arrayValue?.compactMap(\.stringValue),
                [
                    "[a1] button \"close\" (5,5,10,10)", "[a2] button \"Save\" (50,5,30,10)",
                    "[a3] textfield value=\"Hello\" (10,30,150,12) focused", "[a4] textfield (10,50,150,12) secure",
                    "[a5] popupbutton \"Font\" value=\"Helvetica\" (10,70,60,12)",
                    "[a6] checkbox \"Wrap\" (10,90,40,10) checked", "[a7] button \"Delete\" (10,130,40,12)",
                    "[a8] button \"Print\" (60,130,40,12) disabled",
                ])
            let all = try await run(fixture, "ax_tree", ["mode": .string("all")])
            let lines = all["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
            XCTAssertEqual(all["snapshot_id"], .string("x2"))
            XCTAssertTrue(lines.contains("[a15] statictext \"Status ready\" (10,110,100,10)"), "\(lines)")
            XCTAssertFalse(lines.joined().contains("hunter2"))
            XCTAssertEqual(fixture.io.configure { $0.plans.count }, 1)
        }

        func testTreeCapturesGeometryWhenNoScreenshotExistsAndHonorsBounds() async throws {
            let fixture = fixture()
            let tree = try await run(fixture, "ax_tree")
            XCTAssertEqual(fixture.io.configure { $0.plans.count }, 1)
            XCTAssertTrue(
                tree["lines"]?.arrayValue?.contains(.string("[a2] button \"Save\" (100,10,60,20)")) == true)
            let limited = try await run(fixture, "ax_tree", ["max_nodes": .number(2)])
            XCTAssertEqual(limited["truncated"], .bool(true))
            XCTAssertEqual(
                limited["lines"]?.arrayValue?.compactMap(\.stringValue),
                ["[a9] textfield value=\"Hello\" (20,60,300,24) focused", "[a10] textfield (20,100,300,24) secure"])
            let shallow = try await run(fixture, "ax_tree", ["depth": .number(1)])
            let lines = shallow["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
            XCTAssertEqual(lines.count, 6)
            XCTAssertFalse(lines.contains { $0.contains("\"Save\"") })
            XCTAssertEqual(fixture.io.configure { $0.plans.count }, 1)
        }

        func testFindMatchesFieldsCaseInsensitivelyWithRoleFilterAndActions() async throws {
            let fixture = fixture()
            let save = try await run(fixture, "ax_find", ["query": .string("SAVE")])
            XCTAssertEqual(save["app"], .string("TextEdit"))
            XCTAssertEqual(save["hwnd"], .number(1))
            let first = try XCTUnwrap(save["matches"]?.arrayValue?.first)
            XCTAssertEqual(save["matches"]?.arrayValue?.count, 1)
            XCTAssertEqual(first["role"], .string("button"))
            XCTAssertEqual(first["title"], .string("Save"))
            XCTAssertEqual(first["value"], .null)
            XCTAssertEqual(
                first["frame"], .object(["x": .number(100), "y": .number(10), "w": .number(60), "h": .number(20)]))
            XCTAssertEqual(first["enabled"], .bool(true))
            XCTAssertEqual(first["actions"], .array([.string("press")]))
            let close = try await run(fixture, "ax_find", ["query": .string("Close")])
            XCTAssertEqual(close["matches"]?.arrayValue?.first?["title"], .string("close"))
            let field = try await run(fixture, "ax_find", ["query": .string("hello"), "role": .string("AXTextField")])
            XCTAssertEqual(
                field["matches"]?.arrayValue?.first?["actions"], .array([.string("focus"), .string("set_value")]))
            let secret = try await run(fixture, "ax_find", ["query": .string("hunter")])
            XCTAssertEqual(secret["matches"], .array([]))
            let buttons = try await run(
                fixture, "ax_find", ["query": .string("e"), "role": .string("button"), "max": .number(2)])
            XCTAssertEqual(
                buttons["matches"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["close", "Delete"])
            XCTAssertEqual(buttons["truncated"], .bool(true))
        }

        func testStaleReferencesNeverReachAnElement() async throws {
            let fixture = fixture()
            let (ref, snapshot) = try await match(fixture, "save")
            _ = await refusal(
                "stale_ref", fixture, "ax_action",
                ["ref": .string(ref), "snapshot_id": .string("x99"), "action": .string("press")])
            let (_, other) = try await match(fixture, "close")
            _ = await refusal(
                "stale_ref", fixture, "ax_action",
                ["ref": .string(ref), "snapshot_id": .string(other), "action": .string("press")])
            let press: [String: JSONValue] = [
                "ref": .string(ref), "snapshot_id": .string(snapshot), "action": .string("press"),
            ]
            fixture.io.set(nil, attribute: kAXRoleAttribute, of: fixture.save)
            _ = await refusal("stale_ref", fixture, "ax_action", press)
            fixture.io.set("AXButton" as CFString, attribute: kAXRoleAttribute, of: fixture.save)
            fixture.io.setBounds(CGRect(x: 100, y: 10, width: 0, height: 20), of: fixture.save)
            _ = await refusal("stale_ref", fixture, "ax_action", press)
            fixture.io.setBounds(CGRect(x: 1000, y: 1000, width: 60, height: 20), of: fixture.save)
            _ = await refusal("stale_ref", fixture, "ax_action", press)
            fixture.io.setBounds(CGRect(x: 100, y: 10, width: 60, height: 20), of: fixture.save)
            XCTAssertFalse(performed(fixture, kAXPressAction, on: fixture.save))
            for _ in 0..<2 { _ = try await match(fixture, "save") }
            _ = try await run(fixture, "ax_action", press)
            XCTAssertTrue(performed(fixture, kAXPressAction, on: fixture.save))
            _ = try await match(fixture, "save")
            _ = await refusal("stale_ref", fixture, "ax_action", press)
            let (live, current) = try await match(fixture, "save")
            fixture.io.configure { $0.bundles[200] = nil }
            _ = await refusal(
                "stale_ref", fixture, "ax_action",
                ["ref": .string(live), "snapshot_id": .string(current), "action": .string("press")])
            fixture.io.configure { $0.bundles[200] = "com.apple.TextEdit" }
            _ = await refusal(
                "stale_ref", fixture, "ax_action",
                ["ref": .string(live), "snapshot_id": .string(current), "action": .string("press")])
        }

        func testActionsUseAccessibilityAndSecureFieldsRefuseValues() async throws {
            let fixture = fixture()
            let (save, snapshot) = try await match(fixture, "save")
            let pressed = try await run(
                fixture, "ax_action",
                ["ref": .string(save), "snapshot_id": .string(snapshot), "action": .string("press")])
            XCTAssertEqual(pressed["performed"], .bool(true))
            XCTAssertEqual(pressed["title"], .string("Save"))
            XCTAssertEqual(pressed["role"], .string("button"))
            XCTAssertEqual(pressed["frontmost"], .bool(true))
            XCTAssertNotNil(pressed["screenshot"])
            XCTAssertTrue(performed(fixture, kAXPressAction, on: fixture.save))
            XCTAssertTrue(fixture.events.posted.isEmpty)
            let (field, fieldSnapshot) = try await match(fixture, "hello")
            _ = try await run(
                fixture, "ax_action",
                [
                    "ref": .string(field), "snapshot_id": .string(fieldSnapshot), "action": .string("set_value"),
                    "value": .string("World"),
                ])
            XCTAssertEqual(fixture.io.attribute(kAXValueAttribute, of: fixture.field) as? String, "World")
            let tree = try await run(fixture, "ax_tree")
            let lines = tree["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let secureLine = try XCTUnwrap(lines.first { $0.hasSuffix(" secure") })
            let secure = String(secureLine.dropFirst().prefix { $0 != "]" })
            let treeSnapshot = try XCTUnwrap(tree["snapshot_id"]?.stringValue)
            let message = await refusal(
                "secure_input_active", fixture, "ax_action",
                [
                    "ref": .string(secure), "snapshot_id": .string(treeSnapshot), "action": .string("set_value"),
                    "value": .string("guess"),
                ])
            XCTAssertTrue(message?.contains("password") == true)
            XCTAssertEqual(fixture.io.attribute(kAXValueAttribute, of: fixture.secure) as? String, "hunter2")
            fixture.io.set(kCFBooleanFalse, attribute: kAXFocusedAttribute, of: fixture.secure)
            _ = try await run(
                fixture, "ax_action",
                ["ref": .string(secure), "snapshot_id": .string(treeSnapshot), "action": .string("focus")])
            XCTAssertEqual(fixture.io.attribute(kAXFocusedAttribute, of: fixture.secure) as? Bool, true)
            fixture.io.configure { $0.actionResults[kAXShowMenuAction] = .actionUnsupported }
            _ = await refusal(
                "unsupported", fixture, "ax_action",
                ["ref": .string(save), "snapshot_id": .string(snapshot), "action": .string("show_menu")])
            _ = await refusal(
                "unsupported", fixture, "ax_action",
                ["ref": .string(save), "snapshot_id": .string(snapshot), "action": .string("raise")])
            fixture.io.set(fixture.io.window, attribute: kAXWindowAttribute, of: fixture.save)
            let raised = try await run(
                fixture, "ax_action",
                ["ref": .string(save), "snapshot_id": .string(snapshot), "action": .string("raise")])
            XCTAssertEqual(raised["performed"], .bool(true))
            XCTAssertTrue(fixture.io.configure { $0.trace.contains("activate") && $0.trace.contains("raise") })
        }

        func testPickPressesThenSelectsTheMatchingMenuItem() async throws {
            let fixture = fixture()
            let (popup, snapshot) = try await match(fixture, "font")
            let picked = try await run(
                fixture, "ax_action",
                [
                    "ref": .string(popup), "snapshot_id": .string(snapshot), "action": .string("pick"),
                    "value": .string("courier"),
                ])
            XCTAssertEqual(picked["picked"], .string("Courier"))
            XCTAssertTrue(performed(fixture, kAXPressAction, on: fixture.popup))
            XCTAssertTrue(performed(fixture, kAXPressAction, on: fixture.courier))
            let message = await refusal(
                "not_found", fixture, "ax_action",
                [
                    "ref": .string(popup), "snapshot_id": .string(snapshot), "action": .string("pick"),
                    "value": .string("Times"),
                ])
            XCTAssertTrue(message?.contains("Helvetica, Courier") == true)
            XCTAssertTrue(performed(fixture, kAXCancelAction, on: fixture.fonts))
        }

        func testConsequentialControlsNeedTheExactReviewedLineAndPermitOrBypass() async throws {
            let fixture = fixture()
            let (delete, snapshot) = try await match(fixture, "delete")
            let press: [String: JSONValue] = [
                "ref": .string(delete), "snapshot_id": .string(snapshot), "action": .string("press"),
            ]
            let refused = await refusal("confirmation_required", fixture, "ax_action", press)
            let message = try XCTUnwrap(refused)
            let line = "[\(delete)] button \"Delete\" — TextEdit"
            XCTAssertTrue(message.hasSuffix(": " + line), message)
            XCTAssertFalse(performed(fixture, kAXPressAction, on: fixture.delete))
            var reviewed = press
            reviewed["confirm_element"] = .string(line)
            reviewed["permit"] = .object(["ref": .string("a99"), "snapshot_id": .string(snapshot)])
            _ = await refusal("confirmation_required", fixture, "ax_action", reviewed)
            reviewed["permit"] = .object([
                "ref": .string(delete), "snapshot_id": .string(snapshot), "hwnd": .number(1),
            ])
            reviewed["confirm_element"] = .string(line + " ")
            _ = await refusal("confirmation_required", fixture, "ax_action", reviewed)
            reviewed["confirm_element"] = .string(line)
            let approved = try await run(fixture, "ax_action", reviewed)
            XCTAssertEqual(approved["performed"], .bool(true))
            XCTAssertTrue(performed(fixture, kAXPressAction, on: fixture.delete))
            for _ in 0..<2 { _ = await refusal("stale_ref", fixture, "ax_action", reviewed) }
            XCTAssertEqual(
                fixture.io.configure { $0.performed.filter { CFEqual($0.element, fixture.delete) }.count }, 1)
            let (fresh, next) = try await match(fixture, "delete")
            let reissued = await refusal(
                "confirmation_required", fixture, "ax_action",
                ["ref": .string(fresh), "snapshot_id": .string(next), "action": .string("press")])
            let again = try XCTUnwrap(reissued)
            XCTAssertTrue(again.hasSuffix("[\(fresh)] button \"Delete\" — TextEdit"))
        }

        func testBypassedRequestsSkipReviewOnlyWhenTheHostBypassIsOn() async throws {
            for bypass in [false, true] {
                let fixture = fixture(bypass: bypass)
                let (delete, snapshot) = try await match(fixture, "delete")
                let press: [String: JSONValue] = [
                    "ref": .string(delete), "snapshot_id": .string(snapshot), "action": .string("press"),
                ]
                if bypass {
                    let result = try await run(fixture, "ax_action", press, source: "bypass")
                    XCTAssertEqual(result["performed"], .bool(true))
                } else {
                    _ = await refusal("confirmation_required", fixture, "ax_action", press, source: "bypass")
                }
                XCTAssertEqual(performed(fixture, kAXPressAction, on: fixture.delete), bypass)
                let (field, fieldSnapshot) = try await match(fixture, "hello")
                _ = await refusal(
                    "confirmation_required", fixture, "ax_action",
                    [
                        "ref": .string(field), "snapshot_id": .string(fieldSnapshot), "action": .string("set_value"),
                        "value": .string("send now"),
                    ])
            }
        }

        func testTerminalApplicationsRefuseEffectsButAllowListing() async throws {
            let fixture = fixture()
            fixture.io.configure { $0.bundles[200] = "com.apple.Terminal" }
            let (save, snapshot) = try await match(fixture, "save")
            for action in ["press", "set_value", "pick"] {
                var args: [String: JSONValue] = [
                    "ref": .string(save), "snapshot_id": .string(snapshot), "action": .string(action),
                ]
                if action != "press" { args["value"] = .string("x") }
                let message = await refusal("terminal_target", fixture, "ax_action", args)
                XCTAssertEqual(message, "Use run_command for terminal work.")
            }
            _ = try await run(
                fixture, "ax_action",
                ["ref": .string(save), "snapshot_id": .string(snapshot), "action": .string("focus")])
            _ = await refusal("terminal_target", fixture, "menu", ["path": .array([.string("File"), .string("Save")])])
            let listed = try await run(fixture, "menu", ["path": .array([.string("File")])])
            XCTAssertEqual(listed["items"]?.arrayValue?.count, 5)
            XCTAssertFalse(performed(fixture, kAXPressAction, on: fixture.save))
            XCTAssertFalse(performed(fixture, kAXPressAction, on: fixture.saveItem))
        }

        func testMenuPathsListChildrenAndInvokeLeavesThroughAccessibility() async throws {
            let fixture = fixture()
            let file = try await run(fixture, "menu", ["path": .array([.string("File")])])
            XCTAssertEqual(file["path"], .array([.string("File")]))
            XCTAssertEqual(file["app"], .string("TextEdit"))
            XCTAssertNil(file["invoked"])
            let items = file["items"]?.arrayValue ?? []
            XCTAssertEqual(
                items.compactMap { $0["title"]?.stringValue },
                ["Save…", "Export", "Wrap Lines", "Move to Trash", "Print…"])
            XCTAssertEqual(
                items.first,
                .object([
                    "title": .string("Save…"), "enabled": .bool(true), "checked": .bool(false),
                    "shortcut": .string("⌘S"), "has_children": .bool(false),
                ]))
            XCTAssertEqual(items[1]["has_children"], .bool(true))
            XCTAssertEqual(items[2]["checked"], .bool(true))
            XCTAssertEqual(items[4]["enabled"], .bool(false))
            let export = try await run(fixture, "menu", ["path": .array([.string("file"), .string("EXPORT")])])
            XCTAssertEqual(export["path"], .array([.string("File"), .string("Export")]))
            XCTAssertEqual(export["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["PDF"])
            let siblings = try await run(
                fixture, "menu", ["path": .array([.string("File"), .string("Save")]), "list": .bool(true)])
            XCTAssertEqual(siblings["items"]?.arrayValue?.count, 5)
            XCTAssertFalse(performed(fixture, kAXPressAction, on: fixture.saveItem))
            for title in ["Save", "save...", "Save…"] {
                let invoked = try await run(fixture, "menu", ["path": .array([.string("File"), .string(title)])])
                XCTAssertEqual(invoked["invoked"], .bool(true))
                XCTAssertEqual(invoked["frontmost"], .bool(true))
                XCTAssertNotNil(invoked["screenshot"])
            }
            XCTAssertTrue(performed(fixture, kAXPressAction, on: fixture.saveItem))
            let missing = await refusal(
                "not_found", fixture, "menu", ["path": .array([.string("File"), .string("Nope")])])
            XCTAssertTrue(missing?.contains("Choices: Save…, Export") == true)
            _ = await refusal(
                "not_found", fixture, "menu", ["path": .array([.string("File"), .string("Save"), .string("More")])])
            _ = await refusal(
                "target_disabled", fixture, "menu", ["path": .array([.string("File"), .string("Print")])])
            let trash: JSONValue = .array([.string("File"), .string("Move to Trash")])
            let refused = await refusal("confirmation_required", fixture, "menu", ["path": trash])
            let message = try XCTUnwrap(refused)
            let line = "menu \"File › Move to Trash\" — TextEdit"
            XCTAssertTrue(message.hasSuffix(": " + line), message)
            XCTAssertFalse(performed(fixture, kAXPressAction, on: fixture.trashItem))
            let approved = try await run(
                fixture, "menu",
                [
                    "path": trash, "confirm_element": .string(line),
                    "permit": .object(["path": trash, "pid": .number(200)]),
                ])
            XCTAssertEqual(approved["invoked"], .bool(true))
            XCTAssertTrue(performed(fixture, kAXPressAction, on: fixture.trashItem))
            fixture.io.set(nil, attribute: kAXMenuBarAttribute, of: fixture.io.app)
            _ = await refusal("not_found", fixture, "menu", ["path": .array([.string("File")])])
        }

        func testZoomCapturesARegionWithoutReplacingPointerGeometryAndExcludesOverlays() async throws {
            let fixture = fixture()
            fixture.io.configure {
                $0.overlays = [8]
                $0.captureWindows = [4, 5, 8]
            }
            _ = await refusal(
                "stale_target", fixture, "zoom", ["x": .number(0), "y": .number(0), "w": .number(10), "h": .number(10)])
            _ = try await run(fixture, "list_windows")
            _ = try await run(fixture, "screenshot", ["max_width": .number(320)])
            let zoomed = try await run(
                fixture, "zoom",
                ["x": .number(10), "y": .number(20), "w": .number(50), "h": .number(40), "scale": .number(2)])
            let plan = try XCTUnwrap(fixture.io.configure { $0.plans.last })
            XCTAssertEqual(plan.sourceRect, CGRect(x: 20, y: 40, width: 100, height: 80))
            XCTAssertEqual(plan.excludedWindows, [5, 8])
            XCTAssertEqual(fixture.io.configure { $0.plans.first?.excludedWindows }, [5, 8])
            XCTAssertEqual(plan.configuration().sourceRect, CGRect(x: 20, y: 40, width: 100, height: 80))
            XCTAssertEqual(zoomed["width"], .number(100))
            XCTAssertEqual(zoomed["height"], .number(80))
            XCTAssertEqual(zoomed["scale"], .number(2))
            XCTAssertEqual(zoomed["media_type"], .string("image/jpeg"))
            XCTAssertFalse(try XCTUnwrap(zoomed["base64"]?.stringValue).isEmpty)
            XCTAssertEqual(
                zoomed["region"], .object(["x": .number(10), "y": .number(20), "w": .number(50), "h": .number(40)]))
            let sharp = try await run(
                fixture, "zoom",
                ["x": .number(300), "y": .number(0), "w": .number(100), "h": .number(20), "scale": .number(4)])
            XCTAssertEqual(sharp["region"]?["w"], .number(20))
            XCTAssertEqual(sharp["width"], .number(80))
            XCTAssertEqual(sharp["scale"], .number(1))
            _ = await refusal(
                "out_of_range", fixture, "zoom", ["x": .number(320), "y": .number(0), "w": .number(5), "h": .number(5)])
            _ = try await run(fixture, "click", ["x": .number(20), "y": .number(30)])
            XCTAssertEqual(fixture.events.posted.first?.location, CGPoint(x: 40, y: 60))
            let windowed = try await run(
                fixture, "zoom",
                ["x": .number(0), "y": .number(0), "w": .number(10), "h": .number(10), "hwnd": .number(1)])
            XCTAssertEqual(windowed["region"]?["w"], .number(10))
            fixture.io.setBounds(CGRect(x: 0, y: 0, width: 100, height: 100), of: fixture.io.window)
            _ = try await run(fixture, "list_windows")
            _ = await refusal(
                "out_of_range", fixture, "zoom",
                ["x": .number(100), "y": .number(100), "w": .number(5), "h": .number(5), "hwnd": .number(2)])
            _ = await refusal(
                "stale_target", fixture, "zoom",
                ["x": .number(0), "y": .number(0), "w": .number(5), "h": .number(5), "hwnd": .number(1)])
        }

        func testReferenceClicksResolveToElementCentersThroughTheCoordinateFence() async throws {
            let recorder = CueRecorder()
            let fixture = fixture(overlay: { await recorder.record($0) })
            _ = try await run(fixture, "screenshot", ["max_width": .number(320)])
            let (save, snapshot) = try await match(fixture, "save")
            let clicked = try await run(fixture, "click", ["ref": .string(save), "snapshot_id": .string(snapshot)])
            XCTAssertEqual(fixture.events.posted.map(\.type), [.leftMouseDown, .leftMouseUp])
            XCTAssertEqual(fixture.events.posted.first?.location, CGPoint(x: 130, y: 20))
            XCTAssertEqual(clicked["ref"], .string(save))
            XCTAssertEqual(clicked["title"], .string("Save"))
            XCTAssertEqual(clicked["point"], .object(["x": .number(65), "y": .number(10)]))
            XCTAssertEqual(clicked["screen_point"], .object(["x": .number(130), "y": .number(20)]))
            XCTAssertNotNil(clicked["screenshot"])
            let cues = await recorder.cues
            XCTAssertEqual(
                cues,
                [
                    .app("TextEdit"), .point(CGPoint(x: 130, y: 20), label: "Save — TextEdit"),
                    .click(CGPoint(x: 130, y: 20)),
                ])
            let tree = try await run(fixture, "ax_tree")
            let treeSnapshot = try XCTUnwrap(tree["snapshot_id"]?.stringValue)
            let refs =
                tree["lines"]?.arrayValue?.compactMap { line in
                    line.stringValue.map { String($0.dropFirst().prefix { $0 != "]" }) }
                } ?? []
            _ = try await run(
                fixture, "drag",
                ["ref": .string(refs[1]), "ref2": .string(refs[0]), "snapshot_id": .string(treeSnapshot)])
            let drag = fixture.events.posted.suffix(22)
            XCTAssertEqual(drag.first?.type, .leftMouseDown)
            XCTAssertEqual(drag.first?.location, CGPoint(x: 130, y: 20))
            XCTAssertEqual(drag.dropLast().last?.location, CGPoint(x: 20, y: 20))
            let dragCue = await recorder.cues.last
            XCTAssertEqual(dragCue, .drag(CGPoint(x: 130, y: 20), CGPoint(x: 20, y: 20)))
            let other = fixture.io.node(960, role: "AXApplication", pid: 300)
            let otherWindow = fixture.io.node(
                961, role: "AXWindow", title: "Other", frame: CGRect(x: 0, y: 0, width: 640, height: 480), pid: 300)
            fixture.io.set(otherWindow, attribute: kAXFocusedWindowAttribute, of: other)
            fixture.io.set(other, attribute: kAXFocusedApplicationAttribute, of: fixture.io.system)
            fixture.io.configure { $0.bundles[300] = "fixture.editor" }
            _ = try await run(fixture, "screenshot", ["max_width": .number(320)])
            let background = try await run(fixture, "ax_find", ["query": .string("save"), "pid": .number(200)])
            let ref = try XCTUnwrap(background["matches"]?.arrayValue?.first?["ref"]?.stringValue)
            let posted = fixture.events.posted.count
            let message = await refusal(
                "stale_target", fixture, "click",
                ["ref": .string(ref), "snapshot_id": .string(try XCTUnwrap(background["snapshot_id"]?.stringValue))])
            XCTAssertTrue(message?.contains("focus_window") == true, message ?? "")
            XCTAssertEqual(fixture.events.posted.count, posted)
        }

        func testReferenceInputAndInspectionNeverOperateAstral() async throws {
            let fixture = fixture()
            _ = await refusal("permission_denied", fixture, "ax_tree", ["pid": .number(100)])
            _ = await refusal(
                "permission_denied", fixture, "menu", ["pid": .number(100), "path": .array([.string("File")])])
            _ = try await run(fixture, "screenshot", ["max_width": .number(320)])
            let (save, snapshot) = try await match(fixture, "save")
            let click: [String: JSONValue] = ["ref": .string(save), "snapshot_id": .string(snapshot)]
            fixture.io.configure { $0.rows = [self.row(pid: 100, CGRect(x: 0, y: 0, width: 640, height: 480))] }
            _ = await refusal("permission_denied", fixture, "click", click)
            fixture.io.configure {
                $0.rows = [self.row(pid: 300, CGRect(x: 0, y: 0, width: 640, height: 480), name: "Other")]
            }
            let covered = await refusal("stale_target", fixture, "click", click)
            XCTAssertTrue(covered?.contains("covers") == true)
            XCTAssertTrue(fixture.events.posted.isEmpty)
            fixture.io.configure {
                $0.rows = [
                    self.row(
                        pid: 100, CGRect(x: 0, y: 0, width: 640, height: 480), name: MacComputerOverlayIdentity.title,
                        layer: 1000),
                    self.row(pid: 200, CGRect(x: 0, y: 0, width: 640, height: 480), name: "Synthetic browser"),
                ]
            }
            _ = try await run(fixture, "click", click)
            XCTAssertEqual(fixture.events.posted.map(\.type), [.leftMouseDown, .leftMouseUp])
            let astral = fixture.io.node(970, role: "AXApplication", pid: 100)
            fixture.io.set(astral, attribute: kAXFocusedApplicationAttribute, of: fixture.io.system)
            _ = await refusal("permission_denied", fixture, "ax_tree")
            _ = await refusal("permission_denied", fixture, "ax_find", ["query": .string("save")])
            _ = await refusal("permission_denied", fixture, "menu", ["path": .array([.string("File")])])
        }

        func testListAppsReportsRegularApplicationsExceptAstral() async throws {
            let fixture = fixture()
            fixture.io.configure {
                $0.apps = [
                    MacComputerApplication(pid: 100, bundleIdentifier: "fixture.host", name: "Astral"),
                    MacComputerApplication(
                        pid: 200, bundleIdentifier: "com.apple.TextEdit", name: "TextEdit", active: true),
                    MacComputerApplication(pid: 300, bundleIdentifier: "fixture.agent", regular: false, name: "Agent"),
                    MacComputerApplication(pid: 400, bundleIdentifier: "fixture.hidden", name: "Hidden", hidden: true),
                ]
            }
            let listed = try await run(fixture, "list_apps")
            XCTAssertEqual(
                listed["apps"],
                .array([
                    .object([
                        "pid": .number(200), "name": .string("TextEdit"), "bundle_id": .string("com.apple.TextEdit"),
                        "active": .bool(true), "hidden": .bool(false), "window_count": .number(1),
                    ]),
                    .object([
                        "pid": .number(400), "name": .string("Hidden"), "bundle_id": .string("fixture.hidden"),
                        "active": .bool(false), "hidden": .bool(true), "window_count": .number(0),
                    ]),
                ]))
        }

        func testLineFormattingEscapesBoundsAndMarksOffscreenElements() {
            let element = AXUIElementCreateApplication(990)
            let node = MacComputerAXNode(
                element: element, role: "AXButton", subrole: nil, roleDescription: nil,
                title: "Say \"hi\"\n" + String(repeating: "x", count: 120), detail: nil, identifier: nil, text: nil,
                number: nil, enabled: true, focused: false, selected: true, expanded: false,
                frame: CGRect(x: 700, y: 10, width: 10, height: 10), children: [])
            let mapping = MacComputerAXMapping(
                bounds: CGRect(x: -640, y: 0, width: 1280, height: 480), width: 640, height: 240, screenIndex: 1)
            let line = MacComputerAccessibility.line("a5", node, mapping: mapping, window: nil)
            XCTAssertTrue(line.hasPrefix("[a5] button \"Say \\\"hi\\\" xxx"), line)
            XCTAssertTrue(line.hasSuffix("…\" (670,5,5,5) selected collapsed offscreen"), line)
            XCTAssertEqual(MacComputerAccessibility.shortcut("k", modifiers: 7), "⌃⌥⇧⌘K")
            XCTAssertEqual(MacComputerAccessibility.shortcut("x", modifiers: 8), "X")
            XCTAssertNil(MacComputerAccessibility.shortcut("", modifiers: 0))
            XCTAssertEqual(MacComputerAccessibility.menuTitle("  Save As…  "), "save as")
            XCTAssertTrue(MacComputerAccessibility.consequential(["Empty Trash"]))
            XCTAssertTrue(MacComputerAccessibility.consequential(["Buy now"]))
            XCTAssertFalse(MacComputerAccessibility.consequential(["Save", nil]))
        }
    }
#endif
