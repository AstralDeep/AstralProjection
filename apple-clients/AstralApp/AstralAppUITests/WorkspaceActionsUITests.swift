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
            XCTAssertTrue(peer.unexpectedRequests.isEmpty)
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
            XCTAssertTrue(peer.unexpectedRequests.isEmpty)
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
            XCTAssertTrue(peer.unexpectedRequests.isEmpty)
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
            XCTAssertTrue(peer.unexpectedRequests.isEmpty)

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
            XCTAssertTrue(peer.unexpectedRequests.isEmpty)
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
