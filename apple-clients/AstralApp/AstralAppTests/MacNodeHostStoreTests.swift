// Tests that the Mac node host store offers nothing outside the direct-download build, keeps the node under Application Support and builds the owner sign-in nonce.

#if os(macOS)
    import AstralCore
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacNodeHostStoreTests: XCTestCase {
        private func isolatedDefaults() -> UserDefaults {
            let defaults = UserDefaults(suiteName: "node-host-store-\(UUID().uuidString)")!
            return defaults
        }

        func testABuildWithoutTheDirectDownloadMarkerOffersNothing() {
            let store = MacNodeHostStore(
                defaults: isolatedDefaults(), available: false,
                root: FileManager.default.temporaryDirectory.appendingPathComponent("node-\(UUID().uuidString)"))
            XCTAssertFalse(store.controller.isAvailable)
            XCTAssertEqual(store.controller.phase, .unavailable)
        }

        func testAnAvailableBuildStartsWithNothingInstalled() async {
            let store = MacNodeHostStore(
                defaults: isolatedDefaults(), available: true,
                root: FileManager.default.temporaryDirectory.appendingPathComponent("node-\(UUID().uuidString)"))
            await store.controller.refresh()
            XCTAssertEqual(store.controller.phase, .notInstalled)
            XCTAssertFalse(store.controller.keepRunning)
        }

        func testTheNodeLivesUnderTheAppsApplicationSupportFolder() {
            let root = MacNodeHostStore.defaultRoot()
            XCTAssertEqual(root.lastPathComponent, "node")
            XCTAssertTrue(root.path.contains("/Application Support/"))
        }

        func testQuittingWithNoNodeRunningIsHarmless() {
            let store = MacNodeHostStore(
                defaults: isolatedDefaults(), available: true,
                root: FileManager.default.temporaryDirectory.appendingPathComponent("node-\(UUID().uuidString)"))
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            XCTAssertEqual(store.controller.phase, .notInstalled)
        }
    }
#endif
