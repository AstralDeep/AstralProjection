// The PHI group and destination book behind InMemoryMeshKernel: it applies the real kernel's states and refusal codes to adoption, exclusion, proposals and approvals.
// Endpoints are canonicalized with a small subset of the kernel's rules, so tests exercise the host's reactions and the real kernel stays the authority.

import Foundation

nonisolated final class InMemoryPhi: @unchecked Sendable {
    private let lock = NSLock()
    private var included: Set<String> = []
    private var excluded: Set<String> = []
    private var legacyDevices: Set<String> = []
    private var rows: [MeshPhiDestination] = []
    private var statusValue = MeshPhiStatus(modelPresent: false, screened: 0, overBudget: 0, failed: 0)

    func markNotUpgraded(_ deviceId: String) { lock.withLock { _ = legacyDevices.insert(deviceId) } }

    func setStatus(_ value: MeshPhiStatus) { lock.withLock { statusValue = value } }

    func status() -> MeshPhiStatus { lock.withLock { statusValue } }

    func group(members: [MeshMember]) -> MeshPhiGroup {
        lock.withLock { groupLocked(members) }
    }

    func adopt(members: [MeshMember]) -> MeshPhiGroup {
        lock.withLock {
            for member in members {
                let id = member.memberId
                if !legacyDevices.contains(id) && !excluded.contains(id) { included.insert(id) }
            }
            return groupLocked(members)
        }
    }

    func include(_ deviceId: String, members: [MeshMember]) throws -> MeshPhiGroup {
        try lock.withLock {
            guard members.contains(where: { $0.memberId == deviceId }) else {
                throw KernelMapping.refusal("phi_group.unknown_device")
            }
            excluded.remove(deviceId)
            if !legacyDevices.contains(deviceId) { included.insert(deviceId) }
            return groupLocked(members)
        }
    }

    func exclude(_ deviceId: String, members: [MeshMember]) throws -> MeshPhiGroup {
        try lock.withLock {
            guard members.contains(where: { $0.memberId == deviceId }) else {
                throw KernelMapping.refusal("phi_group.unknown_device")
            }
            included.remove(deviceId)
            excluded.insert(deviceId)
            return groupLocked(members)
        }
    }

    func destinations(members: [MeshMember]) -> MeshPhiDestinations {
        lock.withLock { MeshPhiDestinations(group: groupLocked(members), destinations: rows) }
    }

    func allowed(kind: MeshPhiDestinationKind, target: String) -> Bool {
        lock.withLock {
            rows.contains { $0.status == .approved && $0.target == target }
        }
    }

    func propose(source: String, deviceId: String) throws -> MeshPhiProposal {
        guard let data = source.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let origin = object["source"] as? String, let name = object["name"] as? String
        else { throw KernelMapping.refusal("phi_destination.malformed") }
        switch origin {
        case "provider":
            return try endpoint(
                object["base_url"] as? String, kind: .model, name: name, deviceId: nil, source: source)
        case "legacy_server":
            return try endpoint(
                object["endpoint"] as? String, kind: .service, name: name, deviceId: deviceId, source: source)
        case "contact":
            guard let mesh = object["mesh_id"] as? String, !mesh.isEmpty else {
                throw KernelMapping.refusal("phi_destination.malformed")
            }
            return MeshPhiProposal(
                kind: .contact, target: mesh, subject: "contact:" + mesh, name: name, needsApproval: true,
                facts: Self.facts, source: source)
        case "connection":
            let use = object["use"] as? String
            guard use == "model" || use == "service", object["confined"] as? Bool == false else {
                throw KernelMapping.refusal("phi_destination.malformed")
            }
            guard let text = object["endpoint"] as? String else {
                throw KernelMapping.refusal("phi_destination.no_target")
            }
            return try endpoint(
                text, kind: use == "model" ? .model : .service, name: name,
                deviceId: use == "service" ? object["device"] as? String ?? deviceId : nil, source: source)
        default:
            throw KernelMapping.refusal("phi_destination.malformed")
        }
    }

    func approve(_ proposal: MeshPhiProposal, members: [MeshMember]) throws {
        let current = try propose(source: proposal.source, deviceId: members.first { $0.isThisDevice }?.memberId ?? "")
        try lock.withLock {
            if !current.needsApproval { throw KernelMapping.refusal("phi_destination.on_device") }
            if current.kind == .contact { throw KernelMapping.refusal("phi_destination.contact_unavailable") }
            guard let subject = current.subject else { throw KernelMapping.refusal("phi_destination.malformed") }
            rows.removeAll { $0.subject == subject }
            rows.append(
                MeshPhiDestination(
                    subject: subject, form: subject.hasPrefix("local:") ? .local : .endpoint, target: current.target,
                    status: .approved, code: nil, approvedBy: members.first { $0.isThisDevice }?.memberId))
        }
    }

    func revoke(subject: String) throws {
        try lock.withLock {
            guard let index = rows.firstIndex(where: { $0.subject == subject }) else {
                throw KernelMapping.refusal("phi_destination.not_approved")
            }
            let row = rows[index]
            rows[index] = MeshPhiDestination(
                subject: row.subject, form: row.form, target: row.target, status: .revoked, code: row.code,
                approvedBy: row.approvedBy)
        }
    }

    func seed(_ destination: MeshPhiDestination) {
        lock.withLock {
            rows.removeAll { $0.subject == destination.subject }
            rows.append(destination)
        }
    }

    private static let facts: [MeshPhiFact] = [.notOwnerRun, .leavesDevices, .unseenHandling]

    private func groupLocked(_ members: [MeshMember]) -> MeshPhiGroup {
        let list = members.map { member -> MeshPhiMember in
            let state: MeshPhiState
            if excluded.contains(member.memberId) {
                state = .excluded
            } else if legacyDevices.contains(member.memberId) {
                state = .notUpgraded
            } else {
                state = included.contains(member.memberId) ? .included : .notApproved
            }
            return MeshPhiMember(
                deviceId: member.memberId, label: member.label, kind: member.kind, state: state,
                approvedBy: state == .included ? members.first { $0.isThisDevice }?.memberId : nil,
                upgraded: !legacyDevices.contains(member.memberId), isThisDevice: member.isThisDevice)
        }
        let pending = list.filter { $0.state == .notApproved }.map(\.deviceId)
        return MeshPhiGroup(members: list, localCode: nil, rotateFirst: false, pending: pending, keeper: true)
    }

    private func endpoint(
        _ text: String?, kind: MeshPhiDestinationKind, name: String, deviceId: String?, source: String
    ) throws -> MeshPhiProposal
    {
        guard let text, let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
            ["http", "https"].contains(scheme), let host = parts.host?.lowercased(), !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { throw KernelMapping.refusal("phi_destination.invalid_endpoint") }
        let port = parts.port.map { ":" + String($0) } ?? ""
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        let canonical = scheme + "://" + host + port + path
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        let onDevice = loopback && kind == .model
        let subject = loopback && kind == .service ? "local:" + (deviceId ?? "") + ":" + canonical : canonical
        return MeshPhiProposal(
            kind: kind, target: loopback && kind == .service ? subject : canonical,
            subject: onDevice ? nil : subject, name: name, needsApproval: !onDevice,
            facts: onDevice ? [] : Self.facts, source: source)
    }
}
