// State and facts behind the Connections screens: the review card's facts come only from the Kernel's proposal, never from chat text.
// MeshConnectionsView, MeshConnectionAddView and MeshConnectionCard read these types, and MeshRuntime performs the calls.

import Foundation
import Observation

@MainActor
protocol MeshConnectionService: AnyObject {
    func proposeConnection(endpoint: String, name: String, local: Bool) async throws -> MeshConnectionProposal
    func reviewConnection(id: String) async throws -> MeshConnectionProposal
    func approveConnection(proposal: String, flow: String, toolNames: [String]) async throws -> MeshConnection
}

extension MeshRuntime: MeshConnectionService {}

nonisolated struct MeshConnectionCardFacts: Equatable, Sendable {
    struct Tool: Identifiable, Equatable, Sendable {
        let name: String
        let shortHash: String
        var id: String { name }
    }

    let proposalId: String
    let name: String
    let address: String
    let signInHost: String?
    let redirectHost: String?
    let scopes: [String]
    let tools: [Tool]
    let egress: [String]
    let replacesExisting: Bool
    let isLocal: Bool

    init(_ proposal: MeshConnectionProposal) {
        proposalId = proposal.proposal
        name = proposal.name
        address = proposal.endpoint
        signInHost = proposal.issuerHost
        redirectHost = proposal.redirectHost
        scopes = proposal.scopes
        tools = proposal.tools.map { Tool(name: $0.name, shortHash: Self.shortHash($0.hash)) }
        egress = proposal.egress
        replacesExisting = proposal.replaces != nil
        isLocal = proposal.local
    }

    static func shortHash(_ hash: String) -> String {
        let digest: Substring = hash.split(separator: ":").last ?? Substring(hash)
        return String(digest.prefix(8))
    }
}

@MainActor
@Observable
final class MeshConnectionAddModel {
    enum Phase: Equatable {
        case entering
        case proposing
        case reviewing
        case approving
        case done(connection: String)
    }

    private let service: any MeshConnectionService
    private(set) var phase: Phase = .entering
    private(set) var facts: MeshConnectionCardFacts?
    private(set) var problem: String?
    var endpoint = ""
    var name = ""
    var local = false
    var phiSource = false
    var selectedTools: Set<String> = []

    init(service: any MeshConnectionService) {
        self.service = service
    }

    var showsLocalToggle: Bool { Self.isLoopback(endpoint) }

    var canContinue: Bool {
        phase == .entering && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canApprove: Bool { phase == .reviewing }

    nonisolated static func isLoopback(_ address: String) -> Bool {
        guard let host = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        else { return false }
        let bare: String = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return bare == "localhost" || bare == "::1" || bare.hasPrefix("127.")
    }

    func propose() async {
        guard canContinue else { return }
        let address: String = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .proposing
        problem = nil
        do {
            let proposal = try await service.proposeConnection(
                endpoint: address, name: label.isEmpty ? Self.defaultName(address) : label,
                local: showsLocalToggle && local)
            show(proposal)
        } catch {
            problem = MeshRuntime.describe(error)
            phase = .entering
        }
    }

    func review(connection id: String) async {
        guard phase == .entering else { return }
        phase = .proposing
        problem = nil
        do {
            show(try await service.reviewConnection(id: id))
        } catch {
            problem = MeshRuntime.describe(error)
            phase = .entering
        }
    }

    func approve() async {
        guard phase == .reviewing, let facts else { return }
        phase = .approving
        problem = nil
        let flow: String = phiSource ? "phi" : "private"
        let names: [String] = facts.tools.map(\.name).filter { selectedTools.contains($0) }
        do {
            let created = try await service.approveConnection(
                proposal: facts.proposalId, flow: flow, toolNames: names)
            phase = .done(connection: created.id)
        } catch {
            problem = MeshRuntime.describe(error)
            phase = .reviewing
        }
    }

    func startOver() {
        guard phase != .approving, phase != .proposing else { return }
        phase = .entering
        facts = nil
        problem = nil
        phiSource = false
        selectedTools = []
    }

    private func show(_ proposal: MeshConnectionProposal) {
        let card = MeshConnectionCardFacts(proposal)
        facts = card
        phiSource = card.replacesExisting && proposal.flowHint == "phi"
        selectedTools = Set(card.tools.map(\.name))
        phase = .reviewing
    }

    private static func defaultName(_ address: String) -> String {
        URLComponents(string: address)?.host ?? "Connection"
    }
}

nonisolated struct MeshConnectionRowFacts: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let host: String
    let hereLine: String
    let otherLines: [String]
    let unavailableLine: String?
    let needsReview: Bool

    init(_ connection: MeshConnection) {
        id = connection.id
        name = connection.name
        host = URLComponents(string: connection.endpoint)?.host ?? connection.endpoint
        hereLine = connection.thisDevice.state == "signed_in" ? "Signed in here" : "Not signed in here"
        otherLines = connection.otherDevices.filter { $0.state == "signed_in" }.map { "Signed in on \($0.label)" }
        unavailableLine = connection.supportedHere ? nil : "Not available on this device"
        needsReview = !(connection.pendingTools ?? []).isEmpty
    }
}

nonisolated struct MeshLegacyServerRow: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let endpoint: String
    let credentialLine: String

    init(_ server: MeshRemoteMCPServer) {
        id = server.name
        name = server.name
        endpoint = server.endpoint
        credentialLine = server.credentialConfigured ? "Credential saved" : "No credential"
    }
}

@MainActor
@Observable
final class MeshLegacyServersModel {
    private(set) var rows: [MeshLegacyServerRow] = []
    private(set) var problem: String?

    func load(from runtime: MeshRuntime) async {
        do {
            rows = try await runtime.remoteMCPServers().map(MeshLegacyServerRow.init)
            problem = nil
        } catch {
            problem = MeshRuntime.describe(error)
        }
    }
}

nonisolated enum MeshConnectionID {
    static let approve = "mesh.connections.approve"
    static let noTools = "mesh.connections.card.no-tools"
    static let phiSource = "mesh.connections.phi"
    static let error = "mesh.connections.error"
    static let working = "mesh.connections.working"
    static let address = "mesh.connections.address"
    static let name = "mesh.connections.name"
    static let local = "mesh.connections.local"
    static let proceed = "mesh.connections.continue"
    static let add = "mesh.connections.add"
    static let legacy = "mesh.connections.legacy"

    static func fact(_ id: String) -> String { "mesh.connections.card.\(id)" }
    static func tool(_ name: String) -> String { "mesh.connections.tool.\(name)" }
    static func here(_ id: String) -> String { "mesh.connections.here.\(id)" }
    static func row(_ id: String) -> String { "mesh.connections.row.\(id)" }
    static func review(_ id: String) -> String { "mesh.connections.review.\(id)" }
    static func remove(_ id: String) -> String { "mesh.connections.remove.\(id)" }
    static func legacyRow(_ id: String) -> String { "mesh.connections.legacy.\(id)" }
}
