// Verifies the reader side of sharing: the From badge, the read only chat, refresh on open, the verify prompt that fetches nothing, and the stopped state.
// The models run against the in-memory kernel pair, so the states and refusals are the ones the real kernel produces.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshSharedModelTests: XCTestCase {
    private struct Setup {
        let pair: ContactPair
        let bob: KernelContactService
        let grant: String
        let share: MeshShareInfo
    }

    private func setup(bobVerifies: Bool = true) async throws -> Setup {
        let pair = ContactPair.make()
        let invitation = try await pair.alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        let bobSide = try await pair.bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        let aliceSide = try XCTUnwrap(try pair.alice.pendingContactExchanges().first)
        _ = try pair.alice.verifyContact(exchangeId: aliceSide.id)
        if bobVerifies { _ = try pair.bob.verifyContact(exchangeId: bobSide.id) }
        let chat = try pair.alice.createChat(title: "Notes")
        _ = try pair.alice.sendMessage(chatId: chat, text: "hello", continues: nil)
        let proposal = try pair.alice.proposeShare(chatId: chat, contactMesh: contactMeshId("b"))
        let share = try pair.alice.approveShare(proposal)
        let bob = KernelContactService(pair.bob)
        await bob.refreshSharedItems()
        let grant = try XCTUnwrap(bob.sharedItems.first).grant
        return Setup(pair: pair, bob: bob, grant: grant, share: share)
    }

    func testOpeningRefreshesThenReadsAndNeverActs() async throws {
        let setup = try await setup()
        let model = MeshSharedChatModel(item: try XCTUnwrap(setup.bob.sharedItems.first), service: setup.bob)
        await model.open()
        guard case .ready(let view) = model.phase else { return XCTFail("expected ready") }
        XCTAssertEqual(view.messages.map(\.text), ["hello"])
        let names = setup.pair.bob.calls.map(\.name)
        XCTAssertTrue(names.contains("refreshShared"))
        XCTAssertTrue(names.contains("sharedChat"))
        XCTAssertLessThan(
            try XCTUnwrap(names.firstIndex(of: "refreshShared")), try XCTUnwrap(names.firstIndex(of: "sharedChat")))
        for forbidden in ["act", "sendMessage", "createChat", "runTurn", "steer"] {
            XCTAssertFalse(names.contains(forbidden), forbidden)
        }
    }

    func testTheBadgeShowsTheContactNameAsPlainTextAndTheirVerifiedState() async throws {
        let ready = try await setup()
        let item = try XCTUnwrap(ready.bob.sharedItems.first)
        let badge = MeshSharedBadgeFacts(item)
        XCTAssertEqual(badge.text, "From Alice")
        XCTAssertTrue(badge.isVerified)
        XCTAssertEqual(badge.stateLine, "Verified")
        let tricky = MeshSharedItem(
            grant: "g", contact: contactMeshId("a"), contactName: "[Alice](https://evil.example) <b>", chat: "c",
            title: "t", phi: false, withheldPhi: 0, withheldFields: 0, withheldKeys: 0, state: .needsVerification,
            events: 0, updatedAt: Date())
        let other = MeshSharedBadgeFacts(tricky)
        XCTAssertEqual(other.text, "From [Alice](https://evil.example) <b>")
        XCTAssertFalse(other.isVerified)
        XCTAssertEqual(other.stateLine, "Not verified")
    }

    func testAGrantFromAnUnverifiedContactShowsTheVerifyPromptAndFetchesNothing() async throws {
        let setup = try await setup(bobVerifies: false)
        let item = try XCTUnwrap(setup.bob.sharedItems.first)
        XCTAssertEqual(item.state, .needsVerification)
        let model = MeshSharedChatModel(item: item, service: setup.bob)
        XCTAssertEqual(model.phase, .needsVerification)
        await model.open()
        XCTAssertEqual(model.phase, .needsVerification)
        let fetched = await model.attachment(
            MeshAttachment(
                id: "e", handle: "h", chatId: "c", name: "f", mime: "text/plain", size: 1, chunks: 1, chunksHeld: 0,
                complete: false, availability: .absent))
        XCTAssertNil(fetched)
        let names = setup.pair.bob.calls.map(\.name)
        for forbidden in ["refreshShared", "sharedChat", "sharedAttachment", "refreshContactShares"] {
            XCTAssertFalse(names.contains(forbidden), forbidden)
        }
        let row = MeshSharedRowFacts(item)
        XCTAssertEqual(row.stateLine, "Verify Alice to read this.")
        XCTAssertTrue(row.canOpen)
    }

    func testARevokedItemShowsTheStoppedStateAndItsContentIsGone() async throws {
        let setup = try await setup()
        let model = MeshSharedChatModel(item: try XCTUnwrap(setup.bob.sharedItems.first), service: setup.bob)
        await model.open()
        guard case .ready = model.phase else { return XCTFail("expected ready") }
        try setup.pair.alice.revokeShare(id: setup.share.id)
        await model.open()
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.item.state, .stopped)
        let again = MeshSharedChatModel(item: try XCTUnwrap(setup.bob.sharedItems.first), service: setup.bob)
        XCTAssertEqual(again.phase, .stopped)
        await again.open()
        XCTAssertEqual(again.phase, .stopped)
        XCTAssertThrowsError(try setup.pair.bob.sharedChat(grant: setup.grant))
        let row = MeshSharedRowFacts(model.item)
        XCTAssertEqual(row.stateLine, "No longer shared")
        XCTAssertFalse(row.canOpen)
    }

    func testAttachmentsAreFetchedOnlyWhenAskedFor() async throws {
        let setup = try await setup()
        setup.pair.bob.contactBook.seedAttachment(grant: setup.grant, event: "e1", bytes: Data([1, 2, 3]))
        let model = MeshSharedChatModel(item: try XCTUnwrap(setup.bob.sharedItems.first), service: setup.bob)
        await model.open()
        XCTAssertFalse(setup.pair.bob.calls.contains { $0.name == "sharedAttachment" })
        let attachment = MeshAttachment(
            id: "e1", handle: "h", chatId: "c", name: "f.txt", mime: "text/plain", size: 3, chunks: 1, chunksHeld: 0,
            complete: false, availability: .absent)
        let bytes = await model.attachment(attachment)
        XCTAssertEqual(bytes, Data([1, 2, 3]))
        XCTAssertTrue(setup.pair.bob.calls.contains { $0.name == "sharedAttachment" })
    }

    func testWithheldContentIsNamedAndOwnChatListIsUntouchedWhenNothingIsShared() async throws {
        let item = MeshSharedItem(
            grant: "g", contact: contactMeshId("a"), contactName: "Alice", chat: "c", title: "Notes", phi: false,
            withheldPhi: 1, withheldFields: 0, withheldKeys: 0, state: .ready, events: 2, updatedAt: Date())
        XCTAssertEqual(MeshSharedRowFacts(item).withheldLine, "Some of this chat is not shared.")
        let model = MeshSharedChatModel(item: item, service: KernelContactService(ContactPair.make().bob))
        XCTAssertEqual(model.withheldNotice, "Some of this chat is not shared.")
        let harness = MeshRuntimeHarness()
        defer { harness.cleanUp() }
        await harness.runtime.open()
        XCTAssertEqual(harness.runtime.sharedItems, [])
        XCTAssertFalse(harness.kernel.calls.contains { $0.name == "sharedWithMe" })
        await harness.runtime.refreshSharedItems()
        XCTAssertEqual(harness.runtime.sharedItems, [])
    }

    func testIdentifiersAreStable() {
        XCTAssertEqual(MeshSharedID.entry, "mesh.chats.shared")
        XCTAssertEqual(MeshSharedID.badge, "mesh.shared.badge")
        XCTAssertEqual(MeshSharedID.verify, "mesh.shared.verify")
        XCTAssertEqual(MeshSharedID.row("g"), "mesh.shared.row.g")
        XCTAssertEqual(MeshSharedCopy.readOnly, "You can read this chat. You cannot reply to it.")
    }
}
