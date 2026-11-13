// The production MeshKernel: it opens the generated Kernel with the device custody keys, host signer, on-device model and local tools, and maps every call onto the host's Mesh types.
// It resumes runs after opening, ticks them from a timer, starts the network once this device is enrolled, and keeps queued-message anchors for the chat tree.

import AstralKernel
import Foundation

nonisolated final class RealMeshKernel: MeshKernel, @unchecked Sendable {
    static let tickInterval: Duration = .seconds(15)

    private final class Late: @unchecked Sendable {
        weak var kernel: RealMeshKernel?
    }

    private let kernel: Kernel
    private var runsHandle: Runs?
    private let bridge: KernelChangeBridge
    private let lock = NSLock()
    private var queuedBases: [String: String] = [:]
    private var previews: [String: (stamp: ClockStamp, summary: MeshChatSummary)] = [:]
    private var ticker: Task<Void, Never>?
    private let now: @Sendable () -> Date

    private init(kernel: Kernel, bridge: KernelChangeBridge, now: @escaping @Sendable () -> Date) {
        self.kernel = kernel
        self.bridge = bridge
        self.now = now
    }

    static func open(
        config: MeshKernelConfig, issuers: [IssuerConfig], network: NetworkConfig, signer: any AstralHostSigning,
        model: any AstralOnDeviceModel, tools: any MeshLocalTools, listener: any MeshKernelListening,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> RealMeshKernel {
        let late = Late()
        let bridge = KernelChangeBridge(listener: listener) { Task { await late.kernel?.enrolled() } }
        let native = KernelConfig(
            dataDir: config.dataDirectory.path, operationsSecret: config.operationsSecret,
            wrapSecret: config.wrapSecret, restoreMarker: config.installMarker, deviceLabel: config.deviceLabel,
            deviceKind: kind(config.deviceKind), issuers: issuers, network: network)
        do {
            let kernel = try Kernel.open(
                config: native, signer: KernelHostSigner(signer), model: KernelOnDeviceModel(model),
                tools: KernelLocalTools(tools), listener: bridge)
            let opened = RealMeshKernel(kernel: kernel, bridge: bridge, now: now)
            late.kernel = opened
            await opened.resumeAndTick()
            return opened
        } catch {
            throw KernelMapping.error(error)
        }
    }

    private static func kind(_ kind: MeshDeviceKind) -> DeviceKind {
        switch kind {
        case .desktop: return .desktop
        case .pocket: return .pocket
        case .satellite: return .satellite
        case .node: return .node
        }
    }

    deinit { ticker?.cancel() }

    func version() -> String { kernel.version() }

    func startNetwork() async throws {
        guard await kernel.meshStatus().state == .enrolled else { return }
        do { _ = try await kernel.startNetwork() } catch { throw KernelMapping.error(error) }
    }

    func stopNetwork() async {
        lock.withLock {
            ticker?.cancel()
            ticker = nil
        }
        await kernel.stopNetwork()
    }

    func meshStatus() async throws -> MeshStatus { KernelMapping.status(await kernel.meshStatus()) }

    func beginMeshCreation() throws -> MeshAttestationRequest {
        try mapped { MeshAttestationRequest(nonce: try kernel.beginMeshCreation().nonce) }
    }

    func completeMeshCreation(idToken: String) throws -> MeshRecoveryKit {
        try mapped {
            let kit = try kernel.completeMeshCreation(idToken: idToken)
            return MeshRecoveryKit(words: kit.words.split(separator: " ").map(String.init))
        }
    }

    func recoverWithWords(words: String, backupPath: String?) throws -> MeshRecovery {
        try mapped {
            let result = try kernel.recoverWithWords(words: words, backupPath: backupPath)
            return MeshRecovery(
                meshId: result.meshId, deviceId: result.deviceId, eventsImported: Int(clamping: result.eventsImported))
        }
    }

    func createPairingOffer() async throws -> MeshPairingOffer {
        do { return KernelMapping.pairingOffer(try await kernel.createPairingOffer()) } catch {
            throw KernelMapping.error(error)
        }
    }

    func previewPairing(payload: String) throws -> MeshPairingPreview {
        try mapped { KernelMapping.pairingPreview(try kernel.previewPairing(payload: payload)) }
    }

    func approvePairing(payload: String) async throws {
        do { _ = try await kernel.approvePairing(payload: payload, historyGrant: .all) } catch {
            throw KernelMapping.error(error)
        }
    }

    func roster() async throws -> [MeshMember] {
        let roster: RosterInfo
        do { roster = try kernel.roster() } catch { throw KernelMapping.error(error) }
        let peers = (try? await kernel.syncState()) ?? []
        return KernelMapping.members(roster, peers: peers)
    }

    func removeDevice(memberId: String) throws { try mapped { try kernel.removeDevice(memberId: memberId) } }

    func raiseStop() throws { try mapped { _ = try kernel.raiseStop() } }

    func reattest(idToken: String) throws { try mapped { try kernel.reattest(idToken: idToken) } }

    func exportBackup(path: String) throws { try mapped { _ = try kernel.exportBackup(path: path) } }

    func listChats() throws -> [MeshChatSummary] {
        try mapped {
            try kernel.listChats().map { summary in
                if let cached = lock.withLock({ previews[summary.chatId] }), cached.stamp == summary.lastActivity {
                    return cached.summary
                }
                let built = KernelChatMapper.summary(summary, detail: try? kernel.chat(chatId: summary.chatId))
                lock.withLock { previews[summary.chatId] = (summary.lastActivity, built) }
                return built
            }.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func chat(chatId: String) throws -> MeshChatView {
        try mapped {
            let detail = try kernel.chat(chatId: chatId)
            let bases = lock.withLock { queuedBases }
            return KernelChatMapper.map(detail, unknown: kernel.unknownOutcomes(), queuedBases: bases)
        }
    }

    func createChat(title: String) throws -> String { try mapped { try kernel.createChat(title: title) } }

    func sendMessage(chatId: String, text: String, continues: String?) throws -> String {
        try mapped {
            var anchor: String?
            if let head = continues {
                let bases = lock.withLock { queuedBases }
                let view = try kernel.chat(chatId: chatId).view
                switch KernelChatMapper.continuation(for: head, in: view, queuedBases: bases) {
                case .turn(let turn): anchor = turn
                case .root: anchor = nil
                case nil: throw MeshKernelError.refused("That message is not part of this chat yet.")
                }
            }
            let id = try kernel.sendMessage(chatId: chatId, text: text, continues: anchor)
            if let anchor { lock.withLock { queuedBases[id] = anchor } }
            return id
        }
    }

    func fork(chatId: String, eventId: String) throws -> String {
        try mapped {
            let bases = lock.withLock { queuedBases }
            let folded = KernelChatMapper.fold(try kernel.chat(chatId: chatId).view, queuedBases: bases)
            guard let message = folded.messages.first(where: { $0.eventId == eventId }) else {
                throw MeshKernelError.notFound
            }
            guard message.author == .owner else { return message.eventId }
            guard let parent = message.parentId else {
                throw MeshKernelError.refused("This message starts the chat, so there is nothing before it to branch from.")
            }
            return parent
        }
    }

    func act(surfaceId: String, componentId: String, action: String) throws {
        throw MeshKernelError.unavailable("This build cannot run actions from a surface yet.")
    }

    func runTurn(chatId: String) async throws {
        do { _ = try await kernel.runTurn(chatId: chatId) } catch { throw KernelMapping.error(error) }
    }

    func steer(chatId: String, text: String) throws { try mapped { try kernel.steer(chatId: chatId, text: text) } }

    func interrupt(chatId: String) throws { try mapped { try kernel.interrupt(chatId: chatId) } }

    func pendingConsents() throws -> [MeshPendingConsent] {
        kernel.pendingConsents().map { pending in
            let arguments = Data(pending.argumentsJson.utf8)
            return MeshPendingConsent(
                requestId: pending.requestId, chatId: pending.chatId, kind: .action,
                canonicalAction: Data(pending.actionJson.utf8),
                canonicalArguments: (try? KernelCanonicalJSON.canonicalize(arguments)) ?? arguments,
                signingInput: Data())
        }
    }

    func resolveConsent(requestId: String, approve: Bool) throws {
        try mapped { try kernel.resolveConsent(requestId: requestId, approve: approve) }
    }

    func chatRequests(chatId: String) throws -> [MeshRequest] {
        try mapped { try kernel.chatRequests(chatId: chatId).map(KernelMapping.request) }
    }

    func pendingRequestsForMe() throws -> [MeshRequest] {
        try mapped { try kernel.pendingRequestsForMe().map(KernelMapping.request) }
    }

    func sendRequest(chatId: String, text: String, toMember: String) throws -> String {
        try mapped { try kernel.sendRequest(chatId: chatId, text: text, toMember: toMember, continues: nil, call: nil) }
    }

    func claimRequest(requestId: String) throws { try mapped { _ = try kernel.claimRequest(requestId: requestId) } }

    func refuseRequest(requestId: String, code: String) throws {
        try mapped { _ = try kernel.refuseRequest(requestId: requestId, code: code) }
    }

    func recordSpoken(chatId: String, kind: VoiceSpokenKind, text: String) throws {
        try mapped {
            _ = try kernel.recordSpoken(chatId: chatId, kind: kind == .answer ? .answer : .acknowledgement, text: text)
        }
    }

    func setModelProvider(_ config: MeshModelProviderConfig) throws {
        try mapped { try kernel.setModelProvider(config: try KernelMapping.providerConfig(config)) }
    }

    func modelProviders() throws -> [MeshModelProvider] {
        try mapped {
            let infos = try kernel.modelProviders()
            let lowest = infos.map(\.fallbackOrder).min() ?? 0
            return infos.map { KernelMapping.provider($0, lowestOrder: lowest) }
        }
    }

    func syncState() async throws -> MeshSyncState {
        do { return KernelMapping.sync(try await kernel.syncState(), now: now()) } catch {
            throw KernelMapping.error(error)
        }
    }

    func allowance() throws -> MeshAllowance { try mapped { KernelMapping.allowance(try kernel.allowance()) } }

    func runs() async throws -> [MeshRun] {
        do { return try await activeRuns().runs().map(KernelMapping.run) } catch { throw KernelMapping.error(error) }
    }

    func handOffRun(runId: String, memberId: String) async throws {
        do { try await activeRuns().handOffRun(runId: runId, memberId: memberId) } catch { throw KernelMapping.error(error) }
    }

    func takeOverRun(runId: String) async throws -> MeshTakeOver {
        do { return MeshTakeOver(unknownSteps: try await activeRuns().takeOverRun(runId: runId).unknownSteps.count) } catch {
            throw KernelMapping.error(error)
        }
    }

    func learningProposals() async throws -> [MeshProposal] {
        do { return try await activeRuns().learningProposals().map(KernelMapping.proposal) } catch {
            throw KernelMapping.error(error)
        }
    }

    func reviewProposal(id: String, adopt: Bool) async throws -> MeshEvaluation {
        do { return KernelMapping.evaluation(try await activeRuns().reviewProposal(id: id, adopt: adopt)) } catch {
            throw KernelMapping.error(error)
        }
    }

    func undoAdoption(id: String) async throws {
        do { _ = try await activeRuns().undoAdoption(id: id) } catch { throw KernelMapping.error(error) }
    }

    func enrolled() async {
        try? await startNetwork()
        await resumeAndTick()
    }

    private func activeRuns() throws -> Runs {
        try lock.withLock {
            if let runsHandle { return runsHandle }
            let handle = try kernel.runs()
            handle.setRunListener(listener: bridge)
            runsHandle = handle
            return handle
        }
    }

    private func resumeAndTick() async {
        guard await kernel.meshStatus().state == .enrolled, let runs = try? activeRuns() else { return }
        _ = try? await runs.resumeRuns()
        lock.withLock {
            guard ticker == nil else { return }
            ticker = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.tickInterval)
                    _ = try? await runs.tickRuns()
                }
            }
        }
    }

    private func mapped<T>(_ work: () throws -> T) throws -> T {
        do { return try work() } catch { throw KernelMapping.error(error) }
    }
}
