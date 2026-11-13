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

    private func launch(_ scenario: String) {
        app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-mesh", scenario]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testCreatingAMeshShowsRecoveryWordsOnceAndRequiresConfirmation() {
        launch("onboarding")
        XCTAssertTrue(element("mesh.create").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.join").exists)
        XCTAssertTrue(element("mesh.node").exists)
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
        XCTAssertTrue(element("mesh.tab.chats").waitForExistence(timeout: 10))
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
        XCTAssertTrue(element("mesh.restore.count").label.contains("23 of 24"))
        XCTAssertFalse(submit.isEnabled)
        words.typeText(" wrongword")
        XCTAssertTrue(submit.isEnabled)
        attach("mesh-recover")
        submit.tap()
        XCTAssertTrue(element("mesh.restore.error").waitForExistence(timeout: 5))
        XCTAssertFalse(element("mesh.restored.title").exists)

        words.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        words.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: " wrongword".count) + " wordx")
        XCTAssertTrue(element("mesh.restore.count").label.contains("24 of 24"))
        submit.tap()
        XCTAssertTrue(element("mesh.restored.title").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.restored.device").exists)
        XCTAssertTrue(element("mesh.restored.members").exists)
        attach("mesh-restored")
        element("mesh.restored.continue").tap()
        XCTAssertTrue(element("mesh.tab.chats").waitForExistence(timeout: 10))
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
        let reason = app.buttons["Not now"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        reason.tap()
        XCTAssertTrue(element("mesh.request.reason.11111111").waitForExistence(timeout: 5))
        XCTAssertFalse(element("mesh.request.refuse.11111111").exists)
    }

    func testPermissionsAndMailboxLiveInSettings() {
        launch("shell")
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 15))
        selectTab("Settings")
        XCTAssertTrue(element("mesh.settings.permissions").waitForExistence(timeout: 5))
        element("mesh.settings.permissions").tap()
        XCTAssertTrue(element("mesh.tool.grant.this-device/current_datetime").waitForExistence(timeout: 5))
        XCTAssertFalse(element("mesh.tool.revoke.this-device/current_datetime").exists)
        XCTAssertTrue(element("mesh.permissions.remote.none").exists)
        attach("mesh-permissions")
        element("mesh.tool.grant.this-device/current_datetime").tap()
        XCTAssertTrue(element("mesh.tool.granted.this-device/current_datetime").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.tool.revoke.this-device/current_datetime").exists)
        XCTAssertFalse(element("mesh.tool.grant.this-device/current_datetime").exists)
        attach("mesh-permissions-granted")
        goBack()
        XCTAssertTrue(element("mesh.settings.mailbox").waitForExistence(timeout: 5))
        element("mesh.settings.mailbox").tap()
        XCTAssertTrue(element("mesh.mailbox.status").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.mailbox.status").label.contains("No mailbox is set"))
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
        XCTAssertTrue((element("mesh.strip.sync").label).contains("Waiting for Sam's iPhone"))
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
        app.swipeUp()
        XCTAssertTrue(element("mesh.devices.stop").waitForExistence(timeout: 5))
        attach("mesh-devices-safety")
        selectTab("Settings")
        element("mesh.settings.allowance").tap()
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
        launch("shell")
        selectTab("Devices")
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 10))
        element("mesh.devices.add").tap()
        XCTAssertTrue(element("mesh.invite.fallback").waitForExistence(timeout: 5))
        element("mesh.invite.fallback").tap()
        XCTAssertTrue(element("mesh.add.step.1").waitForExistence(timeout: 5))
        attach("mesh-add-fallback-1-start")
        element("mesh.add.start").tap()
        XCTAssertTrue(element("mesh.add.step.2").waitForExistence(timeout: 5))
        attach("mesh-add-fallback-2-code")
        let field = element("mesh.add.payload")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("astral-pair:v1:offer")
        element("mesh.add.continue").tap()
        XCTAssertTrue(element("mesh.add.step.3").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.add.code").exists)
        element("mesh.add.approve").tap()
        XCTAssertTrue(element("mesh.add.done").waitForExistence(timeout: 5))
        element("mesh.add.done").tap()
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 5))
    }

    func testAnUnreadableCodeKeepsThePersonOnTheCodeStepWithAnError() {
        launch("shell")
        selectTab("Devices")
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 10))
        element("mesh.devices.add").tap()
        XCTAssertTrue(element("mesh.invite.fallback").waitForExistence(timeout: 5))
        element("mesh.invite.fallback").tap()
        element("mesh.add.start").tap()
        let field = element("mesh.add.payload")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("not a code")
        element("mesh.add.continue").tap()
        XCTAssertTrue(element("mesh.add.error").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.add.step.2").exists)
        attach("mesh-add-error")
    }

    func testDeviceDetailOffersRequestAndRemovalWithConfirmation() {
        launch("shell")
        selectTab("Devices")
        let row = app.staticTexts["Sam's iPhone"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element("mesh.device.header").waitForExistence(timeout: 5))
        attach("mesh-device-detail")
        app.swipeUp()
        XCTAssertTrue(element("mesh.device.request").waitForExistence(timeout: 5))
        attach("mesh-device-detail-actions")
        element("mesh.device.remove").tap()
        XCTAssertTrue(app.buttons["Remove Device"].waitForExistence(timeout: 5))
        attach("mesh-device-remove-confirm")
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    private func selectTab(_ name: String) {
        let bar = app.tabBars.buttons[name]
        if bar.exists {
            bar.tap()
        } else {
            let side = element("mesh.side." + name.lowercased())
            if side.exists { side.tap() } else { app.radioButtons[name].firstMatch.tap() }
        }
    }

    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
