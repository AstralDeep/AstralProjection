#if os(iOS)
    import UIKit
    import XCTest

    /// Actual toolbar/sheet interactions against an owned loopback peer. These
    /// tests deliberately do not create a share on any real backend or choose a
    /// destination in the system sharing UI.
    final class WorkspaceActionsUITests: XCTestCase {
        private var app: XCUIApplication!
        private var peer: WorkspaceActionLoopback!

        override func tearDown() {
            app?.terminate()
            peer?.stop()
            app = nil
            peer = nil
            super.tearDown()
        }

        func testExportRunsAuthorizedPipelineAndOffersNativeSaveThenCloses() throws {
            try launch(replies: [.authorization: [.init(held: true)], .presentation: [.init()]])
            app.buttons["workspace-action-export"].tap()
            waitForRequests(1)
            XCTAssertTrue(app.staticTexts["Downloading…"].waitForExistence(timeout: 3))
            XCTAssertEqual(peer.requests.map(\.route), [.authorization])
            peer.releaseHeldReplies()
            let save = app.buttons["Save or share astraldeep-canvas.html"]
            XCTAssertTrue(save.waitForExistence(timeout: 15))
            XCTAssertEqual(peer.requests.map(\.route), [.authorization, .presentation])
            try assertCapturedVisibleCanvas()
            save.tap()
            // Invoke the platform handoff, then cancel without sending a file to
            // any external app or writing a user-selected destination.
            let activityList = app.otherElements["ActivityListView"]
            XCTAssertTrue(activityList.waitForExistence(timeout: 8))
            XCTAssertTrue(app.cells["Save to Files"].exists)
            let activity = XCTAttachment(screenshot: app.screenshot())
            activity.name = "Workspace export native share sheet"
            activity.lifetime = .keepAlways
            add(activity)
            // iOS 26 presents this activity view as a popover with a native
            // dismissal region, not an additional Close button.
            app.otherElements["PopoverDismissRegion"].tap()
            XCTAssertTrue(activityList.waitForNonExistence(timeout: 3))
            XCTAssertTrue(save.isHittable)
            app.buttons["Close"].firstMatch.tap()
            XCTAssertTrue(app.buttons["workspace-action-export"].waitForExistence(timeout: 3))
            XCTAssertFalse(save.exists)
            XCTAssertTrue(peer.unexpectedRequests.isEmpty, "Unexpected fixture requests: \(peer.unexpectedRequests)")
        }

        func testExportRefusalRequiresExplicitRetryAndNeverUsesAuthorizationHTML() throws {
            try launch(replies: [.authorization: [.init(status: 403), .init()], .presentation: [.init()]])
            app.buttons["workspace-action-export"].tap()
            let retry = app.buttons["Retry"]
            XCTAssertTrue(retry.waitForExistence(timeout: 8))
            XCTAssertTrue(app.staticTexts["Download failed — check your connection and try again."].exists)
            XCTAssertEqual(peer.requests.map(\.route), [.authorization])
            XCTAssertFalse(app.buttons["Save or share astraldeep-canvas.html"].exists)
            retry.tap()
            XCTAssertTrue(app.buttons["Save or share astraldeep-canvas.html"].waitForExistence(timeout: 15))
            XCTAssertEqual(peer.requests.map(\.route), [.authorization, .authorization, .presentation])
            try assertCapturedVisibleCanvas()
            app.buttons["Close"].firstMatch.tap()
            XCTAssertFalse(retry.exists)
            XCTAssertTrue(peer.unexpectedRequests.isEmpty, "Unexpected fixture requests: \(peer.unexpectedRequests)")
        }

        func testShareSingleAttemptAndSpecificSafeRefusalMessages() throws {
            try launch(replies: [
                .share: [
                    .init(status: 201, held: true), .init(status: 403, error: "phi_blocked"),
                    .init(status: 503, error: "unavailable"),
                ]
            ])
            let share = app.buttons["workspace-action-share"]
            share.tap()
            waitForRequests(1)
            XCTAssertFalse(share.isEnabled)
            XCTAssertFalse(app.staticTexts["Share link copied to clipboard."].exists)
            let beforeShare = UIPasteboard.general.changeCount
            peer.releaseHeldReplies()
            XCTAssertTrue(app.staticTexts["Share link copied to clipboard."].waitForExistence(timeout: 5))
            XCTAssertGreaterThan(UIPasteboard.general.changeCount, beforeShare)
            let afterShare = UIPasteboard.general.changeCount
            XCTAssertTrue(share.isEnabled)
            share.tap()
            XCTAssertTrue(
                app.staticTexts["Sharing refused: the content matched the PHI gate."].waitForExistence(timeout: 5))
            XCTAssertEqual(UIPasteboard.general.changeCount, afterShare)
            share.tap()
            XCTAssertTrue(app.staticTexts["Couldn't create the share link."].waitForExistence(timeout: 5))
            XCTAssertEqual(UIPasteboard.general.changeCount, afterShare)
            XCTAssertFalse(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PRIVATE_SERVER_DETAIL")).firstMatch
                    .exists)
            XCTAssertEqual(peer.requests.map(\.route), [.share, .share, .share])
            for request in peer.requests {
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: String])
                XCTAssertEqual(body, ["chat_id": WorkspaceActionLoopback.chat, "scope": "canvas"])
            }
            XCTAssertTrue(peer.unexpectedRequests.isEmpty, "Unexpected fixture requests: \(peer.unexpectedRequests)")
        }

        func testClosingExportAndChangingChatOrOwnerDiscardsHeldCompletions() throws {
            try launch(replies: [.authorization: [.init(held: true)], .share: [.init(status: 201, held: true)]])
            app.buttons["workspace-action-export"].tap()
            waitForRequests(1)
            XCTAssertTrue(app.staticTexts["Downloading…"].waitForExistence(timeout: 3))
            app.buttons["Close"].firstMatch.tap()
            let share = app.buttons["workspace-action-share"]
            XCTAssertTrue(share.waitForExistence(timeout: 3))
            share.tap()
            waitForRequests(2)
            app.buttons["new-chat-button"].tap()
            XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 3))
            // Read only the counter after the transition settles, never clipboard
            // text. A stale completion must not write even when its banner is hidden.
            let afterNewChat = UIPasteboard.general.changeCount
            peer.releaseHeldReplies()
            XCTAssertFalse(app.buttons["Save or share astraldeep-canvas.html"].waitForExistence(timeout: 1))
            XCTAssertFalse(app.staticTexts["Share link copied to clipboard."].exists)
            XCTAssertFalse(app.staticTexts["Couldn't create the share link."].exists)
            XCTAssertEqual(UIPasteboard.general.changeCount, afterNewChat)
            XCTAssertEqual(peer.requests.map(\.route), [.authorization, .share])
            XCTAssertTrue(peer.unexpectedRequests.isEmpty, "Unexpected fixture requests: \(peer.unexpectedRequests)")

            // A second isolated launch proves the actual account sign-out path,
            // independently of a chat change and without touching the Keychain.
            app.terminate()
            peer.stop()
            try launch(replies: [.share: [.init(status: 201, held: true)]])
            app.buttons["workspace-action-share"].tap()
            waitForRequests(1)
            app.buttons["Settings"].tap()
            app.buttons["Sign out"].tap()
            XCTAssertTrue(app.buttons["Sign in with single sign-on"].waitForExistence(timeout: 5))
            let afterSignOut = UIPasteboard.general.changeCount
            peer.releaseHeldReplies()
            XCTAssertFalse(app.staticTexts["Share link copied to clipboard."].waitForExistence(timeout: 1))
            XCTAssertFalse(app.staticTexts["Couldn't create the share link."].exists)
            XCTAssertEqual(UIPasteboard.general.changeCount, afterSignOut)
            XCTAssertEqual(peer.requests.map(\.route), [.share])
            XCTAssertTrue(peer.unexpectedRequests.isEmpty, "Unexpected fixture requests: \(peer.unexpectedRequests)")
        }

        func testComponentHistoryAndRefineDispatchCurrentEventsAndClearPendingOnRefusal() throws {
            try launchComponents(replies: [:])
            let actions = ["refine", "history", "csv", "share"].map {
                app.buttons["component-action-component-table-\($0)"]
            }
            XCTAssertTrue(actions.allSatisfy(\.isHittable))
            XCTAssertEqual(actions.map(\.label), ["refine", "history", "csv", "share"])
            XCTAssertTrue(app.staticTexts["Provenance: estimated"].exists)
            XCTAssertFalse(app.staticTexts["Provenance: grounded"].exists)
            retainScreenshot("Server-owned component actions")
            app.buttons["component-action-component-empty-history"].tap()
            XCTAssertTrue(
                app.staticTexts["No earlier versions yet — refine the component to create one."].waitForExistence(
                    timeout: 3))
            app.buttons["Close"].tap()
            actions[1].tap()
            XCTAssertTrue(app.buttons["component-restore-2"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["component-restore-2"].label, "v2 · Earlier result · 2026-09-12 00:00")
            retainScreenshot("Component version history")
            app.buttons["component-restore-2"].tap()
            waitForComponentFrames(1)
            XCTAssertTrue(app.staticTexts["Component action result"].exists)
            XCTAssertFalse(actions[1].isEnabled)
            let restore = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: peer.componentFrames[0]) as? [String: Any])
            XCTAssertEqual(restore["action"] as? String, "component_restore")
            let restorePayload = try XCTUnwrap(restore["payload"] as? [String: Any])
            XCTAssertEqual(restorePayload["version_no"] as? Int, 2)
            XCTAssertEqual(restorePayload["component_id"] as? String, "component-table")
            XCTAssertEqual(restorePayload["chat_id"] as? String, WorkspaceActionLoopback.chat)
            peer.refuseLastComponent()
            XCTAssertTrue(app.staticTexts["Synthetic capacity refusal"].waitForExistence(timeout: 3))
            XCTAssertTrue(actions[1].isEnabled)

            actions[0].tap()
            let field = app.textFields.matching(NSPredicate(format: "identifier != %@", "chat-composer-input"))
                .firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.tap()
            field.typeText("  Sort by value  ")
            app.buttons["Refine"].firstMatch.tap()
            waitForComponentFrames(2)
            XCTAssertFalse(actions[0].isEnabled)
            let refine = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: peer.componentFrames[1]) as? [String: Any])
            XCTAssertEqual(refine["action"] as? String, "component_refine")
            XCTAssertEqual((refine["payload"] as? [String: Any])?["instruction"] as? String, "Sort by value")
            XCTAssertNotEqual(refine["submission_id"] as? String, restore["submission_id"] as? String)
            peer.refuseLastComponent()
            let enabled = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in actions[0].isEnabled }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
            XCTAssertTrue(app.staticTexts["Component action result"].exists)
            XCTAssertEqual(
                app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch.value as? String,
                "Draft survives component actions")
            XCTAssertTrue(peer.unexpectedRequests.isEmpty, "Unexpected fixture requests: \(peer.unexpectedRequests)")
        }

        func testComponentCSVAndPrivateShareRequireExplicitUserHandoff() throws {
            try launchComponents(replies: [.componentCSV: [.init()], .share: [.init(status: 201, held: true)]])
            app.buttons["component-action-component-table-csv"].tap()
            let save = app.buttons["Save or share astraldeep-table.csv"]
            XCTAssertTrue(save.waitForExistence(timeout: 8))
            XCTAssertEqual(peer.requests.map(\.route), [.componentCSV])
            app.buttons["Close"].tap()
            let clipboardBefore = UIPasteboard.general.changeCount
            app.buttons["component-action-component-table-share"].tap()
            waitForRequests(2)
            XCTAssertTrue(app.staticTexts["Creating share link…"].exists)
            retainScreenshot("Component share loading background")
            XCTAssertFalse(app.buttons["Copy link"].exists)
            peer.releaseHeldReplies()
            let copy = app.buttons["Copy link"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            retainScreenshot("Private component link before explicit copy")
            XCTAssertEqual(UIPasteboard.general.changeCount, clipboardBefore)
            copy.tap()
            XCTAssertTrue(app.buttons["Copied"].exists)
            XCTAssertGreaterThan(UIPasteboard.general.changeCount, clipboardBefore)
            XCTAssertTrue(peer.nativePreviewRequests.isEmpty)
            app.buttons["Share link"].tap()
            let activity = app.otherElements["ActivityListView"]
            XCTAssertTrue(activity.waitForExistence(timeout: 8))
            retainScreenshot("Explicit component share handoff")
            let preview = XCTNSPredicateExpectation(
                predicate: NSPredicate { [weak self] _, _ in
                    self?.peer.nativePreviewRequests.contains("/share/synthetic_workspace_ui_link") == true
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [preview], timeout: 5), .completed)
            let dismissRegion = app.otherElements.matching(identifier: "PopoverDismissRegion")
                .allElementsBoundByIndex.last { $0.isHittable }
            try XCTUnwrap(dismissRegion).tap()
            XCTAssertTrue(activity.waitForNonExistence(timeout: 3))
            app.buttons["Close"].firstMatch.tap()
            let shareRequest = try XCTUnwrap(peer.requests.first { $0.route == .share })
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: shareRequest.body) as? [String: String],
                ["chat_id": WorkspaceActionLoopback.chat, "scope": "component", "component_id": "component-table"])
            XCTAssertTrue(peer.requests.allSatisfy { $0.authorization == "Bearer \(WorkspaceActionLoopback.token)" })
            XCTAssertTrue(peer.unexpectedRequests.isEmpty, "Unexpected fixture requests: \(peer.unexpectedRequests)")
        }

        func testComponentFailuresStaySafeAndClosingDiscardsLateShare() throws {
            try launchComponents(replies: [
                .componentCSV: [.init(status: 403)],
                .share: [.init(status: 403, error: "phi_blocked"), .init(status: 201, held: true)],
            ])
            app.buttons["component-action-component-table-csv"].tap()
            XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Save or share astraldeep-table.csv"].exists)
            app.buttons["Close"].tap()
            app.buttons["component-action-component-table-share"].tap()
            XCTAssertTrue(
                app.staticTexts["Sharing refused: the content matched the PHI gate."].waitForExistence(timeout: 5))
            retainScreenshot("Component share refusal background")
            XCTAssertFalse(app.buttons["Copy link"].exists)
            XCTAssertFalse(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PRIVATE_SERVER_DETAIL")).firstMatch
                    .exists)
            app.buttons["Close"].tap()
            app.buttons["component-action-component-table-share"].tap()
            waitForRequests(3)
            app.buttons["Close"].tap()
            app.buttons["new-chat-button"].tap()
            XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 3))
            let baseline = UIPasteboard.general.changeCount
            peer.releaseHeldReplies()
            XCTAssertFalse(app.buttons["Copy link"].waitForExistence(timeout: 1))
            XCTAssertEqual(UIPasteboard.general.changeCount, baseline)
            XCTAssertEqual(peer.requests.map(\.route), [.componentCSV, .share, .share])
            XCTAssertTrue(peer.unexpectedRequests.isEmpty, "Unexpected fixture requests: \(peer.unexpectedRequests)")
        }

        func testTimelineKeepsServerOwnedCSVAndShareButNoRefineOrHistory() throws {
            try launchComponents(replies: [.componentCSV: [.init()]], timeline: true)
            XCTAssertFalse(app.buttons["component-action-component-table-refine"].exists)
            XCTAssertFalse(app.buttons["component-action-component-table-history"].exists)
            XCTAssertTrue(app.buttons["component-action-component-table-share"].exists)
            app.buttons["component-action-component-table-csv"].tap()
            XCTAssertTrue(app.buttons["Save or share astraldeep-table.csv"].waitForExistence(timeout: 8))
            XCTAssertEqual(peer.requests.map(\.route), [.componentCSV])
            XCTAssertTrue(peer.componentFrames.isEmpty)
        }

        func testDisconnectedComponentEditNeverReplaysAfterReconnect() throws {
            try launchComponents(replies: [:])
            peer.pauseSocketConnections()
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Reconnecting")).firstMatch
                    .waitForExistence(timeout: 5))
            app.buttons["component-action-component-table-refine"].tap()
            let field = app.textFields.matching(NSPredicate(format: "identifier != %@", "chat-composer-input"))
                .firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.tap()
            field.typeText("Do not replay")
            app.buttons["Refine"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Reconnect before changing this component."].waitForExistence(timeout: 3))
            app.buttons["new-chat-button"].tap()
            XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 3))
            peer.resumeSocketConnections()
            let reconnected = XCTNSPredicateExpectation(
                predicate: NSPredicate { [weak self] _, _ in (self?.peer.registrations ?? 0) >= 2 }, object: nil)
            // Normal socket backoff can reach 30 seconds; do not accelerate it for the fixture.
            XCTAssertEqual(XCTWaiter.wait(for: [reconnected], timeout: 35), .completed)
            XCTAssertTrue(peer.componentFrames.isEmpty)
        }

        private func retainScreenshot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        private func launchComponents(
            replies: [WorkspaceActionLoopback.Route: [WorkspaceActionLoopback.Reply]], timeline: Bool = false
        ) throws {
            peer = try WorkspaceActionLoopback(replies: replies, supportsWebSocket: true)
            peer.start()
            XCTAssertEqual(XCTWaiter.wait(for: [peer.ready], timeout: 3), .completed)
            let port = try XCTUnwrap(peer.port)
            app = XCUIApplication()
            app.launchArguments = [
                "--astral-ui-test-first-login", timeline ? "component-timeline-http" : "component-actions-http",
            ]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launchEnvironment["ASTRAL_UI_WORKSPACE_PORT"] = String(port)
            app.launch()
            XCTAssertTrue(app.staticTexts["Component action result"].waitForExistence(timeout: 10))
            let registered = XCTNSPredicateExpectation(
                predicate: NSPredicate { [weak self] _, _ in self?.peer.registrations == 1 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [registered], timeout: 5), .completed)
        }

        private func waitForComponentFrames(_ count: Int) {
            let observed = XCTNSPredicateExpectation(
                predicate: NSPredicate { [weak self] _, _ in self?.peer.componentFrames.count == count }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 5), .completed)
        }

        private func launch(replies: [WorkspaceActionLoopback.Route: [WorkspaceActionLoopback.Reply]]) throws {
            peer = try WorkspaceActionLoopback(replies: replies)
            peer.start()
            XCTAssertEqual(XCTWaiter.wait(for: [peer.ready], timeout: 3), .completed)
            let port = try XCTUnwrap(peer.port)
            app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-actions-http"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launchEnvironment["ASTRAL_UI_WORKSPACE_PORT"] = String(port)
            app.launch()
            XCTAssertTrue(app.buttons["workspace-action-export"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Visible workspace action result"].exists)
        }

        private func waitForRequests(_ count: Int) {
            let observed = XCTNSPredicateExpectation(
                predicate: NSPredicate { [weak self] _, _ in
                    self?.peer.requests.count == count
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 5), .completed)
        }

        private func assertCapturedVisibleCanvas() throws {
            let request = try XCTUnwrap(peer.requests.first { $0.route == .presentation })
            let capture = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            let components = try XCTUnwrap(capture["components"] as? [[String: Any]])
            XCTAssertEqual(components.first?["content"] as? String, "Visible workspace action result")
            XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("PRIVATE_UNUSED"))
            XCTAssertTrue(peer.requests.allSatisfy { $0.authorization == "Bearer \(WorkspaceActionLoopback.token)" })
        }
    }
#endif
