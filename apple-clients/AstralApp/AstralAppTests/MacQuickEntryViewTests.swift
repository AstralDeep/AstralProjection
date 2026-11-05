// Checks Quick Entry's owner, connection, project, and attachment gates before it can submit a chat message.
// The app's ordinary composer remains responsible for dispatch and delivery.

#if os(macOS)
    import XCTest
    @testable import AstralDeep

    final class MacQuickEntryViewTests: XCTestCase {
        private func state(
            signedIn: Bool = true, connected: Bool = true, updateRequired: Bool = false,
            locked: Bool = false, projectReady: Bool = true, attachmentsPending: Bool = false,
            mainDraftPending: Bool = false
        ) -> MacQuickEntryState {
            MacQuickEntryState(
                signedIn: signedIn, connected: connected, updateRequired: updateRequired,
                locked: locked, projectReady: projectReady, attachmentsPending: attachmentsPending,
                mainDraftPending: mainDraftPending,
                destination: "Current chat: Test")
        }

        func testSubmissionRequiresAnUnambiguousCurrentSession() {
            XCTAssertTrue(state().canSubmit)
            XCTAssertFalse(state(signedIn: false).canSubmit)
            XCTAssertFalse(state(connected: false).canSubmit)
            XCTAssertFalse(state(updateRequired: true).canSubmit)
            XCTAssertFalse(state(locked: true).canSubmit)
            XCTAssertFalse(state(projectReady: false).canSubmit)
            XCTAssertFalse(state(attachmentsPending: true).canSubmit)
            XCTAssertFalse(state(mainDraftPending: true).canSubmit)
        }

        func testFailureReasonMatchesRefusedContext() {
            XCTAssertEqual(state(connected: false).guidance, "Reconnect before sending.")
            XCTAssertEqual(state(projectReady: false).guidance, "Choose a project chat in the main window first.")
            XCTAssertEqual(
                state(attachmentsPending: true).guidance, "Review pending attachments in the main window first.")
            XCTAssertEqual(state(mainDraftPending: true).guidance, "Finish the draft in the main window first.")
            XCTAssertEqual(state().guidance, "Current chat: Test")
        }
    }
#endif
