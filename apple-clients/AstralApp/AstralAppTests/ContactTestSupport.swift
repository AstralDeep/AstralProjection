// Test doubles for the contact screens: a pair of in-memory kernels that complete an exchange through one hub, and a service that forwards to a kernel.
// Mesh ids are built at runtime from a repeated hex digit, so no key-shaped literal is stored.

import XCTest

@testable import AstralDeep

nonisolated func contactMeshId(_ digit: Character) -> String { "sha256:" + String(repeating: String(digit), count: 64) }

nonisolated final class ContactClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = start }

    var now: Date { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

nonisolated struct ContactPair {
    let alice: InMemoryMeshKernel
    let bob: InMemoryMeshKernel
    let aliceLog: ChangeLog
    let bobLog: ChangeLog
    let clock: ContactClock

    static func make() -> ContactPair {
        let hub = InMemoryContactHub()
        let clock = ContactClock()
        let aliceLog = ChangeLog()
        let bobLog = ChangeLog()
        let alice = InMemoryMeshKernel(
            listener: aliceLog, hasMesh: true, meshId: contactMeshId("a"), hub: hub, clock: { clock.now })
        let bob = InMemoryMeshKernel(
            listener: bobLog, hasMesh: true, meshId: contactMeshId("b"), hub: hub, clock: { clock.now })
        return ContactPair(alice: alice, bob: bob, aliceLog: aliceLog, bobLog: bobLog, clock: clock)
    }

    func verifiedPair() async throws -> (alice: MeshContactExchange, bob: MeshContactExchange) {
        let invitation = try await alice.createContactInvitation(name: "Alice", ttlSeconds: 600)
        let bobSide = try await bob.acceptContactInvitation(text: invitation.text, name: "Bob")
        let aliceSide = try XCTUnwrap(try alice.pendingContactExchanges().first)
        _ = try alice.verifyContact(exchangeId: aliceSide.id)
        _ = try bob.verifyContact(exchangeId: bobSide.id)
        return (aliceSide, bobSide)
    }
}

@MainActor
final class KernelContactService: MeshContactService, MeshShareService, MeshSharedService {
    let kernel: InMemoryMeshKernel
    private(set) var contacts: [MeshContact] = []
    private(set) var shares: [MeshShareInfo] = []
    private(set) var sharedItems: [MeshSharedItem] = []
    private var ended: [String: MeshShareInfo] = [:]

    init(_ kernel: InMemoryMeshKernel) { self.kernel = kernel }

    func refreshContacts() async { contacts = (try? kernel.contacts()) ?? [] }

    func refreshShares() async {
        let live = (try? kernel.shares()) ?? []
        let ids = Set(live.map(\.id))
        shares = live + ended.values.filter { !ids.contains($0.id) }
    }

    func refreshSharedItems() async { sharedItems = (try? kernel.sharedWithMe()) ?? [] }

    func createContactInvitation(name: String, ttlSeconds: UInt64) async throws -> MeshContactInvitation {
        try await kernel.createContactInvitation(name: name, ttlSeconds: ttlSeconds)
    }

    func cancelContactInvitation() async { kernel.cancelContactInvitation() }

    func acceptContactInvitation(text: String, name: String) async throws -> MeshContactExchange {
        let exchange = try await kernel.acceptContactInvitation(text: text, name: name)
        await refreshContacts()
        return exchange
    }

    func startContactVerification(mesh: String) async throws -> MeshContactExchange {
        try await kernel.startContactVerification(mesh: mesh)
    }

    func pendingContactExchanges() async throws -> [MeshContactExchange] { try kernel.pendingContactExchanges() }

    func verifyContact(exchangeId: String) async throws -> MeshContact {
        let contact = try kernel.verifyContact(exchangeId: exchangeId)
        await refreshContacts()
        return contact
    }

    func rejectContactExchange(exchangeId: String) async throws {
        try kernel.rejectContactExchange(exchangeId: exchangeId)
    }

    func removeContact(mesh: String) async throws {
        try kernel.removeContact(mesh: mesh)
        await refreshContacts()
    }

    func proposeShare(chatId: String, contactMesh: String) async throws -> MeshShareProposal {
        try kernel.proposeShare(chatId: chatId, contactMesh: contactMesh)
    }

    func approveShare(_ proposal: MeshShareProposal) async throws -> MeshShareInfo {
        let info = try kernel.approveShare(proposal)
        await refreshShares()
        return info
    }

    func revokeShare(_ share: MeshShareInfo) async throws {
        try kernel.revokeShare(id: share.id)
        ended[share.id] = share.revoked()
        await refreshShares()
    }

    func sharedChat(grant: String) async throws -> MeshChatView { try kernel.sharedChat(grant: grant) }

    func refreshShared(grant: String) async throws -> MeshRefreshReport {
        let report = try await kernel.refreshShared(grant: grant)
        await refreshSharedItems()
        return report
    }

    func sharedAttachment(grant: String, event: String) async throws -> Data {
        try await kernel.sharedAttachment(grant: grant, event: event)
    }
}
