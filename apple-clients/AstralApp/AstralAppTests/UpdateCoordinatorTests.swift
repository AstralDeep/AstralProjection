// Verifies the update coordinator's channel, postponed-relaunch, error and published-state logic against a fake updater.
// The real Sparkle delegate entry points run on an unstarted SPUUpdater, so no network or install work happens.

#if os(macOS)
    import AstralCore
    import AstralSparkle
    import Combine
    import SwiftUI
    import XCTest
    @testable import AstralDeep

    @MainActor
    private final class FakeUpdater: UpdaterControlling {
        let changes = PassthroughSubject<Bool, Never>()
        var canCheckForUpdates = true
        var canCheckForUpdatesChanges: AnyPublisher<Bool, Never> { changes.eraseToAnyPublisher() }
        var automaticallyChecksForUpdates = true
        var automaticallyDownloadsUpdates = false
        var allowsAutomaticUpdates = true
        var lastUpdateCheckDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
        private(set) var checks = 0
        func checkForUpdates() { checks += 1 }
    }

    @MainActor
    private final class Busy {
        var value = true
    }

    @MainActor
    final class UpdateCoordinatorTests: XCTestCase {
        private let now = Date(timeIntervalSince1970: 1_800_000_000)

        private func defaults() -> UserDefaults {
            let name = "coordinator-tests-" + UUID().uuidString
            let value = UserDefaults(suiteName: name)!
            addTeardownBlock { value.removePersistentDomain(forName: name) }
            return value
        }

        private func coordinator(
            busy: Busy? = nil, defaults: UserDefaults? = nil, interval: Duration = .milliseconds(10)
        ) -> UpdateCoordinator {
            let now = self.now
            let busy = busy ?? Busy()
            return UpdateCoordinator(
                isBusy: { busy.value }, defaults: defaults ?? self.defaults(), clock: { now }, pollInterval: interval)
        }

        private func sparkle() -> SPUUpdater {
            SPUUpdater(
                hostBundle: .main, applicationBundle: .main,
                userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
        }

        private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line)
            async throws
        {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("condition not met", file: file, line: line)
        }

        func testPreviewChannelIsOptInAndPersisted() {
            let store = defaults()
            let subject = coordinator(defaults: store)
            XCTAssertEqual(subject.allowedChannels(for: sparkle()), [])
            subject.setPreviewChannel(true)
            XCTAssertEqual(subject.allowedChannels(for: sparkle()), ["preview"])
            XCTAssertTrue(store.bool(forKey: UpdateCoordinator.previewKey))
            XCTAssertTrue(coordinator(defaults: store).previewChannel)
            subject.setPreviewChannel(false)
            XCTAssertEqual(subject.allowedChannels(for: sparkle()), [])
            XCTAssertFalse(coordinator(defaults: store).previewChannel)
        }

        func testRelaunchIsPostponedWhileBusyAndReleasedExactlyOnceWhenIdle() async throws {
            let busy = Busy()
            let subject = coordinator(busy: busy)
            var invoked = 0
            let postponed = subject.updater(
                sparkle(), shouldPostponeRelaunchForUpdate: .empty(), untilInvokingBlock: { invoked += 1 })
            XCTAssertTrue(postponed)
            XCTAssertTrue(subject.pendingRelaunch)
            XCTAssertEqual(subject.status, .restartPending)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(invoked, 0)
            XCTAssertTrue(subject.pendingRelaunch)
            busy.value = false
            try await eventually { invoked == 1 }
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(invoked, 1)
            XCTAssertFalse(subject.pendingRelaunch)
            XCTAssertNil(subject.status)
        }

        func testRelaunchProceedsImmediatelyWhenNothingIsRunning() {
            let subject = coordinator(
                busy: {
                    let idle = Busy()
                    idle.value = false
                    return idle
                }())
            var invoked = 0
            XCTAssertFalse(
                subject.updater(
                    sparkle(), shouldPostponeRelaunchForUpdate: .empty(), untilInvokingBlock: { invoked += 1 }))
            XCTAssertEqual(invoked, 0)
            XCTAssertFalse(subject.pendingRelaunch)
        }

        func testASecondPostponeReplacesTheStoredBlockWithoutDoubleInvoking() async throws {
            let busy = Busy()
            let subject = coordinator(busy: busy)
            var first = 0
            var second = 0
            XCTAssertTrue(subject.postponeRelaunch { first += 1 })
            XCTAssertTrue(subject.postponeRelaunch { second += 1 })
            busy.value = false
            try await eventually { second == 1 }
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(first, 0)
            XCTAssertEqual(second, 1)
        }

        func testReleaseIsANoOpWithoutAStoredBlock() {
            let subject = coordinator()
            XCTAssertTrue(subject.releaseRelaunchIfIdle())
            XCTAssertFalse(subject.pendingRelaunch)
        }

        func testNoUpdateFoundRecordsTheCheckAndClearsErrors() {
            let subject = coordinator()
            subject.record(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline"]))
            XCTAssertEqual(subject.lastError, "Offline")
            subject.updaterDidNotFindUpdate(sparkle(), error: NSError(domain: SUSparkleErrorDomain, code: 1001))
            XCTAssertEqual(subject.lastCheck, now)
            XCTAssertNil(subject.lastError)
        }

        func testAbortSurfacesRealErrorsAndIgnoresNoUpdateAndCancel() {
            let subject = coordinator()
            subject.updater(sparkle(), didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: 1001))
            subject.updater(sparkle(), didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: 4007))
            XCTAssertNil(subject.lastError)
            subject.updater(
                sparkle(),
                didAbortWithError: NSError(
                    domain: SUSparkleErrorDomain, code: 3001,
                    userInfo: [NSLocalizedDescriptionKey: "The update is improperly signed."]))
            XCTAssertEqual(subject.lastError, "The update is improperly signed.")
            XCTAssertEqual(subject.status, .failed("The update is improperly signed."))
        }

        func testCycleFinishRecordsCheckTimeAndErrorState() {
            let subject = coordinator()
            subject.updater(
                sparkle(), didFinishUpdateCycleFor: .updatesInBackground,
                error: NSError(domain: "fixture", code: 9, userInfo: [NSLocalizedDescriptionKey: "Feed unreachable"]))
            XCTAssertEqual(subject.lastCheck, now)
            XCTAssertEqual(subject.lastError, "Feed unreachable")
            subject.updater(
                sparkle(), didFinishUpdateCycleFor: .updatesInBackground,
                error: NSError(domain: SUSparkleErrorDomain, code: 1001))
            XCTAssertNil(subject.lastError)
            subject.record(NSError(domain: "fixture", code: 2))
            XCTAssertNotNil(subject.lastError)
            subject.updater(sparkle(), didFinishUpdateCycleFor: .updates, error: nil)
            XCTAssertNil(subject.lastError)
        }

        func testLongErrorDescriptionsAreBounded() {
            let subject = coordinator()
            subject.record(
                NSError(
                    domain: "fixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(repeating: "e", count: 900)]))
            XCTAssertEqual(subject.lastError?.count, 200)
        }

        func testGentleScheduledRemindersAreDeclared() {
            XCTAssertTrue(coordinator().supportsGentleScheduledUpdateReminders)
        }

        func testAttachMirrorsUpdaterStateAndForwardsChangesAndChecks() async throws {
            let subject = coordinator()
            XCTAssertFalse(subject.isEnabled)
            let fake = FakeUpdater()
            subject.attach(fake)
            XCTAssertTrue(subject.isEnabled)
            XCTAssertTrue(subject.canCheckForUpdates)
            XCTAssertEqual(subject.lastCheck, fake.lastUpdateCheckDate)
            XCTAssertTrue(subject.automaticChecks)
            XCTAssertFalse(subject.automaticInstall)
            XCTAssertTrue(subject.automaticInstallAvailable)
            fake.changes.send(false)
            try await eventually { !subject.canCheckForUpdates }
            fake.changes.send(true)
            try await eventually { subject.canCheckForUpdates }
            subject.checkForUpdates()
            XCTAssertEqual(fake.checks, 1)
        }

        func testTogglesWriteThroughToTheUpdater() {
            let subject = coordinator()
            let fake = FakeUpdater()
            subject.attach(fake)
            subject.setAutomaticChecks(false)
            subject.setAutomaticInstall(true)
            XCTAssertFalse(fake.automaticallyChecksForUpdates)
            XCTAssertTrue(fake.automaticallyDownloadsUpdates)
            XCTAssertFalse(subject.automaticChecks)
            XCTAssertTrue(subject.automaticInstall)
        }

        func testDisabledCoordinatorIsInert() {
            let subject = coordinator()
            subject.checkForUpdates()
            subject.setAutomaticChecks(true)
            subject.setAutomaticInstall(true)
            XCTAssertFalse(subject.isEnabled)
            XCTAssertFalse(subject.automaticChecks)
            XCTAssertFalse(subject.automaticInstall)
            XCTAssertNil(subject.status)
        }

        func testPolicyFailureSurfacesInTheChipAndRestartOutranksIt() {
            let subject = coordinator()
            subject.notePolicy(failure: .signature)
            XCTAssertEqual(subject.status, .failed(UpdatePolicyFailure.signature.summary))
            _ = subject.postponeRelaunch {}
            XCTAssertEqual(subject.status, .restartPending)
            subject.notePolicy(failure: nil)
            XCTAssertNil(subject.policyFailure)
        }

        func testTaskActivityCoversTurnsAndComputerSessions() throws {
            let session = try ComputerHostSession(
                json: .object([
                    "session_id": .string("0b4c1f2e-7a5d-4e0b-9c3a-1d2e3f4a5b6c"),
                    "host_id": .string("1c5d2a3f-8b6e-4f1c-8d4b-2e3f4a5b6c7d"), "state": .string("paused"),
                ]))
            XCTAssertFalse(UpdateCoordinator.isTaskActive(turnActive: false, session: nil))
            XCTAssertTrue(UpdateCoordinator.isTaskActive(turnActive: true, session: nil))
            XCTAssertTrue(UpdateCoordinator.isTaskActive(turnActive: false, session: session))
        }

        func testLiveCoordinatorStaysDisabledOutsideTheDirectDownloadBuild() {
            let subject = UpdateCoordinator.live(isBusy: { false })
            XCTAssertFalse(subject.isEnabled)
            XCTAssertEqual(subject.status, nil)
        }

        func testInstalledVersionShowsMarketingVersionAndBuild() {
            let text = UpdateCoordinator.installedVersion()
            XCTAssertNotNil(text.range(of: #"^\S+ \(\S+\)$"#, options: .regularExpression), text)
        }

        func testSparkleAdapterReadsTheUnstartedUpdater() {
            let controller = SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            let adapter = SparkleUpdater(controller: controller)
            XCTAssertFalse(adapter.canCheckForUpdates)
            XCTAssertEqual(adapter.automaticallyChecksForUpdates, controller.updater.automaticallyChecksForUpdates)
            XCTAssertEqual(adapter.automaticallyDownloadsUpdates, controller.updater.automaticallyDownloadsUpdates)
            XCTAssertEqual(adapter.allowsAutomaticUpdates, controller.updater.allowsAutomaticUpdates)
            XCTAssertEqual(adapter.lastUpdateCheckDate, controller.updater.lastUpdateCheckDate)
            var received: [Bool] = []
            let observation = adapter.canCheckForUpdatesChanges.sink { received.append($0) }
            XCTAssertEqual(received, [false])
            observation.cancel()
        }

        func testInfoPlistCarriesTheSparkleConfiguration() throws {
            let info = try XCTUnwrap(Bundle.main.infoDictionary)
            XCTAssertEqual(info["SUFeedURL"] as? String, "https://astraldeep.github.io/appcast.xml")
            let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
            XCTAssertEqual(key, "eg4hW6POM2f99hfVp8K+U5bx5Hpl8+P+IYLuW0+pPzw=")
            XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
            XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
            XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86400)
            XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
            XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
            XCTAssertEqual(info["SUShowReleaseNotes"] as? Bool, true)
            XCTAssertNil(info["SURequireSignedFeed"])
            XCTAssertNil(info["SUAllowsAutomaticUpdates"])
        }

        private func render<V: View>(_ content: V, empty: Bool = false, line: UInt = #line) {
            let view = NSHostingView(rootView: content.environment(ThemeStore()))
            view.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.fittingSize.height > 0, !empty, line: line)
        }

        func testUpdateViewsRenderForEveryState() {
            let subject = coordinator()
            subject.attach(FakeUpdater())
            render(UpdateSettingsSheet(coordinator: subject))
            render(UpdateMenuItems(coordinator: subject))
            render(UpdateStatusChip(coordinator: subject), empty: true)
            subject.record(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline"]))
            render(UpdateSettingsSheet(coordinator: subject))
            render(UpdateStatusChip(coordinator: subject))
            _ = subject.postponeRelaunch {}
            render(UpdateStatusChip(coordinator: subject))
            render(UpdateSettingsSheet(coordinator: subject))
            render(
                UpdateRequiredView(
                    requirement: UpdateRequirement(minimumBuild: 71, installedBuild: 70, message: "Update required"),
                    coordinator: subject))
            render(UpdateMenuItems(coordinator: coordinator()), empty: true)
        }

        func testChipTextsAndLastCheckFormatting() {
            XCTAssertEqual(UpdateStatusChip.title(for: .restartPending), "Update ready, restart when idle")
            XCTAssertEqual(UpdateStatusChip.title(for: .failed("x")), "Update check failed")
            XCTAssertNotEqual(
                UpdateStatusChip.symbol(for: .restartPending), UpdateStatusChip.symbol(for: .failed("x")))
            XCTAssertEqual(UpdateSettingsSheet.lastCheckText(nil), "Never")
            XCTAssertNotEqual(UpdateSettingsSheet.lastCheckText(now), "Never")
        }
    }
#endif
