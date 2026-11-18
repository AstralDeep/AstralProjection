// State behind sharing a chat: choosing a verified contact, the card drawn from the Kernel's proposal, the PHI row, the shares list and revocation.
// Every line on the card comes from the proposal and the signed share, and an unverified contact or a missing PHI destination leaves no share button.

import Foundation
import Observation

nonisolated struct MeshShareCandidate: Identifiable, Equatable, Sendable {
    let mesh: String
    let name: String
    let fingerprint: String
    let isVerified: Bool
    var id: String { mesh }
    var hint: String? { isVerified ? nil : "Verify this contact before sharing." }

    init(_ contact: MeshContact) {
        mesh = contact.mesh
        name = contact.name
        fingerprint = contact.fingerprint
        isVerified = contact.isVerified
    }
}

nonisolated enum MeshSharePhiRow: Equatable, Sendable {
    case included
    case needsDestination
}

nonisolated struct MeshShareCardFacts: Equatable, Sendable {
    let proposal: MeshShareProposal
    let title: String
    let contactName: String
    let fingerprint: String
    let phiRow: MeshSharePhiRow?
    let refusal: String?
    let isUpgrade: Bool

    init(_ proposal: MeshShareProposal) {
        self.proposal = proposal
        title = proposal.title.isEmpty ? "This chat" : proposal.title
        contactName = proposal.contactName
        fingerprint = ConsentPrompt.fingerprint(proposal.contact)
        isUpgrade = proposal.supersedes != nil
        if proposal.phiNeeded {
            phiRow = proposal.phiDestination ? .included : .needsDestination
        } else {
            phiRow = nil
        }
        if let code = proposal.refusal, code != "share.phi_not_destination" {
            refusal = KernelMapping.failureText(code: code)
        } else {
            refusal = nil
        }
    }

    var canShare: Bool {
        proposal.verified && proposal.refusal == nil && (!proposal.phiNeeded || proposal.phiDestination)
    }

    var offersDestinationCard: Bool { phiRow == .needsDestination && proposal.verified }

    var summary: String {
        isUpgrade ? "Share PHI too" : "They can read this chat. They can't change it."
    }
}

@MainActor
@Observable
final class MeshShareModel {
    enum Phase: Equatable {
        case choosing
        case loading
        case reviewing(MeshShareCardFacts)
        case sharing(MeshShareCardFacts)
        case shared(MeshShareInfo)
        case failed(String)
    }

    private let chatId: String
    private let shares: any MeshShareService
    private let contacts: any MeshContactService
    private(set) var phase: Phase = .choosing
    private(set) var notice: String?
    private var chosen: String?

    init(chatId: String, shares: any MeshShareService, contacts: any MeshContactService) {
        self.chatId = chatId
        self.shares = shares
        self.contacts = contacts
    }

    var candidates: [MeshShareCandidate] { contacts.contacts.map(MeshShareCandidate.init) }

    func load() async { await contacts.refreshContacts() }

    @discardableResult
    func pick(_ candidate: MeshShareCandidate) async -> Bool {
        guard candidate.isVerified else {
            notice = "Verify " + candidate.name + " before sharing."
            return false
        }
        notice = nil
        chosen = candidate.mesh
        await propose(candidate.mesh)
        return true
    }

    func reload() async {
        guard let chosen else { return }
        await propose(chosen)
    }

    func back() {
        phase = .choosing
        chosen = nil
    }

    func share() async {
        guard case .reviewing(let facts) = phase, facts.canShare else { return }
        phase = .sharing(facts)
        do {
            phase = .shared(try await shares.approveShare(facts.proposal))
        } catch {
            phase = .failed(MeshRuntime.describe(error))
        }
    }

    private func propose(_ mesh: String) async {
        phase = .loading
        do {
            phase = .reviewing(MeshShareCardFacts(try await shares.proposeShare(chatId: chatId, contactMesh: mesh)))
        } catch {
            phase = .failed(MeshRuntime.describe(error))
        }
    }
}

nonisolated struct MeshShareRowFacts: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let contactName: String
    let stateLine: String
    let isRevoked: Bool
    let canRevoke: Bool
    let phiLine: String?
    let canSharePhi: Bool
    let revokeNote: String

    init(_ share: MeshShareInfo) {
        id = share.id
        title = share.title.isEmpty ? "A chat" : share.title
        contactName = share.contactName
        isRevoked = share.state == .revoked
        canRevoke = share.state != .revoked
        switch share.state {
        case .inEffect: stateLine = "Shared"
        case .waiting: stateLine = "Waiting for " + (share.contactName.isEmpty ? "them" : share.contactName)
        case .revoked: stateLine = "Revoked"
        }
        if share.phiWithheld {
            phiLine = "PHI is withheld."
        } else if share.phi {
            phiLine = "PHI is included."
        } else {
            phiLine = nil
        }
        canSharePhi = share.phiWithheld && share.state != .revoked
        revokeNote = Self.revokeNote(for: share.contactName)
    }

    static func revokeNote(for name: String) -> String {
        let who = name.isEmpty ? "They" : name
        return "New messages will not reach " + (name.isEmpty ? "them" : name) + ". " + who
            + " may keep what they already have."
    }
}

@MainActor
@Observable
final class MeshSharesModel {
    private let shares: any MeshShareService
    private(set) var problem: String?
    private(set) var confirming: MeshShareInfo?

    init(shares: any MeshShareService) { self.shares = shares }

    var rows: [MeshShareRowFacts] { shares.shares.map(MeshShareRowFacts.init) }

    func load() async { await shares.refreshShares() }

    func askToRevoke(_ id: String) { confirming = shares.shares.first { $0.id == id && $0.state != .revoked } }

    func cancelRevoke() { confirming = nil }

    func confirmRevoke() async {
        guard let share = confirming else { return }
        confirming = nil
        do { try await shares.revokeShare(share) } catch { problem = MeshRuntime.describe(error) }
    }
}

enum MeshShareID {
    static let sheet = "mesh.share.sheet"
    static let list = "mesh.shares.list"
    static let card = "mesh.share.card"
    static let phiRow = "mesh.share.phi"
    static let destination = "mesh.share.phi.destination"
    static let confirm = "mesh.share.confirm"
    static let action = "mesh.chat.share"
    static let revokeNote = "mesh.share.revoke.note"
    static let sharePhi = "mesh.share.phi.share"

    static func candidate(_ mesh: String) -> String { "mesh.share.contact." + mesh }
    static func revoke(_ id: String) -> String { "mesh.share.revoke." + id }
    static func row(_ id: String) -> String { "mesh.share.row." + id }
}
