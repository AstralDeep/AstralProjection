// Verifies that a narrow Mac activity row keeps its approval badge on one readable line, so long action, target and
// result text truncates instead of squeezing the badge into a wrapped bubble.

import AstralCore
import SwiftUI
import XCTest

@testable import AstralDeep

#if os(macOS)
    @MainActor
    final class MacActivityRowLayoutTests: XCTestCase {
        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        func testApprovalBadgeStaysOnOneLineInANarrowRow() async throws {
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            for approval: AppModel.ActivityRow.Approval in [.uncertain, .waiting, .granted] {
                let row = AppModel.ActivityRow(
                    id: "step-1", tool: "browser_evaluate", action: "Action",
                    target: "Run the 3-character script shown below in the current page of the Astral browser pane",
                    approval: approval, state: .failed, result: "The decision was not confirmed on this Mac",
                    thumbnail: nil, position: 0, arguments: "{}")
                let label = try XCTUnwrap(row.approvalLabel)
                let mount = SurfaceMount(
                    MacActivityRowView(row: row, compact: true).frame(width: 340).padding(10), model: model,
                    size: CGSize(width: 360, height: 120))
                defer { mount.close() }
                try await mount.settle()
                let lines = try mount.lines()
                let badge = try XCTUnwrap(mount.textFrame(label), "\(label) is not on one line: \(lines)")
                XCTAssertLessThan(badge.height, 24, label)
            }
        }
    }
#endif
