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
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }
}
