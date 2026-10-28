// Covers the Mac Settings window: pane restore and fallback, the Updates, This Mac and Account panes in the three
// reference themes, their disabled and loading states, and the route from Updates… into the Settings window.

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

        private func model(menu: JSONValue? = nil) throws -> AppModel {
            let (model, suite) = try SurfaceFixtures.model(menu: menu)
            suites.append(suite)
            return model
        }

        private func coordinator(enabled: Bool) throws -> UpdateCoordinator {
            let coordinator = UpdateCoordinator(isBusy: { false }, defaults: try defaults())
            if enabled { coordinator.attach(SettingsUpdater()) }
            return coordinator
        }

        private func handoffMenu() throws -> JSONValue {
            let root = try SurfaceFixtures.json("chrome-console")
            var groups = try XCTUnwrap(root["menu"]?.arrayValue)
            var account = try XCTUnwrap(groups.first?.objectValue)
            let items = try XCTUnwrap(account["items"]?.arrayValue).map { item -> JSONValue in
                guard item["key"]?.stringValue == "audit", var fields = item.objectValue else { return item }
                fields["availability"] = .object(["mode": .string("handoff"), "message": .string("Open on the web")])
                return .object(fields)
            }
            account["items"] = .array(items)
            groups[0] = .object(account)
            return try SurfaceFixtures.replacing(root, path: ["menu"], with: .array(groups))
        }

        func testTheLastPaneIsRestoredAndUpdatesFallsBackWhenTheUpdaterIsAbsent() {
            XCTAssertEqual(MacSettingsPane.resolve("thisMac", updatesEnabled: true), .thisMac)
            XCTAssertEqual(MacSettingsPane.resolve("updates", updatesEnabled: true), .updates)
            XCTAssertEqual(MacSettingsPane.resolve("updates", updatesEnabled: false), .account)
            XCTAssertEqual(MacSettingsPane.resolve("removed-pane", updatesEnabled: true), .account)
            XCTAssertEqual(MacSettingsPane.resolve("", updatesEnabled: false), .account)
        }

        func testEveryPaneRendersInEachTheme() async throws {
            for preset in SurfaceFixtures.presets {
                for pane in MacSettingsPane.allCases {
                    let model = try model(menu: try handoffMenu())
                    let store = try defaults()
                    store.set(pane.rawValue, forKey: MacSettingsPane.storageKey)
                    let mount = SurfaceMount(
                        MacSettingsView(updates: try coordinator(enabled: true)).defaultAppStorage(store),
                        model: model, size: CGSize(width: 460, height: pane == .account ? 620 : 360), preset: preset)
                    defer { mount.close() }
                    try await mount.settle()
                    let text = try mount.text()
                    let expected: [String] =
                        switch pane {
                        case .updates: ["Check automatically", "Last checked"]
                        case .thisMac: ["Computer access", "Computer Controls"]
                        case .account: ["Agents & permissions", "LLM settings", "Open on the web", "Sign out"]
                        }
                    for kept in expected {
                        XCTAssertTrue(text.contains(kept), "\(preset) \(pane) missing \(kept): \(text)")
                    }
                    try mount.snapshot(self, name: "settings_\(pane.rawValue)-\(preset)")
                }
            }
        }

        func testUpdatesPaneIsAbsentWithoutAnUpdater() async throws {
            let store = try defaults()
            store.set(MacSettingsPane.updates.rawValue, forKey: MacSettingsPane.storageKey)
            let mount = SurfaceMount(
                MacSettingsView(updates: try coordinator(enabled: false)).defaultAppStorage(store),
                model: try model(), size: CGSize(width: 460, height: 620))
            defer { mount.close() }
            try await mount.settle()
            let text = try mount.text()
            XCTAssertFalse(text.contains("Updates"), text)
            XCTAssertFalse(text.contains("Check automatically"), text)
            XCTAssertTrue(text.contains("Agents & permissions"), text)
        }

        func testThisMacOpensComputerControlsOnlyWhereThisBuildCanHostTasks() async throws {
            for available in [false, true] {
                let host = MacComputerHost(
                    available: available, defaults: try defaults(),
                    permissionProvider: {
                        MacComputerPermissions(accessibility: false, screen: false, monitoring: false)
                    })
                let mount = SurfaceMount(
                    MacSettingsThisMac(host: host), model: try model(), size: CGSize(width: 460, height: 200))
                defer { mount.close() }
                try await mount.settle()
                XCTAssertTrue(try mount.text().contains(host.statusLabel.prefix(20)), "\(available)")
                try mount.click(text: "Computer Controls")
                try await mount.settle()
                XCTAssertEqual(host.controlsPresented, available)
                XCTAssertNil(host.session)
                XCTAssertFalse(host.enabled)
            }
        }

        func testAccountOpensAuthorizedSurfacesAndShowsUnavailableLoadingAndSignedOutStates() async throws {
            let model = try model(menu: try handoffMenu())
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            let mount = SurfaceMount(MacSettingsAccount(), model: model, size: CGSize(width: 460, height: 620))
            defer { mount.close() }
            try await mount.settle()
            try mount.click(text: "Audit log")
            try await mount.settle()
            XCTAssertTrue(sent.isEmpty, "\(sent)")
            model.mandatorySurface = true
            try mount.click(text: "LLM settings")
            try await mount.settle()
            XCTAssertTrue(sent.isEmpty, "\(sent)")
            model.mandatorySurface = false
            try await mount.settle()
            try mount.click(text: "LLM settings")
            try await mount.settle()
            XCTAssertEqual(sent.last?["action"], .string("chrome_open"))
            XCTAssertEqual(sent.last?["payload"]?["surface"], .string("llm"))
            for preset in SurfaceFixtures.presets {
                let loading = try self.model()
                loading.chromeMenu = nil
                let mount = SurfaceMount(
                    MacSettingsAccount(), model: loading, size: CGSize(width: 460, height: 200), preset: preset)
                defer { mount.close() }
                try await mount.settle()
                XCTAssertTrue(try mount.text().contains("Loading settings"), preset)
                try mount.snapshot(self, name: "settings_account_loading-\(preset)")
                loading.signedIn = false
                try await mount.settle()
                XCTAssertTrue(try mount.text().contains("Not signed in"), preset)
            }
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

        func testPanesExposeNamesAndDisabledStateToAccessibility() async throws {
            let model = try model(menu: try handoffMenu())
            let mount = SurfaceMount(MacSettingsAccount(), model: model, size: CGSize(width: 460, height: 620))
            defer { mount.close() }
            try await mount.settle()
            let tree = try mount.accessibility
            XCTAssertEqual(tree.first { $0.identifier == "settings-account-llm" }?.label, "LLM settings")
            let audit = try XCTUnwrap(tree.first { $0.identifier == "settings-account-audit" })
            XCTAssertFalse(audit.enabled)
            XCTAssertEqual(audit.value, "Open on the web")
            XCTAssertNotNil(tree.first { $0.identifier == "settings-account-sign-out" })
        }
    }
#endif
