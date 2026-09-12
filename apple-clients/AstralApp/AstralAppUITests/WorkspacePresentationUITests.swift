import XCTest

final class WorkspacePresentationUITests: XCTestCase {
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
