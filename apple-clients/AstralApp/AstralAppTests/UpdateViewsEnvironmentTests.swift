// Hosts the update sheet, required view and status chip without any environment objects so a
// presentation site that forgets to inject ThemeStore cannot crash the app. The fallback palette is
// Graphite, matching the baked default.

#if os(macOS)
    import AppKit
    import SwiftUI
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class UpdateViewsEnvironmentTests: XCTestCase {
        private func host<V: View>(_ view: V) -> NSHostingView<V> {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
            hosting.layoutSubtreeIfNeeded()
            return hosting
        }

        func testSheetRendersWithoutThemeStoreInEnvironment() {
            let coordinator = UpdateCoordinator(isBusy: { false })
            let hosting = host(UpdateSettingsSheet(coordinator: coordinator))
            XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        }

        func testRequiredViewAndChipRenderWithoutThemeStoreInEnvironment() {
            let coordinator = UpdateCoordinator(isBusy: { false })
            let requirement = UpdateRequirement(minimumBuild: 71, installedBuild: 70, message: "Update required")
            XCTAssertGreaterThan(host(UpdateRequiredView(requirement: requirement, coordinator: coordinator)).fittingSize.height, 0)
            XCTAssertGreaterThanOrEqual(host(UpdateStatusChip(coordinator: coordinator)).fittingSize.height, 0)
        }
    }
#endif
