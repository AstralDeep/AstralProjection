import Foundation
import XCTest

final class ConversationContinuityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testDeterministicProcessRelaunchRestoresSemanticConversationTwentyTimes() {
        launch(scenario: "continuity-seed")
        assertSemanticConversation(timeout: 5)
        app.terminate()

        var durations: [TimeInterval] = []
        for trial in 1...20 {
            let startedAt = Date()
            launch(scenario: "continuity-resume")
            assertSemanticConversation(timeout: 5)
            let duration = Date().timeIntervalSince(startedAt)
            durations.append(duration)
            XCTAssertLessThan(
                duration,
                5,
                "trial \(trial) exceeded the five-second deterministic restoration bound")
            if trial < 20 { app.terminate() }
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "apple-continuity-twentieth-relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(
            data: Data(app.debugDescription.utf8),
            uniformTypeIdentifier: "public.plain-text")
        hierarchy.name = "apple-continuity-twentieth-relaunch-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let sorted = durations.sorted()
        let report = [
            "trials=\(durations.count)",
            "mean_seconds=\(format(durations.reduce(0, +) / Double(durations.count)))",
            "p50_seconds=\(format(percentile(0.50, sorted: sorted)))",
            "p95_seconds=\(format(percentile(0.95, sorted: sorted)))",
            "max_seconds=\(format(sorted.last ?? 0))",
            "samples_seconds=\(durations.map(format).joined(separator: ","))",
        ].joined(separator: "\n")
        let timing = XCTAttachment(
            data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        timing.name = "apple-continuity-relaunch-timings"
        timing.lifetime = .keepAlways
        add(timing)
    }

    func testLiveAuthenticatedProviderGateSurvivesTwentyRelaunches() throws {
        app = XCUIApplication()
        app.launch()
        guard app.staticTexts["Set up your AI provider"].waitForExistence(timeout: 5) else {
            throw XCTSkip("requires an explicitly prepared authenticated simulator session")
        }
        app.terminate()

        var durations: [TimeInterval] = []
        for trial in 1...20 {
            app = XCUIApplication()
            let startedAt = Date()
            app.launch()

            let providerGate = app.staticTexts["Set up your AI provider"]
            XCTAssertTrue(
                providerGate.waitForExistence(timeout: 5),
                "authenticated provider gate was not restored on trial \(trial)")
            XCTAssertFalse(app.buttons["Sign in"].exists)
            let duration = Date().timeIntervalSince(startedAt)
            durations.append(duration)
            XCTAssertLessThan(
                duration,
                5,
                "authenticated relaunch trial \(trial) exceeded five seconds")
            if trial < 20 { app.terminate() }
        }

        let sorted = durations.sorted()
        let report = [
            "surface=mandatory_provider_setup",
            "authentication=persisted_keycloak_pkce_session",
            "trials=\(durations.count)",
            "mean_seconds=\(format(durations.reduce(0, +) / Double(durations.count)))",
            "p50_seconds=\(format(percentile(0.50, sorted: sorted)))",
            "p95_seconds=\(format(percentile(0.95, sorted: sorted)))",
            "max_seconds=\(format(sorted.last ?? 0))",
            "samples_seconds=\(durations.map(format).joined(separator: ","))",
        ].joined(separator: "\n")
        let timing = XCTAttachment(
            data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        timing.name = "apple-live-authenticated-relaunch-timings"
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
        let required = [
            "Continuity question", "continuity.pdf", "Continuity total: 21",
            "Continuity component answer", "Restored continuity canvas",
        ]
        let forbidden = ["Your generated interface appears here", "locator was not restored"]
        let deadline = Date().addingTimeInterval(timeout)
        var texts: [String] = []
        repeat {
            // One public accessibility snapshot observes the whole restored
            // conversation atomically. Seven remote queries plus XCTest's
            // existence-polling floor consumed the launch-inclusive budget.
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

    private func percentile(_ fraction: Double, sorted: [TimeInterval]) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(0, min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1))
        return sorted[rank]
    }

    private func format(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }
}
