// Tests for AppModel's text-only-turn and surface-dismissal reduce logic: a text-only answer still clears the
// canvas skeleton, and closing a settings surface is refused while the mandatory gate is pinned.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelTextOnlyCanvasTests: XCTestCase {

    private let doneStatus = #"{"type":"chat_status","status":"done"}"#
    private let resultUpsert =
        #"{"type":"ui_upsert","ops":[{"op":"upsert","component_id":"wc_result","component":{"type":"card","component_id":"wc_result","title":"Result"}}]}"#

    private func component(_ fields: [String: JSONValue]) -> AstralComponent {
        AstralComponent(json: .object(fields))!
    }

    private var welcomeExamples: AstralComponent {
        component([
            "type": .string("card"), "id": .string("wel_examples"),
            "component_id": .string("wel_examples"), "title": .string("Try asking"),
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

    private func continuityModel() -> AppModel {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        XCTAssertTrue(
            model.beginConversationConnection(UUID().uuidString.lowercased()))
        return model
    }

    func testTextOnlyTurnInContinuityModeKeepsTheWelcomeAndClearsTheSkeleton() {
        let model = continuityModel()
        model.canvas = [welcomeExamples]
        model.sendChat("hello")
        XCTAssertTrue(model.showSkeleton)

        reduce(model, doneStatus)

        XCTAssertFalse(model.showSkeleton, "the shimmer must not latch forever")
        XCTAssertFalse(model.turnActive)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wel_examples"])
    }

    func testTextOnlyTurnInContinuityModeKeepsAnExistingCanvas() {
        let model = continuityModel()
        model.canvas = [workspaceCard]
        model.sendChat("hello")

        reduce(model, doneStatus)

        XCTAssertFalse(model.showSkeleton)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_abc123"])
    }

    func testLegacyComponentTurnStillCommitsItsComponents() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [welcomeExamples]
        model.sendChat("chart it")
        reduce(model, resultUpsert)
        reduce(model, doneStatus)

        XCTAssertFalse(model.showSkeleton)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_result"])
    }

    func testCloseSurfaceDismissesASettingsSurface() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.screen = .surface
        model.pendingSurfaceKey = "llm"
        model.pendingSurface = AppModel.SurfaceContent(
            surfaceKey: "llm", title: "AI provider", components: [])

        model.closeSurface()

        XCTAssertEqual(model.screen, .chat)
        XCTAssertNil(model.pendingSurface)
        XCTAssertEqual(model.pendingSurfaceKey, "")
    }

    func testCloseSurfaceRefusesWhileTheMandatoryGateIsPinned() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.screen = .surface
        model.pendingSurfaceKey = "llm"
        model.pendingSurface = AppModel.SurfaceContent(
            surfaceKey: "llm", title: "Set up your AI provider", components: [])
        model.mandatorySurface = true

        model.closeSurface()

        XCTAssertEqual(model.screen, .surface)
        XCTAssertNotNil(model.pendingSurface)
    }

    func testBlankChromeSurfaceClosesTheSurfaceAndLiftsThePin() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.screen = .surface
        model.pendingSurfaceKey = "llm"
        model.mandatorySurface = true
        model.pendingSurface = AppModel.SurfaceContent(
            surfaceKey: "llm", title: "AI provider", components: [])

        reduce(
            model,
            #"{"type":"chrome_surface","region":"modal","surface_key":"","title":"","components":[],"mode":"replace"}"#
        )

        XCTAssertEqual(model.screen, .chat)
        XCTAssertFalse(model.mandatorySurface)
        XCTAssertNil(model.pendingSurface)
    }
}
