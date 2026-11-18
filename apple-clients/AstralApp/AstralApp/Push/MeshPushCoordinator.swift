// Binds publisher registration to the phone's verified native mesh session and normal authenticated owner.
// Stale registration completions are conditionally revoked, and the mesh receives only a bounded empty-wake capability.

import AstralCore
import Foundation
import Observation

nonisolated struct MeshPushContext: Equatable, Sendable {
    let owner: ConversationAccount
    let meshId: String
    let deviceId: String
    let meshSession: UUID
}

nonisolated struct MeshPushCredential: Sendable {
    let owner: ConversationAccount
    let access: String
}

@MainActor @Observable
final class MeshPushCoordinator {
    typealias Prepare = @MainActor (ConversationAccount) async -> MeshPushContext?
    typealias Current = @MainActor (MeshPushContext) async -> Bool
    typealias Publish = @MainActor (MeshPushContext, MeshWakeRoute?) async -> Bool
    private(set) var status = "Background updates unavailable"
    var isConfigured: Bool { rest != nil }
    private let rest: MeshPushRest?
    private let storage: any MeshKeyStorage
    private let now: @Sendable () -> Int64
    private var credential: @MainActor () async -> MeshPushCredential? = { nil }
    private var requestToken: @MainActor (Bool) -> Void = { _ in }
    private var prepare: Prepare?
    private var current: Current?
    private var publish: Publish?
    private var task: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var epoch = UUID()
    private var token: String?
    private var lease: Lease?
    private var publication: Lease?
    private var publicationTail: Task<Void, Never>?

    private struct Saved: Codable, Equatable {
        let meshId: String
        let deviceId: String
        let revision: Int64
        let expiresAtMS: Int64
    }

    private struct Lease {
        let context: MeshPushContext
        let registration: AstralCore.MeshPushRegistration
        let credential: MeshPushCredential
        let token: String
        let publish: Publish
    }

    init(
        rest: MeshPushRest?,
        storage: any MeshKeyStorage = KeychainMeshKeyStorage(service: KeychainServices.name("mesh-push")),
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.rest = rest
        self.storage = storage
        self.now = now
    }

    func configure(
        credential: @escaping @MainActor () async -> MeshPushCredential?,
        requestToken: @escaping @MainActor (Bool) -> Void
    ) {
        self.credential = credential
        self.requestToken = requestToken
    }

    func bind(prepare: @escaping Prepare, isCurrent: @escaping Current, publish: @escaping Publish) {
        unbind()
        self.prepare = prepare
        self.current = isCurrent
        self.publish = publish
        retry()
    }

    func unbind() {
        epoch = UUID()
        task?.cancel()
        task = nil
        renewal?.cancel()
        renewal = nil
        prepare = nil
        current = nil
        publish = nil
        requestToken(false)
        retireLease()
        status = "Background updates unavailable"
    }

    func authenticationChanged() {
        epoch = UUID()
        task?.cancel()
        requestToken(false)
        retireLease()
        retry()
    }

    func receivedToken(_ value: String) {
        guard value != token else { return }
        token = value
        retry()
    }

    func registrationFailed() {
        token = nil
        requestToken(false)
        task?.cancel()
        epoch = UUID()
        status = "Background updates unavailable: notification registration failed"
        retireLease()
    }

    func retry() {
        task?.cancel()
        let captured = UUID()
        epoch = captured
        task = Task { [weak self] in await self?.register(captured) }
    }

    private func valid(_ context: MeshPushContext, epoch captured: UUID) async -> Bool {
        guard epoch == captured, !Task.isCancelled, let current else { return false }
        let answer = await current(context)
        return answer && epoch == captured && !Task.isCancelled
    }

    private func register(_ captured: UUID) async {
        guard let rest, let prepare, let publish else {
            if epoch == captured { status = "Background updates unavailable: publisher not configured" }
            return
        }
        guard let access = await credential(), epoch == captured, !Task.isCancelled else {
            if epoch == captured {
                requestToken(false)
                retireLease()
                status = "Background updates need an owner session"
            }
            return
        }
        guard let context = await prepare(access.owner), epoch == captured, !Task.isCancelled,
            context.owner == access.owner, MeshPushRest.validID(context.meshId), MeshPushRest.validID(context.deviceId),
            await valid(context, epoch: captured)
        else {
            if epoch == captured {
                requestToken(false)
                retireLease()
                status = "Background updates unavailable: mesh identity not verified"
            }
            return
        }
        if let lease, lease.context == context, lease.credential.owner == access.owner,
            lease.token == token, lease.registration.route.expiresAtMS - now() > 3_600_000
        {
            self.lease = Lease(
                context: lease.context, registration: lease.registration,
                credential: access, token: lease.token, publish: lease.publish)
            status = "Background updates registered"
            return
        }
        guard await recover(access, context: context, epoch: captured) else { return }
        guard await valid(context, epoch: captured) else { return }
        requestToken(true)
        guard let token else {
            status = "Registering for background updates"
            return
        }
        status = "Registering for background updates"
        let snapshot = await rest.status(access: access.access, meshId: context.meshId, deviceId: context.deviceId)
        guard await valid(context, epoch: captured) else { return }
        let revision: Int64
        switch snapshot {
        case .absent: revision = 0
        case .current(let value, _, _): revision = value
        case .signInRequired:
            status = "Background updates need an owner session"
            return
        case .unavailable:
            status = "Background updates unavailable: publisher unreachable"
            return
        }
        let result = await rest.register(
            access: access.access, meshId: context.meshId, deviceId: context.deviceId,
            pushToken: token, expectedRevision: revision)
        guard case .registered(let registration) = result else {
            guard await valid(context, epoch: captured) else { return }
            switch result {
            case .signInRequired: status = "Background updates need an owner session"
            case .conflict: status = "Background registration changed. Retry."
            default: status = "Background updates unavailable: publisher unreachable"
            }
            return
        }
        let candidate = Lease(
            context: context, registration: registration, credential: access, token: token, publish: publish)
        guard await valid(context, epoch: captured), self.token == token else {
            await revoke(candidate)
            return
        }
        do { try save(candidate) } catch {
            status = "Background updates unavailable: protected storage failed"
            await revoke(candidate)
            return
        }
        let published = await append(candidate, epoch: captured)
        guard published, await valid(context, epoch: captured), self.token == token else {
            await revoke(candidate)
            if epoch == captured { status = "Background updates unavailable: mesh changed" }
            return
        }
        lease = candidate
        status = "Background updates registered"
        renewal?.cancel()
        let delay = max(Int64(1), min(82_800_000, registration.route.expiresAtMS - now() - 3_600_000))
        renewal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            guard let self, self.epoch == captured else { return }
            self.retry()
        }
    }

    private func retireLease() {
        guard let lease else { return }
        self.lease = nil
        renewal?.cancel()
        renewal = nil
        Task { await revoke(lease) }
    }

    private func append(_ candidate: Lease, epoch captured: UUID) async -> Bool {
        let previous = publicationTail
        let operation = Task { @MainActor in
            await previous?.value
            guard await valid(candidate.context, epoch: captured) else { return false }
            let result = await candidate.publish(candidate.context, candidate.registration.route)
            if result { publication = candidate }
            return result
        }
        publicationTail = Task { _ = await operation.value }
        return await operation.value
    }

    private func withdraw(_ retired: Lease) async {
        let previous = publicationTail
        let operation = Task { @MainActor in
            await previous?.value
            guard publication?.context == retired.context,
                publication?.registration == retired.registration
            else { return }
            let removed = await retired.publish(retired.context, nil)
            if removed && publication?.registration == retired.registration { publication = nil }
        }
        publicationTail = operation
        await operation.value
    }

    private func revoke(_ retired: Lease) async {
        await withdraw(retired)
        let result = await rest?.revoke(
            access: retired.credential.access, meshId: retired.context.meshId,
            deviceId: retired.context.deviceId, revision: retired.registration.revision)
        if result != .revoked && result != .conflict {
            if lease == nil {
                status = "Background revocation unconfirmed; previous registration expires automatically"
            }
        } else {
            try? forget(owner: retired.credential.owner, record: saved(retired))
        }
    }

    private func key(_ owner: ConversationAccount) -> String { "pending." + owner.locatorStorageKey }

    private func records(_ owner: ConversationAccount) throws -> [Saved] {
        guard let data = try storage.load(key(owner)) else { return [] }
        let values = try JSONDecoder().decode([Saved].self, from: data)
        guard values.count <= 32,
            values.allSatisfy({
                MeshPushRest.validID($0.meshId) && MeshPushRest.validID($0.deviceId)
                    && (1...9_007_199_254_740_991).contains($0.revision)
                    && (1...9_007_199_254_740_991).contains($0.expiresAtMS)
            })
        else { throw CocoaError(.coderReadCorrupt) }
        return values
    }

    private func saved(_ value: Lease) -> Saved {
        Saved(
            meshId: value.context.meshId, deviceId: value.context.deviceId,
            revision: value.registration.revision, expiresAtMS: value.registration.route.expiresAtMS)
    }

    private func save(_ value: Lease) throws {
        var pending = try records(value.credential.owner).filter { $0.expiresAtMS > now() }
        let row = saved(value)
        if !pending.contains(row) { pending.append(row) }
        guard pending.count <= 32 else { throw CocoaError(.fileWriteOutOfSpace) }
        try storage.save(JSONEncoder().encode(pending), key: key(value.credential.owner))
    }

    private func forget(owner: ConversationAccount, record: Saved) throws {
        let pending = try records(owner).filter { $0 != record && $0.expiresAtMS > now() }
        try storage.save(JSONEncoder().encode(pending), key: key(owner))
    }

    private func recover(_ credential: MeshPushCredential, context: MeshPushContext, epoch captured: UUID) async -> Bool
    {
        do {
            for row in try records(credential.owner) {
                if row.expiresAtMS <= now() {
                    try forget(owner: credential.owner, record: row)
                    continue
                }
                let result = await rest?.revoke(
                    access: credential.access, meshId: row.meshId,
                    deviceId: row.deviceId, revision: row.revision)
                guard await valid(context, epoch: captured) else { return false }
                guard result == .revoked || result == .conflict else {
                    status = "Background revocation unconfirmed; retry when the publisher is available"
                    return false
                }
                try forget(owner: credential.owner, record: row)
            }
            return true
        } catch {
            if epoch == captured { status = "Background updates unavailable: protected storage failed" }
            return false
        }
    }
}
