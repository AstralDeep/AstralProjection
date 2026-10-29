// Verifies ephemeral project disclosure choices without changing selection, chat identity or host authority.
// MacProjectSidebar uses this state to reveal selected projects and temporary search results.

import XCTest

@testable import AstralCore

final class ProjectSidebarDisclosureTests: XCTestCase {
    func testSelectedAndActiveProjectsExpandWithoutOpeningUnrelatedProjects() {
        let state = ProjectSidebarDisclosure()
        XCTAssertTrue(state.isExpanded("selected", selected: "selected", active: "active"))
        XCTAssertTrue(state.isExpanded("active", selected: "selected", active: "active"))
        XCTAssertFalse(state.isExpanded("other", selected: "selected", active: "active"))
        XCTAssertFalse(state.isExpanded("other", selected: nil, active: nil))
    }

    func testExplicitCollapseSurvivesSelectionAndActiveChatChanges() {
        var state = ProjectSidebarDisclosure()
        state.toggle("one", selected: "one", active: nil)
        XCTAssertFalse(state.isExpanded("one", selected: "one", active: "one"))
        XCTAssertFalse(state.isExpanded("one", selected: "two", active: "one"))
        XCTAssertTrue(state.isExpanded("two", selected: "two", active: "one"))
        state.toggle("one", selected: "two", active: "one")
        XCTAssertTrue(state.isExpanded("one", selected: "two", active: nil))
    }

    func testSearchTemporarilyRevealsMatchesAndPreservesExplicitCollapse() {
        var state = ProjectSidebarDisclosure()
        state.toggle("one", selected: "one", active: nil)
        XCTAssertTrue(state.isExpanded("one", selected: "one", active: nil, searching: true))
        state.toggle("one", selected: "one", active: nil, searching: true)
        XCTAssertFalse(state.isExpanded("one", selected: "one", active: nil))
        XCTAssertTrue(state.isExpanded("other", selected: "one", active: nil, searching: true))
        XCTAssertFalse(state.isExpanded("other", selected: "one", active: nil))
    }

    func testExplicitNewChatRevealsTheProjectAfterCollapse() {
        var state = ProjectSidebarDisclosure()
        state.toggle("one", selected: "one", active: nil)
        state.reveal("one")
        XCTAssertTrue(state.isExpanded("one", selected: "two", active: nil))
        XCTAssertFalse(state.isExpanded("other", selected: "two", active: nil))
    }

    func testCatalogRefreshRetainsCurrentChoicesAndDropsRemovedProjects() {
        var state = ProjectSidebarDisclosure()
        state.toggle("one", selected: "one", active: nil)
        state.toggle("two", selected: "two", active: nil)
        state.retain(["one"])
        XCTAssertFalse(state.isExpanded("one", selected: "one", active: nil))
        XCTAssertTrue(state.isExpanded("two", selected: "two", active: nil))
    }
}
