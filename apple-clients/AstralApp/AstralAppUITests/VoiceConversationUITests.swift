// UI tests for the voice composer control's accessibility and typed-fallback availability, driven by the
// DEBUG fixture reducer without opening real media, credentials, or a network connection.

import XCTest

final class VoiceConversationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testVoiceControlIsAccessibleInComposerAndTypedFallbackRemainsAvailable() {
        app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "voice-composer"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()

        let voice = app.buttons["voice-control-voice-start"]
        let composer = app.textFields["chat-composer-input"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertEqual(voice.label, "Start voice conversation")
        XCTAssertEqual(voice.value as? String, "Off")
        XCTAssertTrue(voice.isEnabled)
        XCTAssertTrue(voice.isHittable)

        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        XCTAssertEqual(composer.label, "Message AstralDeep")
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(composer.isHittable)
        XCTAssertLessThan(
            abs(voice.frame.midY - composer.frame.midY), 80,
            "voice must remain attached to the chat composer rather than a remote settings surface")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "apple-voice-composer-065"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTerminalVoiceRequestAlertIsAccessibleAndTypedComposerStaysEnabled() {
        app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "voice-terminal"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()

        let notice = app.descendants(matching: .any)["voice-request-terminal-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Voice request alert")
        let value = notice.value as? String ?? ""
        XCTAssertTrue(value.contains("Warning. Request did not complete."))
        XCTAssertTrue(value.contains("The provider could not complete this request."))

        let composer = app.textFields["chat-composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(composer.isHittable)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "apple-voice-terminal-notice-065"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
