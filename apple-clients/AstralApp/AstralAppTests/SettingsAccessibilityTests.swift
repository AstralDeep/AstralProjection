// Checks what assistive technology hears from settings controls and the model's spoken announcements.
// Required fields, idle buttons, the selected filter chip, and approval, failure, banner and connection changes.

import AstralCore
import SwiftUI
import XCTest

@testable import AstralDeep

@MainActor
final class SettingsAccessibilityTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    private func model() throws -> (AppModel, () -> [String]) {
        let suite = "SettingsAccessibilityTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults), tokenStore: InMemoryTokenStore(),
            defaults: defaults)
        var spoken: [String] = []
        model.announcer = { spoken.append($0) }
        model.signedIn = true
        return (model, { spoken })
    }

    func testRequiredFieldsSayRequiredAndOptionalFieldsDoNot() {
        XCTAssertEqual(ParamPickerComponent.accessibleLabel("Address", required: true), "Address, required")
        XCTAssertEqual(ParamPickerComponent.accessibleLabel("Address", required: false), "Address")
    }

    func testIdleButtonsCarryNoValueAndPendingOnesSaySubmitting() {
        XCTAssertEqual(ComponentAccessibility.buttonValue(pending: false), "")
        XCTAssertEqual(ComponentAccessibility.buttonValue(pending: true), "Submitting")
    }

    func testTheSelectedFilterChipStaysEnabledAndDoesNothingWhenActivated() {
        let selected = CompactSettingsLayout.chipState(serverDisabled: true, selected: true)
        XCTAssertFalse(selected.disabled, "a selected chip must stay focusable")
        XCTAssertTrue(selected.inert)
        let disabled = CompactSettingsLayout.chipState(serverDisabled: true, selected: false)
        XCTAssertTrue(disabled.disabled)
        XCTAssertFalse(disabled.inert)
        let active = CompactSettingsLayout.chipState(serverDisabled: false, selected: true)
        XCTAssertFalse(active.disabled)
        XCTAssertFalse(active.inert)
    }

    func testErrorBannersAndTurnFailuresAreAnnouncedOnce() throws {
        let (model, spoken) = try model()
        model.errorBanner = "Couldn't save component"
        model.errorBanner = "Couldn't save component"
        model.errorBanner = nil
        XCTAssertEqual(spoken(), ["Couldn't save component"])

        model.turnActive = true
        model.handleFrame(
            try XCTUnwrap(
                InboundFrame.parse(#"{"type":"error","message":"The provider timed out.","code":"provider_timeout"}"#)))
        XCTAssertFalse(model.turnActive)
        XCTAssertEqual(spoken().last, "The provider timed out. (provider_timeout)")
    }

    func testConnectionLossAndRestoreAreAnnouncedButTheFirstConnectIsNot() async throws {
        let (model, spoken) = try model()
        await model.handle(.connected)
        XCTAssertTrue(spoken().isEmpty)
        await model.handle(.disconnected(reason: "network"))
        XCTAssertEqual(spoken(), ["Connection lost"])
        await model.handle(.disconnected(reason: "network"))
        XCTAssertEqual(spoken(), ["Connection lost"])
        await model.handle(.connected)
        XCTAssertEqual(spoken(), ["Connection lost", "Reconnected"])
        model.signedIn = false
        model.connected = false
        XCTAssertEqual(spoken(), ["Connection lost", "Reconnected"])
    }

    func testAWaitingApprovalIsAnnouncedOncePerRequest() throws {
        let (model, spoken) = try model()
        model.activeChatId = "c1"
        model.turns = [.init(id: "u1", role: "user", text: "Type a sentence")]
        model.canvas = [ActivityFrames.approvalCard("r1")]
        model.canvas = [ActivityFrames.approvalCard("r1")]
        XCTAssertEqual(spoken(), ["Approval waiting: Click in TextEdit"])
        model.canvas = [ActivityFrames.approvalCard("r1"), ActivityFrames.approvalCard("r2")]
        XCTAssertEqual(spoken().count, 2)
    }
}
