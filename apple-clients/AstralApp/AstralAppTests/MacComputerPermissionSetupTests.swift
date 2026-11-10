// Covers the manual setup a Mac shows once macOS stops prompting for a computer permission: the opened pane, the
// app revealed in Finder, the numbered steps and their controls, Relaunch, and refresh clearing them once granted.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacComputerPermissionSetupTests: XCTestCase {
        private final class Probe {
            var accessibility = false
            var screen = false
            var monitoring = false
            var requested: [MacComputerPermission] = []
            var opened: [String] = []
            var revealed: [URL] = []
            var relaunches = 0
            var opens = true
            var relaunched = true

            func grant(_ permission: MacComputerPermission) {
                switch permission {
                case .accessibility: accessibility = true
                case .screen: screen = true
                case .monitoring: monitoring = true
                }
            }
        }

        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func host(_ probe: Probe, available: Bool = true) throws -> MacComputerHost {
            let suite = "MacComputerPermissionSetupTests." + UUID().uuidString
            suites.append(suite)
            let host = MacComputerHost(
                available: available, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                driver: MacComputerTaskDriver(), monitor: MacComputerTaskMonitor(),
                permissionProvider: {
                    MacComputerPermissions(
                        accessibility: probe.accessibility, screen: probe.screen, monitoring: probe.monitoring)
                },
                permissionRequester: {
                    probe.requested.append($0)
                    return false
                },
                settingsOpener: {
                    probe.opened.append($0.absoluteString)
                    return probe.opens
                },
                appRevealer: { probe.revealed.append($0) },
                relauncher: {
                    probe.relaunches += 1
                    return probe.relaunched
                }, desktopProbe: { true }, desktopRearm: { false }, system: MacComputerTestSystem(),
                panelPresenter: { _ in })
            addTeardownBlock { host.applicationWillTerminate() }
            return host
        }

        private static let pane = "x-apple.systempreferences:com.apple.preference.security?"

        private func accessibilityIdentifiers(_ mount: SurfaceMount) -> Set<String> {
            _ = try? mount.accessibility  // SwiftUI builds its accessibility tree only after a client asks for it.
            var found = Set<String>()
            func walk(_ element: AnyObject, depth: Int) {
                if let identifier = element.accessibilityIdentifier?(), !identifier.isEmpty { found.insert(identifier) }
                guard depth < 64 else { return }
                for child in element.accessibilityChildren?() ?? [] { walk(child as AnyObject, depth: depth + 1) }
            }
            walk(mount.view, depth: 0)
            return found
        }

        nonisolated private static func exists(_ url: URL) -> NSPredicate {
            NSPredicate { _, _ in FileManager.default.fileExists(atPath: url.path) }
        }

        func testStepsNameEachPaneAndOnlyScreenRecordingAndInputMonitoringNeedARelaunch() {
            let all: [MacComputerPermission] = [.accessibility, .screen, .monitoring]
            XCTAssertEqual(all.map(\.needsRelaunch), [false, true, true])
            for permission in all {
                let steps = permission.setupSteps
                XCTAssertEqual(steps.count, 5)
                XCTAssertEqual(steps[0], "Open Privacy & Security > \(permission.pane) in System Settings.")
                XCTAssertEqual(steps[1], "If AstralDeep is already listed, select it and click −.")
                XCTAssertEqual(steps[2], "Click +, then choose AstralDeep or drag it in from Finder.")
                XCTAssertEqual(steps[3], "Switch AstralDeep on.")
                XCTAssertEqual(
                    steps[4],
                    permission.needsRelaunch
                        ? "Choose Relaunch. \(permission.title) takes effect after AstralDeep reopens."
                        : "Choose Refresh permissions.")
                XCTAssertTrue(steps.allSatisfy { $0.count <= 80 }, "\(steps)")
            }
            XCTAssertEqual(
                MacComputerPermission.screen.noPromptGuidance, "macOS no longer prompts for Screen Recording.")
        }

        func testUngrantedRequestOpensThePaneRevealsTheAppAndKeepsStepsUntilThatPermissionIsGranted() throws {
            let probe = Probe()
            let host = try host(probe)
            MacComputerControlCommand.permission(.screen).perform(on: host)
            XCTAssertEqual(probe.requested, [.screen])
            XCTAssertEqual(probe.opened, [Self.pane + "Privacy_ScreenCapture"])
            XCTAssertEqual(probe.revealed, [Bundle.main.bundleURL])
            XCTAssertEqual(host.permissionSetup, .screen)
            let guidance = try XCTUnwrap(host.lastError)
            XCTAssertEqual(guidance.leadSentence, "Screen Recording request returned not granted.")

            MacComputerControlCommand.refreshPermissions.perform(on: host)
            XCTAssertEqual(host.permissionSetup, .screen)
            XCTAssertEqual(host.lastError, guidance)
            probe.grant(.accessibility)
            probe.grant(.monitoring)
            MacComputerControlCommand.refreshPermissions.perform(on: host)
            XCTAssertEqual(host.permissionSetup, .screen, "Granting another permission leaves these steps up.")
            XCTAssertEqual(host.lastError, guidance)

            probe.grant(.screen)
            MacComputerControlCommand.refreshPermissions.perform(on: host)
            XCTAssertNil(host.permissionSetup)
            XCTAssertNil(host.lastError)
            XCTAssertFalse(host.enabled)
            XCTAssertEqual(probe.requested, [.screen])
            XCTAssertEqual(probe.relaunches, 0)
        }

        func testRepeatedRequestGuidesWithoutPromptingAndSettingsFailureLeads() throws {
            let probe = Probe()
            let host = try host(probe)
            host.requestAccessibility()
            probe.opens = false
            host.requestAccessibility()
            XCTAssertEqual(probe.requested, [.accessibility])
            XCTAssertEqual(probe.revealed, [Bundle.main.bundleURL, Bundle.main.bundleURL])
            XCTAssertEqual(probe.opened, [Self.pane + "Privacy_Accessibility", Self.pane + "Privacy_Accessibility"])
            XCTAssertEqual(host.permissionSetup, .accessibility)
            XCTAssertEqual(host.lastError?.leadSentence, "AstralDeep could not open System Settings.")
            XCTAssertTrue(host.lastError?.hasSuffix("macOS no longer prompts for Accessibility.") == true)
        }

        func testCompletedSetupKeepsANewerUnrelatedError() throws {
            let probe = Probe()
            let host = try host(probe)
            host.requestAccessibility()
            XCTAssertEqual(host.permissionSetup, .accessibility)
            host.setEnabled(true)
            let unrelated = "Sign in and grant the listed permissions before enabling this Mac."
            XCTAssertEqual(host.lastError, unrelated)
            probe.grant(.accessibility)
            host.refreshPermissions()
            XCTAssertNil(host.permissionSetup)
            XCTAssertEqual(host.lastError, unrelated)
        }

        func testSetupCommandsReopenThePaneRevealTheAppAndRelaunch() throws {
            let probe = Probe()
            let host = try host(probe)
            MacComputerControlCommand.openPermissionSettings.perform(on: host)
            XCTAssertTrue(probe.opened.isEmpty, "Without setup steps there is no pane to reopen.")

            host.requestMonitoring()
            let guidance = host.lastError
            MacComputerControlCommand.openPermissionSettings.perform(on: host)
            MacComputerControlCommand.revealApp.perform(on: host)
            MacComputerControlCommand.relaunch.perform(on: host)
            XCTAssertEqual(probe.opened, Array(repeating: Self.pane + "Privacy_ListenEvent", count: 2))
            XCTAssertEqual(probe.revealed, [Bundle.main.bundleURL, Bundle.main.bundleURL])
            XCTAssertEqual(probe.relaunches, 1)
            XCTAssertEqual(host.lastError, guidance)

            probe.opens = false
            MacComputerControlCommand.openPermissionSettings.perform(on: host)
            XCTAssertEqual(
                host.lastError,
                "AstralDeep could not open System Settings. Open Privacy & Security > Input Monitoring yourself.")
            probe.relaunched = false
            MacComputerControlCommand.relaunch.perform(on: host)
            XCTAssertEqual(host.lastError, "AstralDeep could not relaunch. Quit and reopen it yourself.")
            XCTAssertEqual(host.permissionSetup, .monitoring)

            probe.grant(.monitoring)
            host.refreshPermissions()
            XCTAssertNil(host.permissionSetup)
            XCTAssertNil(host.lastError, "A setup failure clears once the permission is granted.")
        }

        func testControllerOnlyBuildIgnoresEverySetupCommand() throws {
            let probe = Probe()
            let host = try host(probe, available: false)
            let commands: [MacComputerControlCommand] = [
                .permission(.screen), .openPermissionSettings, .revealApp, .relaunch,
            ]
            for command in commands { command.perform(on: host) }
            XCTAssertNil(host.permissionSetup)
            XCTAssertNil(host.lastError)
            XCTAssertTrue(probe.requested.isEmpty)
            XCTAssertTrue(probe.opened.isEmpty)
            XCTAssertTrue(probe.revealed.isEmpty)
            XCTAssertEqual(probe.relaunches, 0)
        }

        func testPanelShowsNumberedStepsWithRelaunchOnlyWhereNeededAndDropsThemOnceGranted() async throws {
            let steps = (1...5).map { "mac-computer-setup-step-\($0)" }
            let controls = [
                "mac-computer-permission-setup", "mac-computer-setup-title", "mac-computer-setup-open-settings",
                "mac-computer-setup-reveal", "mac-computer-refresh-permissions",
            ]
            for permission: MacComputerPermission in [.accessibility, .screen, .monitoring] {
                let probe = Probe()
                let host = try host(probe)
                let (model, suite) = try SurfaceFixtures.model()
                suites.append(suite)
                let mount = SurfaceMount(
                    MacComputerControls(host: host), model: model, size: CGSize(width: 560, height: 1000))
                defer { mount.close() }
                try await mount.settle()
                var identifiers = accessibilityIdentifiers(mount)
                XCTAssertTrue(identifiers.contains("mac-computer-refresh-permissions"), "\(identifiers)")
                XCTAssertFalse(identifiers.contains("mac-computer-permission-setup"))

                MacComputerControlCommand.permission(permission).perform(on: host)
                try await mount.settle()
                identifiers = accessibilityIdentifiers(mount)
                for identifier in controls + steps {
                    XCTAssertTrue(identifiers.contains(identifier), "\(permission) is missing \(identifier)")
                }
                XCTAssertEqual(identifiers.contains("mac-computer-setup-relaunch"), permission.needsRelaunch)
                let text = try mount.text()
                for visible in ["Add AstralDeep to", "Open System Settings", "Show in Finder"] {
                    XCTAssertTrue(text.contains(visible), "\(permission) is missing \(visible) in \(text)")
                }
                XCTAssertEqual(text.contains("Relaunch"), permission.needsRelaunch, text)

                probe.grant(permission)
                MacComputerControlCommand.refreshPermissions.perform(on: host)
                try await mount.settle()
                identifiers = accessibilityIdentifiers(mount)
                XCTAssertFalse(identifiers.contains("mac-computer-permission-setup"), "\(permission)")
                XCTAssertFalse(identifiers.contains("mac-computer-setup-relaunch"), "\(permission)")
            }
        }

        func testRelauncherReopensTheBundleOnlyAfterTheAppHasExited() throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("relaunch-\(UUID().uuidString)")
            addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
            let input = Pipe()
            let app = Process()
            app.executableURL = URL(fileURLWithPath: "/bin/cat")
            app.standardInput = input
            app.standardOutput = FileHandle.nullDevice
            try app.run()
            var quits = 0
            XCTAssertTrue(
                MacAppRelauncher.relaunch(
                    pid: app.processIdentifier, bundle: marker, opener: "/usr/bin/touch", terminate: { quits += 1 }))
            XCTAssertEqual(quits, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "The bundle reopens only after exit.")
            try input.fileHandleForWriting.close()
            app.waitUntilExit()
            wait(for: [XCTNSPredicateExpectation(predicate: Self.exists(marker), object: nil)], timeout: 30)
        }

        func testRelauncherKeepsTheAppRunningWhenTheWaiterCannotStart() {
            var quits = 0
            XCTAssertFalse(
                MacAppRelauncher.relaunch(
                    pid: getpid(), bundle: Bundle.main.bundleURL, shell: "/nonexistent/sh-\(UUID().uuidString)",
                    terminate: { quits += 1 }))
            XCTAssertEqual(quits, 0)
        }
    }
#endif
