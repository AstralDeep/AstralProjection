// Covers the Mac Settings window: pane restore and fallback, the Updates and This Mac panes in the three reference
// themes, and the route from Updates into the Settings window.

#if os(macOS)
    import AppKit
    import AstralCore
    import Combine
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    private final class SettingsUpdater: UpdaterControlling {
        var canCheckForUpdates = true
        var canCheckForUpdatesChanges: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
        var automaticallyChecksForUpdates = true
        var automaticallyDownloadsUpdates = false
        var allowsAutomaticUpdates = true
        var lastUpdateCheckDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
        func checkForUpdates() {}
    }

    @MainActor
    final class MacSettingsWindowTests: XCTestCase {
        private var suites: [String] = []
        private let presets = ["graphite", "midnight", "daylight"]

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func defaults() throws -> UserDefaults {
            let suite = "MacSettingsWindowTests.\(UUID().uuidString)"
            suites.append(suite)
            return try XCTUnwrap(UserDefaults(suiteName: suite))
        }

        private func model() throws -> AppModel {
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            return model
        }

        private func coordinator(enabled: Bool) throws -> UpdateCoordinator {
            let coordinator = UpdateCoordinator(isBusy: { false }, defaults: try defaults())
            if enabled { coordinator.attach(SettingsUpdater()) }
            return coordinator
        }

        func testTheLastPaneIsRestoredAndUpdatesFallsBackWhenTheUpdaterIsAbsent() {
            XCTAssertEqual(MacSettingsPane.resolve("thisMac", updatesEnabled: true), .thisMac)
            XCTAssertEqual(MacSettingsPane.resolve("updates", updatesEnabled: true), .updates)
            XCTAssertEqual(MacSettingsPane.resolve("updates", updatesEnabled: false), .thisMac)
            XCTAssertEqual(MacSettingsPane.resolve("account", updatesEnabled: true), .thisMac)
            XCTAssertEqual(MacSettingsPane.resolve("", updatesEnabled: false), .thisMac)
        }

        func testEveryPaneRendersInEachTheme() async throws {
            for preset in presets {
                for pane in MacSettingsPane.allCases {
                    let store = try defaults()
                    store.set(pane.rawValue, forKey: MacSettingsPane.storageKey)
                    let mount = SurfaceMount(
                        MacSettingsView(updates: try coordinator(enabled: true)).defaultAppStorage(store),
                        model: try model(), size: CGSize(width: 460, height: 360), preset: preset)
                    defer { mount.close() }
                    try await mount.settle()
                    let text = try mount.text()
                    let expected: [String] =
                        switch pane {
                        case .updates: ["Check automatically", "Last checked"]
                        case .thisMac: ["Kernel"]
                        }
                    for kept in expected {
                        XCTAssertTrue(text.contains(kept), "\(preset) \(pane) missing \(kept): \(text)")
                    }
                }
            }
        }

        func testUpdatesPaneIsAbsentWithoutAnUpdater() async throws {
            let store = try defaults()
            store.set(MacSettingsPane.updates.rawValue, forKey: MacSettingsPane.storageKey)
            let mount = SurfaceMount(
                MacSettingsView(updates: try coordinator(enabled: false)).defaultAppStorage(store),
                model: try model(), size: CGSize(width: 460, height: 360))
            defer { mount.close() }
            try await mount.settle()
            let text = try mount.text()
            XCTAssertFalse(text.contains("Check automatically"), text)
            XCTAssertTrue(text.contains("Kernel"), text)
        }

        func testUpdatesItemsOpenTheUpdatesPaneOfTheSettingsWindow() async throws {
            let store = try defaults()
            let updates = try coordinator(enabled: true)
            let mount = SurfaceMount(
                Color.clear.modifier(MacSettingsRouter(updates: updates)).defaultAppStorage(store),
                model: try model(), size: CGSize(width: 100, height: 100))
            defer { mount.close() }
            try await mount.settle()
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            updates.settingsPresented = true
            try await mount.settle()
            XCTAssertFalse(updates.settingsPresented)
            XCTAssertEqual(store.string(forKey: MacSettingsPane.storageKey), MacSettingsPane.updates.rawValue)
            for window in NSApp.windows where !before.contains(ObjectIdentifier(window)) && window.isVisible {
                window.close()
            }
        }
    }
#endif
