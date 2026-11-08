// Tests that app-wide Mac events reach their handlers with no window or view mounted.

#if os(macOS)
    import AVFoundation
    import AppKit
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacAppLifecycleTests: XCTestCase {
        private var calls: [String] = []
        private let appCenter = NotificationCenter()
        private let workspaceCenter = NotificationCenter()

        private func lifecycle() -> MacAppLifecycle {
            MacAppLifecycle(
                handlers: .init(
                    sessionLocked: { self.calls.append("locked") },
                    screensSlept: { self.calls.append("slept") },
                    sessionUnlocked: { self.calls.append("unlocked") },
                    connectionMayHaveChanged: { self.calls.append("connection") },
                    audioConfigurationChanged: { self.calls.append("audio") },
                    willTerminate: { self.calls.append("quit") }),
                appCenter: appCenter, workspaceCenter: workspaceCenter)
        }

        func testQuitCleanupRunsBeforeThePostReturnsWithNoWindow() {
            let subject = lifecycle()
            appCenter.post(name: NSApplication.willTerminateNotification, object: nil)
            XCTAssertEqual(calls, ["quit"])
            withExtendedLifetime(subject) {}
        }

        func testLockAndWakeEventsReachTheirHandlers() async {
            let subject = lifecycle()
            workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            appCenter.post(name: .AVAudioEngineConfigurationChange, object: nil)
            await Task.yield()
            XCTAssertEqual(calls, ["locked", "slept", "unlocked", "connection", "connection", "audio"])
            withExtendedLifetime(subject) {}
        }

        func testReleasedObserversStopFiring() {
            var subject: MacAppLifecycle? = lifecycle()
            XCTAssertNotNil(subject)
            subject = nil
            appCenter.post(name: NSApplication.willTerminateNotification, object: nil)
            XCTAssertEqual(calls, [])
        }
    }
#endif
