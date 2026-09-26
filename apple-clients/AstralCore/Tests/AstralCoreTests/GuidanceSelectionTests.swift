// Checks the shared guidance picker and selection confirmations against current request fencing.
// Notes keep their existing behavior while only confirmed selection commands can replace chat selection.

import XCTest

@testable import AstralCore

final class GuidanceSelectionTests: XCTestCase {
    func testServerGeneratedSelectedAndClearedConfirmations() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/console/guidance-confirmation.json")))
        for entry in fixture["cases"]!.arrayValue! {
            let frame = InboundFrame(name: "chrome_surface", payload: entry["frame"]!)
            let update = try XCTUnwrap(GuidanceSurfaceUpdate(frame: frame))
            let selection = try XCTUnwrap(update.selection)
            XCTAssertEqual(selection.isEmpty, entry["name"]?.stringValue == "cleared")
            XCTAssertEqual(selection.json, frame.payload["selection"])
            var state = GuidanceRequestState()
            let request = try XCTUnwrap(GuidanceRequest(action: "chrome_turn_selection_set", payload: selection.json))
            XCTAssertTrue(state.begin(request, generation: update.generation))
            XCTAssertTrue(state.accepts(update))
        }
    }

    private func picker() throws -> InboundFrame {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/guidance_088/selection_surface.json")))
        return InboundFrame(name: "chrome_surface", payload: fixture["frames"]!["picker"]!)
    }

    private func requests(_ components: [AstralComponent]) -> [GuidanceRequest] {
        components.flatMap { component in
            (GuidanceRequest(component: component).map { [$0] } ?? []) + requests(component.children)
        }
    }

    func testSharedPickerAdmitsOnlyItsOfferedExactCommands() throws {
        let frame = try picker()
        let update = try XCTUnwrap(GuidanceSurfaceUpdate(frame: frame))
        XCTAssertNil(update.selection)
        let controls = requests(update.components)
        XCTAssertEqual(controls.filter { $0.action == "chrome_turn_selection_set" }.count, 5)
        XCTAssertTrue(controls.contains(.selection))
        for request in controls {
            XCTAssertTrue(update.permits(request))
            let text = request.frameText(requestGeneration: update.generation)
            XCTAssertEqual(GuidanceRequest(frameText: text), request)
            XCTAssertTrue(GuidanceRequest.claimsCurrentConnectionSemantics(frameText: text))
        }
        XCTAssertFalse(update.permits(.list))
        var extra = TurnSelection.empty.json.objectValue!
        extra["notes"] = .array([
            .object(["note_id": .string("11111111-1111-4111-8111-111111111111"), "revision": .number(1)])
        ])
        XCTAssertFalse(
            update.permits(try XCTUnwrap(GuidanceRequest(action: "chrome_turn_selection_set", payload: .object(extra))))
        )
    }

    func testSelectionOpenAndCommandsRejectUnknownFieldsAndNonDeclarativeAgentIds() throws {
        XCTAssertEqual(GuidanceRequest.selection.payload["params"], .object(["view": .string("selection")]))
        for params: JSONValue in [
            .object(["view": .string("unknown")]), .object(["view": .string("selection"), "mode": .string("list")]),
        ] {
            XCTAssertNil(
                GuidanceRequest(
                    action: "chrome_open", payload: .object(["surface": .string("guidance"), "params": params])))
        }
        XCTAssertNil(GuidanceRequest(action: "chrome_turn_selection_set", payload: .object([:])))
        var invalid = TurnSelection.empty.json.objectValue!
        invalid["agent"] = .object([
            "agent_id": .string("built_in_agent"), "revision_id": .string("11111111-1111-4111-8111-111111111111"),
        ])
        XCTAssertNotNil(TurnSelection(json: .object(invalid)))
        XCTAssertNil(GuidanceRequest(action: "chrome_turn_selection_set", payload: .object(invalid)))
        let raw = try picker().payload.objectValue!
        for selection in [JSONValue.null, .object([:]), .object(invalid)] {
            var fields = raw
            fields["selection"] = selection
            XCTAssertNil(GuidanceSurfaceUpdate(frame: InboundFrame(name: "chrome_surface", payload: .object(fields))))
        }
    }

    func testOnlyCurrentSelectionConfirmationCanReplaceOrClearSelection() throws {
        let frame = try picker()
        let picker = try XCTUnwrap(GuidanceSurfaceUpdate(frame: frame))
        let command = try XCTUnwrap(requests(picker.components).first { $0.action == "chrome_turn_selection_set" })
        var fields = frame.payload.objectValue!
        fields["selection"] = command.payload
        let confirmation = try XCTUnwrap(
            GuidanceSurfaceUpdate(frame: InboundFrame(name: frame.name, payload: .object(fields))))
        XCTAssertEqual(confirmation.selection?.json, command.payload)
        var state = GuidanceRequestState()
        XCTAssertFalse(state.accepts(confirmation))
        XCTAssertTrue(state.begin(.selection, generation: picker.generation))
        XCTAssertTrue(state.accepts(picker))
        XCTAssertFalse(state.accepts(confirmation))
        XCTAssertTrue(state.begin(command, generation: picker.generation))
        XCTAssertTrue(state.bindSubmission(command.frameText(requestGeneration: picker.generation)))
        XCTAssertTrue(state.accepts(confirmation))
        fields["selection"] = TurnSelection.empty.json
        let cleared = try XCTUnwrap(
            GuidanceSurfaceUpdate(frame: InboundFrame(name: frame.name, payload: .object(fields))))
        XCTAssertTrue(try XCTUnwrap(cleared.selection).isEmpty)
        XCTAssertTrue(state.accepts(cleared))
        fields["request_generation"] = .string("11111111-1111-4111-8111-111111111111")
        let stale = try XCTUnwrap(
            GuidanceSurfaceUpdate(frame: InboundFrame(name: frame.name, payload: .object(fields))))
        XCTAssertFalse(state.accepts(stale))
        state.invalidate()
        XCTAssertFalse(state.accepts(confirmation))
        XCTAssertFalse(state.accepts(cleared))
        XCTAssertNotEqual(confirmation, cleared)
    }
}
