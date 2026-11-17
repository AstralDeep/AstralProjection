// Verifies the Connections models map every proposal fact, start with the PHI label off, approve once and keep the legacy list read-only.
// The in-memory kernel stands in for the real one, so each test names the facts or calls it checks.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshConnectionModelTests: XCTestCase {
    private static let search = MeshConnectionTool(name: "search", hash: "sha256:" + String(repeating: "a", count: 64))
    private static let write = MeshConnectionTool(name: "write", hash: "sha256:" + String(repeating: "b", count: 64))
    private static let guarded = "https://guarded.example/mcp"
    private static let open = "https://open.example/mcp"

    private func harness() async -> MeshRuntimeHarness {
        let h = MeshRuntimeHarness()
        await h.runtime.open()
        h.kernel.connectionBook.registerServer(
            Self.guarded,
            .init(issuer: "https://issuer.example", scopes: ["read"]))
        h.kernel.connectionBook.registerServer(Self.open, .init(tools: [Self.search, Self.write]))
        h.kernel.connectionBook.registerServer("http://127.0.0.1:9000/mcp", .init(tools: [Self.search]))
        return h
    }

    func testCardMapsEveryProposalFact() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let proposal = try await h.runtime.proposeConnection(endpoint: Self.open, name: "Research", local: false)
        let facts = MeshConnectionCardFacts(proposal)
        let guardedFacts = MeshConnectionCardFacts(
            try await h.runtime.proposeConnection(endpoint: Self.guarded, name: "Guarded", local: false))
        XCTAssertEqual(guardedFacts.signInHost, "issuer.example")
        XCTAssertEqual(guardedFacts.scopes, ["read"])
        XCTAssertEqual(facts.proposalId, proposal.proposal)
        XCTAssertEqual(facts.name, proposal.name)
        XCTAssertEqual(facts.address, proposal.endpoint)
        XCTAssertEqual(facts.signInHost, proposal.issuerHost)
        XCTAssertEqual(facts.redirectHost, proposal.redirectHost)
        XCTAssertEqual(facts.scopes, proposal.scopes)
        XCTAssertEqual(facts.egress, proposal.egress)
        XCTAssertEqual(facts.tools.map(\.name), proposal.tools.map(\.name))
        XCTAssertEqual(facts.tools.first?.shortHash, "aaaaaaaa")
        XCTAssertFalse(facts.replacesExisting)
    }

    func testPhiSourceStartsOffAndApprovalCallsTheKernelOnce() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionAddModel(service: h.runtime)
        model.endpoint = Self.open
        await model.propose()
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertFalse(model.phiSource)
        XCTAssertEqual(model.selectedTools, ["search", "write"])
        model.selectedTools.remove("write")
        async let first: Void = model.approve()
        async let second: Void = model.approve()
        _ = await (first, second)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "approveConnection" }.count, 1)
        await h.runtime.settle()
        let created = try XCTUnwrap(h.runtime.connections.first)
        XCTAssertEqual(created.flow, "private")
        XCTAssertEqual(created.tools.map(\.name), ["search"])
        XCTAssertEqual(model.phase, .done(connection: created.id))
    }

    func testPhiToggleSendsThePhiLabel() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionAddModel(service: h.runtime)
        model.endpoint = Self.guarded
        await model.propose()
        model.phiSource = true
        await model.approve()
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.connections.first?.flow, "phi")
    }

    func testLocalToggleAppearsOnlyForLoopbackAddresses() {
        let model = MeshConnectionAddModel(service: MeshConnectionServiceStub())
        for address in ["http://127.0.0.1:9000/mcp", "http://localhost/mcp", "http://[::1]:3000/x"] {
            model.endpoint = address
            XCTAssertTrue(model.showsLocalToggle, address)
        }
        for address in ["https://example.com/mcp", "http://192.168.1.5/mcp", "", "localhost"] {
            model.endpoint = address
            XCTAssertFalse(model.showsLocalToggle, address)
        }
    }

    func testLocalFlagIsSentOnlyWhenToggledOnALoopbackAddress() async {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionAddModel(service: h.runtime)
        model.endpoint = "http://127.0.0.1:9000/mcp"
        await model.propose()
        XCTAssertNil(model.facts)
        XCTAssertEqual(model.phase, .entering)
        XCTAssertNotNil(model.problem)
        model.local = true
        await model.propose()
        XCTAssertEqual(model.facts?.isLocal, true)
    }

    func testRefusalShowsPlainTextAndKeepsTheForm() async {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionAddModel(service: h.runtime)
        model.endpoint = "http://example.com/mcp"
        await model.propose()
        XCTAssertEqual(model.phase, .entering)
        XCTAssertEqual(model.problem, KernelMapping.refusal("connection.egress_refused").message)
    }

    func testRowsReadSignedInStatesPerDevice() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let proposal = try await h.runtime.proposeConnection(endpoint: Self.guarded, name: "Research", local: false)
        var connection = try await h.runtime.approveConnection(
            proposal: proposal.proposal, flow: "private", toolNames: [])
        var row = MeshConnectionRowFacts(connection)
        XCTAssertEqual(row.hereLine, "Not signed in here")
        XCTAssertEqual(row.host, "guarded.example")
        XCTAssertNil(row.unavailableLine)
        XCTAssertFalse(row.needsReview)
        let other = MeshConnectionDeviceState(
            device: "d2", label: "Mac", state: "signed_in", reason: nil, issuer: nil, atMs: 1)
        connection = MeshConnectionTestSupport.with(connection, here: "signed_in", others: [other])
        row = MeshConnectionRowFacts(connection)
        XCTAssertEqual(row.hereLine, "Signed in here")
        XCTAssertEqual(row.otherLines, ["Signed in on Mac"])
    }

    func testLegacyServersAreListedWithoutAnyWrite() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        try await h.runtime.setRemoteMCPServer(
            MeshRemoteMCPConfig(name: "weather", endpoint: "https://weather.example/mcp", bearer: "b"))
        let before = h.kernel.calls.count
        let model = MeshLegacyServersModel()
        await model.load(from: h.runtime)
        XCTAssertEqual(model.rows.map(\.name), ["weather"])
        XCTAssertEqual(model.rows.first?.credentialLine, "Credential saved")
        let after = h.kernel.calls.dropFirst(before).map(\.name)
        XCTAssertFalse(after.contains { $0.hasPrefix("set") || $0.hasPrefix("remove") || $0.hasPrefix("approve") })
    }

    func testAccessibilityIdentifiersAreStable() {
        XCTAssertEqual(MeshConnectionID.approve, "mesh.connections.approve")
        XCTAssertEqual(MeshConnectionID.phiSource, "mesh.connections.phi")
        XCTAssertEqual(MeshConnectionID.add, "mesh.connections.add")
        XCTAssertEqual(MeshConnectionID.legacy, "mesh.connections.legacy")
        XCTAssertEqual(MeshConnectionID.row("c1"), "mesh.connections.row.c1")
        XCTAssertEqual(MeshConnectionID.tool("search"), "mesh.connections.tool.search")
        XCTAssertEqual(MeshConnectionID.fact("scopes"), "mesh.connections.card.scopes")
    }
}

@MainActor
private final class MeshConnectionServiceStub: MeshConnectionService {
    func proposeConnection(endpoint: String, name: String, local: Bool) async throws -> MeshConnectionProposal {
        throw MeshKernelError.stopped
    }

    func reviewConnection(id: String) async throws -> MeshConnectionProposal { throw MeshKernelError.stopped }

    func approveConnection(proposal: String, flow: String, toolNames: [String]) async throws -> MeshConnection {
        throw MeshKernelError.stopped
    }

    func currentConnection(id: String) -> MeshConnection? { nil }
}

nonisolated enum MeshConnectionTestSupport {
    static func with(_ base: MeshConnection, here state: String, others: [MeshConnectionDeviceState])
        -> MeshConnection
    {
        MeshConnection(
            id: base.id, server: base.server, name: base.name, kind: base.kind, endpoint: base.endpoint,
            local: base.local, device: base.device, scheme: base.scheme, issuer: base.issuer, scopes: base.scopes,
            clientId: base.clientId, flow: base.flow, egress: base.egress, tools: base.tools,
            approvedBy: base.approvedBy, approvedByRemovedDevice: base.approvedByRemovedDevice,
            unsupported: base.unsupported, supportedHere: base.supportedHere,
            thisDevice: MeshConnectionDeviceState(
                device: base.thisDevice.device, label: base.thisDevice.label, state: state, reason: nil,
                issuer: nil, atMs: 1),
            attention: base.attention, otherDevices: others, pendingTools: base.pendingTools)
    }
}
