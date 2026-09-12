import Foundation
import XCTest

@testable import AstralCore

final class ComponentChromeTests: XCTestCase {
    private func corpus() throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/workspace_088/component_chrome.json")))
    }

    func testSharedActionCorpus() throws {
        for row in try XCTUnwrap(corpus()["actions"]?.arrayValue) {
            let actual = ComponentChromeModel.actions(from: row["metadata"])
            XCTAssertEqual(
                actual.map { $0.kind.rawValue }, row["expected_kinds"]?.arrayValue?.compactMap(\.stringValue),
                row["name"]?.stringValue ?? "")
        }
    }

    func testSharedVersionCorpusRetainsOnlyMetadata() throws {
        for row in try XCTUnwrap(corpus()["versions"]?.arrayValue) {
            let actual = ComponentChromeModel.versions(from: row["versions"]).map { value in
                JSONValue.object([
                    "version_no": .number(Double(value.number)), "reason": .string(value.reason),
                    "created_at": .string(value.createdAt), "title": .string(value.title),
                ])
            }
            XCTAssertEqual(actual, row["expected"]?.arrayValue, row["name"]?.stringValue ?? "")
        }
    }

    func testUnboundOrDecorativeIdentityNeverOffersActions() {
        for fields: [String: JSONValue] in [
            [:], ["id": .string("alias")], ["component_id": .string("")], ["component_id": .string("wel_a")],
            ["component_id": .string("ly_a")], ["component_id": .string("dg_a")],
        ] {
            XCTAssertNil(
                ComponentChromeModel.canonicalIdentity(of: AstralComponent(type: "text", raw: .object(fields))))
        }
        for type in ["divider", "skeleton"] {
            XCTAssertNil(
                ComponentChromeModel.canonicalIdentity(
                    of: AstralComponent(type: type, raw: .object(["component_id": .string("saved")]))))
        }
        XCTAssertEqual(
            ComponentChromeModel.canonicalIdentity(
                of: AstralComponent(
                    type: "text", raw: .object(["component_id": .string("saved"), "id": .string("alias")]))), "saved")
    }

    func testVersionTextIsPlainAndUsesWebTimestampAndEmptyCopy() {
        let value = ComponentVersion(number: 5, reason: "refine", createdAt: "2026-09-12T12:34:56Z", title: "<Earlier>")
        XCTAssertEqual(value.displayTitle, "v5 · <Earlier> · 2026-09-12 12:34")
        XCTAssertEqual(value.restoreHint, "Restore this version (archived on refine)")
        let empty = ComponentVersion(number: 1, reason: "", createdAt: "", title: "")
        XCTAssertEqual(empty.displayTitle, "v1")
        XCTAssertEqual(empty.restoreHint, "Restore this version")
        XCTAssertEqual(
            ComponentChromeModel.emptyHistory, "No earlier versions yet — refine the component to create one.")
        XCTAssertEqual(ComponentChromeModel.versions(from: .object([:])), [])
        XCTAssertEqual(ComponentChromeModel.versions(from: .array([.object(["version_no": .number(.infinity)])])), [])
    }
    func testNullVersionMetadataIsEmptyAndSpacesAreValidDescriptorText() {
        let versions = ComponentChromeModel.versions(
            from: .array([
                .object(["version_no": .number(1), "reason": .null, "created_at": .null, "title": .null])
            ]))
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.displayTitle, "v1")
        XCTAssertEqual(versions.first?.reason, "")
        let actions = ComponentChromeModel.actions(
            from: .object([
                "version": .number(1),
                "actions": .array([
                    .object([
                        "kind": .string("refine"), "context": .string("live_canvas"),
                        "label": .string(" "), "icon": .string(" "), "title": .string(" "),
                    ])
                ]),
            ]))
        XCTAssertEqual(actions.map(\.label), [" "])
    }

}
