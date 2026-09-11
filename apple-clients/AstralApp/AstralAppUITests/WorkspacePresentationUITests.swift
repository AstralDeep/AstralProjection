import XCTest

final class WorkspacePresentationUITests: XCTestCase {
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
