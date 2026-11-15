// Exercises the native MCP manager through MeshRuntime with a recording kernel, including exact definition approval and separate tool permissions.
// Bearer credentials are passed once and never enter the recorded calls or server list.

import XCTest

@testable import AstralDeep

final class MeshRemoteMCPTests: XCTestCase {
    func testManagerKeepsCredentialsOutOfListingsAndRequiresExactDefinitionApproval() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        try await h.runtime.setRemoteMCPServer(
            MeshRemoteMCPConfig(name: "weather", endpoint: "https://weather.example/mcp", bearer: "private-bearer"))
        let servers = try await h.runtime.remoteMCPServers()
        XCTAssertEqual(servers.map(\.name), ["weather"])
        XCTAssertTrue(servers[0].credentialConfigured)
        XCTAssertFalse(h.kernel.calls.contains { $0.detail.contains("private-bearer") })
        let tool = MeshRemoteMCPTool(
            server: "weather", endpoint: "https://weather.example/mcp", configurationRevision: "reviewed-config",
            name: "lookup", description: "Weather", inputSchemaJSON: "{\"type\":\"object\"}",
            annotationsJSON: "{\"readOnlyHint\":true}", definitionHash: "sha256:original", status: "new")
        h.kernel.setRemoteMCPTools("weather", tools: [tool])
        try await h.runtime.approveRemoteMCPTool(tool)
        let approved = try await h.runtime.refreshRemoteMCPTools("weather")
        XCTAssertEqual(approved[0].status, "approved")
        await h.runtime.refreshTools()
        XCTAssertFalse(h.runtime.isGranted(tool.entry))
        await h.runtime.grant(tool.entry)
        XCTAssertTrue(h.runtime.isGranted(tool.entry))
        XCTAssertEqual(tool.entry.name, "weather__lookup")
        XCTAssertEqual(tool.entry.effect, .outsideEffect)
        let changed = MeshRemoteMCPTool(
            server: "weather", endpoint: "https://weather.example/mcp", configurationRevision: "reviewed-config",
            name: "lookup", description: "Changed weather", inputSchemaJSON: "{}",
            annotationsJSON: "{}", definitionHash: "sha256:changed", status: "changed")
        h.kernel.setRemoteMCPTools("weather", tools: [changed])
        do {
            try await h.runtime.approveRemoteMCPTool(tool)
            XCTFail("A stale hash must be refused")
        } catch {}
        try await h.runtime.approveRemoteMCPTool(changed)
        try await h.runtime.revokeRemoteMCPTool(server: "weather", tool: "lookup")
        let revoked = try await h.runtime.refreshRemoteMCPTools("weather")
        XCTAssertEqual(revoked[0].status, "new")
        try await h.runtime.removeRemoteMCPServer("weather")
        let removed = try await h.runtime.remoteMCPServers()
        XCTAssertTrue(removed.isEmpty)
    }

    func testManagerSurfacesKernelFailures() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        h.kernel.failure = .refused("MCP configuration was refused")
        do {
            _ = try await h.runtime.remoteMCPServers()
            XCTFail("Kernel errors must reach the manager")
        } catch {
            XCTAssertEqual(MeshRuntime.describe(error), "MCP configuration was refused")
        }
    }
}
