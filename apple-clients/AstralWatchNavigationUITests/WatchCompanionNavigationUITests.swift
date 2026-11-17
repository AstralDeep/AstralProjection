// Drives the shipped watch companion shell against the scripted phone in the navigation harness.
// Covers the relayed chat list and chat, the phone-out-of-reach state and the no-mesh state.

import XCTest

@MainActor
final class WatchCompanionNavigationUITests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ASTRAL_WATCH_NAVIGATION_SCENARIO"] = scenario
        app.launch()
        return app
    }

    func testRelayedChatsOpenIntoTheRelayedConversation() throws {
        let app = launch("ready")
        let row = app.buttons["Morning plan"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Lab results"].exists)
        row.tap()
        XCTAssertTrue(app.staticTexts["Astral: good morning"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["voice.conversation.primary"].exists)
    }

    func testPhoneOutOfReachShowsAPlainState() throws {
        let app = launch("unreachable")
        XCTAssertTrue(
            app.staticTexts["Your iPhone is out of reach"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Morning plan"].exists)
    }

    func testNoMeshShowsAPlainState() throws {
        let app = launch("no_mesh")
        XCTAssertTrue(
            app.staticTexts["Open your mesh on your iPhone"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Morning plan"].exists)
    }
}
