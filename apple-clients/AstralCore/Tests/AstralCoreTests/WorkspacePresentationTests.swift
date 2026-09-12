import XCTest

@testable import AstralCore

final class WorkspacePresentationTests: XCTestCase {
    private func fixture() throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/workspace_088/welcome.json")))
    }

    func testSharedFixturePlacementPreservesServerComponentsAndRejectsResultMarkers() throws {
        let fixture = try fixture()
        let components = AstralComponent.list(from: fixture["components"])
        XCTAssertEqual(
            components.compactMap { WorkspaceWelcome.role(of: $0)?.rawValue },
            fixture["expected_roles"]?.arrayValue?.compactMap(\.stringValue))
        XCTAssertFalse(WorkspaceWelcome.containsWork(components))
        for role in WorkspaceWelcome.Role.allCases {
            let source = components.first { WorkspaceWelcome.role(of: $0) == role }!
            XCTAssertEqual(WorkspaceWelcome.components(components, for: role), [source])
            var legacy = source.raw.objectValue!
            legacy.removeValue(forKey: "id")
            legacy.removeValue(forKey: "component_id")
            XCTAssertEqual(WorkspaceWelcome.role(of: AstralComponent(json: .object(legacy))!), role)
        }
        let real = [AstralComponent(json: fixture["result"]!)!, AstralComponent(json: fixture["nested_result"]!)!]
        XCTAssertTrue(WorkspaceWelcome.containsWork(real))
        XCTAssertEqual(WorkspaceWelcome.workComponents(components + real), real)
        XCTAssertEqual(WorkspaceWelcome.components(real, for: .intro), [])
    }

    func testEmptyMalformedAndOrdinaryIdentitiesDoNotQualifyAsLegacyWelcome() {
        for key in ["id", "component_id"] {
            for identity in [JSONValue.string(""), .number(1), .null, .string("real_result")] {
                let raw: JSONValue = .object([
                    "type": .string("button"), "data-welcome": .string("intro"), key: identity,
                ])
                XCTAssertNil(WorkspaceWelcome.role(of: AstralComponent(json: raw)!))
                var example = raw.objectValue!
                example["data-welcome"] = .string("example")
                example["action"] = .string("chat_message")
                example["payload"] = .object(["message": .string("Read this")])
                XCTAssertNil(WorkspaceWelcome.chatMessage(of: AstralComponent(json: .object(example))!))
            }
        }
    }

    func testManifestKeepsStartOrderingAndOwnerScopedDraftContract() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let manifest = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("contracts/ui_protocol.json")))
        let contract = try XCTUnwrap(manifest["presentation_contracts"]?["workspace_088"])
        XCTAssertEqual(
            contract["welcome_roles"]?.arrayValue?.compactMap(\.stringValue),
            WorkspaceWelcome.Role.allCases.map(\.rawValue))
        XCTAssertEqual(
            contract["start_order"]?.arrayValue?.compactMap(\.stringValue),
            ["intro", "permission", "composer", "examples", "more"])
        XCTAssertEqual(contract["draft_lifetime"]?["storage"]?.stringValue, "ephemeral_owner_memory")
        XCTAssertEqual(contract["layout"]?["stacked_below"]?.numberValue, 700)
        XCTAssertEqual(contract["layout"]?["split_from"]?.numberValue, 1024)
        XCTAssertEqual(contract["welcome_identity_prefix"]?.stringValue, "wel_")
        XCTAssertEqual(contract["background_field"]?.stringValue, "async_mode")
    }

    func testRepeatedWelcomeRoleUsesLatestWithoutExtractingChildren() {
        let first = AstralComponent(json: .object(["type": .string("hero"), "data-welcome": .string("intro")]))!
        let latest = AstralComponent(
            json: .object(["type": .string("text"), "content": .string("New"), "data-welcome": .string("intro")]))!
        XCTAssertEqual(WorkspaceWelcome.components([first, latest], for: .intro), [latest])
        XCTAssertNil(WorkspaceWelcome.role(of: AstralComponent(type: "text", raw: .object([:]))))
    }

    func testWatchExamplesUseOnlyValidatedOrdinaryChatActions() throws {
        let fixture = try fixture()
        let components = AstralComponent.list(from: fixture["components"])
        let examples = components.filter { [.examples, .more].contains(WorkspaceWelcome.role(of: $0)) }.flatMap(
            \.children)
        XCTAssertEqual(examples.count, 6)
        for example in examples {
            XCTAssertEqual(WorkspaceWelcome.chatMessage(of: example), example.raw["payload"]?["message"]?.stringValue)
        }
        let valid = examples[0].raw.objectValue!
        let replacements: [[String: JSONValue]] = [
            ["action": .string("effect_approve")], ["component_id": .string("real_result")],
            ["data-welcome": .string("intro")], ["disabled": .bool(true)], ["enabled": .bool(false)],
            ["payload": .object(["message": .string(" \n ")])], ["type": .string("text")],
        ]
        for replacement in replacements {
            let invalid = valid.merging(replacement, uniquingKeysWith: { _, new in new })
            XCTAssertNil(WorkspaceWelcome.chatMessage(of: AstralComponent(json: .object(invalid))!))
        }
        XCTAssertTrue(ClientDispositions.watch.nativeComponentTypes.contains("button"))
    }

    func testOnlyCompleteUnscopedWelcomeFramesQualify() throws {
        let components = try fixture()["components"]!
        let valid: [String: JSONValue] = [
            "type": .string("ui_render"), "target": .string("canvas"), "components": components,
        ]
        for name in ["ui_render", "ui_update"] {
            var payload = valid
            payload["type"] = .string(name)
            let frame = InboundFrame(name: name, payload: .object(payload))
            XCTAssertEqual(WorkspaceWelcome.unscopedComponents(in: frame), frame.renderComponents)
            payload.removeValue(forKey: "target")
            XCTAssertNotNil(
                WorkspaceWelcome.unscopedComponents(in: InboundFrame(name: name, payload: .object(payload))))
        }
        var invalidPayloads: [[String: JSONValue]] = []
        for key in [
            "chat_id", "chatId", "connection_generation", "request_generation", "base_render_revision",
            "frame_sequence",
        ] {
            for value in [JSONValue.null, .string("22222222-2222-4222-8222-222222222222"), .number(0)] {
                invalidPayloads.append(valid.merging([key: value], uniquingKeysWith: { _, new in new }))
            }
        }
        for target in [JSONValue.null, .string("chat"), .string("history"), .number(1)] {
            invalidPayloads.append(valid.merging(["target": target], uniquingKeysWith: { _, new in new }))
        }
        let real = try fixture()["result"]!
        for invalidComponents in [
            JSONValue.array([]), .null, .array(components.arrayValue! + [real]),
            .array(components.arrayValue! + [.null]),
        ] {
            invalidPayloads.append(
                valid.merging(["components": invalidComponents], uniquingKeysWith: { _, new in new }))
        }
        for payload in invalidPayloads {
            XCTAssertNil(
                WorkspaceWelcome.unscopedComponents(in: InboundFrame(name: "ui_render", payload: .object(payload))))
        }
        XCTAssertNil(WorkspaceWelcome.unscopedComponents(in: InboundFrame(name: "ui_append", payload: .object(valid))))
    }

    func testLayoutMatchesWidthBoundsAndExplicitRailPreference() {
        XCTAssertEqual(WorkspaceLayout.forWidth(699, preference: "open"), .stacked)
        XCTAssertEqual(WorkspaceLayout.forWidth(700, preference: "open"), .collapsed)
        XCTAssertEqual(WorkspaceLayout.forWidth(1023, preference: ""), .collapsed)
        XCTAssertEqual(WorkspaceLayout.forWidth(1024, preference: ""), .split)
        XCTAssertEqual(WorkspaceLayout.forWidth(1440, preference: "closed"), .collapsed)
        XCTAssertEqual(WorkspaceLayout.forWidth(1440, preference: "open"), .split)
    }
}
