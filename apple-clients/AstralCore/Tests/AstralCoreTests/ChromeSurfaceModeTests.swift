// Tests for the chrome_surface mode field: defaults to replace when absent, parses when present, and falls
// back safely for non-string values.

import XCTest

@testable import AstralCore

final class ChromeSurfaceModeTests: XCTestCase {

    private func frame(_ json: String) -> InboundFrame {
        InboundFrame.parse(json)!
    }

    func testMandatoryModeParsesWhenPresent() {
        let f = frame(
            #"{"type":"chrome_surface","surface_key":"llm","title":"Set up your AI provider","components":[],"mode":"mandatory"}"#
        )
        XCTAssertEqual(f.surfaceMode, "mandatory")
    }

    func testModeDefaultsToReplaceWhenAbsent() {
        let f = frame(#"{"type":"chrome_surface","surface_key":"theme","title":"Appearance","components":[]}"#)
        XCTAssertEqual(f.surfaceMode, "replace")
    }

    func testExplicitReplaceParses() {
        let f = frame(#"{"type":"chrome_surface","surface_key":"","components":[],"mode":"replace"}"#)
        XCTAssertEqual(f.surfaceMode, "replace")
    }

    func testNonStringModeFallsBackToReplace() {
        let f = frame(#"{"type":"chrome_surface","surface_key":"llm","components":[],"mode":7}"#)
        XCTAssertEqual(f.surfaceMode, "replace")
    }

    func testEvidenceFixtureDecodesAsAnExistingLiteralSurfaceAtFullPageLimit() throws {
        let root = try ManifestDriftTests.manifestURL().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/evidence/inspection_surface.json")))
        let fields = try XCTUnwrap(fixture["native_frame"]?.objectValue)
        let frame = try XCTUnwrap(InboundFrame.parse(Outbound.encode(.object(fields))))
        XCTAssertEqual(frame.name, "chrome_surface")
        XCTAssertEqual(frame.surfaceMode, "replace")
        XCTAssertEqual(frame.payload["request_generation"], fixture["request"]?["request_generation"])
        let components = AstralComponent.list(from: frame.payload["components"])
        XCTAssertEqual(components.count, fields["components"]?.arrayValue?.count)
        let source = try XCTUnwrap(fixture["source_text"]?.stringValue)
        XCTAssertEqual(components.first { $0.type == "keyvalue" }?.keyValuePairs.first?.1, source)
        let page = String(repeating: "🙂", count: 4096)
        XCTAssertEqual(page.utf8.count, 16_384)
        let payload: JSONValue = .array([
            .object([
                "type": .string("keyvalue"),
                "items": .array([
                    .object(["key": .string("Permitted text"), "value": .string(page)])
                ]),
            ])
        ])
        XCTAssertEqual(AstralComponent.list(from: payload).first?.keyValuePairs.first?.1, page)
    }

    func testEvidenceCurrentConnectionRequestCannotBeQueuedOrRepurposed() throws {
        let root = try ManifestDriftTests.manifestURL().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/evidence/inspection_surface.json")))
        let generation = try XCTUnwrap(fixture["request"]?["request_generation"]?.stringValue)
        let request = try XCTUnwrap(fixture["request"]?["payload"])
        let wire = Outbound.uiEvent(
            action: "chrome_open", sessionId: nil, payload: request, requestGeneration: generation)
        XCTAssertNotNil(ConsoleSurfaceRequest(frameText: wire))
        XCTAssertTrue(ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: wire))
        for payload: JSONValue in [
            .object(["surface": .string("evidence"), "params": .object(["kind": .string("delete")])]),
            .object([
                "surface": .string("evidence"),
                "params": .object(["kind": .string("usage"), "owner_id": .string("foreign")]),
            ]),
        ] {
            let invalid = Outbound.uiEvent(action: "chrome_open", sessionId: nil, payload: payload)
            XCTAssertNil(ConsoleSurfaceRequest(frameText: invalid))
            XCTAssertTrue(ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: invalid))
        }
        XCTAssertFalse(ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: "{}"))
    }

    func testEvidenceReadParametersAreClosedAndExactOpaqueIdentitiesAreBounded() {
        let reference = "obs_" + String(repeating: "a", count: 43)
        let view = "view_" + String(repeating: "a", count: 43)
        let allowed: [JSONValue] = [
            .object([:]), .object(["kind": .string("usage")]), .object(["view_id": .string(view)]),
            .object(["kind": .string("source"), "reference": .string(reference)]),
            .object(["kind": .string("preview"), "reference": .string(reference), "offset": .number(8_388_608)]),
        ]
        for params in allowed {
            let wire = Outbound.uiEvent(
                action: "chrome_open", sessionId: nil,
                payload: .object([
                    "surface": .string("evidence"), "params": params,
                ]))
            XCTAssertNotNil(ConsoleSurfaceRequest(frameText: wire))
            let frame = InboundFrame.parse(wire)!
            XCTAssertEqual(
                Set(frame.payload["payload"]!.objectValue!.keys),
                ["surface", "params", "submission_id", "request_generation"])
            XCTAssertEqual(frame.payload["session_id"], .null)
        }
        var invalid: [JSONValue] = [
            .object(["view_id": .string(view + "\n")]), .object(["view_id": .string("view_bad")]),
            .object(["view_id": .number(3)]), .object(["kind": .string("delete"), "reference": .string(reference)]),
            .object(["kind": .string("source")]), .object(["reference": .string(reference)]),
            .object(["kind": .string("source"), "reference": .number(3)]),
            .object(["kind": .string("source"), "reference": .string(reference + "\n")]),
            .object(["kind": .string("source"), "reference": .string(reference), "owner_id": .string("foreign")]),
        ]
        for offset: JSONValue in [.number(-1), .number(8_388_609), .number(0.5), .bool(true), .string("0"), .null] {
            invalid.append(.object(["kind": .string("source"), "reference": .string(reference), "offset": offset]))
        }
        for params in invalid {
            let wire = Outbound.uiEvent(
                action: "chrome_open", sessionId: nil,
                payload: .object([
                    "surface": .string("evidence"), "params": params,
                ]))
            XCTAssertNil(ConsoleSurfaceRequest(frameText: wire))
            XCTAssertTrue(ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: wire))
        }
        let close = Outbound.uiEvent(
            action: "chrome_close", sessionId: nil, payload: .object(["surface": .string("evidence")]))
        XCTAssertEqual(ConsoleSurfaceRequest(frameText: close)?.action, "chrome_close")
        XCTAssertTrue(ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: close))
        let foreign = Outbound.uiEvent(
            action: "chrome_open", sessionId: "44444444-4444-4444-8444-444444444444",
            payload: .object([
                "surface": .string("evidence"), "params": .object(["kind": .string("usage")]),
            ]))
        XCTAssertNil(ConsoleSurfaceRequest(frameText: foreign))
        XCTAssertNil(ConsoleSurfaceRequest(frameText: String(repeating: "x", count: 16_385)))
    }

    func testOfflineEvidenceRequestIsExplicitlyRefusedByGenericTransport() async throws {
        let client = WSClient(url: URL(string: "ws://127.0.0.1:9/ws")!)
        let events = await client.events()
        let wire = Outbound.uiEvent(
            action: "chrome_open", sessionId: nil,
            payload: .object([
                "surface": .string("evidence"), "params": .object(["kind": .string("usage")]),
            ]))
        await client.send(wire)
        var iterator = events.makeAsyncIterator()
        guard case .sendRejected(let action) = await iterator.next() else {
            return XCTFail("Evidence reads must refuse the generic reconnect queue")
        }
        XCTAssertEqual(action, "chrome_open")
        let sent = await client.sendCurrentChromeEvent(wire) { true }
        XCTAssertFalse(sent)
        await client.stop()
    }
}
