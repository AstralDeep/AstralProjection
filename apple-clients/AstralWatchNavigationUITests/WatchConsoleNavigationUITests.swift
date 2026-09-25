// Drives the shipped watch console through catalog, draft, conversation and result navigation.
// A bounded synthetic peer uses the same canonical watch fixture as model tests and records actual outbound actions.

import Foundation
import XCTest

@MainActor
final class WatchConsoleNavigationUITests: XCTestCase {
    private var peer: WatchNavigationPeer!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "WatchConsoleFixtures", withExtension: "json"))
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var menu = try XCTUnwrap(fixture["menu"] as? [String: Any])
        var console = try XCTUnwrap(menu["console"] as? [String: Any])
        var catalog = try XCTUnwrap(console["catalog"] as? [String: Any])
        let scenarios = try XCTUnwrap(catalog["scenarios"] as? [[String: Any]])
        catalog["scenarios"] = scenarios.filter { $0["id"] as? String == "roll_some_dice" }
        console["catalog"] = catalog
        menu["console"] = console
        fixture["menu"] = menu
        peer = try WatchNavigationPeer(consoleFixture: fixture)
        peer.start()
        XCTAssertEqual(XCTWaiter.wait(for: [peer.ready], timeout: 5), .completed)
        app = XCUIApplication()
        app.launchEnvironment["ASTRAL_WATCH_NAVIGATION_PEER"] =
            "ws://127.0.0.1:\(try XCTUnwrap(peer.port))/watch-navigation"
        app.launch()
        XCTAssertTrue(app.staticTexts["AstralDeep Console"].waitForExistence(timeout: 10), app.debugDescription)
    }

    override func tearDownWithError() throws {
        if let peer {
            XCTAssertTrue(peer.errors.isEmpty, peer.errors.joined(separator: "; "))
            peer.stop()
        }
        app?.terminate()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<20 {
            if element.exists && element.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let upward = !element.exists || element.frame.midY > app.frame.midY
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.45 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    private func back() {
        let control = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 3), app.debugDescription)
        control.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCatalogLoadRequiresSendAndResultDetailRetainsTheConversation() throws {
        let start = app.buttons["Start here"]
        reveal(start)
        start.tap()
        let load = app.buttons["Load prompt"]
        reveal(load)
        load.tap()
        let send = app.buttons["watch-send-dictation"]
        reveal(send)
        XCTAssertTrue(peer.frames.isEmpty)
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(
                    format: "label CONTAINS %@", "Roll exactly six six-sided dice and show the normalized results.")
            ).firstMatch.exists)
        capture("Watch console loaded draft")
        send.tap()
        let received = XCTNSPredicateExpectation(
            predicate: NSPredicate { [peer] _, _ in
                peer!.frames.contains { $0["action"] as? String == "chat_message" }
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 5), .completed)
        let message = try XCTUnwrap(peer.frames.first { $0["action"] as? String == "chat_message" })
        XCTAssertEqual(
            (message["payload"] as? [String: Any])?["message"] as? String,
            "Roll exactly six six-sided dice and show the normalized results.")
        peer.renderResult(for: message, text: "Six dice total 21")
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Six dice total 21")).firstMatch
        reveal(result)
        result.tap()
        XCTAssertTrue(app.staticTexts["Six dice total 21"].waitForExistence(timeout: 5), app.debugDescription)
        capture("Watch console result detail")
        back()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(peer.frames.filter { $0["action"] as? String == "chat_message" }.count, 1)
    }

    func testNewChatAndComposerHandoffRemainInTheNavigationStack() throws {
        let newChat = app.buttons["New Chat"]
        reveal(newChat)
        newChat.tap()
        let more = app.buttons["More options"]
        reveal(more)
        more.tap()
        let background = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Run in background"))
            .firstMatch
        reveal(background)
        background.tap()
        let dismiss = app.buttons["OK"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.tables.staticTexts["Continue on your phone or desktop."].firstMatch.exists)
        capture("Watch console handoff")
        XCTAssertFalse(peer.frames.contains { $0["action"] as? String == "chat_message" })
        dismiss.tap()
        let recent = app.buttons["Recent work"]
        reveal(recent)
        recent.tap()
        let received = XCTNSPredicateExpectation(
            predicate: NSPredicate { [peer] _, _ in
                peer!.frames.contains { $0["action"] as? String == "chrome_open" }
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 5), .completed)
        let request = try XCTUnwrap(peer.frames.first { $0["action"] as? String == "chrome_open" })
        XCTAssertEqual((request["payload"] as? [String: Any])?["surface"] as? String, "work")
        peer.respond(to: request, title: "Recent work")
        XCTAssertTrue(app.staticTexts["Synthetic retained evidence"].waitForExistence(timeout: 5))
        back()
        XCTAssertTrue(background.waitForExistence(timeout: 3), app.debugDescription)
        back()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
    }

    func testAgentIntroductionAndSettingsUseTheCurrentServerOffers() throws {
        let directory = app.buttons["Agent Directory"]
        reveal(directory)
        directory.tap()
        let agent = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Alpha Agent")).firstMatch
        reveal(agent)
        capture("Watch console agent directory")
        agent.tap()
        let received = XCTNSPredicateExpectation(
            predicate: NSPredicate { [peer] _, _ in
                peer!.frames.contains { $0["action"] as? String == "chrome_open" }
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 5), .completed)
        let request = try XCTUnwrap(peer.frames.first { $0["action"] as? String == "chrome_open" })
        let payload = try XCTUnwrap(request["payload"] as? [String: Any])
        XCTAssertEqual(payload["surface"] as? String, "agent_intro")
        XCTAssertEqual((payload["params"] as? [String: Any])?["agent_id"] as? String, "alpha")
        peer.respond(to: request, title: "Alpha Agent", surface: "agent_intro")
        XCTAssertTrue(app.staticTexts["Synthetic retained evidence"].waitForExistence(timeout: 5), app.debugDescription)
        capture("Watch console agent introduction")
        back()
        XCTAssertTrue(agent.waitForExistence(timeout: 3), app.debugDescription)
        back()
        let settings = app.buttons["Settings"]
        reveal(settings)
        settings.tap()
        let control = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "LLM settings")).firstMatch
        reveal(control)
        capture("Watch console settings")
        control.tap()
        let dismiss = app.buttons["OK"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.tables.staticTexts["Continue on your phone or desktop."].firstMatch.exists)
        dismiss.tap()
        XCTAssertEqual(peer.frames.filter { $0["action"] as? String == "chrome_open" }.count, 1)
    }
}
