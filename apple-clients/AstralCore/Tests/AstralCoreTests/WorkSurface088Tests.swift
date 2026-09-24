// Tests for the Work surface wire contract: ROTE golden fixture retention, stale-response rejection, closed
// read/close identity validation, malformed-field whole-result refusal, and watch capability opt-in.

import Foundation
import XCTest

@testable import AstralCore

final class WorkSurface088Tests: XCTestCase {
    private let generation = "33333333-3333-4333-8333-333333333333"
    private let next = "44444444-4444-4444-8444-444444444444"
    private let operation = "180cd30b-cc38-432d-8349-1851b0d3ad7e"

    private func fixture() throws -> JSONValue {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/work_088/read_surface.json")))
    }

    private func request(_ mode: String = "list", identity: String? = nil) -> WorkReadRequest {
        var params: [String: JSONValue] = ["mode": .string(mode)]
        if let identity { params[mode == "list" ? "after_id" : "operation_id"] = .string(identity) }
        return WorkReadRequest(payload: .object(["surface": .string("work"), "params": .object(params)]))!
    }

    private func frame(_ name: String = "result", changes: [String: JSONValue] = [:]) throws -> InboundFrame {
        var fields = try fixture()["frames"]![name]!.objectValue!
        fields.merge(changes) { _, new in new }
        return InboundFrame(name: "chrome_surface", payload: .object(fields))
    }

    func testActualROTEGoldenRetainsCompleteMaximumSourceAndPassages() throws {
        let source = try fixture()
        for name in ["list", "detail", "result", "loading", "unavailable", "empty"] {
            let update = try XCTUnwrap(WorkSurfaceUpdate(frame: frame(name)))
            XCTAssertEqual(update.components.count, source["frames"]![name]!["components"]!.arrayValue!.count)
            XCTAssertEqual(update.requestGeneration, generation)
        }
        let result = try XCTUnwrap(WorkSurfaceUpdate(frame: frame()))
        let text = result.components.filter { $0.type == "text" }.compactMap(\.textContent)
        let passages = source["states"]!["result"]!["result"]!["result"]!["content"]!["passages"]!.arrayValue!
        XCTAssertEqual(Array(text[1...8]), passages.compactMap { $0["text"]?.stringValue })
        XCTAssertEqual(text[1].count, 512)
        let card = try XCTUnwrap(result.components.first { $0.type == "card" })
        XCTAssertEqual(card.title, String(repeating: "🙂", count: 128))
        XCTAssertTrue(
            card.children.first!.keyValuePairs.contains {
                $0.1 == "https://example.org/段落/" + String(repeating: "a", count: 1638)
            })
    }

    func testSameSurfaceLateResponseCannotReplaceNewerReadOrClosedView() throws {
        var state = WorkReadState()
        let a = request("detail", identity: operation)
        XCTAssertTrue(state.begin(a, generation: generation))
        let first = try XCTUnwrap(WorkSurfaceUpdate(frame: frame("detail")))
        XCTAssertTrue(state.accepts(first))
        XCTAssertTrue(state.begin(request("result", identity: operation), generation: next))
        XCTAssertFalse(state.accepts(first))
        let second = try XCTUnwrap(WorkSurfaceUpdate(frame: frame(changes: ["request_generation": .string(next)])))
        XCTAssertTrue(state.accepts(second))
        state.invalidate()
        XCTAssertFalse(state.accepts(first))
        XCTAssertFalse(state.accepts(second))
        XCTAssertNil(state.request)
        XCTAssertFalse(state.begin(a, generation: "not-a-generation"))
        XCTAssertNil(state.generation)
    }

    func testClosedReadAndCloseWireIdentitiesNeverBecomeEffectRequests() throws {
        for item in [
            request(), request("list", identity: operation), request("detail", identity: operation),
            request("result", identity: operation),
        ] {
            let text = item.frameText(requestGeneration: generation)
            XCTAssertEqual(WorkReadRequest(frameText: text), item)
            XCTAssertTrue(WorkReadRequest.isCurrentConnectionEvent(text))
            let frame = try XCTUnwrap(InboundFrame.parse(text))
            XCTAssertEqual(frame.payload["session_id"], .null)
            XCTAssertEqual(frame.payload["request_generation"]?.stringValue, generation)
            XCTAssertEqual(frame.payload["payload"]?["request_generation"]?.stringValue, generation)
        }
        let close = Outbound.uiEvent(
            action: "chrome_close", sessionId: nil,
            payload: .object(["surface": .string("work")]), requestGeneration: generation)
        XCTAssertTrue(WorkReadRequest.isCurrentConnectionEvent(close))
        for action in ["work_cancel", "work_submit", "chrome_llm_save", "component_refine", "chrome_close"] {
            let text = Outbound.uiEvent(
                action: action, sessionId: nil,
                payload: .object(["surface": .string("llm")]), requestGeneration: generation)
            XCTAssertFalse(WorkReadRequest.isCurrentConnectionEvent(text))
        }
        XCTAssertFalse(WorkReadRequest.isCurrentConnectionEvent("{}"))
        for text in [request().frameText(requestGeneration: generation), close] {
            var fields = InboundFrame.parse(text)!.payload.objectValue!
            fields["unrecognized"] = .string("private")
            XCTAssertFalse(WorkReadRequest.isCurrentConnectionEvent(Outbound.encode(.object(fields))))
        }
    }

    func testMalformedReadModesAliasesIDsAndExtraFieldsRefuse() {
        let badParams: [JSONValue] = [
            .null, .object([:]), .object(["mode": .string("delete")]),
            .object(["mode": .string("detail")]),
            .object(["mode": .string("list"), "after_id": .string("bad")]),
            .object(["mode": .string("result"), "operation_id": .string(operation.uppercased())]),
            .object(["mode": .string("result"), "operation_id": .number(1)]),
            .object(["mode": .string("list"), "fields": .object([:])]),
        ]
        for params in badParams {
            XCTAssertNil(WorkReadRequest(payload: .object(["surface": .string("work"), "params": params])))
        }
        XCTAssertNil(WorkReadRequest(payload: .null))
        XCTAssertNil(
            WorkReadRequest(
                payload: .object(["surface": .string("llm"), "params": .object(["mode": .string("list")])])))
    }

    func testMissingUnknownAndMalformedSurfaceIdentityNeverPaints() throws {
        for (key, value): (String, JSONValue) in [
            ("request_generation", .null), ("request_generation", .string("bad")),
            ("surface_key", .string("llm")), ("mode", .string("mandatory")), ("mode", .number(7)),
            ("admin_only", .bool(true)), ("admin_only", .string("false")),
            ("region", .string("canvas")), ("title", .number(1)),
            ("chat_id", .string(operation)), ("speech", .object(["text": .string("Speak")])),
        ] {
            XCTAssertNil(WorkSurfaceUpdate(frame: try frame(changes: [key: value])), key)
        }
        var raw = try frame().payload.objectValue!
        raw.removeValue(forKey: "request_generation")
        XCTAssertNil(WorkSurfaceUpdate(frame: InboundFrame(name: "chrome_surface", payload: .object(raw))))
        XCTAssertNil(WorkSurfaceUpdate(frame: InboundFrame(name: "ui_render", payload: try frame().payload)))
    }

    func testOneMalformedPrimitiveOrEffectRefusesTheEntireResult() throws {
        let bad: [JSONValue] = [
            .null, .object(["type": .string("file_download"), "url": .string("https://example.org")]),
            .object(["type": .string("text"), "content": .number(3), "variant": .string("body")]),
            .object([
                "type": .string("text"), "content": .string("x"), "variant": .string("body"),
                "action": .string("delete"),
            ]),
            .object(["type": .string("card"), "title": .string("x"), "variant": .string("default"), "content": .null]),
            .object(["type": .string("keyvalue"), "items": .array([.object(["label": .string("x")])])]),
        ]
        for component in bad {
            var raw = try frame().renderComponents.map(\.raw)
            raw.append(component)
            XCTAssertNil(WorkSurfaceUpdate(frame: try frame(changes: ["components": .array(raw)])))
        }
    }

    func testCompleteSurfaceAndTextBoundsHaveNoSilentPrefixAcceptance() throws {
        let text: JSONValue = .object([
            "type": .string("text"), "content": .string(String(repeating: "x", count: 8193)),
            "variant": .string("body"),
        ])
        XCTAssertNil(WorkSurfaceUpdate(frame: try frame(changes: ["components": .array([text])])))
        let small: JSONValue = .object(["type": .string("text"), "content": .string("x"), "variant": .string("body")])
        XCTAssertNil(
            WorkSurfaceUpdate(frame: try frame(changes: ["components": .array(Array(repeating: small, count: 1025))])))
        var nested = small
        for _ in 0..<10 {
            nested = .object([
                "type": .string("card"), "title": .string(""), "variant": .string("default"),
                "content": .array([nested]),
            ])
        }
        XCTAssertNil(WorkSurfaceUpdate(frame: try frame(changes: ["components": .array([nested])])))
    }

    func testOnlyEnabledButtonsInActualSnapshotCanNavigate() throws {
        let update = try XCTUnwrap(WorkSurfaceUpdate(frame: frame("detail")))
        XCTAssertTrue(update.permits(request("result", identity: operation)))
        XCTAssertFalse(update.permits(request("result", identity: next)))
        let button = update.components.first { $0.type == "button" }!
        var raw = button.raw.objectValue!
        raw["disabled"] = .bool(true)
        let disabled = AstralComponent(json: .object(raw))!
        XCTAssertNil(WorkReadRequest(component: disabled))
        raw["disabled"] = .bool(false)
        raw["local"] = .bool(true)
        XCTAssertNil(WorkReadRequest(component: AstralComponent(json: .object(raw))!))
    }

    func testWatchProjectsExistingDescriptorWithoutInventingNavigation() throws {
        XCTAssertEqual(ClientDispositions.watch.frames["chrome_menu"], .handled)
        XCTAssertEqual(ClientDispositions.watch.frames["chrome_surface"], .handled)
        let menu = try fixture()["menu"]!
        let frame = InboundFrame(name: "chrome_menu", payload: .object(["model": menu]))
        let controls = WorkReadRequest.watchControls(frame: frame)
        XCTAssertEqual(controls.count, 1)
        XCTAssertEqual(controls[0].label, menu["topbar"]?.arrayValue?.first?["label"]?.stringValue)
        XCTAssertEqual(controls[0].action?.surface, "work")
        var bad = menu.objectValue!
        bad["version"] = .number(1e300)
        XCTAssertTrue(
            WorkReadRequest.watchControls(
                frame: InboundFrame(name: "chrome_menu", payload: .object(["model": .object(bad)]))
            ).isEmpty)
        bad = menu.objectValue!
        bad["topbar"] = .array(menu["topbar"]!.arrayValue! + menu["topbar"]!.arrayValue!)
        XCTAssertTrue(WorkReadRequest.watchControls(in: ChromeMenuModel.fromJSON(.object(bad))).isEmpty)
        XCTAssertTrue(WorkReadRequest.watchControls(in: nil).isEmpty)
    }

    func testCapabilityIsExplicitRegistrationOptInNotDeviceOrAuthority() throws {
        let device = DeviceDescriptor.watch(viewportWidth: 198, viewportHeight: 242)
        for supported in [false, true] {
            let text = Outbound.registerUI(
                token: "synthetic", sessionId: nil, device: device, resumed: false,
                workReadSupported: supported)
            let frame = try XCTUnwrap(InboundFrame.parse(text))
            XCTAssertEqual(frame.payload["capabilities"]!.arrayValue!.contains(.string("work_read_v1")), supported)
            XCTAssertNil(frame.payload["device"]?["work_read_v1"])
        }
    }

    func testWorkReadsAndCloseNeverEnterDisconnectedQueueOrCallContext() async {
        let client = WSClient(url: URL(string: "ws://127.0.0.1:9/ws")!)
        let close = Outbound.uiEvent(
            action: "chrome_close", sessionId: nil, payload: .object(["surface": .string("work")]),
            requestGeneration: generation)
        for text in [request().frameText(requestGeneration: generation), close, "{}"] {
            let sent = await client.sendCurrentWorkEvent(text) {
                XCTFail("Disconnected send must refuse before context work")
                return true
            }
            XCTAssertFalse(sent)
        }
        await client.stop()
    }
    func testPrivateSubmissionAndFailureIdentityAreExactAndRetiredTogether() throws {
        let generation = "33333333-3333-4333-8333-333333333333"
        let connection = "44444444-4444-4444-8444-444444444444"
        let request = try XCTUnwrap(
            WorkReadRequest(
                payload: .object([
                    "surface": .string("work"), "params": .object(["mode": .string("list")]),
                ])))
        var state = WorkReadState()
        XCTAssertFalse(state.bindSubmission(frameText: request.frameText(requestGeneration: generation)))
        state.begin(request, generation: generation)
        XCTAssertFalse(state.bindSubmission(frameText: "{}"))
        XCTAssertFalse(state.bindSubmission(frameText: request.frameText(requestGeneration: connection)))
        XCTAssertTrue(state.bindSubmission(frameText: request.frameText(requestGeneration: generation)))
        let submission = try XCTUnwrap(state.submissionId)
        let refused = InboundFrame.parse(
            """
            {"type":"error","submission_id":"\(submission)","accepted":false,
             "code":"capacity_exceeded","message":"Try later","retryable":true,"retry_after_ms":null}
            """)!
        XCTAssertTrue(state.matchesFailure(refused, connectionGeneration: connection))
        var wrong = refused.payload.objectValue!
        wrong["submission_id"] = .string(connection)
        XCTAssertFalse(
            state.matchesFailure(InboundFrame(name: "error", payload: .object(wrong)), connectionGeneration: connection)
        )
        let failed = InboundFrame.parse(
            """
            {"type":"operation_status","operation_id":"\(submission)","action":"chrome_open","surface":"work",
             "chat_id":null,"connection_generation":"\(connection)","request_generation":"\(generation)",
             "sequence":1,"state":"failed","phase":"failed","label":"Unavailable","terminal":true,"retryable":false,
             "error":{"code":"operation_failed","message":"Unavailable"},"retry_after_ms":null,"updated_at":"2026-09-13T00:00:00Z"}
            """)!
        XCTAssertTrue(state.matchesFailure(failed, connectionGeneration: connection))
        XCTAssertFalse(state.matchesFailure(failed, connectionGeneration: generation))
        for (key, value) in [
            ("action", JSONValue.string("work_cancel")), ("surface", .string("theme")),
            ("chat_id", .string(connection)), ("request_generation", .string(connection)),
        ] {
            var fields = failed.payload.objectValue!
            fields[key] = value
            XCTAssertFalse(
                state.matchesFailure(
                    InboundFrame(name: "operation_status", payload: .object(fields)), connectionGeneration: connection))
        }
        var completed = failed.payload.objectValue!
        completed["state"] = .string("completed")
        completed["error"] = .null
        XCTAssertFalse(
            state.matchesFailure(
                InboundFrame(name: "operation_status", payload: .object(completed)), connectionGeneration: connection))
        XCTAssertFalse(
            state.matchesFailure(
                InboundFrame(name: "operation_status", payload: .object([:])), connectionGeneration: connection))
        state.invalidate()
        XCTAssertNil(state.submissionId)
        XCTAssertFalse(state.matchesFailure(refused, connectionGeneration: connection))
        state.begin(request, generation: generation)
        XCTAssertFalse(state.matchesFailure(refused, connectionGeneration: connection))
    }
}
