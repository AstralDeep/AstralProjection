// Tests for AppModel's workspace-verb reduce logic: component_deleted removes by identity,
// components_combined/condensed apply carried rows and remove consumed ones, and save/combine acks drive
// banners and status.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelWorkspaceVerbTests: XCTestCase {

    private func component(_ fields: [String: JSONValue]) -> AstralComponent {
        AstralComponent(json: .object(fields))!
    }

    private var budgetCard: AstralComponent {
        component([
            "type": .string("card"), "component_id": .string("wc_budget"),
            "title": .string("Budget"),
        ])
    }
    private var forecastCard: AstralComponent {
        component([
            "type": .string("card"), "component_id": .string("wc_forecast"),
            "title": .string("Forecast"),
        ])
    }

    private func reduce(_ model: AppModel, _ json: String) {
        model.handleFrame(InboundFrame.parse(json)!)
    }

    func testComponentDeletedRemovesByIdentity() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [budgetCard, forecastCard]
        reduce(model, #"{"type":"component_deleted","component_id":"wc_budget"}"#)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_forecast"])
    }

    func testComponentDeletedUnknownIdIsNoOp() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [budgetCard]
        reduce(model, #"{"type":"component_deleted","component_id":"row-uuid-elsewhere"}"#)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_budget"])
    }

    func testComponentDeletedMidTurnAppliesLiveAndMirrorsIntoBuffer() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [budgetCard, forecastCard]
        model.sendChat("working…")
        model.pendingCanvas = [budgetCard, forecastCard]
        reduce(model, #"{"type":"component_deleted","component_id":"wc_forecast"}"#)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_budget"])
        XCTAssertEqual(model.pendingCanvas.map(\.componentId), ["wc_budget"])
    }

    private let combinedFrame = #"""
        {"type":"components_combined","removed_ids":["wc_budget","wc_forecast"],
         "new_components":[{"id":"row-9","chat_id":"c1","component_type":"combined","title":"Merged",
           "component_data":{"type":"card","component_id":"wc_merged","title":"Merged"}}]}
        """#

    func testCombinedAppliesResultAndRemovesConsumed() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [budgetCard, forecastCard]
        model.statusText = "Combining Budget with Forecast..."
        reduce(model, combinedFrame)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_merged"])
        XCTAssertNil(model.statusText)
    }

    func testCondensedFallsBackToRowIdWhenComponentDataLacksIdentity() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [budgetCard, forecastCard]
        reduce(
            model,
            #"""
            {"type":"components_condensed","removed_ids":["wc_budget","wc_forecast"],
             "new_components":[{"id":"row-3","chat_id":"c1","component_type":"condensed","title":"Summary",
               "component_data":{"type":"card","title":"Summary"}}]}
            """#)
        XCTAssertEqual(model.canvas.map(\.componentId), ["row-3"])
    }

    func testCombinedSkipsMalformedRowsButStillRemoves() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [budgetCard]
        reduce(model, #"{"type":"components_combined","removed_ids":["wc_budget"],"new_components":[{"id":"row-1"}]}"#)
        XCTAssertTrue(model.canvas.isEmpty)
    }

    func testComponentSavedShowsInfoBannerWithTitle() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        reduce(model, #"{"type":"component_saved","component":{"id":"row-1","title":"Budget"}}"#)
        XCTAssertEqual(model.errorBanner, "Saved Budget")
        XCTAssertFalse(model.bannerIsError)
    }

    func testComponentSaveErrorShowsErrorBanner() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        reduce(model, #"{"type":"component_save_error","error":"Component not found"}"#)
        XCTAssertEqual(model.errorBanner, "Component not found")
        XCTAssertTrue(model.bannerIsError)
    }

    func testCombineStatusDrivesStatusLine() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        reduce(model, #"{"type":"combine_status","status":"combining","message":"Combining Budget with Forecast..."}"#)
        XCTAssertEqual(model.statusText, "Combining Budget with Forecast...")
    }

    func testCombineErrorClearsStatusAndShowsErrorBanner() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.statusText = "Condensing 3 components..."
        model.canvas = [budgetCard]
        reduce(model, #"{"type":"combine_error","error":"At least 2 components are required to condense"}"#)
        XCTAssertNil(model.statusText)
        XCTAssertTrue(model.bannerIsError)
        XCTAssertEqual(model.errorBanner, "At least 2 components are required to condense")
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_budget"])
    }

    func testSavedComponentsListIsAcceptedWithoutSideEffects() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.canvas = [budgetCard]
        reduce(model, #"{"type":"saved_components_list","components":[{"id":"row-1","title":"Budget"}]}"#)
        XCTAssertEqual(model.canvas.map(\.componentId), ["wc_budget"])
        XCTAssertNil(model.errorBanner)
        XCTAssertNil(model.statusText)
    }
}
