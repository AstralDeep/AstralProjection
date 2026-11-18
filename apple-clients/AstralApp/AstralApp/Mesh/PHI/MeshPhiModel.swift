// State and facts behind the PHI cards: every line on a card comes from a Kernel proposal or the Kernel's group view, never from chat text.
// MeshPhiDestinationCard, MeshPhiAdoptionCard and MeshPhiDestinationsView read these types, and MeshRuntime performs the calls.

import Foundation
import Observation

nonisolated enum MeshPhiDestinationRequest: Equatable, Hashable, Sendable {
    case provider(name: String)
    case legacyServer(name: String)
    case connection(id: String, usage: String)
    case source(String)
    case contact(mesh: String)
}

nonisolated enum MeshPhiOffer: Equatable, Hashable, Sendable, Identifiable {
    case adoption
    case destination(MeshPhiDestinationRequest)
    case destinations

    var id: String {
        switch self {
        case .adoption: return "adoption"
        case .destination(let request): return "destination." + String(describing: request)
        case .destinations: return "destinations"
        }
    }

    var buttonTitle: String {
        switch self {
        case .adoption: return "Set up PHI"
        case .destination, .destinations: return "Approve where PHI may go"
        }
    }

    static func offer(forCode code: String, defaultProvider: String?, chatHoldsPhi: Bool = false) -> MeshPhiOffer? {
        switch code {
        case "phi.group_not_ready", "phi.device_excluded": return .adoption
        case "provider.no_candidate" where !chatHoldsPhi: return nil
        case "flow.phi_to_model", "provider.no_candidate":
            guard let defaultProvider else { return .destinations }
            return .destination(.provider(name: defaultProvider))
        case "flow.phi_to_service": return .destinations
        default: return nil
        }
    }
}

@MainActor
protocol MeshPhiService: AnyObject {
    func phiDestinations() async throws -> MeshPhiDestinations
    func adoptPhiGroup() async throws -> MeshPhiGroup
    func includePhiDevice(deviceId: String) async throws -> MeshPhiGroup
    func excludePhiDevice(deviceId: String) async throws -> MeshPhiGroup
    func phiProposal(for request: MeshPhiDestinationRequest) async throws -> MeshPhiProposal
    func approvePhiDestination(_ proposal: MeshPhiProposal) async throws
    func revokePhiDestination(subject: String) async throws
}

extension MeshRuntime: MeshPhiService {}

nonisolated enum MeshPhiCopy {
    static func line(_ fact: MeshPhiFact) -> String {
        switch fact {
        case .notOwnerRun: return "You do not run this."
        case .leavesDevices: return "PHI will leave your devices."
        case .unseenHandling: return "Astral can't see what it does with it."
        }
    }

    static let exclusionNote = "Data already on that device stays there. It gets no new PHI."
    static let notUpgradedLine = "Joins after its next update."

    static func approvals(_ count: Int) -> String {
        switch count {
        case 0: return "No approvals"
        case 1: return "1 approval"
        default: return "\(count) approvals"
        }
    }

    static func endpoint(of target: String) -> String {
        guard target.hasPrefix("local:"), let start = target.range(of: ":http") else { return target }
        return String(target[target.index(after: start.lowerBound)...])
    }
}

nonisolated struct MeshPhiCardFacts: Equatable, Sendable {
    let name: String
    let kindLine: String
    let endpoint: String
    let onThisDeviceOnly: Bool
    let lines: [String]
    let needsApproval: Bool
    let proposal: MeshPhiProposal

    init(_ proposal: MeshPhiProposal) {
        self.proposal = proposal
        name = proposal.name
        switch proposal.kind {
        case .model: kindLine = "Model"
        case .service: kindLine = "Service"
        case .contact: kindLine = "Contact"
        }
        endpoint = MeshPhiCopy.endpoint(of: proposal.target)
        onThisDeviceOnly = proposal.target.hasPrefix("local:")
        lines = proposal.facts.map(MeshPhiCopy.line)
        needsApproval = proposal.needsApproval
    }
}

@MainActor
@Observable
final class MeshPhiDestinationModel {
    enum Phase: Equatable {
        case loading
        case reviewing
        case approving
        case approved
        case notNeeded
        case failed
    }

    private let service: any MeshPhiService
    private(set) var phase: Phase = .loading
    private(set) var facts: MeshPhiCardFacts?
    private(set) var problem: String?
    private(set) var problemCode: String?

    init(service: any MeshPhiService) { self.service = service }

    var canApprove: Bool { phase == .reviewing && facts?.needsApproval == true }

    var offersAdoption: Bool { problemCode == "phi.group_not_ready" || problemCode == "phi.device_excluded" }

    func load(_ request: MeshPhiDestinationRequest) async {
        phase = .loading
        problem = nil
        problemCode = nil
        do {
            let proposal = try await service.phiProposal(for: request)
            facts = MeshPhiCardFacts(proposal)
            phase = proposal.needsApproval ? .reviewing : .notNeeded
        } catch {
            fail(error)
        }
    }

    func approve() async {
        guard canApprove, let facts else { return }
        phase = .approving
        problem = nil
        problemCode = nil
        do {
            try await service.approvePhiDestination(facts.proposal)
            phase = .approved
        } catch {
            fail(error, retry: true)
        }
    }

    private func fail(_ error: Error, retry: Bool = false) {
        problem = MeshRuntime.describe(error)
        problemCode = (error as? MeshKernelError)?.code
        phase = retry && facts != nil ? .reviewing : .failed
    }
}

nonisolated struct MeshPhiDeviceRowFacts: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let icon: String
    let stateLine: String
    let approvalsLine: String
    let canExclude: Bool
    let canInclude: Bool
    let isThisDevice: Bool

    init(member: MeshPhiMember, approvals: Int) {
        id = member.deviceId
        label = member.label
        icon = MeshPresentation.icon(member.kind)
        isThisDevice = member.isThisDevice
        approvalsLine = MeshPhiCopy.approvals(approvals)
        canExclude = member.state == .included
        canInclude = member.state == .excluded
        switch member.state {
        case .included: stateLine = "In the PHI group"
        case .excluded: stateLine = "Excluded. " + MeshPhiCopy.exclusionNote
        case .notUpgraded: stateLine = MeshPhiCopy.notUpgradedLine
        case .notApproved: stateLine = "Waiting to join"
        }
    }
}

nonisolated struct MeshPhiDestinationRowFacts: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let statusLine: String
    let canRevoke: Bool
    let canApprove: Bool

    init(_ row: MeshPhiDestination, names: [String: String] = [:]) {
        id = row.subject
        title = names[row.subject] ?? MeshPhiCopy.endpoint(of: row.target ?? row.subject)
        canRevoke = row.status == .approved
        canApprove = false
        switch row.status {
        case .approved: statusLine = "Approved"
        case .revoked: statusLine = "Approval taken back"
        case .expired: statusLine = "Approval expired"
        case .legacyAuthority: statusLine = "Approved by an institution before this update. It can't be approved here."
        case .unsupported: statusLine = "This kind of place can't receive PHI."
        case .invalid: statusLine = "This approval isn't valid."
        case .authorityRemoved, .approverRemoved: statusLine = "The device that approved it was removed."
        case .deviceRemoved: statusLine = "The device it belongs to was removed."
        case .contactMissing: statusLine = "The contact is no longer in your mesh."
        }
    }
}

@MainActor
@Observable
final class MeshPhiGroupModel {
    enum Phase: Equatable {
        case loading
        case ready
        case working
        case failed
    }

    private let service: any MeshPhiService
    private(set) var phase: Phase = .loading
    private(set) var rows: [MeshPhiDeviceRowFacts] = []
    private(set) var destinationRows: [MeshPhiDestinationRowFacts] = []
    private(set) var adopted = false
    private(set) var canAdopt = false
    private(set) var problem: String?

    init(service: any MeshPhiService) { self.service = service }

    func load() async {
        await run { try await self.service.phiDestinations() }
    }

    func adopt() async {
        guard canAdopt, phase == .ready else { return }
        phase = .working
        do {
            _ = try await service.adoptPhiGroup()
            await load()
        } catch { fail(error) }
    }

    func exclude(_ id: String) async { await change(id) { try await $0.excludePhiDevice(deviceId: id) } }

    func include(_ id: String) async { await change(id) { try await $0.includePhiDevice(deviceId: id) } }

    func revoke(_ subject: String) async {
        guard phase == .ready else { return }
        phase = .working
        do {
            try await service.revokePhiDestination(subject: subject)
            await load()
        } catch { fail(error) }
    }

    private func change(_ id: String, _ work: (any MeshPhiService) async throws -> MeshPhiGroup) async {
        guard phase == .ready, rows.contains(where: { $0.id == id }) else { return }
        phase = .working
        do {
            _ = try await work(service)
            await load()
        } catch { fail(error) }
    }

    private func run(_ work: () async throws -> MeshPhiDestinations) async {
        problem = nil
        do { show(try await work()) } catch { fail(error) }
    }

    private func show(_ view: MeshPhiDestinations) {
        let counts = Dictionary(grouping: view.group.members.compactMap(\.approvedBy), by: { $0 }).mapValues(\.count)
        let given = Dictionary(
            grouping: view.destinations.filter { $0.status == .approved }.compactMap(\.approvedBy), by: { $0 }
        ).mapValues(\.count)
        rows = view.group.members.map { member in
            MeshPhiDeviceRowFacts(
                member: member, approvals: counts[member.deviceId, default: 0] + given[member.deviceId, default: 0])
        }
        destinationRows = view.destinations.map { MeshPhiDestinationRowFacts($0) }
        adopted = view.group.isAdopted
        canAdopt = view.group.members.contains { $0.state == .notApproved }
        phase = .ready
    }

    private func fail(_ error: Error) {
        problem = MeshRuntime.describe(error)
        phase = .failed
    }
}

nonisolated enum MeshPhiID {
    static let adoptionCard = "mesh.phi.adoption"
    static let adopt = "mesh.phi.adopt"
    static let destinationCard = "mesh.phi.destination"
    static let approve = "mesh.phi.approve"
    static let destinations = "mesh.phi.destinations"
    static let problem = "mesh.phi.problem"
    static let openAdoption = "mesh.phi.open-adoption"
    static let offer = "mesh.phi.offer"
    static func fact(_ id: String) -> String { "mesh.phi.fact." + id }
    static func line(_ index: Int) -> String { "mesh.phi.line.\(index)" }
    static func device(_ id: String) -> String { "mesh.phi.device." + String(id.suffix(8)) }
    static func exclude(_ id: String) -> String { "mesh.phi.exclude." + String(id.suffix(8)) }
    static func include(_ id: String) -> String { "mesh.phi.include." + String(id.suffix(8)) }
    static func destination(_ subject: String) -> String { "mesh.phi.row." + String(subject.suffix(12)) }
    static func revoke(_ subject: String) -> String { "mesh.phi.revoke." + String(subject.suffix(12)) }
}
