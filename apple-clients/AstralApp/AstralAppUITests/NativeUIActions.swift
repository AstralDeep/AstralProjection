// Activates fixture controls using each platform's native input event and waits on fixture conditions.
// Shared UI tests use macOS clicks and iOS taps, and poll conditions so a wait ends as soon as it holds.

import XCTest

extension XCUIElement {
    func press() {
        #if os(macOS)
            click()
        #else
            tap()
        #endif
    }
}

extension XCTestCase {
    #if os(iOS)
        static func requireIOSFixtureReadiness(file: StaticString = #filePath, line: UInt = #line) {
            let app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-navigation"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launch()
            let result = app.staticTexts["Existing navigation result"]
            let visible = result.waitForExistence(timeout: 8) && result.isHittable
            app.terminate()
            let stopped = app.wait(for: .notRunning, timeout: 8)
            XCTAssertTrue(visible, "The isolated simulator readiness fixture must be visible", file: file, line: line)
            XCTAssertTrue(
                stopped, "The simulator readiness fixture must terminate before tests", file: file, line: line)
        }
    #endif

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }
}
