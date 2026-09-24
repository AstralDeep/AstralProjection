// Tests for AppModel's mid-stream join behavior: stream_subscribed after load_chat leaves an
// already-rehydrated component in place, and the live canvas, not a placeholder, is read for mid-turn guards.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelStreamJoinTests: XCTestCase {

    private var liveChartCard: AstralComponent {
        AstralComponent(
            json: .object([
                "type": .string("card"), "component_id": .string("wc_abc"),
                "title": .string("Live chart"),
            ]))!
    }

    private let subscribedFrame =
        #"{"type":"stream_subscribed","stream_id":"s1","tool_name":"live_chart","component_id":"wc_abc"}"#

    private func reduce(_ model: AppModel, _ json: String) {
        model.handleFrame(InboundFrame.parse(json)!)
    }

    func testMidStreamJoinKeepsRehydratedComponent() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [liveChartCard]
        reduce(model, subscribedFrame)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_abc"])
        XCTAssertEqual(model.canvas[0].type, "card")
    }

    func testSubscribedBuildsPlaceholderOnFreshCanvas() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        reduce(model, subscribedFrame)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_abc"])
        XCTAssertEqual(model.canvas[0].type, "text")
    }

    func testMidTurnGuardReadsTheLiveCanvas() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [liveChartCard]
        model.sendChat("working…")
        reduce(model, subscribedFrame)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_abc"])
        XCTAssertEqual(model.canvas[0].type, "card")
    }

    func testMidTurnPlaceholderAppliesLiveWhenCanvasLacksIdentity() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.sendChat("working…")
        reduce(model, subscribedFrame)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_abc"])
        XCTAssertEqual(model.canvas[0].type, "text")
        XCTAssertTrue(model.pendingCanvas.isEmpty)
    }
}
