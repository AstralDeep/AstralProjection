// The contact, sharing and shared-with-me calls the contact and share screens depend on, so their models run against MeshRuntime or a test double.
// MeshRuntime conforms by forwarding each call to the Kernel through its normal call path.

import Foundation

@MainActor
protocol MeshContactService: AnyObject {
    var contacts: [MeshContact] { get }
    func refreshContacts() async
    func createContactInvitation(name: String, ttlSeconds: UInt64) async throws -> MeshContactInvitation
    func cancelContactInvitation() async
    func acceptContactInvitation(text: String, name: String) async throws -> MeshContactExchange
    func startContactVerification(mesh: String) async throws -> MeshContactExchange
    func pendingContactExchanges() async throws -> [MeshContactExchange]
    func verifyContact(exchangeId: String) async throws -> MeshContact
    func rejectContactExchange(exchangeId: String) async throws
    func removeContact(mesh: String) async throws
}

@MainActor
protocol MeshShareService: AnyObject {
    var shares: [MeshShareInfo] { get }
    func refreshShares() async
    func proposeShare(chatId: String, contactMesh: String) async throws -> MeshShareProposal
    func approveShare(_ proposal: MeshShareProposal) async throws -> MeshShareInfo
    func revokeShare(_ share: MeshShareInfo) async throws
}

@MainActor
protocol MeshSharedService: AnyObject {
    var sharedItems: [MeshSharedItem] { get }
    func refreshSharedItems() async
    func sharedChat(grant: String) async throws -> MeshChatView
    func refreshShared(grant: String) async throws -> MeshRefreshReport
    func sharedAttachment(grant: String, event: String) async throws -> Data
}

extension MeshRuntime: MeshContactService, MeshShareService, MeshSharedService {}
