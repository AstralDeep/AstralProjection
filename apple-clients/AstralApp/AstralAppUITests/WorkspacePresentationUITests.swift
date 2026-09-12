import XCTest

final class WorkspacePresentationUITests: XCTestCase {
    func testWorkspaceActionsFollowServerOrderKeepNativeTargetsAndLeaveWithCanvas() {
        let app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "workspace-actions"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
        defer { app.terminate() }
        let export = app.buttons["workspace-action-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        let share = app.buttons["workspace-action-share"]
        XCTAssertTrue(share.exists)
        XCTAssertFalse(app.buttons["Export this canvas as HTML"].exists)
        let controls = [
            app.buttons["new-chat-button"], app.buttons["Recent chats"], export, share,
            app.buttons["Pulse"], app.buttons["Timeline"],
        ]
        let window = app.windows.firstMatch.frame
        for (index, control) in controls.enumerated() {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertGreaterThanOrEqual(control.frame.minX, window.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, window.maxX)
            if index > 0 {
                let previous = controls[index - 1].frame
                XCTAssertTrue(control.frame.minY > previous.minY || control.frame.minX >= previous.maxX)
            }
        }
        capture(app, name: "workspace-088-server-actions-native-wrap")
        app.buttons["new-chat-button"].tap()
        XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 3))
        XCTAssertFalse(export.exists)
        XCTAssertFalse(share.exists)
    }

    func testHistoryPreviewsDistinguishSameTitleConversationsAndOpenExactRow() {
        let app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "workspace-history"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
        defer { app.terminate() }
        let preview = app.staticTexts["Alpha = 2 Beta = 5"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["First preview"].exists)
        XCTAssertTrue(app.staticTexts["3h"].exists)
        capture(app, name: "workspace-088-history-server-rows")
        preview.tap()
        XCTAssertTrue(app.staticTexts["Opened second history row"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Opened first history row"].exists)
    }

    func testMetricContentAndNativeNewChatTargetMatchWebWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "workspace-styles"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
        defer { app.terminate() }

        let total = app.staticTexts["TOTAL"]
        XCTAssertTrue(total.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["18"].exists)
        XCTAssertTrue(app.staticTexts["Six dice"].exists)
        XCTAssertTrue(app.staticTexts["COMPLETED"].exists)
        let newChat = app.buttons["new-chat-button"]
        XCTAssertGreaterThanOrEqual(newChat.frame.width, 44)
        XCTAssertGreaterThanOrEqual(newChat.frame.height, 44)
        capture(app, name: "workspace-088-card-metrics-native-target")
        newChat.tap()
        XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 3))
        XCTAssertFalse(total.exists)
    }

    func testPhoneCanvasRemainsResponsiveWhileCollapsingAndScrollingMessages() throws {
        #if os(iOS)
            let app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-canvas"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launch()
            defer { app.terminate() }

            guard app.windows.firstMatch.frame.width < 700 else {
                throw XCTSkip("requires the phone stacked workspace layout")
            }
            let toggle = app.buttons["workspace-messages-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            let canvas = app.scrollViews["workspace-canvas-scroll"]
            XCTAssertTrue(canvas.exists)
            for _ in 0..<5 {
                toggle.tap()
                XCTAssertFalse(app.scrollViews["conversation-message-scroll"].exists)
                canvas.swipeUp()
                XCTAssertTrue(app.staticTexts["Canvas layout end"].waitForExistence(timeout: 3))
                toggle.tap()
                XCTAssertTrue(app.scrollViews["conversation-message-scroll"].waitForExistence(timeout: 3))
                canvas.swipeDown()
            }
            let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
            composer.tap()
            composer.typeText("Still responsive")
            XCTAssertTrue((composer.value as? String ?? "").contains("Still responsive"))
            capture(app, name: "workspace-088-canvas-collapse-scroll-synthetic-fixture")
        #endif
    }

    func testStartComposerDisclosureAndIrreversibleWorkTransition() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "workspace-start"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
        defer { app.terminate() }

        let title = app.staticTexts["How can I help?"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        capture(app, name: "workspace-088-start-synthetic-fixture")
        XCTAssertTrue(app.buttons["Research brief"].exists)
        XCTAssertFalse(app.buttons["Business dashboard"].exists)
        app.buttons["More examples"].tap()
        XCTAssertTrue(app.buttons["Business dashboard"].waitForExistence(timeout: 3))
        capture(app, name: "workspace-088-more-synthetic-fixture")
        app.buttons["More examples"].tap()

        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
        XCTAssertTrue(composer.exists)
        composer.tap()
        composer.typeText("Second line")
        XCTAssertTrue((composer.value as? String ?? "").contains("Second line"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-088-multiline-composer"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["Workspace result"].waitForExistence(timeout: 5))
        capture(app, name: "workspace-088-work-synthetic-fixture")
        XCTAssertFalse(title.exists)
        XCTAssertFalse(app.buttons["Research brief"].exists)
        app.buttons["New chat"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
