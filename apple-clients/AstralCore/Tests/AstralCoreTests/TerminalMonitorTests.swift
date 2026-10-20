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
        let malicious = try XCTUnwrap(source["frames"]?["malicious"]?["components"])
        let maliciousNodes = AstralComponent.list(from: malicious)
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
}
