// Holds the pasted-key form for a connection: the key the owner typed, the sharing choice and, for an HTTP API, its header and format.
// MeshConnectionKeyView binds it and MeshRuntime performs the Kernel calls, so a key only ever comes from this form.

import Foundation
import Observation

@MainActor
protocol MeshConnectionKeyService: AnyObject {
    func setConnectionKey(id: String, secrets: [MeshConnectionSecret], recipients: [String]?) async throws
    func proposeKeyConnection(endpoint: String, name: String, local: Bool, key: String, recipients: [String]?)
        async throws -> MeshConnectionProposal
    func proposeHttpApiConnection(_ draft: MeshHttpApiDraft) async throws -> MeshConnectionProposal
}

extension MeshRuntime: MeshConnectionKeyService {}

nonisolated enum MeshKeyFormat: String, CaseIterable, Identifiable, Sendable {
    case bearer
    case plain

    var id: String { rawValue }
    var template: String { self == .bearer ? "Bearer {key}" : "{key}" }
    var label: String { self == .bearer ? "Bearer token" : "Key only" }
}

@MainActor
@Observable
final class MeshConnectionKeyModel: CustomStringConvertible, CustomDebugStringConvertible {
    enum Target: Equatable {
        case existing(connection: String)
        case server
        case httpApi
    }

    enum Phase: Equatable {
        case entering
        case saving
        case saved
        case proposed
    }

    private let service: any MeshConnectionKeyService
    let target: Target
    private(set) var phase: Phase = .entering
    private(set) var problem: String?
    private(set) var proposal: MeshConnectionProposal?
    var key = ""
    var recipients: [String]?
    var endpoint = ""
    var name = ""
    var local = false
    var header = "Authorization"
    var format: MeshKeyFormat = .bearer

    nonisolated var description: String { "MeshConnectionKeyModel" }
    nonisolated var debugDescription: String { description }

    init(service: any MeshConnectionKeyService, target: Target) {
        self.service = service
        self.target = target
    }

    var needsAddress: Bool {
        if case .existing = target { return false }
        return true
    }

    var showsHeader: Bool { target == .httpApi }

    var showsLocalToggle: Bool { target == .server && MeshConnectionAddModel.isLoopback(endpoint) }

    var canSave: Bool {
        guard phase == .entering, !trimmedKey.isEmpty, recipients?.isEmpty != true else { return false }
        guard needsAddress else { return true }
        return !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (target != .httpApi || Self.validHeader(header))
    }

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    nonisolated static func validHeader(_ text: String) -> Bool {
        let scalars: [Unicode.Scalar] = Array(text.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 64, isLetter(first) else { return false }
        return scalars.allSatisfy { isLetter($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    private nonisolated static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    func save() async {
        guard canSave else { return }
        let secret: String = trimmedKey
        let shared: [String]? = recipients
        key = ""
        phase = .saving
        problem = nil
        do {
            try await send(secret, shared)
        } catch {
            problem = MeshRuntime.describe(error)
            phase = .entering
        }
    }

    func clear() {
        key = ""
    }

    private func send(_ secret: String, _ shared: [String]?) async throws {
        let address: String = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown: String = label.isEmpty ? (URLComponents(string: address)?.host ?? "Connection") : label
        switch target {
        case .existing(let id):
            try await service.setConnectionKey(
                id: id, secrets: [MeshConnectionSecret(name: "key", value: secret)], recipients: shared)
            phase = .saved
        case .server:
            proposal = try await service.proposeKeyConnection(
                endpoint: address, name: shown, local: showsLocalToggle && local, key: secret, recipients: shared)
            phase = .proposed
        case .httpApi:
            let draft = MeshHttpApiDraft(
                name: shown, endpoint: address, header: header, format: format.template, key: secret,
                recipients: shared)
            proposal = try await service.proposeHttpApiConnection(draft)
            phase = .proposed
        }
    }
}
