// UI tests for mesh mode over the DEBUG in-memory kernel: creating a mesh with its one-time recovery words, and the seeded shell with honest sync state, devices and settings.
// No sign-in, Keychain item, network or kernel is involved.

import XCTest

final class MeshModeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    private func launch(_ scenario: String, largestText: Bool = false, autoJoin: Bool = true) {
        app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-mesh", scenario]
        if !autoJoin { app.launchArguments.append("--astral-ui-test-no-auto-join") }
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func pressConsentButton(_ button: XCUIElement) {
        #if os(macOS)
            app.activate()
            button.click()
        #else
            button.tap()
        #endif
    }

    func testFirstLaunchShowsCreateAndJoinBeforeAnyServerLogin() {
        launch("firstLaunch")
        XCTAssertTrue(element("mesh.create").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.join").exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    func testLegacyServerLoginPreferenceOpensMeshChoices() {
        launch("legacyLogin")
        XCTAssertTrue(element("mesh.create").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.join").exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    func testAttachmentOnlyMessageShowsItsFileAndTheComposerCanAddAnother() {
        launch("attachments")
        let chat = element("mesh.chat.chat-1")
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertTrue(shown(chat).contains("Shared files"))
        chat.tap()
        let addFile = app.buttons["mesh.composer.attach"]
        XCTAssertTrue(addFile.waitForExistence(timeout: 5))
        XCTAssertTrue(text("notes.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save notes.txt"].isEnabled)
        attach("mesh-file-attachment")
        addFile.tap()
        #if os(macOS)
            XCTAssertTrue(
                waitUntil(5) {
                    self.app.sheets.count > 0 || self.app.dialogs.count > 0 || !self.element("mesh.composer").isHittable
                })
            attach("mesh-file-picker")
        #else
            let cancel = app.buttons["Cancel"]
            guard cancel.waitForExistence(timeout: 10) else {
                XCTFail("The document picker did not present its Cancel button.")
                return
            }
            attach("mesh-file-picker", screenshot: XCUIScreen.main.screenshot())
            cancel.tap()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
            XCTAssertTrue(addFile.isHittable)
        #endif
    }

    func testCreatingAMeshShowsRecoveryWordsOnceAndRequiresConfirmation() {
        launch("onboarding")
        XCTAssertTrue(element("mesh.create").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.join").exists)
        element("mesh.create").tap()

        XCTAssertTrue(element("mesh.recovery.word.1").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.recovery.word.24").exists)
        let proceed = element("mesh.recovery.continue")
        XCTAssertFalse(proceed.isEnabled)
        element("mesh.recovery.written").tap()
        let seventh = app.textFields["mesh.recovery.answer.7"]
        let eighteenth = app.textFields["mesh.recovery.answer.18"]
        XCTAssertTrue(seventh.waitForExistence(timeout: 2))
        seventh.tap()
        seventh.typeText("wrong")
        eighteenth.tap()
        eighteenth.typeText("wrong")
        proceed.tap()
        XCTAssertTrue(element("mesh.recovery.mismatch").waitForExistence(timeout: 2))
        XCTAssertTrue(element("mesh.recovery.word.1").exists)

        replace(seventh, with: "wordg")
        replace(eighteenth, with: "wordr")
        proceed.tap()
        XCTAssertTrue(shellMarker.waitForExistence(timeout: 10))
        XCTAssertFalse(element("mesh.recovery.word.1").exists)
        attach("mesh-created")
    }

    func testRecoveringWithTheWordsShowsTheRestoredMeshAndDevice() {
        launch("onboarding")
        XCTAssertTrue(element("mesh.recover").waitForExistence(timeout: 10))
        element("mesh.recover").tap()
        let words = element("mesh.restore.words")
        XCTAssertTrue(words.waitForExistence(timeout: 5))
        let submit = element("mesh.restore.submit")
        XCTAssertFalse(submit.isEnabled)
        XCTAssertTrue(element("mesh.restore.file.choose").exists)
        words.tap()
        words.typeText((0..<23).map { "word" + String(UnicodeScalar(UInt8(97 + $0))) }.joined(separator: " "))
        XCTAssertTrue(countShows("23 of 24"))
        XCTAssertFalse(submit.isEnabled)
        words.typeText(" wrongword")
        XCTAssertTrue(submit.isEnabled)
        attach("mesh-recover")
        submit.tap()
        XCTAssertTrue(element("mesh.restore.error").waitForExistence(timeout: 5))
        XCTAssertFalse(element("mesh.restored.title").exists)

        #if os(macOS)
            words.tap()
            words.typeKey("a", modifierFlags: .command)
            words.typeText(
                (0..<23).map { "word" + String(UnicodeScalar(UInt8(97 + $0))) }.joined(separator: " ") + " wordx")
        #else
            words.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
            words.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: " wrongword".count) + " wordx")
        #endif
        XCTAssertTrue(countShows("24 of 24"))
        submit.tap()
        XCTAssertTrue(element("mesh.restored.title").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.restored.device").exists)
        XCTAssertTrue(element("mesh.restored.members").exists)
        attach("mesh-restored")
        element("mesh.restored.continue").tap()
        XCTAssertTrue(shellMarker.waitForExistence(timeout: 10))
    }

    func testRequestsShowInTheChatAndCanBeRefusedWithAReason() {
        launch("shell")
        let chat = element("mesh.chat.chat-1")
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        XCTAssertTrue(element("mesh.chat.requests").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.request.refuse.11111111").exists)
        XCTAssertTrue(element("mesh.request.answer.11111111").exists)
        XCTAssertTrue(element("mesh.request.reason.22222222").exists)
        attach("mesh-requests")
        element("mesh.request.refuse.11111111").tap()
        #if os(macOS)
            let reason = app.sheets.buttons["Not now"]
        #else
            let reason = app.buttons["Not now"]
        #endif
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        reason.tap()
        XCTAssertTrue(element("mesh.request.reason.11111111").waitForExistence(timeout: 5))
        XCTAssertFalse(element("mesh.request.refuse.11111111").exists)
    }

    func testRemoteMCPManagerIsReachableFromSettings() {
        launch("shell")
        XCTAssertTrue(waitForShell())
        selectTab("Settings")
        let manager = element("mesh.settings.mcp")
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
        visible("mesh.settings.mcp").tap()
        XCTAssertTrue(element("mesh.mcp.name").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.mcp.endpoint").exists)
        XCTAssertTrue(element("mesh.mcp.bearer").exists)
        XCTAssertTrue(element("mesh.mcp.save").exists)
        attach("mesh-mcp-manager")
    }

    func testPermissionsAndMailboxLiveInSettings() {
        launch("shell")
        XCTAssertTrue(waitForShell())
        selectTab("Settings")
        XCTAssertTrue(element("mesh.settings.permissions").waitForExistence(timeout: 5))
        visible("mesh.settings.permissions").tap()
        XCTAssertTrue(element("mesh.tool.grant.this-device/current_datetime").waitForExistence(timeout: 5))
        XCTAssertFalse(element("mesh.tool.revoke.this-device/current_datetime").exists)
        XCTAssertTrue(element("mesh.permissions.remote.none").exists)
        attach("mesh-permissions")
        visible("mesh.tool.grant.this-device/current_datetime").tap()
        XCTAssertTrue(element("mesh.tool.granted.this-device/current_datetime").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.tool.revoke.this-device/current_datetime").exists)
        XCTAssertFalse(element("mesh.tool.grant.this-device/current_datetime").exists)
        attach("mesh-permissions-granted")
        let mailbox = element("mesh.settings.mailbox")
        #if os(macOS)
            app.terminate()
            launch("shell")
            XCTAssertTrue(waitForShell())
            selectTab("Settings")
            XCTAssertTrue(mailbox.waitForExistence(timeout: 5))
            visible("mesh.settings.mailbox").tap()
        #else
            goBack()
            let settings = app.collectionViews.firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let start = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            attach("mesh-settings-mailbox-revealed")
            XCTAssertTrue(mailbox.waitForExistence(timeout: 5))
            XCTAssertTrue(mailbox.isHittable)
            mailbox.tap()
        #endif
        XCTAssertTrue(element("mesh.mailbox.status").waitForExistence(timeout: 5))
        XCTAssertTrue(shown(element("mesh.mailbox.status")).contains("No mailbox is set"))
    }

    func testReviewOpensTheConsentSheetWithTheActionAndDenyClosesIt() {
        launch("shell")
        let review = element("mesh.consent.review")
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        pressConsentButton(review)
        XCTAssertTrue(element("consent.sheet").waitForExistence(timeout: 10))
        XCTAssertTrue(element("consent.title").exists)
        XCTAssertTrue(element("consent.summary").exists)
        XCTAssertTrue(element("consent.details").exists)
        XCTAssertTrue(element("consent.approve").exists)
        XCTAssertTrue(element("consent.deny").exists)
        attach("mesh-consent-sheet")
        pressConsentButton(element("consent.deny"))
        XCTAssertTrue(element("mesh.consent.review").waitForNonExistence(timeout: 10))
        XCTAssertFalse(element("consent.sheet").exists)
    }

    func testNodeApprovalShowsTheExecutingNodeAndLetsTheOwnerDecline() {
        launch("nodeConsent")
        let review = element("mesh.consent.review")
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        pressConsentButton(review)
        let summary = element("consent.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(shown(summary).contains("Approve mail.send on node 2222 2222 2222 2222"))
        pressConsentButton(element("consent.deny"))
        XCTAssertTrue(review.waitForNonExistence(timeout: 10))
        XCTAssertFalse(element("consent.sheet").exists)
    }

    func testDenyOnTheBannerDismissesTheApprovalWithoutASheet() {
        launch("shell")
        let deny = element("mesh.consent.deny")
        XCTAssertTrue(deny.waitForExistence(timeout: 10))
        deny.tap()
        XCTAssertTrue(element("mesh.consent.review").waitForNonExistence(timeout: 10))
        XCTAssertFalse(element("consent.sheet").exists)
    }

    func testOutcomeUnknownCardOffersCheckOrLeave() {
        launch("shell")
        let chat = element("mesh.chat.chat-1")
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        let card = element("mesh.unknown.check")
        #if os(iOS)
            for _ in 0..<4 where !card.exists { app.swipeUp() }
        #endif
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.unknown.leave").exists)
        attach("mesh-outcome-unknown")
    }

    func testTheLargestTextSizeKeepsEveryMeshScreenUsable() {
        launch("shell", largestText: true)
        selectTab("Devices")
        XCTAssertTrue(element("mesh.devices.toolbar.add").waitForExistence(timeout: 10))
        attach("mesh-xxxl-devices")
        element("mesh.devices.toolbar.add").tap()
        XCTAssertTrue(element("mesh.invite.code").waitForExistence(timeout: 5))
        attach("mesh-xxxl-add-device")
        app.buttons["mesh.add.close"].tap()
        selectTab("Settings")
        XCTAssertTrue(element("mesh.settings.rename").waitForExistence(timeout: 5))
        attach("mesh-xxxl-settings")
        selectTab("Chats")
        let chat = element("mesh.chat.chat-1")
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()
        XCTAssertTrue(element("mesh.composer").waitForExistence(timeout: 5))
        attach("mesh-xxxl-chat")
    }

    func testRunsAndSettingsScreensRender() {
        launch("shell")
        selectTab("Runs")
        XCTAssertTrue(element("mesh.runs.none").waitForExistence(timeout: 10))
        attach("mesh-runs")
        selectTab("Settings")
        XCTAssertTrue(element("mesh.settings.models").waitForExistence(timeout: 5))
        attach("mesh-settings")
        swipeUp()
        XCTAssertTrue(element("mesh.settings.recovery").waitForExistence(timeout: 5))
        attach("mesh-settings-more")
        swipeDown()
        visible("mesh.settings.models").tap()
        XCTAssertTrue(element("mesh.models.save").waitForExistence(timeout: 5))
        attach("mesh-model-provider")
    }

    func testJoinOffersScanOrPasteAndShowsTheComparisonCode() {
        launch("onboarding")
        XCTAssertTrue(element("mesh.join").waitForExistence(timeout: 10))
        element("mesh.join").tap()
        XCTAssertTrue(element("mesh.join.payload").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.join.fallback").exists)
        attach("mesh-join-start")
        element("mesh.join.payload").tap()
        element("mesh.join.payload").typeText("astral-invite:v1:invitation")
        element("mesh.join.continue").tap()
        XCTAssertTrue(element("mesh.join.code").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.join.waiting").exists)
        attach("mesh-join-compare")
        element("mesh.join.cancel").tap()
        XCTAssertTrue(element("mesh.join.payload").waitForExistence(timeout: 5))
    }

    func testJoinCanShowItsOwnCodeInstead() {
        launch("onboarding")
        XCTAssertTrue(element("mesh.join").waitForExistence(timeout: 10))
        element("mesh.join").tap()
        XCTAssertTrue(element("mesh.join.fallback").waitForExistence(timeout: 10))
        element("mesh.join.fallback").tap()
        XCTAssertTrue(element("mesh.join.code").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.join.qr").exists)
        XCTAssertTrue(element("mesh.join.copy").exists)
        XCTAssertTrue(element("mesh.countdown").exists)
        attach("mesh-join-code")
        element("mesh.join.cancel").tap()
        XCTAssertTrue(element("mesh.join.payload").waitForExistence(timeout: 5))
    }

    func testShellShowsWaitingDeviceQueuedMessageBranchesAndApproval() {
        launch("shell")
        selectTab("Devices")
        XCTAssertTrue(element("mesh.strip.sync").waitForExistence(timeout: 10))
        XCTAssertTrue(shown(element("mesh.strip.sync")).contains("Waiting to sync with Sam's iPhone"))
        selectTab("Chats")
        XCTAssertTrue(element("mesh.consent.review").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.consent.deny").exists)

        let chat = element("mesh.chat.chat-1")
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()
        XCTAssertTrue(element("mesh.message.queued").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.message.branches").exists)
        attach("mesh-chat")
    }

    func testDevicesAndSettingsExposeMembersStopAndAllowance() {
        launch("shell")
        selectTab("Devices")
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 10))
        attach("mesh-devices")
        swipeUp()
        XCTAssertTrue(element("mesh.devices.stop").waitForExistence(timeout: 5))
        attach("mesh-devices-safety")
        selectTab("Settings")
        reveal("mesh.settings.allowance").tap()
        XCTAssertTrue(element("mesh.allowance.blocked").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.allowance.share").exists)
        attach("mesh-allowance")
    }

    func testAddingADeviceShowsAnInvitationThenComparesCodesAndApproves() {
        launch("shell")
        selectTab("Devices")
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 10))
        element("mesh.devices.add").tap()
        XCTAssertTrue(element("mesh.invite.code").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.countdown").exists)
        attach("mesh-add-1-invitation")
        XCTAssertTrue(element("mesh.invite.compare").waitForExistence(timeout: 10))
        attach("mesh-add-2-compare")
        element("mesh.invite.approve").tap()
        XCTAssertTrue(element("mesh.invite.done").waitForExistence(timeout: 5))
        attach("mesh-add-3-done")
        element("mesh.invite.done").tap()
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 5))
    }

    func testTheFallbackWalksThroughCodeComparisonAndApproval() {
        launch("shell", autoJoin: false)
        selectTab("Devices")
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 10))
        element("mesh.devices.add").tap()
        XCTAssertTrue(element("mesh.invite.fallback").waitForExistence(timeout: 5))
        visible("mesh.invite.fallback").tap()
        XCTAssertTrue(element("mesh.add.step.1").waitForExistence(timeout: 5))
        attach("mesh-add-fallback-1-start")
        visible("mesh.add.start").tap()
        XCTAssertTrue(element("mesh.add.step.2").waitForExistence(timeout: 5))
        attach("mesh-add-fallback-2-code")
        let field = element("mesh.add.payload")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        visible("mesh.add.payload").tap()
        field.typeText("astral-pair:v1:offer")
        visible("mesh.add.continue").tap()
        XCTAssertTrue(element("mesh.add.step.3").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.add.code").exists)
        visible("mesh.add.approve").tap()
        XCTAssertTrue(element("mesh.add.done").waitForExistence(timeout: 5))
        visible("mesh.add.done").tap()
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 5))
    }

    func testAnUnreadableCodeKeepsThePersonOnTheCodeStepWithAnError() {
        launch("shell", autoJoin: false)
        selectTab("Devices")
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 10))
        element("mesh.devices.add").tap()
        XCTAssertTrue(element("mesh.invite.fallback").waitForExistence(timeout: 5))
        visible("mesh.invite.fallback").tap()
        XCTAssertTrue(element("mesh.add.start").waitForExistence(timeout: 5))
        visible("mesh.add.start").tap()
        let field = element("mesh.add.payload")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        visible("mesh.add.payload").tap()
        field.typeText("not a code")
        visible("mesh.add.continue").tap()
        XCTAssertTrue(element("mesh.add.error").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.add.step.2").exists)
        attach("mesh-add-error")
    }

    func testDeviceDetailOffersRequestAndRemovalWithConfirmation() {
        launch("shell")
        selectTab("Devices")
        #if os(macOS)
            let row = element("mesh.member.cccccccc")
        #else
            let row = app.staticTexts["Sam's iPhone"].firstMatch
        #endif
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element("mesh.device.header").waitForExistence(timeout: 5))
        attach("mesh-device-detail")
        swipeUp()
        XCTAssertTrue(element("mesh.device.request").waitForExistence(timeout: 5))
        attach("mesh-device-detail-actions")
        visible("mesh.device.remove").tap()
        XCTAssertTrue(app.buttons["Remove Device"].waitForExistence(timeout: 5))
        attach("mesh-device-remove-confirm")
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    private func selectTab(_ name: String) {
        let bar = app.tabBars.buttons[name]
        if bar.exists {
            bar.tap()
            return
        }
        #if os(macOS)
            guard name != "Chats" else { return }
            let side = element("mesh.side." + name.lowercased())
            XCTAssertTrue(side.waitForExistence(timeout: 10))
            side.tap()
        #else
            let side = element("mesh.side." + name.lowercased())
            if side.exists { side.tap() } else { app.radioButtons[name].firstMatch.tap() }
        #endif
    }

    private var shellMarker: XCUIElement {
        #if os(macOS)
            return element("mesh.side.devices")
        #else
            return element("mesh.tab.chats")
        #endif
    }

    private func waitForShell() -> Bool {
        #if os(macOS)
            return element("mesh.side.settings").waitForExistence(timeout: 15)
        #else
            return app.tabBars.buttons["Settings"].waitForExistence(timeout: 15)
        #endif
    }

    private func text(_ value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", value, value)).firstMatch
    }

    private func shown(_ element: XCUIElement) -> String {
        element.label.isEmpty ? ((element.value as? String) ?? "") : element.label
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func swipeUp() {
        #if os(iOS)
            app.swipeUp()
        #endif
    }

    private func swipeDown() {
        #if os(iOS)
            app.swipeDown()
        #endif
    }

    private func countShows(_ text: String) -> Bool {
        let count = element("mesh.restore.count")
        let shown = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        let expectation = XCTNSPredicateExpectation(predicate: shown, object: count)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @discardableResult
    private func reveal(_ id: String, attempts: Int = 6) -> XCUIElement {
        #if os(macOS)
            return visible(id, attempts: attempts)
        #else
            let target = element(id)
            var swipes = 0
            while !(target.exists && target.isHittable) && swipes < attempts {
                app.swipeUp(velocity: .slow)
                swipes += 1
            }
            return target
        #endif
    }

    private func visible(_ id: String, attempts: Int = 8) -> XCUIElement {
        let target = element(id)
        #if os(macOS)
            guard target.waitForExistence(timeout: 5), let view = scrollView(containing: target) else { return target }
            var delta: CGFloat = -150
            for _ in 0..<attempts {
                let before = target.frame
                let shownFrame = view.frame.insetBy(dx: 0, dy: 4)
                if shownFrame.contains(before) { break }
                let below = before.maxY > shownFrame.maxY
                view.scroll(byDeltaX: 0, deltaY: delta)
                let moved = target.frame.midY - before.midY
                if (below && moved >= 0) || (!below && moved <= 0) { delta = -delta }
            }
        #endif
        return target
    }

    #if os(macOS)
        private func scrollView(containing target: XCUIElement) -> XCUIElement? {
            let sheet = app.sheets.firstMatch
            let root = sheet.exists ? sheet : app.windows.firstMatch
            let x = target.frame.midX
            return root.scrollViews.allElementsBoundByIndex
                .filter { $0.frame.minX <= x && x <= $0.frame.maxX && $0.frame.height > 0 }
                .max { $0.frame.height < $1.frame.height }
        }
    #endif

    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
    }

    private func attach(_ name: String, screenshot: XCUIScreenshot? = nil) {
        let shot = XCTAttachment(screenshot: screenshot ?? app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
