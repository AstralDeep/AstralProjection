// An in-memory MeshKernel with scripted behavior for unit tests, previews and the UI fixture launch.
// It follows the same state rules the host expects from the real kernel, and reports changes through the listener it was opened with.

import AstralCore
import Foundation

nonisolated final class InMemoryMeshKernel: MeshKernel, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let name: String
        let detail: String
    }

    private let lock = NSLock()
    private let listener: any MeshKernelListening
    private let clock: @Sendable () -> Date
    private var status: MeshStatus
    private var members: [MeshMember] = []
    private var chats: [String: StoredChat] = [:]
    private var order: [String] = []
    private var consents: [MeshPendingConsent] = []
    private var providers: [MeshModelProvider] = []
    private var syncValue = MeshSyncState.empty
    private var allowanceValue: MeshAllowance
    private var counter = 0
    private var log: [Call] = []
    private var offer: MeshPairingOffer?
    private var runsValue: [MeshRun] = []
    private var proposalsValue: [MeshProposal] = []

    var recoveryWords: [String] = (1...24).map { "word\($0)" }
    var turnScript: [MeshTurnEvent] = [
        .started, .assistantDelta("Hello"), .assistantDelta(" there"), .assistantFinished, .finished,
    ]
    var turnReply = "Hello there"
    var consentGate: @Sendable () throws -> Void = {}
    var failure: MeshKernelError?
    var turnError: MeshKernelError?
    var previewResult = MeshPairingPreview(
        comparisonCode: "4821 9307", deviceLabel: "New phone", deviceKind: .pocket, fingerprint: "sha256:0a1b2c3d4e5f")

    private struct StoredChat {
        var title: String
        var messages: [MeshChatMessage]
        var surfaces: [MeshSurface]
        var status: MeshChatStatus
        var updatedAt: Date
    }

    init(
        listener: any MeshKernelListening, hasMesh: Bool = false, hardwareBacked: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.listener = listener
        self.clock = clock
        status = MeshStatus(
            hasMesh: hasMesh, meshId: hasMesh ? "sha256:" + String(repeating: "a", count: 64) : nil,
            deviceId: hasMesh ? "sha256:" + String(repeating: "b", count: 64) : nil, attested: hasMesh,
            stopped: false, hardwareBacked: hardwareBacked)
        allowanceValue = MeshAllowance(
            share: .solo, periodEndsAt: nil, lines: [], modelTokensRemaining: nil, modelTokensLimit: nil, blocked: nil)
        if hasMesh { members = [Self.thisDevice(status: status)] }
    }

    var calls: [Call] { lock.withLock { log } }

    func startNetwork() async throws { try record("startNetwork") }
    func stopNetwork() async { lock.withLock { log.append(Call(name: "stopNetwork", detail: "")) } }
    func version() -> String { "in-memory" }

    func meshStatus() async throws -> MeshStatus {
        try record("meshStatus")
        return lock.withLock { status }
    }

    func beginMeshCreation() throws -> MeshAttestationRequest {
        try record("beginMeshCreation")
        return MeshAttestationRequest(nonce: "nonce-1")
    }

    func completeMeshCreation(idToken: String) throws -> MeshRecoveryKit {
        try record("completeMeshCreation", idToken)
        guard !idToken.isEmpty else { throw MeshKernelError.refused("attestation.missing") }
        lock.withLock {
            status = MeshStatus(
                hasMesh: true, meshId: "sha256:" + String(repeating: "a", count: 64),
                deviceId: "sha256:" + String(repeating: "b", count: 64), attested: true, stopped: false,
                hardwareBacked: status.hardwareBacked)
            members = [Self.thisDevice(status: status)]
        }
        listener.onChange(.rosterChanged)
        return MeshRecoveryKit(words: recoveryWords)
    }

    func createPairingOffer() async throws -> MeshPairingOffer {
        try record("createPairingOffer")
        let made = MeshPairingOffer(shortCode: "12345678", payload: "astral-pair:v1:offer")
        lock.withLock { offer = made }
        return made
    }

    func previewPairing(payload: String) throws -> MeshPairingPreview {
        try record("previewPairing", payload)
        guard payload.hasPrefix("astral-pair:") else { throw MeshKernelError.refused("pairing.malformed") }
        return previewResult
    }

    func approvePairing(payload: String) async throws {
        try record("approvePairing", payload)
        guard payload.hasPrefix("astral-pair:") else { throw MeshKernelError.refused("pairing.malformed") }
        try consentGate()
        lock.withLock {
            members.append(
                MeshMember(
                    memberId: "sha256:" + String(repeating: "c", count: 64), label: previewResult.deviceLabel,
                    kind: previewResult.deviceKind, isThisDevice: false, attested: false, lastSeen: clock(),
                    path: .direct))
        }
        listener.onChange(.rosterChanged)
    }

    func completeJoin() {
        lock.withLock {
            status = MeshStatus(
                hasMesh: true, meshId: "sha256:" + String(repeating: "a", count: 64),
                deviceId: "sha256:" + String(repeating: "d", count: 64), attested: false, stopped: false,
                hardwareBacked: status.hardwareBacked)
            members = [Self.thisDevice(status: status)]
        }
        listener.onChange(.rosterChanged)
    }

    func roster() async throws -> [MeshMember] {
        try record("roster")
        return lock.withLock { members }
    }

    func removeDevice(memberId: String) throws {
        try record("removeDevice", memberId)
        try consentGate()
        lock.withLock { members.removeAll { $0.memberId == memberId && !$0.isThisDevice } }
        listener.onChange(.rosterChanged)
    }

    func raiseStop() throws {
        try record("raiseStop")
        lock.withLock { status.stopped = true }
        listener.onChange(.rosterChanged)
        listener.onChange(.allowanceChanged)
    }

    func reattest(idToken: String) throws {
        try record("reattest", idToken)
        lock.withLock { status.attested = true }
        listener.onChange(.rosterChanged)
    }

    func exportBackup(path: String) throws { try record("exportBackup", path) }

    func listChats() throws -> [MeshChatSummary] {
        try record("listChats")
        return lock.withLock {
            order.compactMap { id in chats[id].map { summary(id: id, chat: $0) } }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func chat(chatId: String) throws -> MeshChatView {
        try record("chat", chatId)
        return try lock.withLock {
            guard let chat = chats[chatId] else { throw MeshKernelError.notFound }
            return MeshChatView(
                chatId: chatId, title: chat.title, messages: chat.messages, branches: branches(of: chat),
                surfaces: chat.surfaces, labels: [], status: chat.status)
        }
    }

    func createChat(title: String) throws -> String {
        try record("createChat", title)
        let id = nextId("chat")
        let now = clock()
        lock.withLock {
            chats[id] = StoredChat(title: title, messages: [], surfaces: [], status: .idle, updatedAt: now)
            order.append(id)
        }
        listener.onChange(.chatChanged(chatId: id))
        return id
    }

    func sendMessage(chatId: String, text: String, continues: String?) throws -> String {
        try record("sendMessage", text + "|" + (continues ?? ""))
        guard !text.isEmpty else { throw MeshKernelError.refused("message.empty") }
        let id = nextId("event")
        let now = clock()
        try lock.withLock {
            guard var chat = chats[chatId] else { throw MeshKernelError.notFound }
            let parent = continues ?? Self.head(of: chat.messages)
            chat.messages.append(
                MeshChatMessage(
                    eventId: id, parentId: parent, author: .owner, authorDevice: status.deviceId, text: text,
                    createdAt: now, delivery: .queued, surfaceIds: []))
            chat.updatedAt = now
            chats[chatId] = chat
        }
        listener.onChange(.chatChanged(chatId: chatId))
        return id
    }

    func fork(chatId: String, eventId: String) throws -> String {
        try record("fork", eventId)
        try lock.withLock {
            guard let chat = chats[chatId], chat.messages.contains(where: { $0.eventId == eventId }) else {
                throw MeshKernelError.notFound
            }
        }
        return eventId
    }

    func act(surfaceId: String, componentId: String, action: String) throws {
        try record("act", surfaceId + "/" + componentId + "/" + action)
    }

    func runTurn(chatId: String) async throws {
        try record("runTurn", chatId)
        if let turnError { throw turnError }
        let now = clock()
        let reply = nextId("event")
        let turnId = "turn-" + reply
        try lock.withLock {
            guard var chat = chats[chatId] else { throw MeshKernelError.notFound }
            chat.messages = chat.messages.map { message in
                message.delivery == .queued
                    ? MeshChatMessage(
                        eventId: message.eventId, parentId: message.parentId, author: message.author,
                        authorDevice: message.authorDevice, text: message.text, createdAt: message.createdAt,
                        delivery: .recorded, surfaceIds: message.surfaceIds) : message
            }
            chat.status = .running(turnId: turnId)
            chats[chatId] = chat
        }
        for event in turnScript {
            if event == .finished {
                lock.withLock {
                    guard var chat = chats[chatId] else { return }
                    chat.messages.append(
                        MeshChatMessage(
                            eventId: reply, parentId: Self.head(of: chat.messages), author: .assistant,
                            authorDevice: status.deviceId, text: turnReply, createdAt: now, delivery: .recorded,
                            surfaceIds: []))
                    chat.status = .idle
                    chats[chatId] = chat
                }
                listener.onChange(.chatChanged(chatId: chatId))
            }
            listener.onChange(.turnProgress(MeshTurnProgress(chatId: chatId, turnId: turnId, event: event)))
        }
    }

    func steer(chatId: String, text: String) throws { try record("steer", text) }
    func interrupt(chatId: String) throws { try record("interrupt", chatId) }

    func pendingConsents() throws -> [MeshPendingConsent] {
        try record("pendingConsents")
        return lock.withLock { consents }
    }

    func resolveConsent(requestId: String, approve: Bool) throws {
        try record("resolveConsent", requestId + (approve ? ":approve" : ":deny"))
        if approve { try consentGate() }
        lock.withLock { consents.removeAll { $0.requestId == requestId } }
    }

    func recordSpoken(chatId: String, kind: VoiceSpokenKind, text: String) throws {
        try record("recordSpoken", chatId + ":" + text)
    }

    func setModelProvider(_ config: MeshModelProviderConfig) throws {
        try record("setModelProvider", config.baseURL + " " + config.model)
        guard config.apiKey.isEmpty == false else { throw MeshKernelError.refused("provider.key_missing") }
        lock.withLock {
            providers = [
                MeshModelProvider(
                    providerId: "provider-1", baseURL: config.baseURL, model: config.model, hasKey: true,
                    isDefault: true)
            ]
        }
    }

    func modelProviders() throws -> [MeshModelProvider] {
        try record("modelProviders")
        return lock.withLock { providers }
    }

    func syncState() async throws -> MeshSyncState {
        try record("syncState")
        return lock.withLock { syncValue }
    }

    func allowance() throws -> MeshAllowance {
        try record("allowance")
        return lock.withLock { allowanceValue }
    }

    func runs() async throws -> [MeshRun] {
        try record("runs")
        return lock.withLock { runsValue }
    }

    func handOffRun(runId: String, memberId: String) async throws {
        try record("handOffRun", runId + ":" + memberId)
        try consentGate()
        lock.withLock {
            guard let index = runsValue.firstIndex(where: { $0.runId == runId }) else { return }
            let run = runsValue[index]
            runsValue[index] = MeshRun(
                runId: run.runId, chatId: run.chatId, kind: run.kind, goal: run.goal, status: run.status,
                reason: run.reason, rounds: run.rounds, tokensSpent: run.tokensSpent, role: .watcher,
                executor: memberId, unknownSteps: run.unknownSteps)
        }
        listener.onChange(.runProgress(runId: runId))
    }

    func takeOverRun(runId: String) async throws -> MeshTakeOver {
        try record("takeOverRun", runId)
        try consentGate()
        let unknown = lock.withLock { () -> Int in
            guard let index = runsValue.firstIndex(where: { $0.runId == runId }) else { return 0 }
            let run = runsValue[index]
            runsValue[index] = MeshRun(
                runId: run.runId, chatId: run.chatId, kind: run.kind, goal: run.goal, status: run.status,
                reason: run.reason, rounds: run.rounds, tokensSpent: run.tokensSpent, role: .executor,
                executor: status.deviceId, unknownSteps: run.unknownSteps)
            return run.unknownSteps
        }
        listener.onChange(.runProgress(runId: runId))
        return MeshTakeOver(unknownSteps: unknown)
    }

    func learningProposals() async throws -> [MeshProposal] {
        try record("learningProposals")
        return lock.withLock { proposalsValue }
    }

    func reviewProposal(id: String, adopt: Bool) async throws -> MeshEvaluation {
        try record("reviewProposal", id + (adopt ? ":adopt" : ":decline"))
        return try lock.withLock {
            guard let index = proposalsValue.firstIndex(where: { $0.proposalId == id }) else {
                throw MeshKernelError.notFound
            }
            let proposal = proposalsValue[index]
            let next: MeshProposal.Status = adopt ? .adopted : .declined
            proposalsValue[index] = MeshProposal(
                proposalId: proposal.proposalId, kind: proposal.kind, name: proposal.name, content: proposal.content,
                status: next, detail: proposal.detail, tools: proposal.tools, untrusted: proposal.untrusted,
                gatePassed: proposal.gatePassed, replayPassed: proposal.replayPassed,
                ownerReasons: proposal.ownerReasons, hygiene: proposal.hygiene)
            return adopt ? .adopted : .declined("owner")
        }
    }

    func undoAdoption(id: String) async throws {
        try record("undoAdoption", id)
        try lock.withLock {
            guard let index = proposalsValue.firstIndex(where: { $0.proposalId == id && $0.status == .adopted })
            else { throw MeshKernelError.notFound }
            let proposal = proposalsValue[index]
            proposalsValue[index] = MeshProposal(
                proposalId: proposal.proposalId, kind: proposal.kind, name: proposal.name, content: proposal.content,
                status: .reversed, detail: proposal.detail, tools: proposal.tools, untrusted: proposal.untrusted,
                gatePassed: proposal.gatePassed, replayPassed: proposal.replayPassed,
                ownerReasons: proposal.ownerReasons, hygiene: proposal.hygiene)
        }
    }

    func setRuns(_ value: [MeshRun]) {
        lock.withLock { runsValue = value }
        listener.onChange(.runProgress(runId: value.first?.runId ?? ""))
    }

    func setProposals(_ value: [MeshProposal]) {
        lock.withLock { proposalsValue = value }
    }

    func setPending(_ requests: [MeshPendingConsent]) {
        lock.withLock { consents = requests }
        for request in requests { listener.onChange(.consentRequested(requestId: request.requestId)) }
    }

    func setSync(_ value: MeshSyncState) {
        lock.withLock { syncValue = value }
        listener.onChange(.syncStateChanged)
    }

    func setAllowance(_ value: MeshAllowance) {
        lock.withLock { allowanceValue = value }
        listener.onChange(.allowanceChanged)
    }

    func setMembers(_ value: [MeshMember]) {
        lock.withLock { members = value }
        listener.onChange(.rosterChanged)
    }

    func seedChat(title: String, messages: [MeshChatMessage], surfaces: [MeshSurface] = []) -> String {
        let id = nextId("chat")
        lock.withLock {
            chats[id] = StoredChat(
                title: title, messages: messages, surfaces: surfaces, status: .idle,
                updatedAt: messages.last?.createdAt ?? clock())
            order.append(id)
        }
        return id
    }

    func setChatStatus(chatId: String, _ value: MeshChatStatus) {
        lock.withLock { chats[chatId]?.status = value }
        listener.onChange(.chatChanged(chatId: chatId))
    }

    private func record(_ name: String, _ detail: String = "") throws {
        let injected = lock.withLock { () -> MeshKernelError? in
            log.append(Call(name: name, detail: detail))
            return failure
        }
        if let injected { throw injected }
    }

    private func nextId(_ kind: String) -> String {
        lock.withLock {
            counter += 1
            return "\(kind)-\(counter)"
        }
    }

    private func summary(id: String, chat: StoredChat) -> MeshChatSummary {
        MeshChatSummary(
            chatId: id, title: chat.title, updatedAt: chat.updatedAt, preview: chat.messages.last?.text ?? "",
            branchCount: max(0, branches(of: chat).count - 1),
            queuedCount: chat.messages.filter { $0.delivery == .queued }.count)
    }

    private func branches(of chat: StoredChat) -> [MeshBranch] {
        let parents = Set(chat.messages.compactMap(\.parentId))
        return chat.messages.filter { !parents.contains($0.eventId) }.map { leaf in
            MeshBranch(
                headId: leaf.eventId, forkId: Self.forkPoint(of: leaf, in: chat.messages),
                messageCount: Self.path(to: leaf, in: chat.messages).count, updatedAt: leaf.createdAt)
        }
    }

    private static func head(of messages: [MeshChatMessage]) -> String? {
        let parents = Set(messages.compactMap(\.parentId))
        return messages.last { !parents.contains($0.eventId) }?.eventId
    }

    private static func path(to leaf: MeshChatMessage, in messages: [MeshChatMessage]) -> [MeshChatMessage] {
        let byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.eventId, $0) })
        var out = [leaf]
        var cursor = leaf.parentId
        while let id = cursor, let next = byId[id] {
            out.append(next)
            cursor = next.parentId
        }
        return out.reversed()
    }

    private static func forkPoint(of leaf: MeshChatMessage, in messages: [MeshChatMessage]) -> String? {
        var counts: [String: Int] = [:]
        for message in messages { if let parent = message.parentId { counts[parent, default: 0] += 1 } }
        return path(to: leaf, in: messages).last { counts[$0.eventId, default: 0] > 1 }?.eventId
    }

    private static func thisDevice(status: MeshStatus) -> MeshMember {
        MeshMember(
            memberId: status.deviceId ?? "", label: "This device", kind: .desktop, isThisDevice: true,
            attested: status.attested, lastSeen: nil, path: .none)
    }
}
