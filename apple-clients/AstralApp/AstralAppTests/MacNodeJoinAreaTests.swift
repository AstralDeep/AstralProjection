// Checks that a node with a legacy owner shows the explanation and the explicit Remove instead of the join button.
// It tests the state choice MacNodeJoinArea switches on and mounts both states, because this process exposes no usable accessibility tree.

#if os(macOS)
    import AppKit
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacNodeJoinAreaTests: XCTestCase {
        private func fittingHeight(legacyOwner: Bool) -> CGFloat {
            let view = MacNodeJoinArea(legacyOwner: legacyOwner, remove: {}) {
                Button("Add this node to my mesh") {}.accessibilityIdentifier("mesh.node.join")
            }
            .environment(ThemeStore())
            return NSHostingView(rootView: view).fittingSize.height
        }

        func testTheLegacyOwnerChoosesTheExplanationOverTheJoinButton() {
            XCTAssertEqual(MacNodeJoinState(legacyOwner: true), .legacyOwner)
            XCTAssertEqual(MacNodeJoinState(legacyOwner: false), .join)
        }

        func testBothStatesMountAndTheLegacyRowIsTallerThanTheJoinButton() {
            let join = fittingHeight(legacyOwner: false)
            let legacy = fittingHeight(legacyOwner: true)
            XCTAssertGreaterThan(join, 0)
            XCTAssertGreaterThan(legacy, join)
        }
    }
#endif
