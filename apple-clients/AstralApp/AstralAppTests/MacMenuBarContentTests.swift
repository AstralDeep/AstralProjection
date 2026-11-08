// Checks that the macOS menu bar companion suppresses remote and local task actions when authority changes.
// The view consumes these decisions while the server and computer host still enforce every action.

#if os(macOS)
    import XCTest
    @testable import AstralDeep

    final class MacMenuBarContentTests: XCTestCase {
        private func state(
            signedIn: Bool = true, connected: Bool = true, navigationLocked: Bool = false,
            updateRequired: Bool = false, turnActive: Bool = false, waitingApprovals: Int = 0,
            workAvailable: Bool = true, computerAvailable: Bool = true, computerTaskActive: Bool = true,
            computerPaused: Bool = false, computerCanResume: Bool = false
        ) -> MacMenuBarPresentation {
            MacMenuBarPresentation(
                signedIn: signedIn, connected: connected, navigationLocked: navigationLocked,
                updateRequired: updateRequired, turnActive: turnActive, waitingApprovals: waitingApprovals,
                workAvailable: workAvailable, computerAvailable: computerAvailable,
                computerTaskActive: computerTaskActive, computerPaused: computerPaused,
                computerCanResume: computerCanResume)
        }

        @MainActor private func window(_ title: String) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                backing: .buffered, defer: true)
            window.title = title
            window.isReleasedWhenClosed = false
            return window
        }

        @MainActor func testOpeningTheAppReusesTheVisibleMainWindow() {
            let quickEntry = window("Quick Entry")
            let main = window("AstralDeep")
            quickEntry.orderFront(nil)
            main.orderFront(nil)
            defer {
                quickEntry.orderOut(nil)
                main.orderOut(nil)
            }
            XCTAssertTrue(MacMainWindow.reusable(in: [quickEntry, main]) === main)
            main.orderOut(nil)
            XCTAssertNil(MacMainWindow.reusable(in: [quickEntry, main]))
        }

        @MainActor func testAHiddenAppReusesItsMainWindowInsteadOfOpeningAnother() {
            let quickEntry = window("Quick Entry")
            let main = window("AstralDeep")
            XCTAssertFalse(main.isVisible)
            XCTAssertTrue(MacMainWindow.reusable(in: [quickEntry, main], appHidden: true) === main)
            XCTAssertNil(MacMainWindow.reusable(in: [quickEntry], appHidden: true))
            XCTAssertNil(MacMainWindow.reusable(in: [quickEntry, main], appHidden: false))
        }

        func testRemoteActionsRequireCurrentConnectedNavigableSession() {
            XCTAssertTrue(state().canOpenWork)
            XCTAssertTrue(state().canOpenSchedule)
            XCTAssertFalse(state(connected: false).canOpenWork)
            XCTAssertFalse(state(connected: false).canOpenSchedule)
            XCTAssertFalse(state(signedIn: false).canStartChat)
            XCTAssertFalse(state(signedIn: false).canOpenSchedule)
            XCTAssertFalse(state(navigationLocked: true).canOpenWork)
            XCTAssertFalse(state(workAvailable: false).canOpenWork)
            XCTAssertFalse(state(updateRequired: true).canStartChat)
            XCTAssertFalse(state(updateRequired: true).canOpenSchedule)
        }

        func testComputerTaskActionsReflectLocalSessionAndResumeReadiness() {
            XCTAssertTrue(state().canPauseComputer)
            XCTAssertTrue(state().canStopComputer)
            XCTAssertFalse(state(computerPaused: true).canPauseComputer)
            XCTAssertFalse(state(computerTaskActive: false).canStopComputer)
            XCTAssertFalse(state(computerAvailable: false).canPauseComputer)
            XCTAssertTrue(state(signedIn: false, connected: false, updateRequired: true).canStopComputer)
            XCTAssertFalse(state(computerPaused: true).canReviewResume)
            XCTAssertTrue(state(computerPaused: true, computerCanResume: true).canReviewResume)
            XCTAssertFalse(state(connected: false, computerCanResume: true).canReviewResume)
        }

        func testStatusDistinguishesDisconnectedWorkAndUpdateGate() {
            XCTAssertEqual(state(computerTaskActive: false).status, "Ready")
            XCTAssertEqual(state(turnActive: true, computerTaskActive: false).status, "Working")
            XCTAssertEqual(state().status, "Computer task active")
            XCTAssertEqual(state(computerPaused: true).status, "Computer task paused")
            XCTAssertEqual(state(connected: false).status, "Disconnected")
            XCTAssertEqual(state(signedIn: false).status, "Sign in required")
            XCTAssertEqual(state(updateRequired: true).status, "Update required")
        }
    }
#endif
