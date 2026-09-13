import Foundation
import XCTest

@testable import AstralCore

final class GuidanceSurface088Tests: XCTestCase {
    let generation = "8c7c08ee-0d23-43db-9156-ea3e4e729f89"
    func fixture() throws -> JSONValue {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/guidance_088/notes_surface.json")))
    }
    func update(_ mode: String, changes: [String: JSONValue] = [:]) throws -> GuidanceSurfaceUpdate? {
        var raw = try fixture()["frames"]![mode]!.objectValue!
        raw.merge(changes) { _, new in new }
        return GuidanceSurfaceUpdate(frame: InboundFrame(name: "chrome_surface", payload: .object(raw)))
    }
    func form(_ mode: String) throws -> GuidanceForm {
        let component = try XCTUnwrap(update(mode)?.components.first { $0.type == "param_picker" })
        return try XCTUnwrap(GuidanceForm(component: component))
    }
    func testExactSharedProducerFramesAndDefaultsAreComplete() throws {
        for mode in ["list", "new", "edit", "forget"] {
            let actual = try XCTUnwrap(update(mode))
            XCTAssertEqual(actual.components.map(\.raw), try fixture()["frames"]![mode]!["components"]!.arrayValue!)
            XCTAssertEqual(actual.generation, generation)
        }
        let create = try form("new")
        let edit = try form("edit")
        XCTAssertEqual(create.defaults["category"], .string("Context"))
        XCTAssertEqual(edit.defaults["category"], .string("Preference"))
        XCTAssertEqual(edit.defaults["expiry"], .string("Keep current expiry"))
        let date = edit.fields.last!
        XCTAssertFalse(edit.visible(date, values: [:]))
        XCTAssertTrue(edit.visible(date, values: ["expiry": .string("Set a date")]))
        XCTAssertNil(create.request(values: [:]))
        let request = try XCTUnwrap(edit.request(values: [:]))
        XCTAssertEqual(request.payload["fields"]?["value"], edit.defaults["value"])
        XCTAssertTrue(try XCTUnwrap(update("edit")).permits(request))
        XCTAssertFalse(try XCTUnwrap(update("new")).permits(request))
    }
    func testEveryCommandHasCurrentWireIdentityAndNeverUsesReadRetryPayload() throws {
        var requests = [GuidanceRequest.list]
        for mode in ["list", "new", "edit", "forget"] {
            func collect(_ component: AstralComponent) {
                if let r = GuidanceRequest(component: component) { requests.append(r) }
                component.children.forEach(collect)
            }
            try XCTUnwrap(update(mode)).components.forEach(collect)
        }
        requests.append(try XCTUnwrap(form("edit").request(values: [:])))
        requests.append(try XCTUnwrap(form("list").request(values: ["search": .string("context")])))
        for request in requests {
            let wire = request.frameText(requestGeneration: generation)
            XCTAssertEqual(GuidanceRequest(frameText: wire), request)
            XCTAssertTrue(GuidanceRequest.claimsCurrentConnectionSemantics(frameText: wire))
            var state = GuidanceRequestState()
            XCTAssertTrue(state.begin(request, generation: generation))
            XCTAssertTrue(state.bindSubmission(wire))
            XCTAssertTrue(try state.accepts(XCTUnwrap(update("list"))))
            state.invalidate()
            XCTAssertFalse(try state.accepts(XCTUnwrap(update("list"))))
            XCTAssertNil(state.submissionId)
        }
    }
    func testMalformedCommandsFieldsIdentityAndUnboundedValuesAreRefused() throws {
        let form = try form("edit")
        for values: [String: JSONValue] in [
            ["value": .string(" ")], ["value": .string(String(repeating: "🙂", count: 1025))],
            ["enabled": .string("true")], ["category": .string("Other")], ["injected": .string("x")],
            ["expiry": .string("Set a date")], ["value": .string("bad\0value")],
        ] { XCTAssertNil(form.request(values: values)) }
        XCTAssertNotNil(form.request(values: ["value": .string(String(repeating: "🙂", count: 1024))]))
        XCTAssertNotNil(
            form.request(values: ["expiry": .string("Set a date"), "expiry_date": .string("2027-01-01T00:00:00.123Z")]))
        for mode in ["execute", "delete", "result"] {
            XCTAssertNil(
                GuidanceRequest(
                    action: "chrome_open",
                    payload: .object(["surface": .string("guidance"), "params": .object(["mode": .string(mode)])])))
        }
        var body = try XCTUnwrap(form.request(values: [:])).payload.objectValue!
        body["expected_revision"] = .number(1.5)
        XCTAssertNil(GuidanceRequest(action: "chrome_note_save", payload: .object(body)))
    }
    func testAnyUnknownFrameOrFieldRefusesWholePrivateSurface() throws {
        for change: [String: JSONValue] in [
            ["region": .string("sidebar")], ["region": .null], ["mode": .null],
            ["surface_key": .string("work")], ["mode": .string("mandatory")], ["admin_only": .bool(true)],
            ["request_generation": .null], ["chat_id": .string(generation)], ["speech": .string("private")],
        ] { XCTAssertNil(try update("edit", changes: change)) }
        let form = try form("edit")
        for (key, value): (String, JSONValue) in [
            ("submit_action", .string("chrome_llm_save")), ("actions", .array([])), ("fields", .array([])),
            ("submit_payload", .object(["note_id": .string(generation), "expected_revision": .number(0)])),
        ] {
            var raw = form.component.raw.objectValue!
            raw[key] = value
            XCTAssertNil(GuidanceForm(component: AstralComponent(json: .object(raw))!))
        }
        var raw = form.component.raw.objectValue!
        var fields = raw["fields"]!.arrayValue!
        var category = fields[0].objectValue!
        category["default"] = .string("Other")
        fields[0] = .object(category)
        raw["fields"] = .array(fields)
        XCTAssertNil(GuidanceForm(component: AstralComponent(json: .object(raw))!))
    }
    func testOnlyPendingExactFailureRetiresAndCapabilitiesRemainOptIn() throws {
        let device = DeviceDescriptor.watch(viewportWidth: 198, viewportHeight: 242)
        for supported in [false, true] {
            let wire = Outbound.registerUI(
                token: "synthetic", sessionId: nil, device: device, resumed: false, guidanceNotesSupported: supported)
            XCTAssertEqual(
                try XCTUnwrap(InboundFrame.parse(wire)).payload["capabilities"]!.arrayValue!.contains(
                    .string("guidance_notes_v1")), supported)
        }
        let menu = try JSONValue.parse(
            Data(
                #"{"version":2,"topbar":[{"key":"guidance","kind":"action","label":"Private notes","action":{"surface":"guidance","params":{"mode":"list"}}},{"key":"bad","kind":"action","label":"Bad","action":{"surface":"guidance","params":{"mode":"execute"}}}],"menu":[]}"#
                    .utf8))
        XCTAssertEqual(GuidanceRequest.controls(in: ChromeMenuModel.fromJSON(menu)).map(\.key), ["guidance"])
        XCTAssertTrue(GuidanceRequest.controls(in: nil).isEmpty)
        var state = GuidanceRequestState()
        XCTAssertFalse(state.begin(.list, generation: "bad"))
        XCTAssertFalse(state.bindSubmission("{}"))
        XCTAssertTrue(state.begin(.list, generation: generation))
        XCTAssertTrue(state.bindSubmission(GuidanceRequest.list.frameText(requestGeneration: generation)))
        let submission = try XCTUnwrap(state.submissionId)
        let refusal = InboundFrame.parse(
            """
            {"type":"error","submission_id":"\(submission)","accepted":false,"code":"capacity_exceeded","message":"Try later","retryable":true,"retry_after_ms":null}
            """)!
        XCTAssertTrue(state.matchesFailure(refusal, connectionGeneration: generation))
        var status: [String: JSONValue] = [
            "type": .string("operation_status"), "operation_id": .string(generation), "action": .string("chrome_open"),
            "surface": .string("guidance"), "chat_id": .null, "connection_generation": .string(generation),
            "request_generation": .string(generation), "sequence": .number(1), "state": .string("failed"),
            "phase": .string("failed"), "label": .string("Unavailable"), "terminal": .bool(true),
            "retryable": .bool(false),
            "error": .object(["code": .string("operation_failed"), "message": .string("Unavailable")]),
            "retry_after_ms": .null, "updated_at": .string("2026-09-13T00:00:00Z"),
        ]
        XCTAssertTrue(
            state.matchesFailure(
                InboundFrame(name: "operation_status", payload: .object(status)), connectionGeneration: generation))
        status["surface"] = .string("work")
        XCTAssertFalse(
            state.matchesFailure(
                InboundFrame(name: "operation_status", payload: .object(status)), connectionGeneration: generation))
        XCTAssertFalse(
            state.matchesFailure(InboundFrame(name: "ready", payload: .object([:])), connectionGeneration: generation))
        state.invalidate()
        XCTAssertFalse(state.matchesFailure(refusal, connectionGeneration: generation))
    }

}
