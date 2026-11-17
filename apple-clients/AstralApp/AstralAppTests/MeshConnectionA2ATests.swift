// Verifies the A2A connection screens' facts: each card state comes from the Kernel's proposal, a sign-in need shows the attention banner and a changed card blocks use until approved.
// It also checks that sign-in routing never offers a device code on Apple and that a pasted key is cleared once handed over.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshConnectionA2ATests: XCTestCase {
    private static let signedURL = "https://agents.example/signed/card.json"
    private static let unsignedURL = "https://agents.example/unsigned/card.json"
    private static let keyedURL = "https://agents.example/keyed/card.json"
    private static let oauthURL = "https://agents.example/oauth/card.json"
    private static let signature = "sha256:" + String(repeating: "d", count: 64)

    private func harness() async -> MeshRuntimeHarness {
        let h = MeshRuntimeHarness()
        await h.runtime.open()
        let book = h.kernel.connectionBook
        book.registerCard(
            Self.signedURL,
            .init(signed: true, signer: Self.signature, interfaceHosts: ["run.agents.example"]))
        book.registerCard(Self.unsignedURL, .init(signed: false))
        book.registerCard(Self.keyedURL, .init(scheme: "key"))
        book.registerCard(
            Self.oauthURL,
            .init(
                signed: true, signer: Self.signature, scheme: "oauth", issuer: "https://login.agents.example",
                scopes: ["ask"], interfaceHosts: ["run.agents.example"]))
        return h
    }

    private func added(_ h: MeshRuntimeHarness, _ url: String, name: String = "Helper") async throws -> MeshConnection {
        let proposal = try await h.runtime.proposeA2AConnection(
            cardURL: url, name: name, key: url == Self.keyedURL ? "fake-" + UUID().uuidString : nil, recipients: nil)
        let tools: [String] = proposal.tools.map(\.name)
        return try await h.runtime.approveConnection(proposal: proposal.proposal, flow: "private", toolNames: tools)
    }

    func testASignedCardShowsItsShortThumbprintAndItsHosts() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let proposal = try await h.runtime.proposeA2AConnection(
            cardURL: Self.oauthURL, name: "Helper", key: nil, recipients: nil)
        let facts = try XCTUnwrap(MeshA2ACardFacts(proposal))
        XCTAssertTrue(facts.signed)
        XCTAssertEqual(facts.signedLine, "Signed by dddddddd")
        XCTAssertEqual(facts.authHosts, ["login.agents.example", "astraldeep.github.io"])
        XCTAssertEqual(facts.interfaceHosts, ["run.agents.example"])
        XCTAssertEqual(facts.schemeLine, "Signs in with its own site")
        let card = MeshConnectionCardFacts(proposal)
        XCTAssertNotNil(card.a2a)
        XCTAssertNil(card.change)
    }

    func testAnUnsignedCardShowsItsWarning() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let proposal = try await h.runtime.proposeA2AConnection(
            cardURL: Self.unsignedURL, name: "Helper", key: nil, recipients: nil)
        let facts = try XCTUnwrap(MeshA2ACardFacts(proposal))
        XCTAssertFalse(facts.signed)
        XCTAssertEqual(facts.signedLine, "Not signed")
        XCTAssertTrue(facts.unsignedWarning.contains("not signed"))
        XCTAssertEqual(facts.schemeLine, "No sign-in")
    }

    func testAMcpProposalHasNoAgentCard() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        h.kernel.connectionBook.registerServer("https://open.example/mcp", .init())
        let proposal = try await h.runtime.proposeConnection(
            endpoint: "https://open.example/mcp", name: "Open", local: false)
        XCTAssertNil(MeshA2ACardFacts(proposal))
        XCTAssertNil(MeshA2AChangeFacts(proposal, previous: nil))
    }

    func testAKeyAgentAsksForTheKeyThenClearsIt() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionA2AModel(service: h.runtime)
        model.cardURL = Self.keyedURL
        await model.propose()
        XCTAssertEqual(model.phase, .needsKey)
        XCTAssertFalse(model.canContinue)
        let secret = "fake-" + UUID().uuidString
        model.key = secret
        XCTAssertTrue(model.canContinue)
        await model.propose()
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(model.key, "")
        XCTAssertEqual(model.review.facts?.a2a?.scheme, "key")
        XCTAssertFalse(h.kernel.calls.contains { $0.detail.contains(secret) })
    }

    func testApprovingAnAgentCreatesAnAgentConnection() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionA2AModel(service: h.runtime)
        model.cardURL = Self.signedURL
        model.name = "Helper"
        await model.propose()
        XCTAssertEqual(model.review.facts?.tools.map(\.name), ["ask_helper"])
        await model.review.approve()
        await h.runtime.settle()
        let created = try XCTUnwrap(h.runtime.connections.first)
        XCTAssertEqual(created.kind, "a2a")
        XCTAssertEqual(created.endpoint, Self.signedURL)
        XCTAssertEqual(MeshConnectionSignInRoute.of(created), .none)
    }

    func testAnUnreachableCardShowsTheKernelsRefusal() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionA2AModel(service: h.runtime)
        model.cardURL = "http://agents.example/card.json"
        await model.propose()
        XCTAssertEqual(model.phase, .entering)
        XCTAssertEqual(model.problem, "Use an https address for the agent card.")
    }

    func testAuthRequiredShowsTheAttentionBanner() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let connection = try await added(h, Self.oauthURL)
        h.kernel.connectionBook.seedDeviceState(
            connection.id,
            MeshConnectionDeviceState(
                device: connection.thisDevice.device, label: "This device", state: "needs_attention",
                reason: "not_signed_in", issuer: nil, atMs: 1))
        await h.runtime.refreshConnections()
        let items = MeshConnectionAttentionFacts.all(h.runtime.connections)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.line, "The agent needs you to sign in or add a key.")
        XCTAssertFalse(items.first?.needsReview ?? true)
    }

    func testAChangedCardBlocksUseUntilItIsApproved() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let connection = try await added(h, Self.signedURL)
        h.kernel.connectionBook.changeCard(Self.signedURL) {
            $0.hash = "sha256:" + String(repeating: "e", count: 64)
            $0.interfaceHosts = ["other.agents.example"]
            $0.signer = "sha256:" + String(repeating: "f", count: 64)
            $0.extendedHash = "sha256:" + String(repeating: "1", count: 64)
        }
        await h.runtime.refreshConnections()
        let blocked = try XCTUnwrap(h.runtime.connections.first)
        let attention = try XCTUnwrap(MeshConnectionAttentionFacts(blocked))
        XCTAssertTrue(attention.needsReview)
        XCTAssertTrue(MeshConnectionRowFacts(blocked).needsReview)
        let model = MeshConnectionAddModel(service: h.runtime)
        await model.review(connection: connection.id)
        let change = try XCTUnwrap(model.facts?.change)
        XCTAssertEqual(change.addedHosts, ["other.agents.example"])
        XCTAssertEqual(change.removedHosts, ["run.agents.example"])
        XCTAssertTrue(change.toolChanged)
        XCTAssertEqual(change.signer, "ffffffff")
        XCTAssertTrue(change.extendedPending)
        XCTAssertEqual(change.blockedLine, "Blocked until you approve.")
        await model.approve()
        await h.runtime.settle()
        XCTAssertNil(MeshConnectionAttentionFacts(try XCTUnwrap(h.runtime.connections.first)))
    }

    func testSignInRoutingFollowsTheSchemeAndNeverUsesADeviceCode() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let oauth = try await added(h, Self.oauthURL, name: "Guarded")
        let keyed = try await added(h, Self.keyedURL, name: "Keyed")
        let open = try await added(h, Self.signedURL, name: "Open")
        XCTAssertEqual(MeshConnectionSignInRoute.of(oauth), .browser)
        XCTAssertEqual(MeshConnectionSignInRoute.of(keyed), .key)
        XCTAssertEqual(MeshConnectionSignInRoute.of(open), .none)
        XCTAssertEqual(MeshConnectionSignInRoute.redirect, .appLink)
    }
}
