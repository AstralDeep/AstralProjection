// Tests for AppModel's first-turn reduce logic: wel_-prefixed welcome components are purged from the canvas
// when a turn arms, via sendChat and the chat_message event path, and excluded from every canvas-history
// snapshot.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelFirstTurnContractTests: XCTestCase {

    private let doneStatus = #"{"type":"chat_status","status":"done"}"#
    private let resultUpsert =
        #"{"type":"ui_upsert","ops":[{"op":"upsert","component_id":"wc_result","component":{"type":"card","component_id":"wc_result","title":"Result"}}]}"#
    private let resultRender =
        #"{"type":"ui_render","target":"canvas","components":[{"type":"card","component_id":"wc_result","title":"Result"}]}"#

    private func component(_ fields: [String: JSONValue]) -> AstralComponent {
        AstralComponent(json: .object(fields))!
    }

    private var welcomeHero: AstralComponent {
        component([
            "type": .string("hero"), "id": .string("wel_hero"),
            "component_id": .string("wel_hero"), "heading": .string("Welcome"),
        ])
    }
    private var welcomeExamples: AstralComponent {
        component([
            "type": .string("card"), "id": .string("wel_examples"),
            "component_id": .string("wel_examples"), "title": .string("Try asking"),
        ])
    }
    private var welcomeHint: AstralComponent {
        component([
            "type": .string("text"), "id": .string("wel_hint"),
            "content": .string("Pick an agent"),
        ])
    }
    private var workspaceCard: AstralComponent {
        component([
            "type": .string("card"), "component_id": .string("wc_abc123"),
            "title": .string("Budget"),
        ])
    }

    private func reduce(_ model: AppModel, _ json: String) {
        model.handleFrame(InboundFrame.parse(json)!)
    }

    func testSendChatPurgesWelcomeWhenArming() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [welcomeHero, welcomeExamples, welcomeHint]
        model.sendChat("what's the weather?")
        XCTAssertTrue(model.pendingReplace)
        XCTAssertTrue(model.canvas.isEmpty)
    }

    func testSendChatKeepsNonWelcomeComponents() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [welcomeHero, workspaceCard]
        model.sendChat("hello")
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_abc123"])
    }

    func testSendEventChatMessagePurgesWelcomeWhenArming() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [welcomeHero, welcomeHint]
        model.sendEvent("chat_message", .object(["message": .string("hi")]))
        XCTAssertTrue(model.pendingReplace)
        XCTAssertTrue(model.canvas.isEmpty)
    }

    func testCommitNeverArchivesWelcomeToHistory() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [workspaceCard]
        model.sendChat("first")
        model.canvas = [welcomeHero, workspaceCard]
        reduce(model, resultRender)
        reduce(model, doneStatus)
        XCTAssertEqual(model.canvasHistory.count, 1)
        XCTAssertEqual(model.canvasHistory[0].components.map(\.componentId), ["wc_abc123"])
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_result"])
    }

    func testCommitSkipsHistoryWhenOnlyWelcomeWasShowing() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [welcomeHero, welcomeExamples]
        model.sendChat("first")
        model.canvas = [welcomeHero]
        reduce(model, resultRender)
        reduce(model, doneStatus)
        XCTAssertTrue(model.canvasHistory.isEmpty)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_result"])
    }

    func testTextOnlyTurnDropsWelcomeFromKeptCanvas() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.sendChat("just a question")
        model.canvas = [welcomeHero, workspaceCard]
        reduce(model, doneStatus)
        XCTAssertFalse(model.turnActive)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_abc123"])
        XCTAssertTrue(model.canvasHistory.isEmpty)
    }

    func testUpsertOnlyTurnDropsWelcomeAtCommit() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.sendChat("just a question")
        model.canvas = [welcomeHero, workspaceCard]
        reduce(model, resultUpsert)
        reduce(model, doneStatus)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_abc123", "wc_result"])
        XCTAssertTrue(model.canvasHistory.isEmpty)
    }

    func testCommitStillArchivesAPlainCanvas() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [workspaceCard]
        model.sendChat("next")
        reduce(model, resultRender)
        reduce(model, doneStatus)
        XCTAssertEqual(model.canvasHistory.count, 1)
        XCTAssertEqual(model.canvasHistory[0].components, [workspaceCard])
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_result"])
    }
}
