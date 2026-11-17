// The production MeshKernel: it opens the generated Kernel with the device custody keys, host signer, on-device model and local tools, and maps every call onto the host's Mesh types.
// It resumes runs after opening, ticks them from a timer, starts the network once this device is enrolled, and keeps queued-message anchors for the chat tree.

import AstralCore
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
    private let localTools: any MeshLocalTools
    private let peerTools: [MeshPeerTool]

    private init(
        kernel: Kernel, bridge: KernelChangeBridge, localTools: any MeshLocalTools, peerTools: [MeshPeerTool],
        now: @escaping @Sendable () -> Date
    ) {
        self.kernel = kernel
        self.bridge = bridge
        self.localTools = localTools
        self.peerTools = peerTools
        self.now = now
    }

    static func open(
        config: MeshKernelConfig, network: NetworkConfig, signer: any AstralHostSigning,
        model: any AstralOnDeviceModel, tools: any MeshLocalTools, listener: any MeshKernelListening,
        peerTools: [MeshPeerTool] = [], keystore: any AstralKernel.HostKeystore = ConnectionKeychain(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> RealMeshKernel {
        let late = Late()
        let bridge = KernelChangeBridge(listener: listener) { Task { await late.kernel?.enrolled() } }
        let native = KernelConfig(
            dataDir: config.dataDirectory.path, operationsSecret: config.operationsSecret,
            wrapSecret: config.wrapSecret, restoreMarker: config.installMarker, deviceLabel: config.deviceLabel,
            deviceKind: kind(config.deviceKind), network: network)
        do {
            let kernel = try Kernel.open(
                config: native, signer: KernelHostSigner(signer), model: KernelOnDeviceModel(model),
                tools: KernelLocalTools(tools), listener: bridge,
                peerTools: peerTools.map { PeerToolSpec(device: $0.deviceId, tool: KernelLocalTools.native($0.spec)) })
            do { try kernel.setKeystore(keystore: keystore) } catch {
                await kernel.close()
                throw error
            }
            if let profile = config.deviceProfileJSON { try? kernel.setDeviceProfile(deviceProfileJson: profile) }
            let opened = RealMeshKernel(
                kernel: kernel, bridge: bridge, localTools: tools, peerTools: peerTools, now: now)
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
        guard try await enrolledStatus() != nil else { return }
        do { _ = try await kernel.startNetwork() } catch { throw KernelMapping.error(error) }
    }

    func stopNetwork() async {
        lock.withLock {
            ticker?.cancel()
            ticker = nil
        }
        await kernel.stopNetwork()
    }

    func close() async {
        lock.withLock {
            ticker?.cancel()
            ticker = nil
        }
        await kernel.close()
    }

    func syncNow() async throws {
        do { try await kernel.syncNow() } catch { throw KernelMapping.error(error) }
    }

    func meshStatus() async throws -> MeshStatus {
        do { return KernelMapping.status(try await kernel.meshStatus()) } catch { throw KernelMapping.error(error) }
    }

    private func enrolledStatus() async throws -> AstralKernel.MeshStatus? {
        do {
            let status = try await kernel.meshStatus()
            return status.state == .enrolled ? status : nil
        } catch { throw KernelMapping.error(error) }
    }

    func meshPrincipal() throws -> MeshVerifiedPrincipal {
        try mapped { KernelMapping.principal(try kernel.meshPrincipal()) }
    }

    func setWakeRoute(expectedMeshId: String, expectedDeviceId: String, route: MeshWakeRoute?) async throws {
        try mapped {
            try kernel.setWakeRoute(
                expectedMeshId: expectedMeshId, expectedDeviceId: expectedDeviceId,
                route: route.map {
                    AstralKernel.WakeRoute(
                        publisher: $0.publisher, capability: $0.capability, expiresAtMs: $0.expiresAtMS)
                })
        }
    }

    func wakeRoutes() async throws -> [MeshDeviceWakeRoute] {
        try mapped {
            try kernel.wakeRoutes().map { entry in
                MeshDeviceWakeRoute(
                    meshId: entry.meshId, deviceId: entry.deviceId,
                    route: MeshWakeRoute(
                        publisher: entry.route.publisher, capability: entry.route.capability,
                        expiresAtMS: entry.route.expiresAtMs))
            }
        }
    }

    func createMesh() throws -> MeshRecoveryKit {
        try mapped {
            let kit = try kernel.createMesh()
            return MeshRecoveryKit(words: kit.words.split(separator: " ").map(String.init))
        }
    }

    func confirmMeshRecovery() throws { try mapped { try kernel.confirmMeshRecovery() } }

    func recoverWithWords(words: String, backupPath: String?) throws -> MeshRecovery {
        try mapped {
            let result = try kernel.recoverWithWords(words: words, backupPath: backupPath)
            return MeshRecovery(
                meshId: result.meshId, deviceId: result.deviceId, eventsImported: Int(clamping: result.eventsImported))
        }
    }

    func createInvitation() async throws -> MeshInvitation {
        do { return KernelMapping.invitation(try await kernel.createInvitation(), now: now()) } catch {
            throw KernelMapping.error(error)
        }
    }

    func acceptInvitation(payload: String) async throws -> MeshInvitationAccepted {
        do { return KernelMapping.accepted(try await kernel.acceptInvitation(payload: payload), now: now()) } catch {
            throw KernelMapping.error(error)
        }
    }

    func approveInvitation() async throws {
        do { _ = try await kernel.approveInvitation(historyGrant: .all) } catch { throw KernelMapping.error(error) }
    }

    func cancelInvitation() async { await kernel.cancelInvitation() }

    func cancelPairingOffer() { kernel.cancelPairingOffer() }

    func renameDevice(memberId: String, label: String) throws {
        try mapped { try kernel.renameDevice(deviceId: memberId, label: label) }
    }

    func createPairingOffer() async throws -> MeshPairingOffer {
        do { return KernelMapping.pairingOffer(try await kernel.createPairingOffer(), now: now()) } catch {
            throw KernelMapping.error(error)
        }
    }

    func previewPairing(payload: String) throws -> MeshPairingPreview {
        try mapped { KernelMapping.pairingPreview(try kernel.previewPairing(payload: payload), now: now()) }
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

    func mintCallerTicket(
        nodeId: String, holderKey: String, label: String, toolNames: [String], a2a: Bool, lifetimeSeconds: UInt64
    ) throws -> MeshCallerTicket {
        try mapped {
            KernelMapping.callerTicket(
                try kernel.mintCallerTicket(
                    nodeId: nodeId, holderKey: holderKey, label: label, toolNames: toolNames, a2a: a2a,
                    lifetimeS: lifetimeSeconds))
        }
    }

    func callerTickets() throws -> [MeshCallerTicket] {
        try mapped { try kernel.callerTickets().map(KernelMapping.callerTicket) }
    }

    func revokeCallerTicket(id: String) throws { try mapped { try kernel.revokeCallerTicket(id: id) } }

    func verifyCallerRequest(_ request: MeshCallerRequest) throws -> MeshVerifiedCaller {
        try mapped {
            KernelMapping.verifiedCaller(try kernel.verifyCallerRequest(request: KernelMapping.callerRequest(request)))
        }
    }

    func raiseStop() throws { try mapped { _ = try kernel.raiseStop() } }

    func resumeStop() throws { try mapped { _ = try kernel.resumeStop() } }

    func exportBackup(path: String) throws { try mapped { _ = try kernel.exportBackup(path: path) } }

    func listChats() throws -> [MeshChatSummary] {
        try mapped {
            try kernel.listChats().map { summary in
                if let cached = lock.withLock({ previews[summary.chatId] }), cached.stamp == summary.lastActivity,
                    cached.summary.queuedCount == 0
                {
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
            return KernelChatMapper.map(detail, unknown: try kernel.unknownOutcomes(), queuedBases: bases)
        }
    }

    func chatForDevice(chatId: String, deviceProfileJson: String) throws -> MeshChatView {
        try mapped {
            let detail = try kernel.chatForDevice(chatId: chatId, deviceProfileJson: deviceProfileJson)
            let bases = lock.withLock { queuedBases }
            return KernelChatMapper.map(detail, unknown: try kernel.unknownOutcomes(), queuedBases: bases)
        }
    }

    func createChat(title: String) throws -> String { try mapped { try kernel.createChat(title: title) } }

    func sendMessage(chatId: String, text: String, continues: String?) throws -> String {
        try sendMessage(chatId: chatId, text: text, continues: continues, attachments: [])
    }

    func addAttachment(chatId: String, bytes: Data, mime: String, name: String) throws -> MeshAttachment {
        try mapped {
            KernelMapping.attachment(try kernel.addAttachment(chatId: chatId, bytes: bytes, mime: mime, name: name))
        }
    }

    func fetchAttachment(handle: String) async throws -> Data {
        do { return try await kernel.fetchAttachment(handle: handle) } catch { throw KernelMapping.error(error) }
    }

    func sendMessage(chatId: String, text: String, continues: String?, attachments: [String]) throws -> String {
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
            let id = try kernel.sendMessageWithAttachments(
                chatId: chatId, text: text, continues: anchor, attachments: attachments)
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
                throw MeshKernelError.refused(
                    "This message starts the chat, so there is nothing before it to branch from.")
            }
            return parent
        }
    }

    func act(surfaceId: String, componentId: String, capability: String, args: [String: JSONValue]) async throws
        -> MeshActResult
    {
        do {
            let body = try JSONEncoder().encode(
                JSONValue.object(["capability": .string(capability), "args": .object(args)]))
            let result = try await kernel.act(
                surfaceId: surfaceId, componentId: componentId, actionJson: String(decoding: body, as: UTF8.self))
            return MeshActResult(status: result.status, code: result.code, text: result.text)
        } catch { throw KernelMapping.error(error) }
    }

    func restoreMarker() throws -> Data? { try mapped { try kernel.restoreMarker() } }

    func pendingOrdinaryMessages() async throws -> [MeshPendingMessage] {
        try mapped {
            try kernel.pendingOrdinaryMessages().map { MeshPendingMessage(chatId: $0.chatId, messageId: $0.messageId) }
        }
    }

    func resumePendingMessage(chatId: String, messageId: String) async throws {
        do { _ = try await kernel.resumePendingMessage(chatId: chatId, messageId: messageId) } catch {
            throw KernelMapping.error(error)
        }
    }

    func cancelPendingMessage(chatId: String, messageId: String) async throws {
        do { _ = try await kernel.cancelPendingMessage(chatId: chatId, messageId: messageId) } catch {
            throw KernelMapping.error(error)
        }
    }

    func ordinaryResumeTargets() async throws -> [MeshResumeTarget] {
        guard let status = try await enrolledStatus(), !status.stopped else { return [] }
        let unknown = try mapped { try kernel.unknownOutcomes() }.map(\.chatId)
        let excluded = Set(try await runs().map(\.chatId)).union(unknown)
        return try mapped {
            try kernel.listChats().compactMap { summary in
                guard !excluded.contains(summary.chatId) else { return nil }
                let view = try kernel.chat(chatId: summary.chatId).view
                return Self.ordinaryResumeTarget(in: view, deviceId: status.deviceId, feed: status.feed)
            }
        }
    }

    static func ordinaryResumeTarget(in view: AstralKernel.ChatView, deviceId: String, feed: String)
        -> MeshResumeTarget?
    {
        let open = view.turns.filter { $0.status == .running }
        guard open.count == 1, let turn = open.first, turn.author == deviceId,
            turn.feed == feed, let messageId = turn.message,
            view.messages.contains(where: {
                $0.id == messageId && $0.kind == "chat.user_message" && $0.role == .user && $0.author == deviceId
            })
        else { return nil }
        return MeshResumeTarget(chatId: view.chatId, turnId: turn.id)
    }

    func resumeTurn(chatId: String, turnId: String) async throws {
        do { _ = try await kernel.resumeTurn(chatId: chatId, turnId: turnId) } catch {
            throw KernelMapping.error(error)
        }
    }

    func steerTurn(chatId: String, turnId: String, text: String) throws -> Bool {
        try mapped { try kernel.steerTurn(chatId: chatId, turnId: turnId, text: text) }
    }

    func steerMessage(chatId: String, messageId: String, text: String) throws -> Bool {
        try mapped { try kernel.steerMessage(chatId: chatId, messageId: messageId, text: text) }
    }

    func steerRequest(requestId: String, text: String) throws -> Bool {
        try mapped { try kernel.steerRequest(requestId: requestId, text: text) }
    }

    func runMessage(chatId: String, messageId: String) async throws {
        do { _ = try await kernel.runMessage(chatId: chatId, messageId: messageId) } catch {
            throw KernelMapping.error(error)
        }
    }

    func interruptTurn(chatId: String, turnId: String) throws -> Bool {
        try mapped { try kernel.interruptTurn(chatId: chatId, turnId: turnId) }
    }

    func interruptMessage(chatId: String, messageId: String) throws -> Bool {
        try mapped { try kernel.interruptMessage(chatId: chatId, messageId: messageId) }
    }

    func interruptRequest(requestId: String) throws -> Bool {
        try mapped { try kernel.interruptRequest(requestId: requestId) }
    }

    func runTurn(chatId: String) async throws {
        do { _ = try await kernel.runTurn(chatId: chatId) } catch { throw KernelMapping.error(error) }
    }

    func steer(chatId: String, text: String) throws { try mapped { try kernel.steer(chatId: chatId, text: text) } }

    func interrupt(chatId: String) throws { try mapped { try kernel.interrupt(chatId: chatId) } }

    func pendingConsents() throws -> [MeshPendingConsent] {
        try mapped { try kernel.pendingConsents() }.map { pending in
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

    func tools() -> [MeshToolEntry] {
        let mine = localTools.list().map {
            MeshToolEntry(
                name: $0.name, summary: $0.summary, effect: $0.effect, deviceId: nil,
                annotations: MeshToolAnnotations(json: $0.annotationsJSON))
        }
        let known = Set(mine.map(\.name))
        let fixed = peerTools.filter { !known.contains($0.spec.name) }.map {
            MeshToolEntry(
                name: $0.spec.name, summary: $0.spec.summary, effect: $0.spec.effect, deviceId: $0.deviceId,
                annotations: MeshToolAnnotations(json: $0.spec.annotationsJSON))
        }
        let seen = Set(fixed.map(\.id))
        let published = ((try? kernel.peerToolCatalog()) ?? []).map {
            MeshToolEntry(
                name: $0.tool.name, summary: $0.tool.description, effect: KernelLocalTools.meshEffect($0.tool.effect),
                deviceId: $0.device, grantName: $0.grantName, published: true,
                annotations: MeshToolAnnotations(json: $0.tool.annotationsJson))
        }.filter { !seen.contains($0.id) }
        return mine + fixed + published
    }

    func publishToolCatalog() throws {
        let specs = localTools.list().map(KernelLocalTools.native)
        try mapped { _ = try kernel.publishToolCatalog(tools: specs) }
    }

    func grants() throws -> [MeshGrant] {
        try mapped {
            try kernel.grants().map {
                MeshGrant(
                    grantId: $0.grant, tool: $0.tool, scope: $0.scope, grantedBy: $0.grantedBy,
                    consented: $0.consented, refusal: $0.refusal)
            }
        }
    }

    func resolveHandle(chatId: String, handle: String) throws -> MeshResolvedHandle {
        try mapped {
            let resolved = try kernel.resolveHandle(chatId: chatId, handle: handle)
            guard let kind = MeshResolvedHandle.Kind(rawValue: resolved.kind) else {
                throw MeshKernelError.refused("That link or image cannot be shown.")
            }
            return MeshResolvedHandle(kind: kind, value: resolved.value, mime: resolved.mime)
        }
    }

    func answerRequest(requestId: String) async throws {
        do { _ = try await kernel.answerRequest(requestId: requestId) } catch { throw KernelMapping.error(error) }
    }

    func grantTool(name: String, scope: String) throws {
        try mapped { _ = try kernel.grantTool(tool: name, scope: scope) }
    }

    func revokeTool(name: String, scope: String) throws {
        try mapped { _ = try kernel.revokeTool(tool: name, scope: scope) }
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

    func setModelProviderRecipients(name: String, recipients: [String]?) throws -> MeshModelProvider {
        try mapped {
            let order = try kernel.modelProviders().map(\.fallbackOrder).min() ?? 0
            return KernelMapping.provider(
                try kernel.setModelProviderRecipients(name: name, recipients: recipients), lowestOrder: order)
        }
    }

    func modelProviders() throws -> [MeshModelProvider] {
        try mapped {
            let infos = try kernel.modelProviders()
            let lowest = infos.map(\.fallbackOrder).min() ?? 0
            return infos.map { KernelMapping.provider($0, lowestOrder: lowest) }
        }
    }

    func setRemoteMCPServer(_ config: MeshRemoteMCPConfig) throws {
        try mapped {
            try kernel.setRemoteMcpServer(
                config: RemoteMcpConfig(name: config.name, endpoint: config.endpoint, bearer: config.bearer))
        }
    }

    func remoteMCPServers() throws -> [MeshRemoteMCPServer] {
        try mapped {
            try kernel.remoteMcpServers().map {
                MeshRemoteMCPServer(name: $0.name, endpoint: $0.endpoint, credentialConfigured: $0.credentialConfigured)
            }
        }
    }

    func removeRemoteMCPServer(_ name: String) throws {
        try mapped { try kernel.removeRemoteMcpServer(name: name) }
    }

    func refreshRemoteMCPTools(_ server: String) async throws -> [MeshRemoteMCPTool] {
        do {
            return try await kernel.refreshRemoteMcpTools(server: server).map {
                MeshRemoteMCPTool(
                    server: $0.server, endpoint: $0.endpoint, configurationRevision: $0.configurationRevision,
                    name: $0.name, description: $0.description, inputSchemaJSON: $0.inputSchemaJson,
                    annotationsJSON: $0.annotationsJson, definitionHash: $0.definitionHash, status: $0.status)
            }
        } catch { throw KernelMapping.error(error) }
    }

    func approveRemoteMCPTool(_ tool: MeshRemoteMCPTool) async throws {
        do {
            try await kernel.approveRemoteMcpTool(
                server: tool.server, tool: tool.name, definitionHash: tool.definitionHash,
                configurationRevision: tool.configurationRevision)
        } catch { throw KernelMapping.error(error) }
    }

    func revokeRemoteMCPTool(server: String, tool: String) throws {
        try mapped { try kernel.revokeRemoteMcpTool(server: server, tool: tool) }
    }

    func mailboxState() throws -> MeshMailboxState { try mapped { KernelMapping.mailbox(try kernel.mailboxState()) } }

    func syncState() async throws -> MeshSyncState {
        do { return KernelMapping.sync(try await kernel.syncState(), now: now()) } catch {
            throw KernelMapping.error(error)
        }
    }

    func allowance() throws -> MeshAllowance { try mapped { KernelMapping.allowance(try kernel.allowance()) } }

    func proposeConnection(endpoint: String, name: String, local: Bool) async throws -> MeshConnectionProposal {
        do {
            return KernelMapping.connectionProposal(
                try await kernel.proposeConnection(endpoint: endpoint, name: name, local: local))
        } catch { throw KernelMapping.error(error) }
    }

    func reviewConnection(id: String) async throws -> MeshConnectionProposal {
        do { return KernelMapping.connectionProposal(try await kernel.reviewConnection(id: id)) } catch {
            throw KernelMapping.error(error)
        }
    }

    func approveConnection(proposal: String, flow: String, toolNames: [String], clientId: String?) throws
        -> MeshConnection
    {
        try mapped {
            KernelMapping.connection(
                try kernel.approveConnection(proposal: proposal, flow: flow, toolNames: toolNames, clientId: clientId))
        }
    }

    func removeConnection(id: String) throws { try mapped { try kernel.removeConnection(id: id) } }

    func connections() throws -> [MeshConnection] {
        try mapped { try kernel.connections().map(KernelMapping.connection) }
    }

    func beginConnectionSignIn(id: String, redirect: MeshSignInRedirect) async throws -> MeshSignInStart {
        do {
            return KernelMapping.signInStart(
                try await kernel.beginConnectionSignIn(id: id, redirect: KernelMapping.signInRedirect(redirect)))
        } catch { throw KernelMapping.error(error) }
    }

    func completeConnectionSignIn(flow: String, redirectURL: String) async throws -> MeshConnectionState {
        do {
            return KernelMapping.connectionState(
                try await kernel.completeConnectionSignIn(flow: flow, redirectUrl: redirectURL))
        } catch { throw KernelMapping.error(error) }
    }

    func pollConnectionSignIn(flow: String) async throws -> MeshSignInPoll {
        do { return KernelMapping.signInPoll(try await kernel.pollConnectionSignIn(flow: flow)) } catch {
            throw KernelMapping.error(error)
        }
    }

    func cancelConnectionSignIn(flow: String) throws { try mapped { try kernel.cancelConnectionSignIn(flow: flow) } }

    func refreshConnection(id: String) async throws -> MeshConnectionState {
        do { return KernelMapping.connectionState(try await kernel.refreshConnection(id: id)) } catch {
            throw KernelMapping.error(error)
        }
    }

    func connectionStepUp(id: String, challenge: [String]) throws -> MeshStepUpPlan {
        try mapped { KernelMapping.stepUpPlan(try kernel.connectionStepUp(id: id, challenge: challenge)) }
    }

    func noteConnectionCallSucceeded(id: String) throws {
        try mapped { try kernel.noteConnectionCallSucceeded(id: id) }
    }

    func runs() async throws -> [MeshRun] {
        do { return try await activeRuns().runs().map(KernelMapping.run) } catch { throw KernelMapping.error(error) }
    }

    func handOffRun(runId: String, memberId: String) async throws {
        do { try await activeRuns().handOffRun(runId: runId, memberId: memberId) } catch {
            throw KernelMapping.error(error)
        }
    }

    func takeOverRun(runId: String) async throws -> MeshTakeOver {
        do {
            return MeshTakeOver(unknownSteps: try await activeRuns().takeOverRun(runId: runId).unknownSteps.count)
        } catch {
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
        guard (try? await enrolledStatus()) != nil, let runs = try? activeRuns() else { return }
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
