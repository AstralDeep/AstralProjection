// Tests the shared terminal panel fixture as a correlated generic Apple chrome surface: literal
// sanitized output, interactive-panel versus read-only controls, and a content-free watch handoff.

import Foundation
import XCTest

@testable import AstralCore

final class TerminalPanelTests: XCTestCase {
    private func fixture() throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/terminal/panel_surface.json")))
    }

    private func manifest() throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/ui_protocol.json")))
    }

    private func walk(_ components: [AstralComponent], _ found: inout [AstralComponent]) {
        for component in components {
            found.append(component)
            walk(component.children, &found)
        }
    }

    private func actions(_ frame: JSONValue) throws -> [String] {
        var nodes: [AstralComponent] = []
        walk(AstralComponent.list(from: try XCTUnwrap(frame["components"])), &nodes)
        return nodes.compactMap { $0.raw["action"]?.stringValue }
    }

    func testInteractivePanelDeclaresTheGovernedTerminalOperations() throws {
        let source = try fixture()
        let frame = try XCTUnwrap(source["native_frame"])
        let accepted = Set(
            try manifest()["accept_actions"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let allowed: Set<String> = [
            "chrome_open", "chrome_close", "chrome_terminal_input", "chrome_terminal_resize",
            "chrome_terminal_interrupt", "chrome_terminal_close",
        ]
        let used = Set(try actions(frame))
        XCTAssertTrue(used.isSubset(of: allowed))
        XCTAssertTrue(accepted.isSuperset(of: used))
        XCTAssertTrue(used.contains("chrome_terminal_interrupt"))
        XCTAssertTrue(used.contains("chrome_terminal_close"))
        var nodes: [AstralComponent] = []
        walk(AstralComponent.list(from: try XCTUnwrap(frame["components"])), &nodes)
        let forms = nodes.filter { $0.type == "param_picker" }
        XCTAssertEqual(
            Set(forms.compactMap { $0.raw["submit_action"]?.stringValue }),
            Set(["chrome_terminal_input", "chrome_terminal_resize"]))
        for form in forms {
            let payload = try XCTUnwrap(form.raw["submit_payload"])
            XCTAssertEqual(payload["surface"]?.stringValue, "terminal")
            XCTAssertNotNil(payload["session_id"]?.stringValue)
        }
        XCTAssertEqual(frame["surface_key"]?.stringValue, "terminal")
        XCTAssertEqual(
            frame["request_generation"]?.stringValue,
            source["request"]?["request_generation"]?.stringValue)
    }

    func testReadOnlyPanelFramesNeverCarryInteractiveControls() throws {
        let source = try fixture()
        for name in ["list", "panel", "malicious", "closed"] {
            let frame = try XCTUnwrap(source["read_only_frames"]?[name])
            let used = try actions(frame)
            XCTAssertEqual(Set(used), Set(["chrome_open", "chrome_close"]), name)
            var nodes: [AstralComponent] = []
            walk(AstralComponent.list(from: try XCTUnwrap(frame["components"])), &nodes)
            XCTAssertFalse(nodes.contains { $0.type == "param_picker" }, name)
        }
    }

    func testMaliciousOutputIsLiteralSanitizedTextWithoutLinksOrClipboard() throws {
        let source = try fixture()
        let frame = try XCTUnwrap(source["frames"]?["malicious"]?["components"])
        var nodes: [AstralComponent] = []
        walk(AstralComponent.list(from: frame), &nodes)
        let code = try XCTUnwrap(nodes.first { $0.type == "code" })
        XCTAssertEqual(code.raw["code"]?.stringValue, source["expected_sanitized_text"]?.stringValue)
        XCTAssertFalse(code.raw["code"]?.stringValue?.contains("\u{1b}") ?? true)
        XCTAssertFalse(code.raw["code"]?.stringValue?.contains("evil.example") ?? true)
        XCTAssertFalse(code.raw["code"]?.stringValue?.contains("clipboard theft") ?? true)
    }

    func testWatchHandoffContainsNoPrivateSessionOrOutput() throws {
        let source = try fixture()
        let watch = try XCTUnwrap(source["watch_components"]?.arrayValue)
        XCTAssertEqual(Set(watch.compactMap { $0["type"]?.stringValue }), Set(["badge", "alert"]))
        let serialized = watch.compactMap { AstralComponent(json: $0)?.fallbackText }.joined(separator: "\n")
        for value in ["term_01JABCDEF", "ops@staging.example", "/srv/astral/work", "hello"] {
            XCTAssertFalse(serialized.contains(value))
        }
        XCTAssertTrue(serialized.contains("phone or desktop"))
    }

    func testContractDeclaresClosedPanelDispositions() throws {
        let document = try manifest()
        let contract = try XCTUnwrap(document["presentation_contracts"]?["terminal_panel"])
        XCTAssertEqual(contract["surface_key"]?.stringValue, "terminal")
        XCTAssertEqual(
            Set((contract["actions"]?.objectValue ?? [:]).keys),
            Set([
                "chrome_terminal_input", "chrome_terminal_resize",
                "chrome_terminal_interrupt", "chrome_terminal_close",
            ]))
        XCTAssertEqual(contract["dispositions"]?["browser"]?.stringValue, "interactive_panel")
        XCTAssertEqual(contract["dispositions"]?["windows"]?.stringValue, "interactive_panel")
        XCTAssertEqual(contract["dispositions"]?["ios"]?.stringValue, "read_only_monitor")
        XCTAssertEqual(contract["dispositions"]?["macos"]?.stringValue, "read_only_monitor")
        XCTAssertEqual(contract["dispositions"]?["watchos"]?.stringValue, "phone_desktop_handoff")
        XCTAssertEqual(contract["dispositions"]?["voice"]?.stringValue, "omitted_by_server")
        XCTAssertEqual(contract["rote_devices"]?["tablet"]?.stringValue, "read_only_monitor")
        XCTAssertEqual(contract["rote_devices"]?["mobile"]?.stringValue, "read_only_monitor")
    }

    func testTerminalRequestsUseAClosedCurrentConnectionContract() throws {
        let allowed: [JSONValue] = [
            .object(["mode": .string("list")]),
            .object(["mode": .string("panel"), "session_id": .string("term_fixture")]),
            .object([
                "mode": .string("panel"), "session_id": .string("term_fixture"),
                "offset": .number(9_007_199_254_740_991),
            ]),
        ]
        for params in allowed {
            let wire = Outbound.uiEvent(
                action: "chrome_open", sessionId: nil,
                payload: .object(["surface": .string("terminal"), "params": params]))
            XCTAssertNotNil(ConsoleSurfaceRequest(frameText: wire))
            XCTAssertTrue(ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: wire))
        }
        let refused: [JSONValue] = [
            .object(["mode": .string("panel")]),
            .object(["mode": .string("monitor"), "session_id": .string("term_fixture")]),
            .object(["mode": .string("panel"), "session_id": .string("bad id")]),
            .object([
                "mode": .string("panel"), "session_id": .string("term_fixture"),
                "offset": .number(-1),
            ]),
        ]
        for params in refused {
            let wire = Outbound.uiEvent(
                action: "chrome_open", sessionId: nil,
                payload: .object(["surface": .string("terminal"), "params": params]))
            XCTAssertNil(ConsoleSurfaceRequest(frameText: wire))
            XCTAssertTrue(ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: wire))
        }
        let close = Outbound.uiEvent(
            action: "chrome_close", sessionId: nil, payload: .object(["surface": .string("terminal")]))
        XCTAssertNotNil(ConsoleSurfaceRequest(frameText: close))
        XCTAssertTrue(ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: close))
        let foreign = Outbound.uiEvent(
            action: "chrome_open", sessionId: "44444444-4444-4444-8444-444444444444",
            payload: .object(["surface": .string("terminal"), "params": allowed[0]]))
        XCTAssertNil(ConsoleSurfaceRequest(frameText: foreign))
    }

    func testDisconnectedTransportRejectsEveryTerminalReadAndCloseInsteadOfQueueing() async {
        let socket = WSClient(url: URL(string: "ws://127.0.0.1:9/no-socket-started")!)
        let events = await socket.events()
        for _ in 0..<65 {
            let wire = Outbound.uiEvent(
                action: "chrome_open", sessionId: nil,
                payload: .object(["surface": .string("terminal"), "params": .object(["mode": .string("list")])]))
            await socket.send(wire)
            let sent = await socket.sendCurrentChromeEvent(wire) { true }
            XCTAssertFalse(sent)
        }
        await socket.send(
            Outbound.uiEvent(
                action: "chrome_close", sessionId: nil, payload: .object(["surface": .string("terminal")])))
        await socket.stop()
        var rejected: [String] = []
        for await event in events {
            guard case .sendRejected(let action) = event else {
                XCTFail("Terminal events entered the disconnected queue")
                continue
            }
            rejected.append(action)
        }
        XCTAssertEqual(rejected, Array(repeating: "chrome_open", count: 65) + ["chrome_close"])
    }
}
