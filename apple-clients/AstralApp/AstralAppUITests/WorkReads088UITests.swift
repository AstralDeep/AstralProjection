#if os(iOS)
    import XCTest

    /// Actual server-menu, scrolling, retry and close over the existing isolated HTTP/WS fixture.
    final class WorkReads088UITests: XCTestCase {
        private var app: XCUIApplication!
        private var peer: WorkspaceActionLoopback!
        private let operation = "66666666-6666-4666-8666-666666666666"

        override func tearDown() {
            app?.terminate()
            peer?.stop()
            app = nil
            peer = nil
            super.tearDown()
        }

        private func launch() throws {
            peer = try WorkspaceActionLoopback(replies: [:], supportsWebSocket: true, supportsWorkReads: true)
            peer.start()
            wait(for: [peer.ready], timeout: 3)
            let port = try XCTUnwrap(peer.port)
            app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-actions-http"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launchEnvironment["ASTRAL_UI_WORKSPACE_PORT"] = String(port)
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
                        [
                            "key": "work", "kind": "action", "label": "Research records", "icon": "briefcase",
                            "action": ["surface": "work", "params": ["mode": "list"]],
                        ],
                        [
                            "key": "theme", "kind": "action", "label": "Theme", "icon": "paintpalette",
                            "action": ["surface": "theme"],
                        ],
                    ], "menu": [],
                ],
            ])
            XCTAssertTrue(app.buttons["Research records"].waitForExistence(timeout: 3))
        }

        private func request(_ count: Int) throws -> [String: Any] {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.peer.workFrames.count >= count }, object: nil)
            wait(for: [ready], timeout: 3)
            return try XCTUnwrap(
                try JSONSerialization.jsonObject(with: XCTUnwrap(peer.workFrames.last)) as? [String: Any])
        }

        private func button(_ label: String, mode: String) -> [String: Any] {
            var params = ["mode": mode]
            if mode != "list" { params["operation_id"] = operation }
            return [
                "type": "button", "label": label, "variant": "secondary", "action": "chrome_open", "disabled": false,
                "local": false,
                "payload": ["surface": "work", "params": params],
            ]
        }

        private func reply(_ request: [String: Any], title: String, components: [[String: Any]]) throws {
            try peer.sendWorkFrame([
                "type": "chrome_surface", "surface_key": "work", "region": "modal", "title": title,
                "mode": "replace", "admin_only": false,
                "request_generation": try XCTUnwrap(request["request_generation"]), "components": components,
            ])
        }

        func testServerMenuReadResultScrollLiteralEvidenceAndCloseThenOtherSurface() throws {
            try launch()
            app.buttons["Research records"].tap()
            let first = try request(1)
            try reply(
                first, title: "Saved work",
                components: [
                    ["type": "text", "content": "Completed operation", "variant": "body"],
                    button("View result", mode: "result"),
                ])
            XCTAssertTrue(app.buttons["View result"].waitForExistence(timeout: 3))
            app.buttons["View result"].tap()
            let second = try request(2)
            XCTAssertNotEqual(first["request_generation"] as? String, second["request_generation"] as? String)
            let prefix = "**Source** [URL](https://example.test) <b>literal</b>\n"
            let suffix = "\nEND OF EXACT EVIDENCE"
            let excerpt = prefix + String(repeating: "x", count: 8192 - prefix.utf8.count - suffix.utf8.count) + suffix
            try reply(
                second, title: "Retained page result",
                components: [
                    [
                        "type": "card", "title": "Original source", "variant": "default",
                        "content": [
                            ["type": "text", "content": excerpt, "variant": "body"],
                            button("Refresh result", mode: "result"),
                        ],
                    ]
                ])
            XCTAssertTrue(app.staticTexts["Retained page result"].waitForExistence(timeout: 3))
            let literal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
            XCTAssertTrue(literal.waitForExistence(timeout: 3))
            XCTAssertEqual(literal.label, excerpt)
            let refresh = app.buttons["Refresh result"]
            for _ in 0..<18 where !refresh.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(
                refresh.isHittable, "The whole bounded source must remain scrollable to its final read-only action")
            refresh.tap()
            let third = try request(3)
            try reply(
                third, title: "Refreshed result",
                components: [["type": "text", "content": "Still retained", "variant": "body"]])
            XCTAssertTrue(app.staticTexts["Refreshed result"].waitForExistence(timeout: 3))
            try reply(third, title: "Duplicate must not paint", components: [])
            try peer.sendWorkFrame([
                "type": "chrome_surface", "surface_key": "llm", "title": "Late mandatory", "mode": "mandatory",
                "components": [["type": "text", "content": "Must not paint"]],
            ])
            XCTAssertTrue(app.staticTexts["Refreshed result"].exists)
            app.buttons["Close"].firstMatch.tap()
            XCTAssertEqual(try request(4)["action"] as? String, "chrome_close")
            app.buttons["Theme"].tap()
            XCTAssertEqual((try request(5)["payload"] as? [String: Any])?["surface"] as? String, "theme")
            try peer.sendWorkFrame([
                "type": "chrome_surface", "surface_key": "theme", "title": "Current theme", "mode": "replace",
                "components": [["type": "text", "content": "Theme content", "variant": "body"]],
            ])
            XCTAssertTrue(app.staticTexts["Current theme"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["Late mandatory"].exists)
            XCTAssertTrue(peer.unexpectedRequests.isEmpty)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Work close preserves explicit theme navigation"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func testActualTimeoutRetiresOldResponseAndRetryUsesNewGeneration() throws {
            try launch()
            app.buttons["Research records"].tap()
            let old = try request(1)
            XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 13))
            try reply(
                old, title: "Expired response",
                components: [["type": "text", "content": "Must not paint", "variant": "body"]])
            XCTAssertTrue(app.buttons["Retry"].exists)
            app.buttons["Retry"].tap()
            let current = try request(2)
            XCTAssertNotEqual(old["request_generation"] as? String, current["request_generation"] as? String)
            try reply(
                current, title: "Retried work",
                components: [["type": "text", "content": "Fresh read", "variant": "body"]])
            XCTAssertTrue(app.staticTexts["Retried work"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["Expired response"].exists)
            app.buttons["Close"].firstMatch.tap()
            XCTAssertEqual(try request(3)["action"] as? String, "chrome_close")
            XCTAssertTrue(peer.unexpectedRequests.isEmpty)
        }
    }
#endif
