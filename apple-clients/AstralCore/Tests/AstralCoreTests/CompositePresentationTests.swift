// Exercises composite primitive normalization, semantic states and finite chart geometry.
// These values are consumed directly by the Apple renderer and accessibility descriptions.

import XCTest

@testable import AstralCore

final class CompositePresentationTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    func testActionsPreservePayloadIdentityAndDisabledState() throws {
        let group = ActionGroupPresentation(
            try json(
                #"{"label":"Review","align":" END ","buttons":[null,7,{"id":"approve","label":"Approve","action":"confirm","payload":{"nonce":"bound"},"disabled":true},{"type":"text","label":"Cancel","action":"cancel"}]}"#
            ))
        XCTAssertEqual(group.label, "Review")
        XCTAssertEqual(group.alignment, "end")
        XCTAssertEqual(group.buttons.count, 2)
        XCTAssertEqual(group.buttons[0].componentId, "approve")
        XCTAssertEqual(group.buttons[0].raw["payload"]?["nonce"], .string("bound"))
        XCTAssertEqual(group.buttons[0].raw["disabled"], .bool(true))
        XCTAssertEqual(group.buttons[1].type, "button")
        XCTAssertEqual(group.buttons[1].raw["action"], .string("cancel"))
        XCTAssertEqual(ActionGroupPresentation(.null).alignment, "start")
        XCTAssertTrue(ActionGroupPresentation(.null).buttons.isEmpty)
        for align in ["start", "center", "between"] {
            XCTAssertEqual(ActionGroupPresentation(.object(["align": .string(align)])).alignment, align)
        }
    }

    func testStatsRetainZeroValuesTrendsAndAllSemanticStates() throws {
        let stats = StatGroupPresentation(
            try json(
                #"{"title":"Counts","columns":99,"items":[false,{"label":"None","value":0,"delta":"0%","hint":"No change","trend":" FLAT ","variant":"invalid"},{"trend":"up","variant":"success"},{"trend":"down","variant":"warning"},{}]}"#
            ))
        XCTAssertEqual(stats.title, "Counts")
        XCTAssertEqual(stats.columns, 6)
        XCTAssertEqual(stats.items.count, 4)
        XCTAssertEqual(stats.items[0].value, "0")
        XCTAssertEqual(stats.items[0].delta, "0%")
        XCTAssertEqual(stats.items[0].hint, "No change")
        XCTAssertEqual(stats.items.map(\.trendSymbol), ["–", "▲", "▼", ""])
        XCTAssertEqual(stats.items.map(\.variant), ["default", "success", "warning", "default"])
        XCTAssertEqual(StatGroupPresentation(.null).columns, 4)
        XCTAssertEqual(StatGroupPresentation(.object(["columns": .number(-10)])).columns, 1)
        XCTAssertEqual(StatGroupPresentation(.object(["columns": .number(.infinity)])).columns, 4)
    }

    func testGaugeUsesOrderedThresholdsAndClampsMalformedValues() throws {
        let gauge = GaugePresentation(
            try json(
                #"{"label":"Capacity","value":0.75,"display_value":"3 of 4","subtitle":"Ready","thresholds":[false,{"at":0.5,"variant":"warning"},{"at":0.9,"variant":"error"},{"at":0.7,"variant":"invalid"}]}"#
            ))
        XCTAssertEqual(gauge.value, 0.75)
        XCTAssertEqual(gauge.variant, "warning")
        XCTAssertEqual(gauge.accessibilityLabel, "Capacity: 3 of 4")
        XCTAssertEqual(gauge.subtitle, "Ready")
        for (value, expected) in [
            (JSONValue.number(-2), "0%"), (.number(2), "100%"), (.string("0.425"), "42%"), (.string("bad"), "0%"),
            (.number(.nan), "0%"), (.number(.infinity), "0%"),
        ] {
            XCTAssertEqual(GaugePresentation(.object(["value": value])).accessibilityLabel, expected)
        }
        XCTAssertEqual(GaugePresentation(.null).variant, "default")
        XCTAssertEqual(CompositeValue.number(.string("nan"), default: 3), 3)
        XCTAssertEqual(CompositeValue.text(.null), "")
        XCTAssertEqual(CompositeValue.text(nil), "")
    }

    func testPipelineAnnouncesOnlyFirstActiveStepAndRetainsDetails() throws {
        let pipeline = PipelinePresentation(
            try json(
                #"{"title":"Pipeline","orientation":"VERTICAL","steps":[0,{"label":"Load","status":"done","detail":"12 rows"},{"status":"active"},{"status":"active"},{"status":"error"},{"status":"injected"}]}"#
            ))
        XCTAssertEqual(pipeline.title, "Pipeline")
        XCTAssertTrue(pipeline.vertical)
        XCTAssertEqual(pipeline.steps.map(\.isCurrent), [false, true, false, false, false])
        XCTAssertEqual(pipeline.steps.map(\.variant), ["success", "info", "info", "error", "default"])
        XCTAssertEqual(pipeline.steps[0].label, "Load")
        XCTAssertEqual(pipeline.steps[0].detail, "12 rows")
        XCTAssertEqual(pipeline.steps.last?.status, "pending")
        XCTAssertFalse(PipelinePresentation(.null).vertical)
        XCTAssertTrue(PipelinePresentation(.null).steps.isEmpty)
    }

    func testDonutMatchesProportionsAndKeepsEverySeriesAccessible() throws {
        let donut = DonutPresentation(
            try json(
                #"{"title":"Shares","center_label":"Total","center_value":"100","labels":["A","B"],"data":[60,40,-1,"bad",0,0,0]}"#
            ))
        XCTAssertEqual(donut.title, "Shares")
        XCTAssertEqual(donut.centerLabel, "Total")
        XCTAssertEqual(donut.centerValue, "100")
        XCTAssertEqual(donut.segments.count, 7)
        XCTAssertEqual(donut.segments[0].start, 0)
        XCTAssertEqual(donut.segments[0].end, 0.6, accuracy: 0.00001)
        XCTAssertEqual(donut.segments[1].start, 0.6, accuracy: 0.00001)
        XCTAssertEqual(donut.segments[1].end, 1)
        XCTAssertEqual(donut.segments[2].value, 0)
        XCTAssertEqual(donut.segments[2].label, "series 3")
        XCTAssertEqual(donut.segments[6].series, 0)
        let overflow = DonutPresentation(.object(["data": .array([.number(1e308), .number(1e308)])]))
        XCTAssertEqual(overflow.segments[0].end, 0.5)
        XCTAssertEqual(overflow.segments[1].end, 1)
        XCTAssertEqual(DonutPresentation(.object(["data": .array([.number(0)])])).segments[0].end, 0)
        XCTAssertTrue(DonutPresentation(.null).segments.isEmpty)
    }

    func testRadarScaleAndGeometryAreBoundedWithoutLosingSourceValues() throws {
        let radar = RadarPresentation(
            try json(
                #"{"title":"Quality","axes":["A","B","C"],"max_value":10,"datasets":[false,{"label":"Run","data":[20,5,-2]},{"label":"Partial","data":["2"]}]}"#
            ))
        XCTAssertEqual(radar.title, "Quality")
        XCTAssertTrue(radar.canRender)
        XCTAssertEqual(radar.axes, ["A", "B", "C"])
        XCTAssertEqual(radar.datasets[0].values, [20, 5, 0])
        XCTAssertEqual(radar.datasets[0].label, "Run")
        XCTAssertEqual(radar.datasets[0].points[0].x, 0.5, accuracy: 0.00001)
        XCTAssertEqual(radar.datasets[0].points[0].y, 0.05, accuracy: 0.00001)
        XCTAssertEqual(radar.datasets[1].points[1].x, 0.5)
        XCTAssertEqual(radar.datasets[1].points[1].y, 0.5)
        XCTAssertEqual(radar.datasets[1].series, 1)
        for maximum in [JSONValue.null, .number(0), .number(-5), .string("bad"), .number(.infinity)] {
            let model = RadarPresentation(
                .object([
                    "axes": .array([.string("A"), .string("B"), .string("C")]), "max_value": maximum,
                    "datasets": .array([.object(["data": .array([.number(2)])])]),
                ]))
            XCTAssertEqual(model.datasets[0].points[0].y, 0.05, accuracy: 0.00001)
        }
        let zero = RadarPresentation(try json(#"{"axes":["A","B","C"],"datasets":[{"data":[0,0,0]}]}"#))
        XCTAssertEqual(zero.datasets[0].points.map(\.y), [0.5, 0.5, 0.5])
        XCTAssertFalse(RadarPresentation(.null).canRender)
        XCTAssertFalse(RadarPresentation(try json(#"{"axes":["A","B"],"datasets":[{}]}"#)).canRender)
    }

    func testOnlyLargeScreenClientsAdvertiseCompositeRenderers() {
        for type in ["action_group", "stat_group", "gauge", "pipeline_stepper", "donut_chart", "radar_chart"] {
            XCTAssertEqual(ClientDispositions.ios.components[type], .native)
            XCTAssertEqual(ClientDispositions.macos.components[type], .native)
            XCTAssertFalse(ClientDispositions.watch.nativeComponentTypes.contains(type))
            guard case .fallback = ClientDispositions.watch.components[type] else {
                return XCTFail("Watch must keep the server fallback for \(type)")
            }
        }
        XCTAssertEqual(ClientDispositions.ios.frames["rote_config"], .handled)
        XCTAssertEqual(ClientDispositions.watch.frames["rote_config"], .handled)
        XCTAssertEqual(ClientDispositions.watch.frames["user_preferences"], .handled)
    }
}
