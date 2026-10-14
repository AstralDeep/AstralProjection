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

    func testInterruptedVoiceSessionKeepsServerControlsAndTypedFallbackAvailable() {
        app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "voice-interruption"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()

        // Scene churn may re-drive the controller after the fixture installs, so pin controls and status presence rather than one transient message.
        let status = app.descendants(matching: .any)["voice-conversation-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertFalse(status.label.isEmpty)

        let end = app.buttons["voice-control-voice-end"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertEqual(end.label, "End voice conversation")
        XCTAssertTrue(end.isEnabled)
        XCTAssertTrue(end.isHittable)
        XCTAssertTrue(app.buttons["voice-control-voice-microphone"].exists)
        XCTAssertTrue(app.buttons["voice-control-voice-mute"].exists)

        let composer = app.textFields["chat-composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(composer.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["voice-request-terminal-notice"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "apple-voice-interruption-065"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRecoveredVoiceAcceptsExactlyOneTurnAndStaysFencedAgainstStaleNoticeReplays() {
        app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "voice-recovery"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()

        let status = app.descendants(matching: .any)["voice-conversation-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertFalse(status.label.isEmpty)

        let staleNotice = app.descendants(matching: .any)["voice-request-terminal-notice"]
        XCTAssertTrue(
            staleNotice.waitForNonExistence(timeout: 3),
            "the interrupted turn's failure notice must be cleared by exactly the newer accepted turn "
                + "and must stay cleared across same-turn churn, older-turn replays, and duplicates")

        let end = app.buttons["voice-control-voice-end"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertEqual(end.label, "End voice conversation")
        XCTAssertTrue(end.isEnabled)
        XCTAssertTrue(end.isHittable)

        let composer = app.textFields["chat-composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(composer.isHittable)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "apple-voice-recovery-065"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
