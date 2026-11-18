// Checks the macOS menu bar companion status line and that opening the app reuses the existing main window.
// The menu offers only opening the app and Settings, so no action depends on a server session.

#if os(macOS)
    import XCTest
    @testable import AstralDeep

    final class MacMenuBarContentTests: XCTestCase {
        @MainActor private func window(_ title: String) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                backing: .buffered, defer: true)
            window.title = title
            window.isReleasedWhenClosed = false
            return window
        }

        @MainActor func testOpeningTheAppReusesTheVisibleMainWindow() {
            let other = window("Settings")
            let main = window("AstralDeep")
            other.orderFront(nil)
            main.orderFront(nil)
            defer {
                other.orderOut(nil)
                main.orderOut(nil)
            }
            XCTAssertTrue(MacMainWindow.reusable(in: [other, main]) === main)
            main.orderOut(nil)
            XCTAssertNil(MacMainWindow.reusable(in: [other, main]))
        }

        @MainActor func testAHiddenAppReusesItsMainWindowInsteadOfOpeningAnother() {
            let other = window("Settings")
            let main = window("AstralDeep")
            XCTAssertFalse(main.isVisible)
            XCTAssertTrue(MacMainWindow.reusable(in: [other, main], appHidden: true) === main)
            XCTAssertNil(MacMainWindow.reusable(in: [other], appHidden: true))
            XCTAssertNil(MacMainWindow.reusable(in: [other, main], appHidden: false))
        }

        func testStatusReportsTheUpdateGate() {
            XCTAssertEqual(MacMenuBarPresentation(updateRequired: false).status, "Ready")
            XCTAssertEqual(MacMenuBarPresentation(updateRequired: true).status, "Update required")
        }
    }
#endif
