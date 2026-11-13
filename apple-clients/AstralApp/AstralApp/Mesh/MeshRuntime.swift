// The observable model that owns the kernel handle for mesh mode, opens it with the device custody keys, and publishes what the screens show.
// Kernel callbacks arrive on any thread, are queued in order, and refresh published state on the main actor; every kernel call runs off the main thread.

import AstralCore
import Foundation
import Observation
import OSLog

@MainActor
protocol MeshSpeechSink: AnyObject {
    func answerDelta(_ text: String)
    func answerFinished()
    func toolStarted(id: String, cancelSafe: Bool)
    func toolFinished(id: String)
    func setRiskyActionPending(_ pending: Bool)
}

extension OnDeviceVoiceController: MeshSpeechSink {}

nonisolated final class MeshChangeRelay: MeshKernelListening, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MeshKernelChange>.Continuation?
    private var queued = 0
    let stream: AsyncStream<MeshKernelChange>

    init() {
        var captured: AsyncStream<MeshKernelChange>.Continuation?
        stream = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
    }

    var pending: Int { lock.withLock { queued } }

    func onChange(_ change: MeshKernelChange) {
        lock.withLock { queued += 1 }
        continuation?.yield(change)
    }

    func handled() { lock.withLock { queued -= 1 } }

    func finish() { continuation?.finish() }
}

nonisolated struct MeshToolActivity: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case running, succeeded, failed }
    let id: String
    let name: String
    let cancelSafe: Bool
    var state: State
}

nonisolated struct MeshTurnState: Equatable, Sendable {
    var turnId: String
    var running: Bool
    var streamingText = ""
    var tools: [MeshToolActivity] = []
    var awaitingConsent: String?
    var unknown: [MeshUnknownOutcome] = []
    var failure: String?
    var answeredOnDevice = false
    var interrupted = false
}

nonisolated enum MeshCreationState: Equatable, Sendable {
    case idle
    case signingIn
    case finishing
    case recovery([String])
    case failed(String)
}

nonisolated struct MeshRestoredMesh: Equatable, Sendable {
    let meshId: String
    let deviceId: String
    let deviceLabel: String
    let memberCount: Int
    let eventsImported: Int
}

nonisolated enum MeshRestoreState: Equatable, Sendable {
    case idle
    case recovering
    case restored(MeshRestoredMesh)
    case failed(String)
}

nonisolated enum MeshRecoveryWords {
    static let count = 24

    static func normalize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { token in
            let word = token.filter { $0.isASCII && $0.isLetter }
            return word.isEmpty ? nil : String(word)
        }
    }
}

nonisolated enum MeshJoinState: Equatable, Sendable {
    case idle
    case starting
    case offered(MeshPairingOffer)
    case accepted(MeshInvitationAccepted)
    case joined
    case failed(String)
}

nonisolated enum MeshVerificationState: Equatable, Sendable {
    case idle
    case signingIn
    case failed(String)
}

nonisolated enum MeshAddDeviceState: Equatable, Sendable {
    case idle
    case previewing(MeshPairingPreview, payload: String)
    case approving
    case added(String)
    case failed(String)
}

nonisolated enum MeshInviteState: Equatable, Sendable {
    case idle
    case creating
    case waiting(MeshInvitation)
    case requested(MeshJoinRequest)
    case approving
    case added(String)
    case failed(String)
}

nonisolated enum MeshUnknownChoice: Equatable, Sendable {
    case leaveAsUnknown
    case checkFirst
}

nonisolated enum MeshRequestRefusal: String, CaseIterable, Sendable {
    case busy = "request.busy"
    case notNow = "request.not_now"
    case declined = "request.declined"

    var title: String {
        switch self {
        case .busy: return "Busy right now"
        case .notNow: return "Not now"
        case .declined: return "I do not want this"
        }
    }

    var reason: String {
        switch self {
        case .busy: return "the device was busy"
        case .notNow: return "not now"
        case .declined: return "the owner declined"
        }
    }
}

nonisolated enum MeshProviderInputError: Error, Equatable, Sendable {
    case invalidURL
    case insecureURL
    case missingModel
    case missingKey

    var message: String {
        switch self {
        case .invalidURL: return "Enter the base URL of an OpenAI-compatible service."
        case .insecureURL: return "Use an https address. Plain http is allowed only for this device."
        case .missingModel: return "Enter a model name."
        case .missingKey: return "Enter the API key."
        }
    }
}

nonisolated enum MeshProviderInput {
    static func validate(baseURL: String, model: String, key: String) -> Result<
        MeshModelProviderConfig, MeshProviderInputError
    > {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return .failure(.invalidURL) }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard scheme == "https" || loopback else { return .failure(.insecureURL) }
        guard !name.isEmpty else { return .failure(.missingModel) }
        guard !secret.isEmpty else { return .failure(.missingKey) }
        return .success(MeshModelProviderConfig(baseURL: base, model: name, apiKey: secret))
    }
}

nonisolated enum MeshMailboxInputError: Error, Equatable, Sendable {
    case containsSpaces
    case tooLong

    var message: String {
        switch self {
        case .containsSpaces: return "A mailbox address has no spaces. Paste it exactly as it was given to you."
        case .tooLong: return "That mailbox address is too long."
        }
    }
}

nonisolated enum MeshMailboxInput {
    static let maximumLength = 4096

    static func validate(_ text: String) -> Result<String?, MeshMailboxInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        guard !trimmed.contains(where: \.isWhitespace) else { return .failure(.containsSpaces) }
        guard trimmed.utf8.count <= maximumLength else { return .failure(.tooLong) }
        return .success(trimmed)
    }
}

nonisolated enum MeshRecoveryConfirmation {
    static let positions = [7, 18]

    static func verify(words: [String], answers: [String]) -> Bool {
        guard answers.count == positions.count, words.count >= positions.max() ?? 0 else { return false }
        return zip(positions, answers).allSatisfy { position, answer in
            answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[position - 1].lowercased()
        }
    }
}

@MainActor
@Observable
final class MeshRuntime {
    enum Phase: Equatable {
        case closed
        case opening
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .closed
    private(set) var status = MeshStatus.empty
    private(set) var members: [MeshMember] = []
    private(set) var sync = MeshSyncState.empty
    private(set) var chats: [MeshChatSummary] = []
    private(set) var currentChatId: String?
    private(set) var currentChat: MeshChatView?
    private(set) var attachmentDrafts: [String: [MeshAttachment]] = [:]
    private(set) var importingAttachment = false
    private var attachmentSession = UUID()
    private(set) var selectedHead: String?
    private(set) var headPinned = false
    private(set) var turns: [String: MeshTurnState] = [:]
    private(set) var pendingConsents: [MeshPendingConsent] = []
    private(set) var allowance: MeshAllowance?
    private(set) var providers: [MeshModelProvider] = []
    private(set) var runs: [MeshRun] = []
    private(set) var proposals: [MeshProposal] = []
    private(set) var toolEntries: [MeshToolEntry] = []
    private(set) var grantedTools: Set<String> = []
    private(set) var meshGrants: [MeshGrant] = []
    private(set) var resolvedHandles: [String: MeshResolvedHandle] = [:]
    private(set) var mailbox = MeshMailboxState.off
    private(set) var mailboxAddress: String?
    private(set) var chatRequests: [MeshRequest] = []
    private(set) var requestsForMe: [MeshRequest] = []
    private(set) var creation = MeshCreationState.idle
    private(set) var join = MeshJoinState.idle
    private(set) var restore = MeshRestoreState.idle
    private(set) var addDevice = MeshAddDeviceState.idle
    private(set) var invite = MeshInviteState.idle
    private(set) var verification = MeshVerificationState.idle
    private(set) var acknowledgedOutcomes: Set<String> = []
    private(set) var spoken: [VoiceSpokenRecord] = []
    private(set) var restoredInstall = false
    private(set) var networkNotice: String?
    var notice: String?
    @ObservationIgnored weak var speechSink: MeshSpeechSink?

    @ObservationIgnored private var kernel: (any MeshKernel)?
    @ObservationIgnored private var keys: DeviceKeys?
    @ObservationIgnored private var wakeSession = UUID()
    @ObservationIgnored private var wakeDataRevision = UUID()
    @ObservationIgnored private let relay = MeshChangeRelay()
    @ObservationIgnored nonisolated(unsafe) private var consumer: Task<Void, Never>?
    @ObservationIgnored private var turnTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var speakingChatId: String?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private let makeKernel: MeshKernelFactory
    @ObservationIgnored private let makeKeys: @Sendable () throws -> DeviceKeys
    @ObservationIgnored private let consent: ConsentCoordinator
    @ObservationIgnored private let onDeviceModel: any AstralOnDeviceModel
    @ObservationIgnored private let tools: any MeshLocalTools
    @ObservationIgnored private let dataDirectory: URL
    @ObservationIgnored private let deviceLabel: String
    @ObservationIgnored private let deviceKind: MeshDeviceKind
    @ObservationIgnored private let enrollment: @Sendable (String) async throws -> String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date

    private static let acknowledgedKey = "astral.mesh.acknowledged-outcomes"
    private static let mailboxKey = "astral.mesh.mailbox"

    init(
        makeKernel: @escaping MeshKernelFactory,
        makeKeys: @escaping @Sendable () throws -> DeviceKeys,
        consent: ConsentCoordinator,
        onDeviceModel: any AstralOnDeviceModel,
        tools: any MeshLocalTools,
        dataDirectory: URL,
        deviceLabel: String,
        deviceKind: MeshDeviceKind,
        enrollment: @escaping @Sendable (String) async throws -> String,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeKernel = makeKernel
        self.makeKeys = makeKeys
        self.consent = consent
        self.onDeviceModel = onDeviceModel
        self.tools = tools
        self.dataDirectory = dataDirectory
        self.deviceLabel = deviceLabel
        self.deviceKind = deviceKind
        self.enrollment = enrollment
        self.defaults = defaults
        self.now = now
        acknowledgedOutcomes = Set(defaults.stringArray(forKey: Self.acknowledgedKey) ?? [])
        mailboxAddress = defaults.string(forKey: Self.mailboxKey)
        let relay = relay
        consumer = Task { [weak self] in
            for await change in relay.stream {
                await self?.handle(change)
                relay.handled()
            }
        }
    }

    deinit {
        consumer?.cancel()
        relay.finish()
    }

    var voiceChatId: String? { speakingChatId }
    var isReady: Bool { phase == .ready }
    var hasMesh: Bool { status.hasMesh }
    var currentTurn: MeshTurnState? { currentChatId.flatMap { turns[$0] } }
    var onDeviceModelAvailable: Bool { onDeviceModel.available() }
    var kernelVersion: String? { kernel?.version() }

    var syncSummary: MeshSyncSummary {
        let others = sync.devices.filter { device in members.first { $0.memberId == device.memberId }?.isThisDevice != true }
        if others.isEmpty { return members.count <= 1 ? .alone : .unknown }
        if let behind = others.first(where: { $0.state != .synced }) {
            return .waiting(device: behind.label, since: behind.lastSeen)
        }
        return .synced
    }

    var currentTurnsForDisplay: [AppModel.ChatTurn] { displayRows.map(\.turn) }

    var displayHead: String? {
        guard let view = currentChat else { return nil }
        guard let head = selectedHead else { return MeshChatTree.defaultHead(of: view.messages) }
        return headPinned ? head : MeshChatTree.leaf(descendingFrom: head, in: view.messages)
    }

    var displayRows: [MeshChatMapper.Row] {
        guard let view = currentChat else { return [] }
        return MeshChatMapper.rows(
            for: view, head: displayHead, streaming: currentTurn?.streamingText, resolved: resolvedHandles)
    }

    func open() async {
        if case .opening = phase { return }
        if phase == .ready { return }
        phase = .opening
        do {
            let makeKeys = makeKeys
            let keys = try await Task.detached { try makeKeys() }.value
            self.keys = keys
            restoredInstall = keys.wasRestored
            let config = MeshKernelConfig(
                dataDirectory: dataDirectory, deviceLabel: deviceLabel, deviceKind: deviceKind,
                operationsSecret: try keys.operationsSecret(), wrapSecret: try keys.wrapSecret(),
                installMarker: try keys.installMarker(), restoredInstall: keys.wasRestored, mailbox: mailboxAddress,
                deviceProfileJSON: MeshDeviceProfile.json(kind: deviceKind))
            let signer = MeshHostSigner(keys: keys, presenter: consent)
            let factory = makeKernel
            let model = onDeviceModel
            let tools = tools
            let listener = relay
            let opened = try await Task.detached { try await factory(config, signer, model, tools, listener) }.value
            kernel = opened
            phase = .ready
            do {
                try await Task.detached { try await opened.startNetwork() }.value
                networkNotice = nil
            } catch {
                networkNotice = Self.describe(error)
            }
            await refreshAll()
        } catch {
            var diagnosticCode = (error as NSError).code
            if case MeshSecretStoreError.keychain(let status) = error { diagnosticCode = Int(status) }
            Logger(subsystem: "com.personalailabs.astraldeep.mesh", category: "runtime").error(
                "mesh_open_failed type=\(String(reflecting: type(of: error)), privacy: .public) code=\(diagnosticCode, privacy: .public)")
            if mailboxAddress != nil, Self.isMailboxRefusal(error) {
                storeMailbox(nil)
                phase = .closed
                notice = KernelMapping.failureText(code: "config.mailbox") + " It was removed."
                await open()
                return
            }
            phase = .failed(Self.describe(error))
        }
    }

    func saveMailbox(_ text: String) async -> MeshMailboxInputError? {
        let address: String?
        switch MeshMailboxInput.validate(text) {
        case .failure(let error): return error
        case .success(let value): address = value
        }
        guard address != mailboxAddress else { return nil }
        storeMailbox(address)
        await close()
        await open()
        return nil
    }

    func refreshMailbox() async {
        if let value = await attempt({ $0.mailboxState() }) { mailbox = value }
    }

    private func storeMailbox(_ address: String?) {
        mailboxAddress = address
        if let address { defaults.set(address, forKey: Self.mailboxKey) } else { defaults.removeObject(forKey: Self.mailboxKey) }
    }

    private static func isMailboxRefusal(_ error: Error) -> Bool {
        guard case MeshKernelError.refused(let text) = error else { return false }
        return text == KernelMapping.failureText(code: "config.mailbox")
    }

    func close() async {
        wakeSession = UUID()
        for task in turnTasks.values { task.cancel() }
        turnTasks = [:]
        if let kernel { await Task.detached { await kernel.stopNetwork() }.value }
        kernel = nil
        phase = .closed
        status = .empty
        chats = []
        currentChat = nil
        currentChatId = nil
        attachmentDrafts = [:]
        attachmentSession = UUID()
        importingAttachment = false
        members = []
        pendingConsents = []
        runs = []
        proposals = []
        chatRequests = []
        requestsForMe = []
        toolEntries = []
        grantedTools = []
        meshGrants = []
        resolvedHandles = [:]
        mailbox = .off
        turns = [:]
    }

    func settle() async {
        while relay.pending > 0 || !turnTasks.isEmpty {
            for task in Array(turnTasks.values) { await task.value }
            await Task.yield()
        }
    }

    func synchronizeAfterWake(
        waitForChange: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws -> Bool {
        guard isReady, status.hasMesh, let kernel else { return false }
        let session = wakeSession
        let revision = wakeDataRevision
        let meshId = status.meshId
        let deviceId = status.deviceId
        try await Task.detached { try await kernel.syncNow() }.value
        while !Task.isCancelled, isReady, status.hasMesh, wakeSession == session,
            status.meshId == meshId, status.deviceId == deviceId
        {
            if wakeDataRevision != revision { return true }
            try await waitForChange()
        }
        return false
    }

    func refreshAll() async {
        await refreshStatus()
        guard status.hasMesh else { return }
        await refreshRoster()
        await refreshChats()
        await refreshRequests()
        await refreshSync()
        await refreshConsents()
        await refreshAllowance()
        await refreshProviders()
        await refreshRuns()
        await refreshProposals()
        _ = try? await call { try $0.publishToolCatalog() }
        await refreshTools()
        await refreshMailbox()
        if let id = currentChatId { await reloadChat(id) }
    }

    func refreshStatus() async {
        if let value = await attempt({ try await $0.meshStatus() }) {
            status = value
            if value.hasMesh, join != .idle, join != .joined {
                join = .joined
                keys?.acknowledgeRestore()
                restoredInstall = false
            }
        }
    }

    func refreshRoster() async {
        if let value = await attempt({ try await $0.roster() }) { members = value }
    }

    func refreshChats() async {
        if let value = await attempt({ try $0.listChats() }) { chats = value }
    }

    func refreshTools() async {
        if let value = await attempt({ $0.tools() }) { toolEntries = value }
        if let value = await attempt({ try $0.grants() }) {
            meshGrants = value.filter { $0.refusal == nil }
            grantedTools = Set(meshGrants.map(\.key))
        }
    }

    func isGranted(_ tool: MeshToolEntry) -> Bool { grantedTools.contains(tool.grantKey) }

    func grant(for tool: MeshToolEntry) -> MeshGrant? { meshGrants.first { $0.key == tool.grantKey } }

    func grant(_ tool: MeshToolEntry) async {
        let name = tool.grantTarget
        let scope = tool.scope
        let granted: Void? = await attempt { try $0.grantTool(name: name, scope: scope) }
        guard granted != nil else { return }
        await refreshTools()
    }

    func revoke(_ tool: MeshToolEntry) async {
        let name = tool.grantTarget
        let scope = tool.scope
        let revoked: Void? = await attempt { try $0.revokeTool(name: name, scope: scope) }
        guard revoked != nil else { return }
        await refreshTools()
    }

    func refreshRequests() async {
        if let value = await attempt({ try $0.pendingRequestsForMe() }) { requestsForMe = value }
    }

    func memberLabel(_ memberId: String?) -> String {
        guard let memberId else { return "A device" }
        return members.first { $0.memberId == memberId }?.label ?? "Another device"
    }

    func sendRequest(_ text: String, to member: MeshMember, in chatId: String? = nil) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !member.isThisDevice else { return false }
        if status.stopped {
            notice = MeshKernelError.stopped.message
            return false
        }
        let chat: String
        if let chatId = chatId ?? currentChatId {
            chat = chatId
        } else if let created = await attempt({ [title = Self.title(from: trimmed)] in try $0.createChat(title: title) }) {
            chat = created
        } else {
            return false
        }
        let memberId = member.memberId
        guard await attempt({ try $0.sendRequest(chatId: chat, text: trimmed, toMember: memberId) }) != nil else {
            return false
        }
        await refreshChats()
        if chat == currentChatId { await reloadChat(chat) }
        return true
    }

    func answer(_ request: MeshRequest) async {
        let id = request.requestId
        guard turns[request.chatId]?.running != true else {
            notice = "This chat is already answering. Try again when it finishes."
            return
        }
        startTurn(chatId: request.chatId, announcesFailure: true) { try await $0.answerRequest(requestId: id) }
        await Task.yield()
        await refreshRequests()
        if request.chatId == currentChatId { await reloadChat(request.chatId) }
    }

    func refuse(_ request: MeshRequest, because reason: MeshRequestRefusal) async {
        let id = request.requestId
        await perform { try $0.refuseRequest(requestId: id, code: reason.rawValue) }
        await refreshRequests()
        if request.chatId == currentChatId { await reloadChat(request.chatId) }
    }

    func refreshSync() async {
        if let value = await attempt({ try await $0.syncState() }) { sync = value }
    }

    func refreshConsents() async {
        if let value = await attempt({ try $0.pendingConsents() }) {
            pendingConsents = value
            speechSink?.setRiskyActionPending(!value.isEmpty)
        }
    }

    func refreshAllowance() async {
        if let value = await attempt({ try $0.allowance() }) { allowance = value }
    }

    func refreshProviders() async {
        if let value = await attempt({ try $0.modelProviders() }) { providers = value }
    }

    func refreshRuns() async {
        if let value = await attempt({ try await $0.runs() }) { runs = value }
    }

    func refreshProposals() async {
        if let value = await attempt({ try await $0.learningProposals() }) { proposals = value }
    }

    func handOff(_ run: MeshRun, to member: MeshMember) async {
        await perform { try await $0.handOffRun(runId: run.runId, memberId: member.memberId) }
        await refreshRuns()
    }

    func takeOver(_ run: MeshRun) async -> MeshTakeOver? {
        do {
            let result = try await call { try await $0.takeOverRun(runId: run.runId) }
            await refreshRuns()
            return result
        } catch {
            if let hosting = error as? HostSigningError, case .consentDenied = hosting {
                notice = MeshKernelError.consentDenied.message
            } else {
                notice = Self.describe(error)
            }
            await refreshRuns()
            return nil
        }
    }

    func review(_ proposal: MeshProposal, adopt: Bool) async -> MeshEvaluation? {
        let result = await attempt({ try await $0.reviewProposal(id: proposal.proposalId, adopt: adopt) })
        await refreshProposals()
        return result
    }

    func undo(_ proposal: MeshProposal) async {
        await perform { try await $0.undoAdoption(id: proposal.proposalId) }
        await refreshProposals()
    }

    func createMesh() async {
        guard kernel != nil, creation == .idle || isFailedCreation else { return }
        creation = .signingIn
        do {
            let request = try await call { try $0.beginMeshCreation() }
            let token = try await enrollment(request.nonce)
            creation = .finishing
            let kit = try await call { try $0.completeMeshCreation(idToken: token) }
            keys?.acknowledgeRestore()
            restoredInstall = false
            creation = .recovery(kit.words)
            await refreshStatus()
            await refreshRoster()
        } catch {
            creation = .failed(Self.describe(error))
        }
    }

    func confirmRecoveryWritten(answers: [String]) -> Bool {
        guard case .recovery(let words) = creation, MeshRecoveryConfirmation.verify(words: words, answers: answers)
        else { return false }
        creation = .idle
        Task { await refreshAll() }
        return true
    }

    func dismissCreationFailure() {
        if isFailedCreation { creation = .idle }
    }

    func recoverMesh(words: String, backup: URL?) async {
        guard kernel != nil, restore == .idle || isFailedRestore else { return }
        let list = MeshRecoveryWords.normalize(words)
        guard list.count == MeshRecoveryWords.count else {
            restore = .failed(KernelMapping.failureText(code: "recovery.bad_length"))
            return
        }
        restore = .recovering
        let phrase = list.joined(separator: " ")
        let scoped = backup?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { backup?.stopAccessingSecurityScopedResource() } }
        do {
            let result = try await call { try $0.recoverWithWords(words: phrase, backupPath: backup?.path) }
            keys?.acknowledgeRestore()
            restoredInstall = false
            await refreshAll()
            let label = members.first(where: \.isThisDevice)?.label ?? deviceLabel
            restore = .restored(
                MeshRestoredMesh(
                    meshId: result.meshId, deviceId: result.deviceId, deviceLabel: label, memberCount: members.count,
                    eventsImported: result.eventsImported))
        } catch {
            restore = .failed(Self.describe(error))
        }
    }

    func dismissRestoreFailure() {
        if isFailedRestore { restore = .idle }
    }

    func finishRestore() {
        if case .restored = restore { restore = .idle }
    }

    func beginJoin() async {
        guard kernel != nil, join == .idle || isFailedJoin else { return }
        join = .starting
        do {
            join = .offered(try await call { try await $0.createPairingOffer() })
        } catch {
            join = .failed(Self.describe(error))
        }
    }

    func cancelJoin() {
        join = .idle
        Task { await perform { $0.cancelPairingOffer() } }
    }

    func acceptInvitation(payload: String) async {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kernel != nil, join == .idle || isFailedJoin else { return }
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192 else {
            join = .failed("That is not an invitation from one of your devices.")
            return
        }
        join = .starting
        do {
            join = .accepted(try await call { try await $0.acceptInvitation(payload: trimmed) })
        } catch {
            join = .failed(Self.describe(error))
        }
    }

    func startInvitation() async {
        guard kernel != nil, invite != .creating, invite != .approving else { return }
        invite = .creating
        do {
            invite = .waiting(try await call { try await $0.createInvitation() })
        } catch {
            invite = .failed(Self.describe(error))
        }
    }

    func approveInvitation() async {
        guard case .requested(let request) = invite else { return }
        invite = .approving
        do {
            try await call { try await $0.approveInvitation() }
            invite = .added(request.deviceLabel)
            await refreshRoster()
            await refreshSync()
        } catch MeshKernelError.consentDenied {
            invite = .failed("Adding the device was not approved.")
        } catch {
            invite = .failed(Self.describe(error))
        }
    }

    func cancelInvitation() async {
        let active: Bool
        switch invite {
        case .waiting, .requested: active = true
        default: active = false
        }
        invite = .idle
        if active { _ = try? await call { await $0.cancelInvitation() } }
    }

    func resetInvite() { invite = .idle }

    func renameDevice(_ member: MeshMember, to label: String) async -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != member.label else { return false }
        let id = member.memberId
        guard await attempt({ try $0.renameDevice(memberId: id, label: trimmed) }) != nil else { return false }
        await refreshRoster()
        return true
    }

    func previewAddDevice(payload: String) async {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192 else {
            addDevice = .failed("That is not a pairing code from one of your devices.")
            return
        }
        do {
            addDevice = .previewing(try await call { try $0.previewPairing(payload: trimmed) }, payload: trimmed)
        } catch {
            addDevice = .failed(Self.describe(error))
        }
    }

    func approveAddDevice() async {
        guard case .previewing(let preview, let payload) = addDevice else { return }
        addDevice = .approving
        do {
            try await call { try await $0.approvePairing(payload: payload) }
            addDevice = .added(preview.deviceLabel)
            await refreshRoster()
            await refreshSync()
        } catch MeshKernelError.consentDenied {
            addDevice = .failed("Adding the device was not approved.")
        } catch {
            addDevice = .failed(Self.describe(error))
        }
    }

    func resetAddDevice() { addDevice = .idle }

    func verifyIdentity() async {
        guard kernel != nil, verification != .signingIn else { return }
        verification = .signingIn
        do {
            let request = try await call { try $0.beginAttestation() }
            let token = try await enrollment(request.nonce)
            try await call { try $0.reattest(idToken: token) }
            verification = .idle
            await refreshStatus()
            await refreshRoster()
        } catch {
            verification = .failed(Self.describe(error))
        }
    }

    func dismissVerificationFailure() { verification = .idle }

    func removeDevice(_ member: MeshMember) async {
        guard !member.isThisDevice else { return }
        await perform { try $0.removeDevice(memberId: member.memberId) }
        await refreshRoster()
        await refreshSync()
    }

    func resume() async {
        await perform { try $0.resumeStop() }
        await refreshStatus()
        await refreshAllowance()
    }

    func raiseStop() async {
        await perform { try $0.raiseStop() }
        await refreshStatus()
        await refreshAllowance()
    }

    func openChat(_ chatId: String) async {
        currentChatId = chatId
        selectedHead = nil
        headPinned = false
        currentChat = nil
        chatRequests = []
        await reloadChat(chatId)
    }

    func closeChat() {
        currentChatId = nil
        currentChat = nil
        chatRequests = []
        selectedHead = nil
        headPinned = false
    }

    func newChat(title: String = "New chat") async -> String? {
        guard let id = await attempt({ try $0.createChat(title: title) }) else { return nil }
        await refreshChats()
        await openChat(id)
        return id
    }

    func selectBranch(head: String) {
        guard let view = currentChat, view.messages.contains(where: { $0.eventId == head }) else { return }
        selectedHead = head
        headPinned = false
    }

    func branchFrom(message: MeshChatMessage) async {
        guard let chatId = currentChatId else { return }
        if let eventId = await attempt({ try $0.fork(chatId: chatId, eventId: message.eventId) }) {
            selectedHead = eventId
            headPinned = true
        }
    }

    var draftAttachments: [MeshAttachment] {
        currentChatId.flatMap { attachmentDrafts[$0] } ?? []
    }

    func attachFile(_ url: URL) async -> Bool {
        guard !importingAttachment else { return false }
        guard !status.stopped else {
            notice = MeshKernelError.stopped.message
            return false
        }
        guard currentTurn?.running != true else {
            notice = "Wait for the current answer before attaching a file."
            return false
        }
        let chatId: String
        if let current = currentChatId { chatId = current }
        else if let created = await newChat() { chatId = created }
        else { return false }
        guard attachmentDrafts[chatId, default: []].count < MeshAttachmentFile.maximumCount else {
            notice = "A message can hold up to eight files."
            return false
        }
        importingAttachment = true
        let session = attachmentSession
        defer { if attachmentSession == session { importingAttachment = false } }
        guard let attachment = await attempt({ kernel in
            let input = try MeshAttachmentFile.read(url)
            return try kernel.addAttachment(chatId: chatId, bytes: input.bytes, mime: input.mime, name: input.name)
        }) else { return false }
        guard attachmentSession == session else { return false }
        attachmentDrafts[chatId, default: []].append(attachment)
        await refreshChats()
        return true
    }

    func removeDraftAttachment(_ id: String) {
        guard let chatId = currentChatId else { return }
        attachmentDrafts[chatId]?.removeAll { $0.id == id }
    }

    func attachmentBytes(_ attachment: MeshAttachment) async -> Data? {
        guard attachment.availability == .present else {
            notice = "This file is not available on this device."
            return nil
        }
        return await attempt { try await $0.fetchAttachment(handle: attachment.handle) }
    }

    func send(_ text: String, speaking: Bool = false) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !draftAttachments.isEmpty, !importingAttachment else { return false }
        if status.stopped {
            notice = MeshKernelError.stopped.message
            return false
        }
        let chatId: String
        if let current = currentChatId {
            chatId = current
        } else if let created = await newChat(title: Self.title(from: trimmed)) {
            chatId = created
        } else {
            return false
        }
        let attachments = attachmentDrafts[chatId, default: []].map(\.id)
        let continues = displayHead
        guard let eventId = await attempt({ kernel in
            if attachments.isEmpty { return try kernel.sendMessage(chatId: chatId, text: trimmed, continues: continues) }
            return try kernel.sendMessage(chatId: chatId, text: trimmed, continues: continues, attachments: attachments)
        })
        else { return false }
        attachmentDrafts[chatId] = nil
        selectedHead = eventId
        headPinned = false
        await reloadChat(chatId)
        if speaking { speakingChatId = chatId }
        startTurn(chatId: chatId)
        return true
    }

    func steer(_ text: String) async {
        guard let chatId = currentChatId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform { try $0.steer(chatId: chatId, text: trimmed) }
    }

    func interrupt() async {
        guard let chatId = currentChatId else { return }
        await interrupt(chatId: chatId)
    }

    func interrupt(chatId: String) async {
        guard turns[chatId]?.running == true, turns[chatId]?.interrupted != true else { return }
        turns[chatId]?.interrupted = true
        await perform { try $0.interrupt(chatId: chatId) }
    }

    func review(_ request: MeshPendingConsent) async {
        do {
            try await call { try $0.resolveConsent(requestId: request.requestId, approve: true) }
        } catch {
            if case MeshKernelError.consentDenied = error {
                await perform { try $0.resolveConsent(requestId: request.requestId, approve: false) }
            } else if let hosting = error as? HostSigningError, case .consentDenied = hosting {
                await perform { try $0.resolveConsent(requestId: request.requestId, approve: false) }
            } else {
                notice = Self.describe(error)
            }
        }
        await refreshConsents()
    }

    func deny(_ request: MeshPendingConsent) async {
        await perform { try $0.resolveConsent(requestId: request.requestId, approve: false) }
        await refreshConsents()
    }

    func resolveUnknown(_ outcome: MeshUnknownOutcome, choice: MeshUnknownChoice) async {
        acknowledgedOutcomes.insert(outcome.stepId)
        defaults.set(Array(acknowledgedOutcomes).sorted(), forKey: Self.acknowledgedKey)
        guard choice == .checkFirst, currentChatId != nil else { return }
        _ = await send("Before doing anything else, check whether \(outcome.tool) already completed. Do not repeat it.")
    }

    func act(surfaceId: String, componentId: String, capability: String, args: [String: JSONValue] = [:]) async {
        let result = await attempt {
            try await $0.act(surfaceId: surfaceId, componentId: componentId, capability: capability, args: args)
        }
        guard let result else { return }
        if result.refused {
            notice = KernelMapping.failureText(code: result.code ?? result.status, fallback: "That action did not run.")
        }
        if let chatId = currentChatId { await reloadChat(chatId) }
    }

    func saveProvider(baseURL: String, model: String, key: String) async -> MeshProviderInputError? {
        switch MeshProviderInput.validate(baseURL: baseURL, model: model, key: key) {
        case .failure(let error):
            return error
        case .success(let config):
            await perform { try $0.setModelProvider(config) }
            await refreshProviders()
            return nil
        }
    }

    func exportBackup(to url: URL) async {
        await perform { try $0.exportBackup(path: url.path) }
    }

    func submitVoice(_ turn: OwnerVoiceTurn) async {
        guard turn.integrity == .owner, turn.source == .deviceMicrophone else {
            notice = "A spoken transcript from a file or call is not treated as your message."
            return
        }
        _ = await send(turn.text, speaking: true)
    }

    func recordSpoken(_ record: VoiceSpokenRecord) async {
        spoken.append(record)
        guard let chatId = speakingChatId ?? currentChatId else { return }
        await perform { try $0.recordSpoken(chatId: chatId, kind: record.kind, text: record.text) }
    }

    func cancelVoiceTool(id: String) async {
        guard let chatId = speakingChatId ?? currentChatId,
            turns[chatId]?.tools.first(where: { $0.id == id })?.cancelSafe == true
        else { return }
        await interrupt(chatId: chatId)
    }

    func outcomeNeedsAttention(_ outcome: MeshUnknownOutcome) -> Bool {
        !acknowledgedOutcomes.contains(outcome.stepId)
    }

    func prompt(for request: MeshPendingConsent) -> ConsentPrompt? {
        switch request.kind {
        case .action:
            if request.signingInput.isEmpty {
                return try? ConsentPrompt.pending(
                    canonicalAction: request.canonicalAction, canonicalArguments: request.canonicalArguments)
            }
            return try? ConsentPrompt.action(
                canonicalAction: request.canonicalAction, canonicalArguments: request.canonicalArguments,
                signingInput: request.signingInput)
        case .roster:
            return try? ConsentPrompt.roster(signingInput: request.signingInput)
        }
    }

    private var isFailedCreation: Bool {
        if case .failed = creation { return true }
        return false
    }

    private var isFailedRestore: Bool {
        if case .failed = restore { return true }
        return false
    }

    private var isFailedJoin: Bool {
        if case .failed = join { return true }
        return false
    }

    private func startTurn(
        chatId: String, announcesFailure: Bool = false, run: (@Sendable (any MeshKernel) async throws -> Void)? = nil
    ) {
        turns[chatId] = MeshTurnState(turnId: "", running: true)
        turnTasks[chatId]?.cancel()
        turnTasks[chatId] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.call { kernel in
                    if let run { try await run(kernel) } else { try await kernel.runTurn(chatId: chatId) }
                }
            } catch {
                if announcesFailure { self.notice = Self.describe(error) }
                if self.turns[chatId]?.interrupted != true, var state = self.turns[chatId] {
                    self.record(failure: Self.describe(error), in: &state)
                    self.turns[chatId] = state
                }
                self.turns[chatId]?.running = false
            }
            self.turnTasks[chatId] = nil
        }
    }

    private func reloadChat(_ chatId: String) async {
        guard let view = await attempt({ try $0.chat(chatId: chatId) }) else { return }
        guard currentChatId == chatId else { return }
        await resolveHandles(in: view)
        guard currentChatId == chatId else { return }
        currentChat = view
        if let index = chats.firstIndex(where: { $0.chatId == chatId }) {
            chats[index].queuedCount = view.messages.filter { $0.delivery == .queued }.count
        }
        if let value = await attempt({ try $0.chatRequests(chatId: chatId) }), currentChatId == chatId {
            chatRequests = value
        }
        if let head = selectedHead, !view.messages.contains(where: { $0.eventId == head }) {
            selectedHead = nil
            headPinned = false
        }
        if case .outcomeUnknown(let outcome) = view.status, turns[chatId]?.unknown.contains(outcome) != true {
            var state = turns[chatId] ?? MeshTurnState(turnId: "", running: false)
            state.unknown.append(outcome)
            turns[chatId] = state
        }
    }

    private func resolveHandles(in view: MeshChatView) async {
        let wanted = Set(view.rendered.flatMap(MeshRenderedMapper.handles(in:))).subtracting(resolvedHandles.keys)
        let chatId = view.chatId
        for handle in wanted.sorted() {
            if let value = try? await call({ try $0.resolveHandle(chatId: chatId, handle: handle) }) {
                resolvedHandles[handle] = value
            }
        }
    }

    private func handle(_ change: MeshKernelChange) async {
        guard kernel != nil else { return }
        switch change {
        case .chatChanged(let chatId):
            await refreshChats()
            await refreshRequests()
            if let current = currentChatId, chatId == nil || chatId == current { await reloadChat(current) }
        case .syncStateChanged:
            await refreshSync()
            await refreshMailbox()
        case .consentRequested:
            await refreshConsents()
        case .rosterChanged:
            await refreshStatus()
            await refreshRoster()
            await refreshSync()
        case .turnProgress(let progress):
            await apply(progress)
        case .allowanceChanged:
            await refreshAllowance()
        case .runProgress:
            await refreshRuns()
        case .joinRequested(let request):
            if case .waiting = invite { invite = .requested(request) }
        case .pairingFailed(let code):
            let message = KernelMapping.failureText(code: code)
            switch invite {
            case .waiting, .requested: invite = .failed(message)
            default: break
            }
            switch join {
            case .offered, .accepted: join = .failed(message)
            default: break
            }
        }
        switch change {
        case .chatChanged, .rosterChanged, .allowanceChanged, .runProgress: wakeDataRevision = UUID()
        default: break
        }
    }

    private func apply(_ progress: MeshTurnProgress) async {
        var state = turns[progress.chatId] ?? MeshTurnState(turnId: progress.turnId, running: true)
        state.turnId = progress.turnId
        let speaking = speakingChatId == progress.chatId
        switch progress.event {
        case .started:
            state = MeshTurnState(turnId: progress.turnId, running: true)
        case .assistantDelta(let text):
            state.streamingText += text
            if speaking { speechSink?.answerDelta(text) }
        case .assistantFinished:
            if speaking { speechSink?.answerFinished() }
        case .toolStarted(let id, let name, let cancelSafe):
            state.tools.append(MeshToolActivity(id: id, name: name, cancelSafe: cancelSafe, state: .running))
            if speaking { speechSink?.toolStarted(id: id, cancelSafe: cancelSafe) }
        case .toolFinished(let id, let succeeded):
            if let index = state.tools.firstIndex(where: { $0.id == id }) {
                state.tools[index].state = succeeded ? .succeeded : .failed
            }
            if speaking { speechSink?.toolFinished(id: id) }
        case .awaitingConsent(let requestId):
            state.awaitingConsent = requestId
            await refreshConsents()
        case .outcomeUnknown(let outcome):
            if !state.unknown.contains(outcome) { state.unknown.append(outcome) }
        case .finished:
            state.running = false
            state.awaitingConsent = nil
            turns[progress.chatId] = state
            if progress.chatId == currentChatId { await reloadChat(progress.chatId) }
            state.streamingText = ""
            if speaking { speakingChatId = nil }
        case .interrupted:
            state.running = false
            state.interrupted = true
            state.awaitingConsent = nil
            if speaking { speakingChatId = nil }
        case .failed(let reason):
            state.running = false
            record(failure: reason, in: &state)
            if speaking { speakingChatId = nil }
        }
        turns[progress.chatId] = state
    }

    private func record(failure text: String, in state: inout MeshTurnState) {
        if text == KernelMapping.failureText(code: "provider."), providers.isEmpty, onDeviceModelAvailable {
            state.answeredOnDevice = true
            state.failure = nil
        } else {
            state.failure = text
        }
    }

    private func call<T: Sendable>(_ work: @escaping @Sendable (any MeshKernel) async throws -> T) async throws -> T {
        guard let kernel else { throw MeshKernelError.unavailable("The mesh is not open.") }
        return try await Task.detached(priority: .userInitiated) { try await work(kernel) }.value
    }

    private func attempt<T: Sendable>(_ work: @escaping @Sendable (any MeshKernel) async throws -> T) async -> T? {
        do {
            return try await call(work)
        } catch {
            notice = Self.describe(error)
            return nil
        }
    }

    private func perform(_ work: @escaping @Sendable (any MeshKernel) async throws -> Void) async {
        _ = await attempt(work)
    }

    private static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 48 ? String(line.prefix(48)) + "..." : line
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let kernel = error as? MeshKernelError { return kernel.message }
        if let signing = error as? HostSigningError {
            switch signing {
            case .consentDenied: return MeshKernelError.consentDenied.message
            case .digestMismatch: return "The approval did not match the request, so nothing was signed."
            case .calledOnMainThread: return "The approval could not be shown."
            }
        }
        if let enrollment = error as? EnrollmentSignInError {
            switch enrollment {
            case .cancelled: return "Sign-in was cancelled."
            default: return "Sign-in could not be completed."
            }
        }
        return "Something went wrong. Try again."
    }
}
