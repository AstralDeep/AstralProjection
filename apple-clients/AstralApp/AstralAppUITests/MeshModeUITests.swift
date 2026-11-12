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

        replace(seventh, with: "word7")
        replace(eighteenth, with: "word18")
        proceed.tap()
        XCTAssertTrue(element("mesh.tab.chats").waitForExistence(timeout: 10))
        XCTAssertFalse(element("mesh.recovery.word.1").exists)
        attach("mesh-created")
    }

    func testJoinShowsTheCodeQrAndCopy() {
        launch("onboarding")
        XCTAssertTrue(element("mesh.join").waitForExistence(timeout: 10))
        element("mesh.join").tap()
        XCTAssertTrue(element("mesh.join.code").waitForExistence(timeout: 10))
        XCTAssertTrue(element("mesh.join.qr").exists)
        XCTAssertTrue(element("mesh.join.copy").exists)
        XCTAssertTrue(element("mesh.join.waiting").exists)
        attach("mesh-join")
        element("mesh.join.cancel").tap()
        XCTAssertTrue(element("mesh.create").waitForExistence(timeout: 5))
    }

    func testShellShowsWaitingDeviceQueuedMessageBranchesAndApproval() {
        launch("shell")
        XCTAssertTrue(element("mesh.strip.sync").waitForExistence(timeout: 10))
        XCTAssertTrue((element("mesh.strip.sync").label).contains("Waiting for Sam's iPhone"))
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
        XCTAssertTrue(element("mesh.tab.devices").waitForExistence(timeout: 10))
        selectTab("Devices")
        XCTAssertTrue(element("mesh.devices.add").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.devices.stop").exists)
        attach("mesh-devices")
        selectTab("Settings")
        element("mesh.settings.allowance").tap()
        XCTAssertTrue(element("mesh.allowance.blocked").waitForExistence(timeout: 5))
        XCTAssertTrue(element("mesh.allowance.share").exists)
        attach("mesh-allowance")
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    private func selectTab(_ name: String) {
        let bar = app.tabBars.buttons[name]
        if bar.exists { bar.tap() } else { app.radioButtons[name].firstMatch.tap() }
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
