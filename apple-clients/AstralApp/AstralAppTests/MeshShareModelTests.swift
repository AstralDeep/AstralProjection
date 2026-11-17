// Verifies the share flow: only verified contacts can be picked, the PHI row gates the Share button, and revocation says what it does before it asks.
// The models run against the in-memory kernel pair, so the refusals and states are the ones the real kernel produces.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshShareModelTests: XCTestCase {
    private struct Setup {
        let pair: ContactPair
        let alice: KernelContactService
        let bob: KernelContactService
        let chat: String
    }

    private func setup(verified: Bool = true, phi: Bool = false) async throws -> Setup {
        let pair = ContactPair.make()
        if verified {
            _ = try await pair.verifiedPair()
        } else {
            let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
            _ = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        }
        let chat = try pair.alice.createChat(title: "Notes")
        _ = try pair.alice.sendMessage(chatId: chat, text: "hello", continues: nil)
        if phi { pair.alice.markChatHoldsPhi(chat) }
        let alice = KernelContactService(pair.alice)
        await alice.refreshContacts()
        return Setup(pair: pair, alice: alice, bob: KernelContactService(pair.bob), chat: chat)
    }

    private func model(_ setup: Setup) -> MeshShareModel {
        MeshShareModel(chatId: setup.chat, shares: setup.alice, contacts: setup.alice)
    }

    private func reviewing(_ model: MeshShareModel) throws -> MeshShareCardFacts {
        guard case .reviewing(let facts) = model.phase else {
            XCTFail("expected reviewing, got \(model.phase)")
            throw MeshKernelError.notFound
        }
        return facts
    }

    func testAnUnverifiedContactCannotBePicked() async throws {
        let setup = try await setup(verified: false)
        let shares = model(setup)
        let candidate = try XCTUnwrap(shares.candidates.first)
        XCTAssertFalse(candidate.isVerified)
        XCTAssertEqual(candidate.hint, "Verify this contact before sharing.")
        let picked = await shares.pick(candidate)
        XCTAssertFalse(picked)
        XCTAssertEqual(shares.phase, .choosing)
        XCTAssertEqual(shares.notice, "Verify Bob before sharing.")
        XCTAssertFalse(setup.pair.alice.calls.contains { $0.name == "proposeShare" })
    }

    func testAVerifiedPlainChatShowsTheCardAndSharesAfterThePresencePrompt() async throws {
        let setup = try await setup()
        let shares = model(setup)
        await shares.pick(try XCTUnwrap(shares.candidates.first))
        let facts = try reviewing(shares)
        XCTAssertEqual(facts.title, "Notes")
        XCTAssertEqual(facts.contactName, "Bob")
        XCTAssertNil(facts.phiRow)
        XCTAssertTrue(facts.canShare)
        setup.pair.alice.consentGate = { throw MeshKernelError.consentDenied }
        await shares.share()
        guard case .failed = shares.phase else { return XCTFail("expected failure") }
        XCTAssertEqual(try setup.pair.alice.shares(), [])
        setup.pair.alice.consentGate = {}
        await shares.reload()
        await shares.share()
        guard case .shared(let info) = shares.phase else { return XCTFail("expected shared") }
        XCTAssertEqual(info.state, .inEffect)
        XCTAssertEqual(try setup.pair.bob.sharedWithMe().count, 1)
    }

    func testAPhiChatWithNoDestinationOffersTheDestinationCardAndNoShareButton() async throws {
        let setup = try await setup(phi: true)
        let shares = model(setup)
        await shares.pick(try XCTUnwrap(shares.candidates.first))
        let blocked = try reviewing(shares)
        XCTAssertEqual(blocked.phiRow, .needsDestination)
        XCTAssertTrue(blocked.offersDestinationCard)
        XCTAssertFalse(blocked.canShare)
        XCTAssertNil(blocked.refusal)
        await shares.share()
        XCTAssertFalse(setup.pair.alice.calls.contains { $0.name == "approveShare" })
        let destination = try setup.pair.alice.proposeContactPhiDestination(mesh: blocked.proposal.contact)
        try setup.pair.alice.approvePhiDestination(destination)
        await shares.reload()
        let ready = try reviewing(shares)
        XCTAssertEqual(ready.phiRow, .included)
        XCTAssertTrue(ready.canShare)
        await shares.share()
        guard case .shared(let info) = shares.phase else { return XCTFail("expected shared") }
        XCTAssertTrue(info.phi)
    }

    func testARefusalShowsPlainTextAndNoShareButton() async throws {
        let setup = try await setup()
        let first = model(setup)
        await first.pick(try XCTUnwrap(first.candidates.first))
        await first.share()
        let again = model(setup)
        await again.pick(try XCTUnwrap(again.candidates.first))
        let facts = try reviewing(again)
        XCTAssertEqual(facts.refusal, "This chat is already shared with that contact.")
        XCTAssertFalse(facts.canShare)
    }

    func testTheRevokeCardSaysWhatItDoesBeforeTheTapAndAsksToConfirm() async throws {
        let setup = try await setup()
        let first = model(setup)
        await first.pick(try XCTUnwrap(first.candidates.first))
        await first.share()
        let list = MeshSharesModel(shares: setup.alice)
        await list.load()
        let row = try XCTUnwrap(list.rows.first)
        XCTAssertTrue(row.revokeNote.contains("New messages will not reach Bob."))
        XCTAssertTrue(row.revokeNote.contains("may keep what they already have"))
        XCTAssertTrue(row.canRevoke)
        list.askToRevoke(row.id)
        XCTAssertNotNil(list.confirming)
        XCTAssertFalse(setup.pair.alice.calls.contains { $0.name == "revokeShare" })
        list.cancelRevoke()
        XCTAssertNil(list.confirming)
        XCTAssertEqual(try setup.pair.alice.shares().count, 1)
        list.askToRevoke(row.id)
        await list.confirmRevoke()
        XCTAssertTrue(setup.pair.alice.calls.contains { $0.name == "revokeShare" })
        let revoked = try XCTUnwrap(list.rows.first)
        XCTAssertTrue(revoked.isRevoked)
        XCTAssertEqual(revoked.stateLine, "Revoked")
        XCTAssertFalse(revoked.canRevoke)
        XCTAssertEqual(try setup.pair.bob.sharedWithMe().first?.state, .stopped)
    }

    func testWaitingAndWithheldPhiNoticesRender() {
        let waiting = MeshShareInfo(
            id: "g", chat: "c", title: "Notes", contact: contactMeshId("b"), contactName: "Bob", phi: false,
            phiWithheld: false, state: .waiting)
        XCTAssertEqual(MeshShareRowFacts(waiting).stateLine, "Waiting for Bob")
        let withheld = MeshShareInfo(
            id: "g", chat: "c", title: "Notes", contact: contactMeshId("b"), contactName: "Bob", phi: false,
            phiWithheld: true, state: .inEffect)
        let facts = MeshShareRowFacts(withheld)
        XCTAssertEqual(facts.phiLine, "PHI is withheld.")
        XCTAssertTrue(facts.canSharePhi)
        XCTAssertFalse(MeshShareRowFacts(withheld.revoked()).canSharePhi)
    }

    func testNamesStayPlainTextAndIdentifiersAreStable() {
        let proposal = MeshShareProposal(
            id: "g", chat: contactMeshId("3"), title: "<i>Notes</i>", contact: contactMeshId("b"),
            contactName: "[Bob](https://evil.example)", verified: true, labels: [], phiNeeded: false,
            phiDestination: false, supersedes: nil, refusal: nil)
        let facts = MeshShareCardFacts(proposal)
        XCTAssertEqual(facts.title, "<i>Notes</i>")
        XCTAssertEqual(facts.contactName, "[Bob](https://evil.example)")
        XCTAssertEqual(facts.fingerprint, "bbbb bbbb bbbb bbbb")
        XCTAssertEqual(MeshShareID.confirm, "mesh.share.confirm")
        XCTAssertEqual(MeshShareID.action, "mesh.chat.share")
        XCTAssertEqual(MeshShareID.revoke("x"), "mesh.share.revoke.x")
    }
}
