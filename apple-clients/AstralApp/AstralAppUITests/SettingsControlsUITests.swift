// Exercises native settings editing, validation and accepted responses over the owned loopback fixture.
// It verifies real controls and transmitted values without provider credentials or a chat query.

#if os(iOS)
    import XCTest

    final class SettingsControlsUITests: XCTestCase {
        private var app: XCUIApplication!
        private var peer: WorkspaceActionLoopback!

        override func setUpWithError() throws {
            continueAfterFailure = false
            peer = try WorkspaceActionLoopback(
                replies: [:], supportsWebSocket: true, supportsWorkReads: true, supportsSettingsControls: true)
            peer.start()
            wait(for: [peer.ready], timeout: 3)
            app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-actions-http"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launchEnvironment["ASTRAL_UI_WORKSPACE_PORT"] = String(try XCTUnwrap(peer.port))
            app.launch()
            XCTAssertTrue(app.buttons["workspace-action-export"].waitForExistence(timeout: 10))
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.peer.registrations == 1 }, object: nil)
            wait(for: [ready], timeout: 5)
            try peer.sendWorkFrame([
                "type": "chrome_menu",
                "model": [
                    "version": 2,
                    "topbar": [
                        ["key": "theme", "kind": "action", "label": "Theme", "action": ["surface": "theme"]],
                        ["key": "llm", "kind": "action", "label": "Provider", "action": ["surface": "llm"]],
                    ], "menu": [],
                ],
            ])
            XCTAssertTrue(app.buttons["Theme"].waitForExistence(timeout: 3))
        }

        override func tearDown() {
            if let peer { XCTAssertTrue(peer.unexpectedRequests.isEmpty) }
            app?.terminate()
            peer?.stop()
            super.tearDown()
        }

        private func request(_ count: Int, action: String) throws -> [String: Any] {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.peer.workFrames.count >= count }, object: nil)
            wait(for: [ready], timeout: 3)
            let frame = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: XCTUnwrap(peer.workFrames.last)) as? [String: Any])
            XCTAssertEqual(frame["action"] as? String, action)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(frame["request_generation"] as? String)))
            return frame
        }

        private func reply(_ request: [String: Any], surface: String, components: [[String: Any]]) throws {
            try peer.sendWorkFrame([
                "type": "chrome_surface", "surface_key": surface, "region": "modal", "title": "Settings",
                "mode": "replace", "admin_only": false,
                "request_generation": try XCTUnwrap(request["request_generation"]), "components": components,
            ])
        }

        private func tap(_ element: XCUIElement) {
            for _ in 0..<6 where !element.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(element.isHittable, app.debugDescription)
            element.tap()
        }

        private func replace(_ field: XCUIElement, with text: String) {
            tap(field)
            let existing = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + text)
            if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        }

        private func colors(_ value: String) -> [[String: Any]] {
            [
                ["type": "theme_apply", "colors": ["primary": value]],
                ["type": "color_picker", "label": "Primary", "color_key": "primary", "value": value],
            ]
        }

        func testCustomHexValidationFailurePreservesDraftAndAcceptedSaveUpdatesControl() throws {
            app.buttons["Theme"].tap()
            try reply(request(1, action: "chrome_open"), surface: "theme", components: colors("#6366F1"))
            let field = app.textFields["theme-color-primary"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            replace(field, with: "bad")
            tap(app.buttons["Apply Primary color"])
            XCTAssertTrue(app.staticTexts["Enter a six-digit hex color, such as #123ABC."].exists)
            XCTAssertEqual(peer.workFrames.count, 1)
            replace(field, with: "123abc")
            tap(app.buttons["Apply Primary color"])
            let save = try request(2, action: "save_theme")
            let payload = try XCTUnwrap(save["payload"] as? [String: Any])
            XCTAssertEqual(payload["surface"] as? String, "theme")
            XCTAssertEqual((payload["theme"] as? [String: String])?["color_value"], "#123ABC")
            XCTAssertFalse(app.buttons["Apply Primary color"].isEnabled)
            try reply(
                save, surface: "theme",
                components: [
                    ["type": "alert", "variant": "error", "message": "Color save refused"]
                ])
            XCTAssertTrue(app.staticTexts["Color save refused"].waitForExistence(timeout: 3))
            XCTAssertEqual(field.value as? String, "123abc")
            tap(app.buttons["Apply Primary color"])
            let retry = try request(3, action: "save_theme")
            XCTAssertNotEqual(save["request_generation"] as? String, retry["request_generation"] as? String)
            try reply(retry, surface: "theme", components: colors("#123ABC"))
            let accepted = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "#123ABC"), object: field)
            wait(for: [accepted], timeout: 3)
            XCTAssertTrue(app.buttons["Apply Primary color"].isEnabled)
        }

        private func form(_ count: Int) -> [[String: Any]] {
            [
                [
                    "type": "param_picker", "title": "Provider controls",
                    "fields": [
                        [
                            "name": "provider", "label": "Provider", "kind": "select", "default": "custom",
                            "options": [
                                ["value": "openai", "label": "OpenAI"],
                                ["value": "custom", "label": "Custom endpoint"],
                            ],
                        ],
                        [
                            "name": "tools", "label": "Tools", "kind": "checklist", "default": ["read", "saved-tool"],
                            "options": [["value": "read", "label": "Read files"]],
                        ],
                        ["name": "count", "label": "Count", "kind": "number", "default": count],
                        ["name": "title", "label": "Title", "kind": "text", "default": "", "required": true],
                    ],
                    "actions": [["label": "Test fields", "action": "chrome_llm_test", "variant": "primary"]],
                ]
            ]
        }

        func testLabeledSelectChecklistAndNumberEditsSurviveOwnedFormRefresh() throws {
            app.buttons["Provider"].tap()
            try reply(request(1, action: "chrome_open"), surface: "llm", components: form(3))
            XCTAssertTrue(app.buttons["param-field-provider"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["param-field-provider"].value as? String, "Custom endpoint")
            XCTAssertEqual(app.switches["param-field-tools-read"].value as? String, "Selected")
            XCTAssertEqual(app.switches["param-field-tools-saved-tool"].value as? String, "Selected")
            tap(app.buttons["Test fields"])
            XCTAssertTrue(app.staticTexts["Title is required."].exists)
            XCTAssertEqual(peer.workFrames.count, 1)
            replace(app.textFields["param-field-title"], with: "Edited title")
            app.staticTexts["param-picker-form-title"].tap()
            let read = app.switches["param-field-tools-read"]
            XCTAssertTrue(read.isHittable)
            read.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertEqual(read.value as? String, "Not selected")
            let count = app.textFields["param-field-count"]
            replace(count, with: "4.5")
            app.staticTexts["param-picker-form-title"].tap()
            tap(app.buttons["Test fields"])
            let submitted = try request(2, action: "chrome_llm_test")
            let fields = try XCTUnwrap((submitted["payload"] as? [String: Any])?["fields"] as? [String: Any])
            XCTAssertEqual(fields["provider"] as? String, "custom")
            XCTAssertEqual(fields["tools"] as? [String], ["saved-tool"])
            XCTAssertEqual(fields["count"] as? Double, 4.5)
            XCTAssertEqual(fields["title"] as? String, "Edited title")
            XCTAssertTrue(app.staticTexts["param-status-chrome_llm_test"].exists)
            try reply(
                submitted, surface: "llm",
                components: [
                    ["type": "alert", "variant": "error", "message": "Validation refused"]
                ] + form(7))
            XCTAssertTrue(app.staticTexts["Validation refused"].waitForExistence(timeout: 3))
            XCTAssertEqual(count.value as? String, "4.5")
            XCTAssertEqual(app.textFields["param-field-title"].value as? String, "Edited title")
            XCTAssertFalse(app.staticTexts["param-status-chrome_llm_test"].exists)
            XCTAssertTrue(app.buttons["Test fields"].isEnabled)
        }
    }
#endif
