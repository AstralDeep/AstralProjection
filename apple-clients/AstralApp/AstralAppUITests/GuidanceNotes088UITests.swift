// UI tests (iOS only) for the notes surface over WorkspaceActionLoopback's owned fixture peer, covering menu,
// scrolling, retry, and close.

#if os(iOS)
    import XCTest

    final class GuidanceNotes088UITests: XCTestCase {
        private var app: XCUIApplication!
        private var peer: WorkspaceActionLoopback!
        override func setUpWithError() throws {
            continueAfterFailure = false
            peer = try WorkspaceActionLoopback(
                replies: [:], supportsWebSocket: true, supportsWorkReads: true, supportsGuidanceNotes: true)
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
                        [
                            "key": "guidance", "kind": "action", "label": "Private notes", "icon": "note.text",
                            "action": ["surface": "guidance", "params": ["mode": "list"]],
                        ]
                    ], "menu": [],
                ],
            ])
            XCTAssertTrue(app.buttons["Private notes"].waitForExistence(timeout: 5))
            app.buttons["Private notes"].tap()
        }
        override func tearDown() {
            if let peer {
                let attachment = XCTAttachment(
                    data: try! JSONSerialization.data(
                        withJSONObject: peer.workFrames.map { try! JSONSerialization.jsonObject(with: $0) }),
                    uniformTypeIdentifier: "public.json")
                attachment.name = "Actual iOS synthetic notes frames"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertTrue(peer.unexpectedRequests.isEmpty)
            }
            app?.terminate()
            peer?.stop()
            super.tearDown()
        }
        private func request(_ count: Int, action: String) throws -> [String: Any] {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.peer.workFrames.count >= count }, object: nil)
            wait(for: [ready], timeout: 5)
            let frame = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: XCTUnwrap(peer.workFrames.last)) as? [String: Any])
            XCTAssertEqual(frame["action"] as? String, action)
            XCTAssertTrue(frame["session_id"] is NSNull)
            return frame
        }
        private func reply(_ request: [String: Any], mode: String) throws {
            var frames = try JSONSerialization.jsonObject(with: Data(Self.framesJSON.utf8)) as! [String: [String: Any]]
            frames[mode]!["request_generation"] = request["request_generation"]!
            try peer.sendWorkFrame(frames[mode]!)
        }
        private func tap(_ element: XCUIElement) {
            for _ in 0..<16 where !element.isHittable {
                let directionDown = element.exists && element.frame.midY < app.frame.height * 0.2
                if directionDown {
                    app.scrollViews.firstMatch.swipeDown()
                } else {
                    app.scrollViews.firstMatch.swipeUp()
                }
            }
            XCTAssertTrue(element.isHittable, app.debugDescription)
            element.tap()
        }
        func testActualCreateFieldsExpiryVisibilityAndUnknownWriteRetry() throws {
            try reply(request(1, action: "chrome_open"), mode: "list")
            XCTAssertTrue(app.buttons["Add note"].waitForExistence(timeout: 5))
            app.buttons["Add note"].tap()
            try reply(request(2, action: "chrome_open"), mode: "new")
            let category = app.buttons["param-field-category"]
            XCTAssertTrue(category.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(category.value as? String, "Context")
            category.tap()
            app.buttons["Goal"].tap()
            let value = app.textViews["param-field-value"]
            tap(value)
            value.typeText("**Literal note** <b>no markup</b>\nSecond line")
            app.staticTexts["param-picker-form-title"].tap()
            tap(app.switches["param-field-enabled"])
            let expiry = app.buttons["param-field-expiry"]
            XCTAssertEqual(expiry.value as? String, "No expiry")
            XCTAssertFalse(app.textFields["param-field-expiry_date"].exists)
            tap(expiry)
            app.buttons["Set a date"].tap()
            let date = app.textFields["param-field-expiry_date"]
            XCTAssertTrue(date.waitForExistence(timeout: 3), app.debugDescription)
            tap(date)
            date.typeText("2027-01-01T00:00:00Z")
            app.keyboards.buttons["Return"].tap()
            tap(app.buttons["param-action-chrome_note_save"])
            let save = try request(3, action: "chrome_note_save")
            let payload = try XCTUnwrap(save["payload"] as? [String: Any])
            let fields = try XCTUnwrap(payload["fields"] as? [String: Any])
            XCTAssertEqual(payload["expected_revision"] as? Int, 0)
            XCTAssertEqual(fields["category"] as? String, "Goal")
            XCTAssertEqual(fields["value"] as? String, "**Literal note** <b>no markup</b>\nSecond line")
            XCTAssertEqual(fields["enabled"] as? Bool, false)
            XCTAssertEqual(fields["expiry"] as? String, "Set a date")
            XCTAssertEqual(fields["expiry_date"] as? String, "2027-01-01T00:00:00Z")
            try peer.sendWorkFrame([
                "type": "error", "submission_id": save["submission_id"]!, "accepted": false,
                "code": "capacity_exceeded", "message": "Try later", "retryable": true, "retry_after_ms": NSNull(),
            ])
            XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
            app.buttons["Retry"].tap()
            let retry = try request(4, action: "chrome_open")
            XCTAssertEqual((retry["payload"] as? [String: Any])?["params"] as? [String: String], ["mode": "list"])
            XCTAssertNotEqual(save["request_generation"] as? String, retry["request_generation"] as? String)
            try reply(retry, mode: "list")
            XCTAssertTrue(app.buttons["Add note"].waitForExistence(timeout: 5))
            app.buttons["Close"].firstMatch.tap()
            _ = try request(5, action: "chrome_close")
        }
        func testActualLiteralCurrentValueToggleAndForgetReview() throws {
            try reply(request(1, action: "chrome_open"), mode: "list")
            let literal =
                "Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private"
            XCTAssertTrue(app.staticTexts[literal].waitForExistence(timeout: 5))
            XCTAssertFalse(app.links[literal].exists)
            tap(app.buttons["Disable"])
            let toggle = try request(2, action: "chrome_note_toggle")
            let payload = try XCTUnwrap(toggle["payload"] as? [String: Any])
            XCTAssertEqual(payload["expected_revision"] as? Int, 3)
            XCTAssertEqual(payload["enabled"] as? Bool, false)
            try reply(toggle, mode: "list")
            XCTAssertTrue(app.buttons["Add note"].waitForExistence(timeout: 5))
            tap(app.buttons["Forget"])
            let review = try request(3, action: "chrome_open")
            try reply(review, mode: "forget")
            XCTAssertTrue(app.buttons["Keep note"].waitForExistence(timeout: 5))
            XCTAssertTrue(
                app.staticTexts["Forget permanently erases this note's current value. This cannot be undone."].exists)
            tap(app.buttons["Forget note"])
            let forget = try request(4, action: "chrome_note_forget")
            XCTAssertEqual((forget["payload"] as? [String: Any])?["expected_revision"] as? Int, 3)
            try reply(forget, mode: "list")
            XCTAssertTrue(app.buttons["Add note"].waitForExistence(timeout: 5))
            app.buttons["Close"].firstMatch.tap()
            _ = try request(5, action: "chrome_close")
        }
        private static let framesJSON =
            #"{"list":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"text","content":"Private notes are guidance you can select for your work.","variant":"body"},{"type":"button","label":"Add note","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"new"}},"variant":"secondary","disabled":false,"local":false},{"type":"param_picker","title":"","description":"","fields":[{"name":"search","label":"Search notes","kind":"text","default":""}],"submit_label":"Search","submit_action":"chrome_note_search","submit_payload":{}},{"type":"card","title":"Preference","content":[{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"},{"type":"button","label":"Edit","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"edit","note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}},"variant":"secondary","disabled":false,"local":false},{"type":"button","label":"Disable","action":"chrome_note_toggle","payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3,"enabled":false},"variant":"secondary","disabled":false,"local":false},{"type":"button","label":"Forget","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"forget","note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}},"variant":"secondary","disabled":false,"local":false}],"variant":"default"},{"type":"button","label":"Refresh","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list","search":""}},"variant":"secondary","disabled":false,"local":false}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"},"new":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Back to notes","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"param_picker","title":"Add note","description":"","fields":[{"name":"category","label":"Category","kind":"select","default":"Context","options":["Profession","Goal","Preference","Workflow tag","Context"]},{"name":"value","label":"Note","kind":"textarea","default":"","help":"Describe your preferences or context. Do not include patient information."},{"name":"enabled","label":"Enabled","kind":"boolean","default":true},{"name":"expiry","label":"Expiry","kind":"select","default":"No expiry","options":["No expiry","Set a date"]},{"name":"expiry_date","label":"Expiry date (UTC)","kind":"text","default":"","help":"Use a UTC date and time, for example 2026-12-31T23:59:00Z.","visible_when":{"expiry":"Set a date"}}],"submit_label":"Save note","submit_action":"chrome_note_save","submit_payload":{"note_id":"0fe0d7ba-812a-4881-9f61-77e23327d492","expected_revision":0}}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"},"edit":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Back to notes","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"text","content":"Current note","variant":"h3"},{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"},{"type":"param_picker","title":"Edit note","description":"","fields":[{"name":"category","label":"Category","kind":"select","default":"Preference","options":["Profession","Goal","Preference","Workflow tag","Context"]},{"name":"value","label":"Note","kind":"textarea","default":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","help":"Describe your preferences or context. Do not include patient information."},{"name":"enabled","label":"Enabled","kind":"boolean","default":true},{"name":"expiry","label":"Expiry","kind":"select","default":"Keep current expiry","options":["Keep current expiry","No expiry","Set a date"]},{"name":"expiry_date","label":"Expiry date (UTC)","kind":"text","default":"","help":"Use a UTC date and time, for example 2026-12-31T23:59:00Z.","visible_when":{"expiry":"Set a date"}}],"submit_label":"Save note","submit_action":"chrome_note_save","submit_payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"},"forget":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Keep note","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"card","title":"Preference","content":[{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"}],"variant":"default"},{"type":"alert","message":"Forget permanently erases this note's current value. This cannot be undone.","variant":"warning"},{"type":"button","label":"Forget note","action":"chrome_note_forget","payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3},"variant":"danger","disabled":false,"local":false}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"}}"#
    }
#endif
