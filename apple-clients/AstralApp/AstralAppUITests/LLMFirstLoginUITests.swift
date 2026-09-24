// UI tests for LLM first-login: immediate feedback and phase responsiveness, invalid-credential and
// provider-unavailable terminals stay editable and retryable, and the 10-second watchdog never invents a
// server terminal.

import XCTest

final class LLMFirstLoginUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testImmediateFeedbackPhaseResponsivenessAndSuccess() throws {
        let peer = try WorkspaceActionLoopback(replies: [.firstLoginCompletion: [.init(status: 204, held: true)]])
        peer.start()
        defer { peer.stop() }
        wait(for: [peer.ready], timeout: 2)
        let port = try XCTUnwrap(peer.port)
        launch(scenario: "slow-success", completionPort: port)
        let form = element("llm-provider-form-title")
        let apiKey = app.secureTextFields["param-field-api_key"]
        let save = app.buttons["llm-save-button"]

        XCTAssertTrue(form.waitForExistence(timeout: 5))
        XCTAssertTrue(apiKey.waitForExistence(timeout: 2))
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        focusAndType(apiKey, "ui-only-placeholder")
        let status = app.staticTexts["llm-save-status"]
        _ = status.exists
        save.tap()
        XCTAssertTrue(
            status.waitForExistence(timeout: 0.25),
            "Save must expose local-only submitting feedback within 250 ms")
        XCTAssertEqual(status.label, "AI provider setup status")
        XCTAssertFalse(save.isEnabled, "only the duplicate Save control is single-flight disabled")
        XCTAssertEqual(save.value as? String, "Submitting")
        XCTAssertTrue(apiKey.isEnabled)
        focusAndType(apiKey, "x")
        XCTAssertTrue(
            waitForStatus(
                status,
                containingAny: ["Waiting to check", "Checking your provider credentials", "Saving credentials"],
                timeout: 1.25),
            "an operation still active after one second must expose its current phase")
        XCTAssertTrue(form.exists)
        XCTAssertEqual(peer.requests.count, 1)
        XCTAssertEqual(peer.requests.first?.route, .firstLoginCompletion)
        XCTAssertEqual(peer.requests.first?.authorization, "")
        XCTAssertTrue(peer.requests.first?.body.isEmpty == true)
        XCTAssertTrue(peer.unexpectedRequests.isEmpty)

        let terminalReleasedAt = Date()
        peer.releaseHeldReplies()
        XCTAssertTrue(form.waitForNonExistence(timeout: 5))
        XCTAssertLessThan(
            Date().timeIntervalSince(terminalReleasedAt), 5,
            "durably completed first-login setup must advance exactly once within five seconds")
    }

    func testInvalidCredentialTerminalKeepsSecureFormEditableAndRetryable() {
        launch(scenario: "invalid-credentials")
        let apiKey = app.secureTextFields["param-field-api_key"]
        let save = app.buttons["llm-save-button"]
        XCTAssertTrue(apiKey.waitForExistence(timeout: 5))
        focusAndType(apiKey, "invalid-ui-placeholder")
        let status = app.staticTexts["llm-save-status"]
        save.tap()

        XCTAssertTrue(
            waitForStatus(status, containingAny: ["Check your provider credentials"], timeout: 3))
        XCTAssertTrue(apiKey.isEnabled)
        XCTAssertTrue(waitForEnabled(save, enabled: true, timeout: 2))
        XCTAssertEqual(save.value as? String, "Ready")

        focusAndType(apiKey, "-corrected")
    }

    func testProviderUnavailableTerminalIsExplicitAndRetryable() {
        launch(scenario: "provider-unavailable")
        let apiKey = app.secureTextFields["param-field-api_key"]
        let save = app.buttons["llm-save-button"]
        XCTAssertTrue(apiKey.waitForExistence(timeout: 5))
        focusAndType(apiKey, "unavailable-ui-placeholder")
        let status = app.staticTexts["llm-save-status"]
        save.tap()

        XCTAssertTrue(
            waitForStatus(status, containingAny: ["Provider unavailable"], timeout: 3))
        XCTAssertTrue(apiKey.isEnabled)
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(element("llm-provider-form-title").exists)
    }

    func testTenSecondWatchdogEndsLoadingWithoutInventingServerTerminal() {
        launch(scenario: "client-watchdog")
        let apiKey = app.secureTextFields["param-field-api_key"]
        let save = app.buttons["llm-save-button"]
        XCTAssertTrue(apiKey.waitForExistence(timeout: 5))
        focusAndType(apiKey, "timeout-ui-placeholder")

        let status = app.staticTexts["llm-save-status"]
        _ = status.exists
        save.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 0.25))
        let acknowledgedAt = Date()
        let sceneExerciseStarted = Date()
        exerciseSceneOrWindowResponsiveness()
        let sceneOverhead = Date().timeIntervalSince(sceneExerciseStarted)
        XCTAssertTrue(
            waitForStatus(
                status,
                containingAny: ["Unable to confirm; reconnecting"],
                timeout: 11 + sceneOverhead))
        XCTAssertLessThan(Date().timeIntervalSince(acknowledgedAt) - sceneOverhead, 11.5)
        XCTAssertTrue(apiKey.isEnabled)
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.value as? String, "Ready")

        save.tap()
        XCTAssertTrue(save.isEnabled)
        let retainedStatus = app.staticTexts["llm-save-status"]
        XCTAssertEqual(retainedStatus.value as? String, "Unable to confirm; reconnecting")
    }

    private func launch(scenario: String, completionPort: UInt16? = nil) {
        app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", scenario]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        if let completionPort {
            app.launchEnvironment["ASTRAL_UI_FIRST_LOGIN_GATE_PORT"] = String(completionPort)
        }
        app.launch()
    }

    private func focusAndType(_ field: XCUIElement, _ text: String) {
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
            guard field.exists else {
                XCTFail("The provider field disappeared before the editing assertion completed")
                return
            }
            field.tap()
            if fieldHasFocus(field) { break }
        }
        XCTAssertTrue(field.exists, "The provider field must remain available for typing")
        field.typeText(text)
    }

    private func fieldHasFocus(_ field: XCUIElement) -> Bool {
        #if os(macOS)
            return true
        #else
            return (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
        #endif
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitForStatus(
        _ status: XCUIElement,
        containingAny fragments: [String],
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement,
                let value = element.value as? String
            else { return false }
            return fragments.contains { value.localizedCaseInsensitiveContains($0) }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: status)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForEnabled(
        _ element: XCUIElement,
        enabled: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { candidate, _ in
            (candidate as? XCUIElement)?.isEnabled == enabled
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func exerciseSceneOrWindowResponsiveness() {
        #if os(iOS)
            XCUIDevice.shared.press(.home)
            app.activate()
            let foreground = NSPredicate { candidate, _ in
                (candidate as? XCUIApplication)?.state == .runningForeground
            }
            let expectation = XCTNSPredicateExpectation(predicate: foreground, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 2), .completed)
        #else
            app.activate()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 1))
        #endif
    }
}
