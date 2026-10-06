// UI tests for conversation continuity across process relaunch: one relaunch deterministically restores the
// same semantic conversation, with a 20-second guard against a hung restoration and the measured relaunch time
// attached as evidence, and the authenticated provider gate survives a relaunch.

import Foundation
import XCTest

final class ConversationContinuityUITests: XCTestCase {
    private let hungRestorationGuard: TimeInterval = 20
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testDeterministicProcessRelaunchRestoresSemanticConversation() {
        launch(scenario: "continuity-seed")
        assertSemanticConversation(timeout: hungRestorationGuard)
        app.terminate()

        let startedAt = Date()
        launch(scenario: "continuity-resume")
        assertSemanticConversation(timeout: hungRestorationGuard)
        let duration = Date().timeIntervalSince(startedAt)
        XCTAssertLessThan(
            duration, hungRestorationGuard,
            "restoration hung: the relaunched conversation was not restored within the 20-second hang guard")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "apple-continuity-relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(
            data: Data(app.debugDescription.utf8),
            uniformTypeIdentifier: "public.plain-text")
        hierarchy.name = "apple-continuity-relaunch-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let timing = XCTAttachment(
            data: Data("relaunch_seconds=\(format(duration))".utf8), uniformTypeIdentifier: "public.plain-text")
        timing.name = "apple-continuity-relaunch-timing"
        timing.lifetime = .keepAlways
        add(timing)
    }

    func testLiveAuthenticatedProviderGateSurvivesRelaunch() throws {
        app = XCUIApplication()
        app.launch()
        guard app.staticTexts["Set up your AI provider"].waitForExistence(timeout: 5) else {
            throw XCTSkip("requires an explicitly prepared authenticated simulator session")
        }
        app.terminate()

        app = XCUIApplication()
        let startedAt = Date()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Set up your AI provider"].waitForExistence(timeout: 5),
            "authenticated provider gate was not restored after relaunch")
        XCTAssertFalse(app.buttons["Sign in"].exists)
        let duration = Date().timeIntervalSince(startedAt)
        XCTAssertLessThan(duration, 5, "authenticated relaunch exceeded five seconds")

        let report = [
            "surface=mandatory_provider_setup",
            "authentication=persisted_keycloak_pkce_session",
            "relaunch_seconds=\(format(duration))",
        ].joined(separator: "\n")
        let timing = XCTAttachment(
            data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        timing.name = "apple-live-authenticated-relaunch-timing"
        timing.lifetime = .keepAlways
        add(timing)
    }

    private func launch(scenario: String) {
        if app == nil { app = XCUIApplication() }
        app.launchArguments = ["--astral-ui-test-first-login", scenario]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
    }

    private func assertSemanticConversation(timeout: TimeInterval) {
        let disclosure = app.buttons["collapsed-chat-toggle"]
        if disclosure.exists && disclosure.label == "Show conversation" { disclosure.press() }
        let required = [
            "Continuity question", "continuity.pdf", "Continuity total: 21",
            "Continuity component answer", "Restored continuity canvas",
        ]
        let forbidden = ["Your generated interface appears here", "locator was not restored"]
        let deadline = Date().addingTimeInterval(timeout)
        var texts: [String] = []
        repeat {
            if let snapshot = try? app.snapshot() {
                var pending: [XCUIElementSnapshot] = [snapshot]
                texts.removeAll(keepingCapacity: true)
                while let node = pending.popLast() {
                    if node.elementType == .staticText {
                        texts.append(node.label)
                        if let value = node.value as? String { texts.append(value) }
                    }
                    pending.append(contentsOf: node.children)
                }
                if required.allSatisfy({ fragment in texts.contains { $0.contains(fragment) } }) { break }
            }
        } while Date() < deadline
        for fragment in required {
            XCTAssertTrue(texts.contains { $0.contains(fragment) }, "Missing restored text: \(fragment)")
        }
        for fragment in forbidden {
            XCTAssertFalse(texts.contains { $0.contains(fragment) }, "Unexpected restored text: \(fragment)")
        }
    }

    private func format(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }
}
