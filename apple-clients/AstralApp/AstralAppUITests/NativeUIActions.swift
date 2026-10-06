// Activates fixture controls using each platform's native input event.
// Shared UI tests use macOS clicks and iOS taps without changing their behavior assertions.

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
