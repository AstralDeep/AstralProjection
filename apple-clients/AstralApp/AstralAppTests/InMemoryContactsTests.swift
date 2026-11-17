// Verifies the in-memory kernel's contact book and shares follow the real kernel's refusals, states and consent gates, with two kernels completing one exchange.
// Each failure names the kernel code it expects, so a drift from the real codes shows up here.

import XCTest

@testable import AstralDeep

final class InMemoryContactsTests: XCTestCase {
    private func expect(_ code: String, line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(code)", line: line)
        } catch {
            XCTAssertEqual((error as? MeshKernelError)?.code, code, line: line)
        }
    }

    private func chatWithText(_ kernel: InMemoryMeshKernel) throws -> String {
        let id = try kernel.createChat(title: "Notes")
        _ = try kernel.sendMessage(chatId: id, text: "hello", continues: nil)
        return id
    }

    func testBothSidesShowOneTwelveDigitCodeAndStayUnverifiedUntilVerified() async throws {
        let pair = ContactPair.make()
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        XCTAssertTrue(invitation.text.hasPrefix("astral-contact:v1:"))
        XCTAssertTrue(invitation.link.hasPrefix("https://astraldeep.github.io/contact/#"))
        let bobSide = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        let aliceSide = try XCTUnwrap(try pair.alice.pendingContactExchanges().first)
        XCTAssertEqual(bobSide.code, aliceSide.code)
        XCTAssertEqual(bobSide.code.replacingOccurrences(of: " ", with: "").count, 12)
        XCTAssertEqual(bobSide.name, "Alice")
        XCTAssertEqual(aliceSide.name, "Bob")
        XCTAssertEqual(try pair.bob.contacts().first?.state, .unverified)
        XCTAssertTrue(pair.aliceLog.changes.contains(.contactsChanged))
        XCTAssertTrue(pair.bobLog.changes.contains(.contactsChanged))
        let verified = try pair.alice.verifyContact(exchangeId: aliceSide.id)
        XCTAssertTrue(verified.isVerified)
        XCTAssertEqual(try pair.alice.pendingContactExchanges(), [])
        XCTAssertEqual(try pair.bob.contacts().first?.state, .unverified)
    }

    func testInvitationRefusalsUseTheKernelCodes() async throws {
        let pair = ContactPair.make()
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 60)
        await expect("contact.invitation_open") {
            _ = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 60)
        }
        await expect("contact.self") { _ = try await pair.alice.acceptContactInvitation(text: invitation.text, name: "A") }
        await expect("contact.invite_malformed") {
            _ = try await pair.bob.acceptContactInvitation(text: "astral-contact:v2:AAAA", name: "Bob")
        }
        await expect("contact.invite_malformed") { _ = try await pair.bob.acceptContactInvitation(text: "7", name: "Bob") }
        pair.clock.advance(61)
        await expect("contact.invite_expired") {
            _ = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        }
        await expect("contact.invite_lifetime") {
            _ = try await pair.bob.createContactInvitation(name: "Bob", ttlSeconds: 90_000)
        }
    }

    func testCancelledInvitationCannotBeAccepted() async throws {
        let pair = ContactPair.make()
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        pair.alice.cancelContactInvitation()
        await expect("contact.unreachable") {
            _ = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        }
    }

    func testVerifyAsksForPresenceAndADeniedPromptWritesNothing() async throws {
        let pair = ContactPair.make()
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        _ = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        let side = try XCTUnwrap(try pair.alice.pendingContactExchanges().first)
        pair.alice.consentGate = { throw MeshKernelError.consentDenied }
        XCTAssertThrowsError(try pair.alice.verifyContact(exchangeId: side.id))
        XCTAssertEqual(try pair.alice.contacts().first?.state, .unverified)
        XCTAssertEqual(try pair.alice.pendingContactExchanges().count, 1)
        pair.alice.consentGate = {}
        XCTAssertTrue(try pair.alice.verifyContact(exchangeId: side.id).isVerified)
        await expect("contact.exchange_unknown") { _ = try pair.alice.verifyContact(exchangeId: side.id) }
    }

    func testRejectingAnExchangeLeavesTheContactUnverified() async throws {
        let pair = ContactPair.make()
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        _ = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        let side = try XCTUnwrap(try pair.alice.pendingContactExchanges().first)
        try pair.alice.rejectContactExchange(exchangeId: side.id)
        XCTAssertEqual(try pair.alice.pendingContactExchanges(), [])
        XCTAssertEqual(try pair.alice.contacts().first?.state, .unverified)
        let again = try await pair.alice.startContactVerification(mesh: contactMeshId("b"))
        XCTAssertEqual(again.code, side.code)
        await expect("contact.unverified") { _ = try await pair.alice.startContactVerification(mesh: contactMeshId("9")) }
    }

    func testNoticesAndADowngradeAreReported() async throws {
        let pair = ContactPair.make()
        _ = try await pair.verifiedPair()
        let mesh = contactMeshId("b")
        pair.alice.contactBook.seedNotice(mesh: mesh, notice: MeshContactNotice(notice: "device_added", device: "d"))
        XCTAssertEqual(try pair.alice.contacts().first?.notices.map(\.kind), [.deviceAdded])
        pair.alice.contactBook.downgrade(mesh: mesh)
        let contact = try XCTUnwrap(try pair.alice.contacts().first)
        XCTAssertEqual(contact.state, .unverified)
        XCTAssertEqual(contact.reason, "contact.roster_rejected")
        XCTAssertTrue(pair.aliceLog.changes.contains(.sharesChanged))
    }

    func testAnUnverifiedContactCannotBeSharedWith() async throws {
        let pair = ContactPair.make()
        let chat = try chatWithText(pair.alice)
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        _ = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        let proposal = try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b"))
        XCTAssertFalse(proposal.verified)
        XCTAssertEqual(proposal.refusal, "contact.unverified")
        await expect("contact.unverified") { _ = try pair.alice.approveShare(proposal) }
    }

    func testAVerifiedShareReachesTheReaderAndRevocationStopsIt() async throws {
        let pair = ContactPair.make()
        _ = try await pair.verifiedPair()
        let chat = try chatWithText(pair.alice)
        let proposal = try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b"))
        XCTAssertNil(proposal.refusal)
        XCTAssertEqual(proposal.contactName, "Bob")
        let share = try pair.alice.approveShare(proposal)
        XCTAssertEqual(share.state, .inEffect)
        let item = try XCTUnwrap(try pair.bob.sharedWithMe().first)
        XCTAssertEqual(item.state, .ready)
        XCTAssertEqual(item.contactName, "Alice")
        XCTAssertEqual(try pair.bob.sharedChat(grant: item.grant).messages.map(\.text), ["hello"])
        _ = try pair.alice.sendMessage(chatId: chat, text: "later", continues: nil)
        let report = try await pair.bob.refreshShared(grant: item.grant)
        XCTAssertEqual(report.stopped, [])
        XCTAssertEqual(try pair.bob.sharedChat(grant: item.grant).messages.count, 2)
        try pair.alice.revokeShare(id: share.id)
        XCTAssertEqual(try pair.alice.shares(), [])
        let stopped = try XCTUnwrap(try pair.bob.sharedWithMe().first)
        XCTAssertEqual(stopped.state, .stopped)
        await expect("share.grant_unknown") { _ = try pair.bob.sharedChat(grant: item.grant) }
        await expect("share.grant_unknown") { try pair.alice.revokeShare(id: share.id) }
    }

    func testApprovalAsksForPresenceAndTheProposalCannotBeReplayed() async throws {
        let pair = ContactPair.make()
        _ = try await pair.verifiedPair()
        let chat = try chatWithText(pair.alice)
        let proposal = try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b"))
        pair.alice.consentGate = { throw MeshKernelError.consentDenied }
        XCTAssertThrowsError(try pair.alice.approveShare(proposal))
        XCTAssertEqual(try pair.alice.shares(), [])
        pair.alice.consentGate = {}
        await expect("share.proposal_unknown") { _ = try pair.alice.approveShare(proposal) }
        let fresh = try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b"))
        _ = try pair.alice.approveShare(fresh)
        let second = try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b"))
        XCTAssertEqual(second.refusal, "share.exists")
    }

    func testAPhiChatNeedsAnApprovedContactDestinationAndThenUpgradesTheShare() async throws {
        let pair = ContactPair.make()
        _ = try await pair.verifiedPair()
        let chat = try chatWithText(pair.alice)
        pair.alice.markChatHoldsPhi(chat)
        let blocked = try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b"))
        XCTAssertTrue(blocked.phiNeeded)
        XCTAssertFalse(blocked.phiDestination)
        XCTAssertEqual(blocked.refusal, "share.phi_not_destination")
        let destination = try pair.alice.proposeContactPhiDestination(mesh: contactMeshId("b"))
        XCTAssertEqual(destination.kind, .contact)
        XCTAssertTrue(destination.needsApproval)
        try pair.alice.approvePhiDestination(destination)
        let allowed = try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b"))
        XCTAssertNil(allowed.refusal)
        XCTAssertTrue(allowed.phiDestination)
        XCTAssertEqual(try pair.alice.approveShare(allowed).phi, true)
    }

    func testContactPhiDestinationNeedsAVerifiedContact() async throws {
        let pair = ContactPair.make()
        await expect("contact.unverified") { _ = try pair.alice.proposeContactPhiDestination(mesh: contactMeshId("b")) }
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        _ = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        let source = #"{"mesh_id":"\#(contactMeshId("b"))","name":"Bob","source":"contact"}"#
        let proposal = try pair.alice.proposePhiDestination(source: source)
        await expect("phi_destination.contact_unavailable") { try pair.alice.approvePhiDestination(proposal) }
    }

    func testRemovingAContactEndsItsSharesAndItsPhiDestination() async throws {
        let pair = ContactPair.make()
        _ = try await pair.verifiedPair()
        let chat = try chatWithText(pair.alice)
        _ = try pair.alice.approveShare(try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b")))
        try pair.alice.removeContact(mesh: contactMeshId("b"))
        XCTAssertEqual(try pair.alice.contacts(), [])
        XCTAssertEqual(try pair.alice.shares(), [])
        XCTAssertEqual(try pair.bob.sharedWithMe().first?.state, .stopped)
        await expect("contact.unverified") { try pair.alice.removeContact(mesh: contactMeshId("b")) }
    }

    func testAReaderWhoHasNotVerifiedFetchesNothing() async throws {
        let pair = ContactPair.make()
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        let bobSide = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        let aliceSide = try XCTUnwrap(try pair.alice.pendingContactExchanges().first)
        _ = try pair.alice.verifyContact(exchangeId: aliceSide.id)
        let chat = try chatWithText(pair.alice)
        _ = try pair.alice.approveShare(try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b")))
        let item = try XCTUnwrap(try pair.bob.sharedWithMe().first)
        XCTAssertEqual(item.state, .needsVerification)
        await expect("contact.unverified") { _ = try await pair.bob.refreshShared(grant: item.grant) }
        await expect("share.grant_unknown") { _ = try pair.bob.sharedChat(grant: item.grant) }
        await expect("share.grant_unknown") { _ = try await pair.bob.sharedAttachment(grant: item.grant, event: "e") }
        _ = try pair.bob.verifyContact(exchangeId: bobSide.id)
        XCTAssertEqual(try pair.bob.sharedWithMe().first?.state, .ready)
    }
}
