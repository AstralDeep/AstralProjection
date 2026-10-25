// Tests the shared terminal monitor fixture as a correlated generic Apple chrome surface: literal
// sanitized output, read-only actions, and a content-free watch handoff.

import Foundation
import XCTest

@testable import AstralCore

final class TerminalMonitorTests: XCTestCase {
    private func fixture() throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/terminal/monitor_surface.json")))
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

    func testCorrelatedSurfaceHasOnlyReadOnlyActionsAndExactOutput() throws {
        let source = try fixture()
        let frame = try XCTUnwrap(source["native_frame"])
        let components = AstralComponent.list(from: frame["components"])
        var nodes: [AstralComponent] = []
        walk(components, &nodes)
        let actions = nodes.filter { $0.type == "button" }.compactMap { $0.raw["action"]?.stringValue }
        XCTAssertEqual(actions, ["chrome_open", "chrome_open", "chrome_close"])
        XCTAssertTrue(nodes.allSatisfy { !["input", "param_picker"].contains($0.type) })
        let ordinaryCode = try XCTUnwrap(nodes.first { $0.type == "code" })
        XCTAssertEqual(
            ordinaryCode.raw["code"]?.stringValue,
            "$ printf 'hello\\n'\nhello\n$ printf 'done\\n'\ndone\n")
        let malicious = try XCTUnwrap(source["frames"]?["malicious"]?["components"])
        var maliciousNodes: [AstralComponent] = []
        walk(AstralComponent.list(from: malicious), &maliciousNodes)
        let code = try XCTUnwrap(maliciousNodes.first { $0.type == "code" })
        XCTAssertEqual(code.raw["code"]?.stringValue, source["expected_sanitized_text"]?.stringValue)
        XCTAssertFalse(code.raw["code"]?.stringValue?.contains("\u{1b}") ?? true)
        XCTAssertFalse(code.raw["code"]?.stringValue?.contains("evil.example") ?? true)
        XCTAssertFalse(code.raw["code"]?.stringValue?.contains("clipboard theft") ?? true)
        XCTAssertEqual(frame["surface_key"]?.stringValue, "terminal")
        XCTAssertEqual(
            frame["request_generation"]?.stringValue,
            source["request"]?["request_generation"]?.stringValue)
        let accepted = Set(
            try manifest()["accept_actions"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        XCTAssertTrue(accepted.isSuperset(of: actions))
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

    func testContractDeclaresClosedReadOnlyDispositions() throws {
        let document = try manifest()
        let contract = try XCTUnwrap(document["presentation_contracts"]?["terminal_monitor"])
        XCTAssertEqual(contract["surface_key"]?.stringValue, "terminal")
        XCTAssertEqual(
            contract["controls"]?["actions"]?.arrayValue?.compactMap(\.stringValue),
            ["chrome_open", "chrome_close"])
        XCTAssertEqual(contract["dispositions"]?["ios"]?.stringValue, "read_only_monitor")
        XCTAssertEqual(contract["dispositions"]?["macos"]?.stringValue, "read_only_monitor")
        XCTAssertEqual(contract["dispositions"]?["watchos"]?.stringValue, "phone_desktop_handoff")
        XCTAssertEqual(contract["dispositions"]?["voice"]?.stringValue, "omitted_by_server")
    }

    func testTerminalRequestsUseAClosedCurrentConnectionContract() {
        let allowed: [JSONValue] = [
            .object(["mode": .string("list")]),
            .object(["mode": .string("monitor"), "session_id": .string("term_fixture")]),
            .object([
                "mode": .string("monitor"), "session_id": .string("term_fixture"),
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
        let invalid: [JSONValue] = [
            .object([:]), .object(["mode": .string("create")]),
            .object(["mode": .string("list"), "owner_id": .string("foreign")]),
            .object(["mode": .string("monitor")]),
            .object(["mode": .string("monitor"), "session_id": .string("bad\n")]),
            .object(["mode": .string("monitor"), "session_id": .string(String(repeating: "x", count: 65))]),
            .object(["mode": .string("monitor"), "session_id": .string("term"), "offset": .number(-1)]),
            .object(["mode": .string("monitor"), "session_id": .string("term"), "offset": .number(0.5)]),
            .object(["mode": .string("monitor"), "session_id": .string("term"), "offset": .bool(true)]),
            .object(["mode": .string("monitor"), "session_id": .string("term"), "input": .string("whoami")]),
        ]
        for params in invalid {
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
