// Verifies that agent security notices come only from bounded server-owned fields and remain optional for native peers.

import XCTest

@testable import AstralCore

final class AgentConnectionSecurityTests: XCTestCase {
    private let notice: JSONValue = .object([
        "kind": .string("standard_mcp"), "title": .string("Standard MCP connection"),
        "message": .string("Astral permissions still apply. The provider controls its data handling."),
    ])

    func testTrustedTopLevelNoticeDecodesForAgentAndConsoleCatalog() throws {
        let agent = try XCTUnwrap(Agent(json: .object(["id": .string("remote-mcp-1"), "connection_security": notice])))
        XCTAssertEqual(agent.connectionSecurity?.title, "Standard MCP connection")
        XCTAssertEqual(agent.connectionSecurity?.message, notice["message"]?.stringValue)
        let catalog = try XCTUnwrap(
            ConsoleCatalog(
                json: .object([
                    "categories": .array([]), "scenarios": .array([]),
                    "agents": .array([
                        .object([
                            "id": .string("remote-mcp-1"), "name": .string("Remote MCP"),
                            "description": .string("External tools"), "state": .string("ready"),
                            "owned": .bool(false), "connection_security": notice,
                        ])
                    ]),
                ])))
        XCTAssertEqual(catalog.agents.first?.connectionSecurity, agent.connectionSecurity)
    }

    func testNativePanAtlasAndRemoteMetadataNeverImplyAWarning() throws {
        for payload: JSONValue in [
            .object(["id": .string("panatlas-1"), "url": .string("https://panatlas.net/agent")]),
            .object(["id": .string("legacy"), "metadata": .object(["connection_security": notice])]),
            .object(["id": .string("legacy"), "url": .string("https://example.test/mcp")]),
        ] {
            XCTAssertNil(try XCTUnwrap(Agent(json: payload)).connectionSecurity)
        }
    }

    func testLegacyAgentInitializerKeepsTheNoticeOptional() {
        let agent = Agent(
            id: "panatlas-1", name: "PanAtlas", description: "Native agent", isPublic: true,
            scopes: [:], tools: [], toolDescriptions: [:], permissions: [:], toolScopeMap: [:])
        XCTAssertNil(agent.connectionSecurity)
    }

    func testUnknownMalformedOrUnboundedNoticesAreIgnoredWithoutDroppingTheAgent() throws {
        var invalid: [JSONValue] = [.null, .string("standard_mcp")]
        for (field, value): (String, JSONValue) in [
            ("kind", .string("native_astral")), ("title", .string("")), ("message", .bool(true)),
            ("title", .string(String(repeating: "x", count: 121))),
            ("message", .string(String(repeating: "x", count: 2001))),
            ("message", .string("unsafe\u{0000}text")),
        ] {
            var object = try XCTUnwrap(notice.objectValue)
            object[field] = value
            invalid.append(.object(object))
        }
        for value in invalid {
            XCTAssertNil(
                try XCTUnwrap(
                    Agent(
                        json: .object([
                            "id": .string("remote-mcp-1"), "connection_security": value,
                        ]))
                ).connectionSecurity)
        }
    }
}
