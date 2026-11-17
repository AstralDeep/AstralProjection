// Verifies the in-memory kernel's connection book refuses what the real kernel refuses and moves a connection through its states.
// Each test names the kernel code it expects, so a drift from the real kernel's codes shows up here.

import XCTest

@testable import AstralDeep

final class InMemoryConnectionsTests: XCTestCase {
    private static let search = MeshConnectionTool(name: "search", hash: "sha256:" + String(repeating: "1", count: 64))
    private static let open = "https://open.example/mcp"
    private static let guarded = "https://guarded.example/mcp"

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        func now() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private struct Harness {
        let kernel: InMemoryMeshKernel
        let clock: Clock
        let changes: ChangeLog

        func propose(_ endpoint: String = InMemoryConnectionsTests.open, name: String = "Research", local: Bool = false)
            async throws -> MeshConnectionProposal
        {
            try await kernel.proposeConnection(endpoint: endpoint, name: name, local: local)
        }

        func approve(_ proposal: MeshConnectionProposal, flow: String = "private", tools: [String] = []) throws
            -> MeshConnection
        {
            try kernel.approveConnection(proposal: proposal.proposal, flow: flow, toolNames: tools, clientId: nil)
        }

        func connect(_ endpoint: String, tools: [String] = []) async throws -> MeshConnection {
            try approve(try await propose(endpoint), tools: tools)
        }

        func begin(_ id: String, _ redirect: MeshSignInRedirect = .appLink) async throws -> MeshSignInStart {
            try await kernel.beginConnectionSignIn(id: id, redirect: redirect)
        }

        func complete(_ start: MeshSignInStart, state: String) async throws -> MeshConnectionState {
            let url = start.redirectURI + "?state=" + state
            return try await kernel.completeConnectionSignIn(flow: start.flow, redirectURL: url)
        }
    }

    private func make(hasMesh: Bool = true) -> Harness {
        let clock = Clock()
        let changes = ChangeLog()
        let kernel = InMemoryMeshKernel(listener: changes, hasMesh: hasMesh, clock: { clock.now() })
        kernel.connectionBook.registerServer(Self.open, .init(tools: [Self.search]))
        kernel.connectionBook.registerServer(
            Self.guarded, .init(issuer: "https://issuer.example", scopes: ["read"], tools: [Self.search]))
        return Harness(kernel: kernel, clock: clock, changes: changes)
    }

    private func expect(_ code: String, line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(code)", line: line)
        } catch {
            XCTAssertEqual((error as? MeshKernelError)?.code, code, line: line)
        }
    }

    func testProposalNeedsAMeshAndAValidNameAndEndpoint() async {
        let none = make(hasMesh: false)
        await expect("mesh.not_enrolled") { _ = try await none.propose() }
        let h = make()
        await expect("connection.malformed") { _ = try await h.propose(name: String(repeating: "n", count: 81)) }
        await expect("connection.malformed") { _ = try await h.propose(name: "") }
        await expect("connection.egress_refused") { _ = try await h.propose("http://public.example/mcp") }
        await expect("connection.egress_refused") { _ = try await h.propose("http://127.0.0.1:9/mcp") }
        await expect("connection.malformed") { _ = try await h.propose(Self.open + "?token=1") }
        await expect("net.unreachable") { _ = try await h.propose("https://nowhere.example/mcp") }
    }

    func testAnOpenServerListsToolsAndAGuardedOneDoesNotUntilSignIn() async throws {
        let h = make()
        let open = try await h.propose(Self.open)
        XCTAssertEqual(open.scheme, "none")
        XCTAssertEqual(open.tools, [Self.search])
        let guarded = try await h.propose(Self.guarded)
        XCTAssertEqual(guarded.scheme, "oauth")
        XCTAssertEqual(guarded.issuerHost, "issuer.example")
        XCTAssertTrue(guarded.tools.isEmpty)
        XCTAssertEqual(guarded.egress, ["guarded.example", "issuer.example"])
    }

    func testApprovalRefusesBeforeAnyWriteAndConsumesTheProposalOnce() async throws {
        let h = make()
        let proposal = try await h.propose()
        await expect("connection.tool_unknown") { _ = try h.approve(proposal, tools: ["nope"]) }
        await expect("connection.record_unsupported") { _ = try h.approve(proposal, flow: "open") }
        XCTAssertTrue(try h.kernel.connections().isEmpty)
        let value = try h.approve(proposal, tools: ["search"])
        XCTAssertEqual(value.tools, [Self.search])
        XCTAssertEqual(value.thisDevice.state, "not_signed_in")
        await expect("connection.proposal_unknown") { _ = try h.approve(proposal) }
        XCTAssertEqual(try h.kernel.connections().count, 1)
        XCTAssertTrue(h.changes.changes.contains(.connectionsChanged))
    }

    func testADeniedPresencePromptWritesNothing() async throws {
        let h = make()
        h.kernel.connectionBook.presenceDenied = true
        let proposal = try await h.propose()
        XCTAssertThrowsError(try h.approve(proposal)) { XCTAssertEqual($0 as? MeshKernelError, .consentDenied) }
        XCTAssertTrue(try h.kernel.connections().isEmpty)
    }

    func testANodeCannotApproveAndAProposalExpiresAfterTenMinutes() async throws {
        let h = make()
        let proposal = try await h.propose()
        h.kernel.connectionBook.isNode = true
        await expect("connection.consent_node_device") { _ = try h.approve(proposal) }
        h.kernel.connectionBook.isNode = false
        h.clock.advance(601)
        await expect("connection.proposal_expired") { _ = try h.approve(proposal) }
    }

    func testOnlyEightProposalsAreHeldAndTheOldestIsEvicted() async throws {
        let h = make()
        let first = try await h.propose(name: "n0")
        for index in 1..<9 { _ = try await h.propose(name: "n\(index)") }
        await expect("connection.proposal_unknown") { _ = try h.approve(first) }
    }

    func testARecordChangedAfterReviewIsRefusedAndRemovalDropsEverything() async throws {
        let h = make()
        let created = try await h.connect(Self.open)
        let review = try await h.kernel.reviewConnection(id: created.id)
        XCTAssertEqual(review.replaces, created.id)
        _ = try h.approve(try await h.kernel.reviewConnection(id: created.id))
        await expect("connection.changed") { _ = try h.approve(review) }
        let missing = String(repeating: "0", count: 32)
        await expect("connection.unknown") { _ = try await h.kernel.reviewConnection(id: missing) }
        await expect("connection.malformed") { try h.kernel.removeConnection(id: "not-an-id") }
        await expect("connection.unknown") { try h.kernel.removeConnection(id: missing) }
        try h.kernel.removeConnection(id: created.id)
        XCTAssertTrue(try h.kernel.connections().isEmpty)
    }

    func testSignInFollowsTheLoopbackRulesAndStoresACredentialOnce() async throws {
        let h = make()
        let created = try await h.connect(Self.guarded)
        await expect("connection.redirect_invalid") { _ = try await h.begin(created.id, .loopback(port: 0)) }
        let start = try await h.begin(created.id, .loopback(port: 4000))
        XCTAssertEqual(start.redirectURI, "http://127.0.0.1:4000/callback")
        await expect("oauth.state_mismatch") { _ = try await h.complete(start, state: "x") }
        let elsewhere = "http://127.0.0.1:4001/callback?state=x"
        await expect("connection.redirect_invalid") {
            _ = try await h.kernel.completeConnectionSignIn(flow: start.flow, redirectURL: elsewhere)
        }
        XCTAssertTrue(h.kernel.connectionBook.credentialAccounts.isEmpty)
        let state = try await h.complete(start, state: "state-2")
        XCTAssertEqual(state.state, "signed_in")
        XCTAssertTrue(state.toolsPending)
        XCTAssertEqual(h.kernel.connectionBook.credentialAccounts.count, 1)
        await expect("connection.flow_unknown") { _ = try await h.complete(start, state: "state-2") }
        XCTAssertEqual(try h.kernel.connections().first?.thisDevice.state, "signed_in")
        try h.kernel.removeConnection(id: created.id)
        XCTAssertTrue(h.kernel.connectionBook.credentialAccounts.isEmpty)
    }

    func testSignInRefusalsForKeystoreDeviceCodeOpenServersAndFlowLimits() async throws {
        let h = make()
        let open = try await h.connect(Self.open, tools: ["search"])
        await expect("connection.no_sign_in") { _ = try await h.begin(open.id) }
        let created = try await h.connect(Self.guarded)
        await expect("connection.device_code_unavailable") { _ = try await h.begin(created.id, .deviceCode) }
        h.kernel.connectionBook.hasKeystore = false
        await expect("connection.keystore_unavailable") { _ = try await h.begin(created.id) }
        h.kernel.connectionBook.hasKeystore = true
        for _ in 0..<4 { _ = try await h.begin(created.id) }
        await expect("connection.too_many_flows") { _ = try await h.begin(created.id) }
        h.clock.advance(601)
        let start = try await h.begin(created.id)
        h.clock.advance(601)
        await expect("connection.flow_expired") { _ = try await h.complete(start, state: "state-6") }
        try h.kernel.cancelConnectionSignIn(flow: "never-open")
    }

    func testANodeUsesTheDeviceCodeFlowAndPollsUntilDone() async throws {
        let h = make()
        let created = try await h.connect(Self.guarded)
        h.kernel.connectionBook.isNode = true
        let start = try await h.begin(created.id, .deviceCode)
        XCTAssertNotNil(start.userCode)
        XCTAssertNil(start.authorizationURL)
        await expect("connection.flow_kind") { _ = try await h.complete(start, state: "x") }
        let pending = try await h.kernel.pollConnectionSignIn(flow: start.flow)
        XCTAssertEqual(pending, .pending(intervalSeconds: 5))
        guard case .done(let state) = try await h.kernel.pollConnectionSignIn(flow: start.flow) else {
            return XCTFail("expected done")
        }
        XCTAssertEqual(state.state, "signed_in")
        await expect("connection.flow_unknown") { _ = try await h.kernel.pollConnectionSignIn(flow: start.flow) }
    }

    func testRefreshMovesAConnectionIntoAttentionAndStepUpNeedsAReviewedRecord() async throws {
        let h = make()
        let created = try await h.connect(Self.guarded)
        await expect("connection.not_signed_in") { _ = try await h.kernel.refreshConnection(id: created.id) }
        _ = try await h.complete(try await h.begin(created.id), state: "state-2")
        let refusing = InMemoryConnections.Server(
            issuer: "https://issuer.example", scopes: ["read"], refreshRefused: true)
        h.kernel.connectionBook.registerServer(Self.guarded, refusing)
        let refused = try await h.kernel.refreshConnection(id: created.id)
        XCTAssertEqual(refused.reason, "refresh_refused")
        XCTAssertEqual(try h.kernel.connections().first?.attention, "refresh_refused")
        let plan = try h.kernel.connectionStepUp(id: created.id, challenge: ["write"])
        XCTAssertEqual(plan, .review(scopes: ["read", "write"]))
        await expect("connection.step_up_limit") { _ = try h.kernel.connectionStepUp(id: created.id, challenge: []) }
        await expect("connection.step_up_unreviewed") { _ = try await h.begin(created.id) }
        let review = try await h.kernel.reviewConnection(id: created.id)
        XCTAssertEqual(review.scopes, ["read", "write"])
        _ = try h.approve(review)
        _ = try await h.begin(created.id)
        try h.kernel.noteConnectionCallSucceeded(id: created.id)
        let again = try h.kernel.connectionStepUp(id: created.id, challenge: ["read"])
        XCTAssertEqual(again, .signIn(scopes: ["read", "write"]))
        await expect("connection.unknown") { try h.kernel.noteConnectionCallSucceeded(id: "x") }
    }

    func testOtherDevicesStatesAreListed() async throws {
        let h = make()
        let created = try await h.connect(Self.guarded)
        let other = MeshConnectionDeviceState(
            device: "sha256:" + String(repeating: "e", count: 64), label: "Phone", state: "signed_in", reason: nil,
            issuer: "https://issuer.example", atMs: 4)
        h.kernel.connectionBook.seedDeviceState(created.id, other)
        XCTAssertEqual(try h.kernel.connections().first?.otherDevices, [other])
    }
}
