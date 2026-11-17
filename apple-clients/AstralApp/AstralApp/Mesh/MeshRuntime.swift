// The observable model that owns the kernel handle for mesh mode, opens it with the device custody keys, and publishes what the screens show.
// Kernel callbacks arrive on any thread, are queued in order, and refresh published state on the main actor; every kernel call runs off the main thread.

import AstralCore
import Foundation
import OSLog
import Observation

@MainActor
protocol MeshSpeechSink: AnyObject {
    func answerDelta(_ text: String)
    func answerFinished()
    func toolStarted(id: String, cancelSafe: Bool)
    func toolFinished(id: String)
    func setRiskyActionPending(_ pending: Bool)
}

extension OnDeviceVoiceController: MeshSpeechSink {}

nonisolated final class MeshSessionListener: MeshKernelListening, @unchecked Sendable {
    private let session: UUID
    private let relay: MeshChangeRelay

    init(session: UUID, relay: MeshChangeRelay) {
        self.session = session
        self.relay = relay
    }

    func onChange(_ change: MeshKernelChange) { relay.onChange(change, session: session) }
}

nonisolated final class MeshChangeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<(UUID, MeshKernelChange)>.Continuation?
    private var queued = 0
    let stream: AsyncStream<(UUID, MeshKernelChange)>

    init() {
        var captured: AsyncStream<(UUID, MeshKernelChange)>.Continuation?
        stream = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
    }

    var pending: Int { lock.withLock { queued } }

    func onChange(_ change: MeshKernelChange, session: UUID) {
        lock.withLock { queued += 1 }
        continuation?.yield((session, change))
    }

    func handled() { lock.withLock { queued -= 1 } }

    func finish() { continuation?.finish() }
}

nonisolated final class MeshSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var current: Bool { lock.withLock { active } }
    func retire() { lock.withLock { active = false } }
}

nonisolated final class MeshTurnLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var retired = false
    private var completed = false
    private var interrupted = false
    private var entered = false
    private var cancelledPending = false
    private var cancellationError: Error?

    func enter() -> Bool {
        lock.withLock {
            guard !retired else { return false }
            entered = true
            return true
        }
    }
    func retire() { lock.withLock { retired = true } }
    func finish() { lock.withLock { completed = true } }
    func acknowledgeInterrupt() { lock.withLock { interrupted = true } }
    var finished: Bool { lock.withLock { completed } }
    var retiring: Bool { lock.withLock { retired } }
    func acknowledgePendingCancellation() { lock.withLock { cancelledPending = true } }
    func rejectPendingCancellation(_ error: Error) { lock.withLock { cancellationError = error } }
    var interruptionAccepted: Bool { lock.withLock { interrupted || cancelledPending } }
    var retirementFailure: Error? {
        lock.withLock { !entered && !interrupted && !cancelledPending ? cancellationError : nil }
    }
}

nonisolated final class MeshTurnWork: @unchecked Sendable {
    let id: UUID
    let task: Task<Result<MeshActResult?, Error>, Never>
    private let lifetime: MeshTurnLifetime
    private let kernel: any MeshKernel
    private let chatId: String
    private let lock = NSLock()
    private var retirement: Task<Void, Never>?
    private let waitForRetry: @Sendable (Duration) async -> Void
    private let interruptOperation: (@Sendable (any MeshKernel, String) throws -> Bool)?
    private let steerOperation: (@Sendable (any MeshKernel, String, String) throws -> Bool)?
    private let cancelPendingOperation: (@Sendable (any MeshKernel, String) async throws -> Void)?

    init(
        id: UUID, kernel: any MeshKernel, chatId: String,
        waitForEntry: @escaping @Sendable () async -> Void = {},
        waitForRetry: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        interrupt: (@Sendable (any MeshKernel, String) throws -> Bool)? = nil,
        steer: (@Sendable (any MeshKernel, String, String) throws -> Bool)? = nil,
        cancelPending: (@Sendable (any MeshKernel, String) async throws -> Void)? = nil,
        operation: @escaping @Sendable (any MeshKernel) async throws -> MeshActResult?
    ) {
        self.id = id
        self.kernel = kernel
        self.chatId = chatId
        self.waitForRetry = waitForRetry
        interruptOperation = interrupt
        steerOperation = steer
        cancelPendingOperation = cancelPending
        let lifetime = MeshTurnLifetime()
        self.lifetime = lifetime
        task = Task.detached(priority: .userInitiated) {
            defer { lifetime.finish() }
            await waitForEntry()
            guard lifetime.enter() else { return .success(nil) }
            do { return .success(try await operation(kernel)) } catch { return .failure(error) }
        }
    }

    func steer(_ text: String) throws -> Bool {
        guard !lifetime.retiring, !lifetime.finished, let steerOperation else { return false }
        return try steerOperation(kernel, chatId, text)
    }

    var retiring: Bool { lifetime.retiring }
    var interruptionAccepted: Bool { lifetime.interruptionAccepted }
    var retirementFailure: Error? { lifetime.retirementFailure }

    func retire(explicitStop: Bool = false) -> Task<Void, Never> {
        lifetime.retire()
        return lock.withLock {
            if let retirement { return retirement }
            let lifetime = lifetime
            let kernel = kernel
            let chatId = chatId
            let worker = task
            let waitForRetry = waitForRetry
            let interruptOperation = interruptOperation
            let cancelPending = explicitStop ? cancelPendingOperation : nil
            let retirement = Task.detached {
                let cancellation = cancelPending.map { operation in
                    Task.detached {
                        do {
                            try await operation(kernel, chatId)
                            lifetime.acknowledgePendingCancellation()
                        } catch {
                            lifetime.rejectPendingCancellation(error)
                        }
                    }
                }
                if let interruptOperation {
                    var delay = 20
                    while !lifetime.finished {
                        if (try? interruptOperation(kernel, chatId)) == true {
                            lifetime.acknowledgeInterrupt()
                            break
                        }
                        await waitForRetry(.milliseconds(delay))
                        delay = min(delay * 2, 250)
                    }
                }
                _ = await worker.value
                await cancellation?.value
            }
            self.retirement = retirement
            return retirement
        }
    }
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
    var restored = false
    var notice: String?
    var completionWarning: String?
    var tools: [MeshToolActivity] = []
    var awaitingConsent: String?
    var unknown: [MeshUnknownOutcome] = []
    var failure: String?
    var phiOffer: MeshPhiOffer?
    var answeredOnDevice = false
    var interrupted = false
    var stopRequested = false
}

nonisolated enum MeshCreationState: Equatable, Sendable {
    case idle
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
    case missingRecipients
    case saving
    case failed(String)

    var message: String {
        switch self {
        case .invalidURL: return "Enter the base URL of an OpenAI-compatible service."
        case .insecureURL: return "Use an https address. Plain http is allowed only for this device."
        case .missingModel: return "Enter a model name."
        case .missingKey: return "Enter the API key."
        case .missingRecipients: return "Select at least one device."
        case .saving: return "Wait for the current provider save to finish."
        case .failed(let message): return message
        }
    }
}

nonisolated enum MeshProviderInput {
    static func validate(baseURL: String, model: String, key: String, recipients: [String]? = nil) -> Result<
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
        guard recipients?.isEmpty != true else { return .failure(.missingRecipients) }
        return .success(MeshModelProviderConfig(baseURL: base, model: name, apiKey: secret, recipients: recipients))
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
    private(set) var meshAuthorityRevision = UUID()
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
    private(set) var connections: [MeshConnection] = []
    var presentingPhi: MeshPhiOffer?
    private(set) var phiOffer: MeshPhiOffer?
    private(set) var allowance: MeshAllowance?
    private(set) var providers: [MeshModelProvider] = []
    private(set) var savingProvider = false
    private(set) var runs: [MeshRun] = []
    private(set) var proposals: [MeshProposal] = []
    private(set) var toolEntries: [MeshToolEntry] = []
    private(set) var callerTickets: [MeshCallerTicket] = []
    private(set) var grantedTools: Set<String> = []
    private(set) var meshGrants: [MeshGrant] = []
    private(set) var resolvedHandles: [String: MeshResolvedHandle] = [:]
    private(set) var mailbox = MeshMailboxState.off
    private(set) var mailboxAddress: String?
    private(set) var chatRequests: [MeshRequest] = []
    private(set) var requestsForMe: [MeshRequest] = []
    private(set) var confirmingRecovery = false
    private(set) var creation = MeshCreationState.idle
    private(set) var join = MeshJoinState.idle
    private(set) var restore = MeshRestoreState.idle
    private(set) var addDevice = MeshAddDeviceState.idle
    private(set) var invite = MeshInviteState.idle
    private(set) var acknowledgedOutcomes: Set<String> = []
    private(set) var spoken: [VoiceSpokenRecord] = []
    private(set) var restoredInstall = false
    private(set) var networkNotice: String?
    var notice: String?
    @ObservationIgnored weak var speechSink: MeshSpeechSink?

    @ObservationIgnored private var kernel: (any MeshKernel)?
    @ObservationIgnored private var keys: DeviceKeys?
    @ObservationIgnored private var wakeSession = UUID()
    @ObservationIgnored private var wakeSessionGate = MeshSessionGate()
    @ObservationIgnored private var wakeDataRevision = UUID()
    @ObservationIgnored private let relay = MeshChangeRelay()
    @ObservationIgnored nonisolated(unsafe) private var consumer: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var turnTasks: [String: MeshTurnWork] = [:]
    @ObservationIgnored private var turnReservations: [String: UUID] = [:]
    @ObservationIgnored private var supersededTurns: [String: Set<String>] = [:]
    @ObservationIgnored private var recoveryScan: UUID?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private(set) var speakingChatId: String?
    @ObservationIgnored private var voiceSessionChatId: String?
    @ObservationIgnored private var lastOpenedChatId: String?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private let makeKernel: MeshKernelFactory
    @ObservationIgnored private let makeKeys: @Sendable () throws -> DeviceKeys
    @ObservationIgnored private let consent: ConsentCoordinator
    @ObservationIgnored private let onDeviceModel: any AstralOnDeviceModel
    @ObservationIgnored private let tools: any MeshLocalTools
    @ObservationIgnored private let dataDirectory: URL
    @ObservationIgnored private let deviceLabel: String
    @ObservationIgnored private let deviceKind: MeshDeviceKind
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let waitForTurnEntry: @Sendable () async -> Void
    @ObservationIgnored let phiPrompts: MeshPhiPromptCenter

    private static let acknowledgedKey = "astral.mesh.v2.acknowledged-outcomes"
    private static let mailboxKey = "astral.mesh.v2.mailbox"

    init(
        makeKernel: @escaping MeshKernelFactory,
        makeKeys: @escaping @Sendable () throws -> DeviceKeys,
        consent: ConsentCoordinator,
        onDeviceModel: any AstralOnDeviceModel,
        tools: any MeshLocalTools,
        dataDirectory: URL,
        deviceLabel: String,
        deviceKind: MeshDeviceKind,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        waitForTurnEntry: @escaping @Sendable () async -> Void = {},
        phiPrompts: MeshPhiPromptCenter? = nil
    ) {
        self.phiPrompts = phiPrompts ?? MeshPhiPromptCenter()
        self.makeKernel = makeKernel
        self.makeKeys = makeKeys
        self.consent = consent
        self.onDeviceModel = onDeviceModel
        self.tools = tools
        self.dataDirectory = dataDirectory
        self.deviceLabel = deviceLabel
        self.deviceKind = deviceKind
        self.defaults = defaults
        self.now = now
        self.waitForTurnEntry = waitForTurnEntry
        acknowledgedOutcomes = Set(defaults.stringArray(forKey: Self.acknowledgedKey) ?? [])
        mailboxAddress = defaults.string(forKey: Self.mailboxKey)
        let relay = relay
        consumer = Task { [weak self] in
            for await (session, change) in relay.stream {
                await self?.handle(change, session: session)
                relay.handled()
            }
        }
    }

    deinit {
        consumer?.cancel()
        relay.finish()
        for work in turnTasks.values { _ = work.retire() }
    }

    var voiceChatId: String? { voiceSessionChatId ?? speakingChatId }
    var isReady: Bool { phase == .ready }
    var hasMesh: Bool { status.hasMesh && !status.recoveryPending }
    var currentTurn: MeshTurnState? { currentChatId.flatMap { turns[$0] } }
    var onDeviceModelAvailable: Bool { onDeviceModel.available() }
    var kernelVersion: String? { kernel?.version() }

    var syncSummary: MeshSyncSummary {
        let others = sync.devices.filter { device in
            members.first { $0.memberId == device.memberId }?.isThisDevice != true
        }
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
        if phase == .opening || closing { return }
        if phase == .ready {
            await refreshAll()
            return
        }
        phase = .opening
        wakeSessionGate.retire()
        wakeSessionGate = MeshSessionGate()
        wakeSession = UUID()
        let session = wakeSession
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
            let listener = MeshSessionListener(session: session, relay: relay)
            let opened = try await Task.detached { try await factory(config, signer, model, tools, listener) }.value
            guard wakeSession == session, phase == .opening else {
                await opened.stopNetwork()
                return
            }
            kernel = opened
            phase = .ready
            do {
                try await Task.detached { try await opened.startNetwork() }.value
                networkNotice = nil
            } catch {
                networkNotice = Self.describe(error)
            }
            guard wakeSession == session, isReady else {
                await opened.stopNetwork()
                return
            }
            await refreshAll()
        } catch {
            guard wakeSession == session else { return }
            var diagnosticCode = (error as NSError).code
            if case MeshSecretStoreError.keychain(let status) = error { diagnosticCode = Int(status) }
            Logger(subsystem: "com.personalailabs.astraldeep.mesh", category: "runtime").error(
                "mesh_open_failed type=\(String(reflecting: type(of: error)), privacy: .public) code=\(diagnosticCode, privacy: .public)"
            )
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
        if let value = await attempt({ try $0.mailboxState() }) { mailbox = value }
    }

    private func storeMailbox(_ address: String?) {
        mailboxAddress = address
        if let address {
            defaults.set(address, forKey: Self.mailboxKey)
        } else {
            defaults.removeObject(forKey: Self.mailboxKey)
        }
    }

    private static func isMailboxRefusal(_ error: Error) -> Bool {
        (error as? MeshKernelError)?.code == "config.mailbox"
    }

    func close() async {
        if closing {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        closing = true
        defer {
            closing = false
            let waiters = closeWaiters
            closeWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        phase = .closed
        wakeSessionGate.retire()
        wakeSession = UUID()
        let retiring = Array(turnTasks.values).map { $0.retire() }
        for task in retiring { await task.value }
        turnTasks = [:]
        turnReservations = [:]
        supersededTurns = [:]
        if let kernel {
            await Task.detached {
                await kernel.stopNetwork()
                await kernel.close()
            }.value
        }
        kernel = nil
        phase = .closed
        status = .empty
        creation = .idle
        chats = []
        currentChat = nil
        currentChatId = nil
        lastOpenedChatId = nil
        voiceSessionChatId = nil
        attachmentDrafts = [:]
        attachmentSession = UUID()
        importingAttachment = false
        members = []
        pendingConsents = []
        connections = []
        runs = []
        proposals = []
        chatRequests = []
        requestsForMe = []
        toolEntries = []
        callerTickets = []
        grantedTools = []
        meshGrants = []
        resolvedHandles = [:]
        mailbox = .off
        turns = [:]
    }

    func settle() async {
        while relay.pending > 0 || !turnTasks.isEmpty {
            for work in Array(turnTasks.values) { _ = await work.task.value }
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
        let session = wakeSession
        await refreshStatus()
        guard hasMesh else { return }
        await refreshRoster()
        await refreshChats()
        await refreshRequests()
        await refreshSync()
        await refreshConsents()
        await refreshConnections()
        await refreshAllowance()
        await refreshProviders()
        await refreshRuns()
        await refreshProposals()
        _ = try? await call { try $0.publishToolCatalog() }
        await refreshTools()
        await refreshMailbox()
        if let id = currentChatId { await reloadChat(id) }
        await recoverOrdinaryTurns(expectedSession: session)
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

    func refreshCallerTickets() async {
        if let value = await attempt({ try $0.callerTickets() }) { callerTickets = value }
    }

    func mintCallerTicket(
        nodeId: String, holderKey: String, label: String, toolNames: [String], a2a: Bool, lifetimeSeconds: UInt64
    ) async -> Result<MeshCallerTicket, MeshKernelError> {
        do {
            let ticket = try await call {
                try $0.mintCallerTicket(
                    nodeId: nodeId, holderKey: holderKey, label: label, toolNames: toolNames, a2a: a2a,
                    lifetimeSeconds: lifetimeSeconds)
            }
            await refreshCallerTickets()
            return .success(ticket)
        } catch let error as MeshKernelError {
            return .failure(error)
        } catch {
            return .failure(.refused(Self.describe(error)))
        }
    }

    func revokeCallerTicket(id: String) async -> MeshKernelError? {
        do {
            try await call { try $0.revokeCallerTicket(id: id) }
            await refreshCallerTickets()
            return nil
        } catch let error as MeshKernelError {
            return error
        } catch {
            return .refused(Self.describe(error))
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

    func sendRequest(_ text: String, to member: MeshMember) async -> Bool {
        await sendRequest(text, to: member, in: currentChatId)
    }

    func sendRequest(_ text: String, to member: MeshMember, in chatId: String?) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !member.isThisDevice else { return false }
        if status.stopped {
            notice = MeshKernelError.stopped.message
            return false
        }
        let chat: String
        if let chatId {
            chat = chatId
        } else if let created = await attempt({ [title = Self.title(from: trimmed)] in try $0.createChat(title: title) }
        ) {
            chat = created
        } else {
            return false
        }
        let memberId = member.memberId
        guard
            await attempt(allowRetired: true, { try $0.sendRequest(chatId: chat, text: trimmed, toMember: memberId) })
                != nil
        else {
            return false
        }
        await refreshChats()
        if chat == currentChatId { await reloadChat(chat) }
        return true
    }

    func answer(_ request: MeshRequest) async {
        let id = request.requestId
        guard turnReservations[request.chatId] == nil, turns[request.chatId]?.running != true else {
            notice = "This chat is already answering. Try again when it finishes."
            return
        }
        startTurn(
            chatId: request.chatId, announcesFailure: true,
            interrupt: { kernel, _ in try kernel.interruptRequest(requestId: id) },
            steer: { kernel, _, text in try kernel.steerRequest(requestId: id, text: text) },
            run: { try await $0.answerRequest(requestId: id) })
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

    func refreshConnections() async {
        if let value = await attempt({ try $0.connections() }) { connections = value }
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
        guard isReady, kernel != nil, creation == .idle || isFailedCreation else { return }
        let session = wakeSession
        notice = nil
        creation = .finishing
        do {
            let kit = try await call { try $0.createMesh() }
            guard isReady, wakeSession == session else { return }
            keys?.acknowledgeRestore()
            restoredInstall = false
            creation = .recovery(kit.words)
            await refreshStatus()
            await refreshRoster()
        } catch {
            guard isReady, wakeSession == session else { return }
            creation = .failed(Self.describe(error))
        }
    }

    func confirmRecoveryWritten(answers: [String]) async -> Bool {
        guard !confirmingRecovery, case .recovery(let words) = creation,
            MeshRecoveryConfirmation.verify(words: words, answers: answers)
        else { return false }
        confirmingRecovery = true
        notice = nil
        defer { confirmingRecovery = false }
        let session = wakeSession
        do {
            try await call { try $0.confirmMeshRecovery() }
            guard isReady, wakeSession == session else { return false }
            await refreshStatus()
            guard hasMesh else { return false }
            creation = .idle
            await refreshAll()
            return true
        } catch {
            guard isReady, wakeSession == session else { return false }
            notice = Self.describe(error)
            return false
        }
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
        lastOpenedChatId = chatId
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
        guard hasMesh else { return nil }
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
        if let current = currentChatId {
            chatId = current
        } else if let created = await newChat() {
            chatId = created
        } else {
            return false
        }
        guard attachmentDrafts[chatId, default: []].count < MeshAttachmentFile.maximumCount else {
            notice = "A message can hold up to eight files."
            return false
        }
        importingAttachment = true
        let session = attachmentSession
        let attended = phiPrompts.canShow
        defer { if attachmentSession == session { importingAttachment = false } }
        guard
            let attachment = await attempt({ kernel in
                let input = try MeshAttachmentFile.read(url)
                return try kernel.addAttachment(
                    chatId: chatId, bytes: input.bytes, mime: input.mime, name: input.name, attended: attended)
            })
        else { return false }
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
        let session = wakeSession
        guard let bytes = await attempt({ try await $0.fetchAttachment(handle: attachment.handle) }),
            isReady, wakeSession == session
        else { return nil }
        if let chatId = currentChatId { await reloadChat(chatId) }
        guard isReady, wakeSession == session else { return nil }
        return bytes
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
        guard let reservation = reserveTurn(chatId: chatId) else { return false }
        let session = wakeSession
        defer { releaseReservation(chatId: chatId, id: reservation) }
        let attachments = attachmentDrafts[chatId, default: []].map(\.id)
        let continues = displayHead
        let attended = !speaking && phiPrompts.canShow
        guard
            let eventId = await attempt(
                allowRetired: true,
                { kernel in
                    if attachments.isEmpty, !attended {
                        return try kernel.sendMessage(chatId: chatId, text: trimmed, continues: continues)
                    }
                    return try kernel.sendMessage(
                        chatId: chatId, text: trimmed, continues: continues, attachments: attachments,
                        attended: attended)
                })
        else { return false }
        guard isReady, wakeSession == session else { return true }
        attachmentDrafts[chatId] = nil
        selectedHead = eventId
        headPinned = false
        await reloadChat(chatId)
        if speaking { speakingChatId = chatId }
        startTurn(
            chatId: chatId, reservation: reservation,
            interrupt: { kernel, chat in try kernel.interruptMessage(chatId: chat, messageId: eventId) },
            steer: { kernel, chat, text in try kernel.steerMessage(chatId: chat, messageId: eventId, text: text) },
            cancelPending: { kernel, chat in try await kernel.cancelPendingMessage(chatId: chat, messageId: eventId) },
            run: { try await $0.runMessage(chatId: chatId, messageId: eventId) })
        return true
    }

    func send(_ text: String, to chatId: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isReady, hasMesh, !status.stopped, let meshId = status.meshId,
            chats.contains(where: { $0.chatId == chatId }), let reservation = reserveTurn(chatId: chatId)
        else { return false }
        let session = wakeSession
        defer { releaseReservation(chatId: chatId, id: reservation) }
        guard
            let eventId = await attempt(
                allowRetired: true,
                { kernel in
                    let head = MeshChatTree.defaultHead(of: try kernel.chat(chatId: chatId).messages)
                    return try kernel.sendMessage(chatId: chatId, text: trimmed, continues: head)
                })
        else { return false }
        guard isReady, wakeSession == session, status.meshId == meshId, !status.stopped else { return false }
        if currentChatId == chatId {
            selectedHead = eventId
            headPinned = false
            await reloadChat(chatId)
            guard isReady, wakeSession == session, status.meshId == meshId else { return false }
        }
        startTurn(
            chatId: chatId, reservation: reservation,
            interrupt: { kernel, chat in try kernel.interruptMessage(chatId: chat, messageId: eventId) },
            steer: { kernel, chat, text in try kernel.steerMessage(chatId: chat, messageId: eventId, text: text) },
            cancelPending: { kernel, chat in try await kernel.cancelPendingMessage(chatId: chat, messageId: eventId) },
            run: { try await $0.runMessage(chatId: chatId, messageId: eventId) })
        return true
    }

    func steer(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard isReady, !status.stopped, let chatId = currentChatId, let work = turnTasks[chatId], !work.retiring else {
            notice = "That turn did not accept the follow-up."
            return false
        }
        let session = wakeSession
        do {
            let accepted = try await Task.detached { try work.steer(trimmed) }.value
            if !accepted, wakeSession == session { notice = "That turn did not accept the follow-up." }
            return accepted
        } catch {
            if wakeSession == session { notice = Self.describe(error) }
            return false
        }
    }

    func interrupt() async {
        guard let chatId = currentChatId else { return }
        await interrupt(chatId: chatId)
    }

    func interrupt(chatId: String) async {
        guard isReady, turns[chatId]?.running == true, turns[chatId]?.interrupted != true,
            turns[chatId]?.stopRequested != true
        else { return }
        let session = wakeSession
        if let work = turnTasks[chatId] {
            turns[chatId]?.stopRequested = true
            await work.retire(explicitStop: true).value
            guard wakeSession == session, isReady,
                turnReservations[chatId] == nil || turnReservations[chatId] == work.id,
                turns[chatId]?.restored != true
            else { return }
            turns[chatId]?.running = false
            turns[chatId]?.stopRequested = false
            turns[chatId]?.notice = nil
            turns[chatId]?.awaitingConsent = nil
            if let error = work.retirementFailure {
                notice = Self.describe(error)
                turns[chatId]?.failure = Self.describe(error)
            }
        } else {
            guard let turnId = turns[chatId]?.turnId, !turnId.isEmpty else { return }
            guard let acknowledged = await attempt({ try $0.interruptTurn(chatId: chatId, turnId: turnId) }),
                wakeSession == session, turns[chatId]?.turnId == turnId
            else { return }
            if acknowledged {
                turns[chatId]?.stopRequested = true
            } else {
                notice = "That turn could not be stopped."
            }
        }
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
        let chatId = currentChatId ?? "surface:" + surfaceId
        guard let reservation = reserveTurn(chatId: chatId), let kernel else { return }
        let session = wakeSession
        let work = launchWork(
            chatId: chatId, id: reservation, kernel: kernel, announcesFailure: true,
            operation: {
                try await $0.act(surfaceId: surfaceId, componentId: componentId, capability: capability, args: args)
            })
        let result = await work.task.value
        guard isReady, wakeSession == session else { return }
        if case .success(let value) = result, let value, value.refused {
            notice = KernelMapping.failureText(code: value.code ?? value.status, fallback: "That action did not run.")
        }
        if currentChatId == chatId { await reloadChat(chatId) }
    }

    func saveProvider(baseURL: String, model: String, key: String, recipients: [String]? = nil) async
        -> MeshProviderInputError?
    {
        guard !savingProvider else { return .saving }
        switch MeshProviderInput.validate(baseURL: baseURL, model: model, key: key, recipients: recipients) {
        case .failure(let error):
            return error
        case .success(let config):
            savingProvider = true
            defer { savingProvider = false }
            let session = wakeSession
            do {
                try await call { try $0.setModelProvider(config) }
                guard isReady, wakeSession == session else {
                    return .failed("The mesh session changed while saving the provider.")
                }
                await refreshProviders()
                return nil
            } catch {
                return .failed(Self.describe(error))
            }
        }
    }

    func setProviderRecipients(_ provider: MeshModelProvider, recipients: [String]?) async -> Result<
        MeshModelProvider, MeshProviderInputError
    > {
        guard !savingProvider else { return .failure(.saving) }
        guard recipients?.isEmpty != true else { return .failure(.missingRecipients) }
        savingProvider = true
        defer { savingProvider = false }
        let session = wakeSession
        do {
            let updated = try await call {
                try $0.setModelProviderRecipients(name: provider.providerId, recipients: recipients)
            }
            guard isReady, wakeSession == session else {
                return .failure(.failed("The mesh session changed while saving provider sharing."))
            }
            await refreshProviders()
            return .success(updated)
        } catch {
            return .failure(.failed(Self.describe(error)))
        }
    }

    func phiDestinations() async throws -> MeshPhiDestinations { try await call { try $0.phiDestinations() } }

    func adoptPhiGroup() async throws -> MeshPhiGroup {
        let group = try await call { try $0.adoptPhiGroup() }
        phiOffer = nil
        return group
    }

    func includePhiDevice(deviceId: String) async throws -> MeshPhiGroup {
        try await call { try $0.includePhiDevice(deviceId: deviceId) }
    }

    func excludePhiDevice(deviceId: String) async throws -> MeshPhiGroup {
        try await call { try $0.excludePhiDevice(deviceId: deviceId) }
    }

    func phiProposal(for request: MeshPhiDestinationRequest) async throws -> MeshPhiProposal {
        try await call { kernel in
            switch request {
            case .provider(let name): return try kernel.proposeProviderPhiDestination(name: name)
            case .legacyServer(let name): return try kernel.proposeLegacyPhiDestination(name: name)
            case .connection(let id, let usage): return try kernel.proposeConnectionPhiDestination(id: id, usage: usage)
            case .source(let source): return try kernel.proposePhiDestination(source: source)
            }
        }
    }

    func approvePhiDestination(_ proposal: MeshPhiProposal) async throws {
        try await call { try $0.approvePhiDestination(proposal) }
        phiOffer = nil
    }

    func revokePhiDestination(subject: String) async throws {
        try await call { try $0.revokePhiDestination(subject: subject) }
    }

    func dismissPhiOffer() { phiOffer = nil }

    func offerPhi(forCode code: String?) {
        guard let code else { return }
        phiOffer = MeshPhiOffer.offer(forCode: code, defaultProvider: providers.first { $0.isDefault }?.providerId)
    }

    func proposeConnection(endpoint: String, name: String, local: Bool) async throws -> MeshConnectionProposal {
        try await call { try await $0.proposeConnection(endpoint: endpoint, name: name, local: local) }
    }

    func reviewConnection(id: String) async throws -> MeshConnectionProposal {
        try await call { try await $0.reviewConnection(id: id) }
    }

    func approveConnection(proposal: String, flow: String, toolNames: [String]) async throws -> MeshConnection {
        try await call {
            try $0.approveConnection(proposal: proposal, flow: flow, toolNames: toolNames, clientId: nil)
        }
    }

    func beginConnectionSignIn(id: String, redirect: MeshSignInRedirect) async throws -> MeshSignInStart {
        try await call { try await $0.beginConnectionSignIn(id: id, redirect: redirect) }
    }

    func completeConnectionSignIn(flow: String, redirectURL: String) async throws -> MeshConnectionState {
        try await call { try await $0.completeConnectionSignIn(flow: flow, redirectURL: redirectURL) }
    }

    func cancelConnectionSignIn(flow: String) async throws {
        try await call { try $0.cancelConnectionSignIn(flow: flow) }
    }

    func removeConnection(id: String) async throws {
        try await call { try $0.removeConnection(id: id) }
    }

    func setRemoteMCPServer(_ config: MeshRemoteMCPConfig) async throws {
        try await call { try $0.setRemoteMCPServer(config) }
    }

    func remoteMCPServers() async throws -> [MeshRemoteMCPServer] {
        try await call { try $0.remoteMCPServers() }
    }

    func removeRemoteMCPServer(_ name: String) async throws {
        try await call { try $0.removeRemoteMCPServer(name) }
    }

    func refreshRemoteMCPTools(_ server: String) async throws -> [MeshRemoteMCPTool] {
        try await call { try await $0.refreshRemoteMCPTools(server) }
    }

    func approveRemoteMCPTool(_ tool: MeshRemoteMCPTool) async throws {
        try await call { try await $0.approveRemoteMCPTool(tool) }
    }

    func revokeRemoteMCPTool(server: String, tool: String) async throws {
        try await call { try $0.revokeRemoteMCPTool(server: server, tool: tool) }
    }

    func exportBackup(to url: URL) async {
        await perform { try $0.exportBackup(path: url.path) }
    }

    func prepareMeshPush(owner: ConversationAccount) async -> MeshPushContext? { nil }

    func meshPushContextCurrent(_ context: MeshPushContext) async -> Bool { false }

    func publishMeshWakeRoute(_ context: MeshPushContext, route: MeshWakeRoute?) async -> Bool { false }

    func prepareWatchVoice(owner: CompanionVoiceOwner) async throws -> PairedWatchVoiceContext {
        let mismatch = MeshKernelError.unavailable("Open the mesh this Watch belongs to on your iPhone.")
        guard isReady, hasMesh, status.meshId == owner.meshId else { throw mismatch }
        let principal = try await call { try $0.meshPrincipal() }
        guard principal.meshId == owner.meshId, status.meshId == owner.meshId else { throw mismatch }
        let scope = try await prepareVoiceSession()
        guard status.meshId == owner.meshId else { throw mismatch }
        guard let title = currentChat?.title, currentChat?.chatId == scope.chatId else {
            throw MeshKernelError.unavailable("Choose a chat before starting Watch voice.")
        }
        return PairedWatchVoiceContext(owner: owner, chatId: scope.chatId, title: title, meshSession: scope.session)
    }

    var companionMeshId: String? { isReady && hasMesh ? status.meshId : nil }

    var companionStopped: Bool { status.stopped }

    func trackCompanionState() {
        _ = (chats, turns, status, isReady)
    }

    func companionChatView(chatId: String) async -> MeshChatView? {
        guard companionMeshId != nil, chats.contains(where: { $0.chatId == chatId }) else { return nil }
        let profile = MeshDeviceProfile.watchJSON()
        return try? await call { try $0.chatForDevice(chatId: chatId, deviceProfileJson: profile) }
    }

    func companionSend(chatId: String, text: String) async -> Bool {
        guard companionMeshId != nil, !status.stopped, chats.contains(where: { $0.chatId == chatId }) else {
            return false
        }
        return await send(text, to: chatId)
    }

    func companionStop(chatId: String) async {
        guard companionMeshId != nil else { return }
        await interrupt(chatId: chatId)
    }

    func companionRunState(chatId: String) -> CompanionRunState {
        guard let turn = turns[chatId] else { return .idle }
        if turn.running { return turn.stopRequested ? .stopping : .running }
        return turn.failure == nil ? .idle : .failed
    }

    func watchVoiceContextCurrent(_ context: PairedWatchVoiceContext) async -> Bool {
        isReady && hasMesh && !status.stopped && status.meshId == context.owner.meshId
            && wakeSession == context.meshSession && currentChatId == context.chatId
    }

    func prepareVoiceSession() async throws -> MeshVoiceScope {
        guard isReady, hasMesh else {
            throw MeshKernelError.unavailable("Open your mesh before starting voice.")
        }
        guard !status.stopped else { throw MeshKernelError.stopped }
        let session = wakeSession
        if currentChatId == nil {
            if let lastOpenedChatId, chats.contains(where: { $0.chatId == lastOpenedChatId }) {
                await openChat(lastOpenedChatId)
            } else {
                _ = await newChat(title: "Voice chat")
            }
        }
        guard isReady, wakeSession == session, let chatId = currentChatId, currentChat?.chatId == chatId else {
            throw MeshKernelError.unavailable("Choose a chat before starting voice.")
        }
        voiceSessionChatId = chatId
        return MeshVoiceScope(chatId: chatId, session: session)
    }

    func submitVoice(_ turn: OwnerVoiceTurn, scope: MeshVoiceScope? = nil) async {
        if let scope {
            guard wakeSession == scope.session, isReady else { return }
            guard currentChatId == scope.chatId else {
                notice = "Voice paused because the conversation changed. Start voice in this chat."
                return
            }
        }
        if turn.source == .pairedWatchMicrophone, scope == nil {
            notice = "Watch voice needs a current mesh conversation."
            return
        }
        guard turn.integrity == .owner, turn.source == .deviceMicrophone || turn.source == .pairedWatchMicrophone else {
            notice = "A transcript without a live owner microphone session is not treated as your message."
            return
        }
        _ = await send(turn.text, speaking: true)
    }

    func recordSpoken(_ record: VoiceSpokenRecord, scope: MeshVoiceScope? = nil) async {
        if let scope, wakeSession != scope.session { return }
        spoken.append(record)
        guard let chatId = scope?.chatId ?? speakingChatId ?? currentChatId else { return }
        await perform { try $0.recordSpoken(chatId: chatId, kind: record.kind, text: record.text) }
    }

    func interruptVoice(scope: MeshVoiceScope? = nil) async {
        if let scope, wakeSession != scope.session { return }
        guard let chatId = scope?.chatId ?? voiceChatId ?? currentChatId else { return }
        await interrupt(chatId: chatId)
    }

    func cancelVoiceTool(id: String, scope: MeshVoiceScope? = nil) async {
        if let scope, wakeSession != scope.session { return }
        guard let chatId = scope?.chatId ?? speakingChatId ?? currentChatId,
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

    private func reserveTurn(chatId: String, quietly: Bool = false) -> UUID? {
        guard isReady, kernel != nil else { return nil }
        guard turnReservations[chatId] == nil else {
            if !quietly { notice = "This chat is already answering. Try again when it finishes." }
            return nil
        }
        let id = UUID()
        turnReservations[chatId] = id
        return id
    }

    private func releaseReservation(chatId: String, id: UUID) {
        if turnReservations[chatId] == id, turnTasks[chatId] == nil { turnReservations[chatId] = nil }
    }

    private func startTurn(
        chatId: String, reservation: UUID? = nil, turnId: String = "", announcesFailure: Bool = false,
        interrupt: (@Sendable (any MeshKernel, String) throws -> Bool)? = nil,
        steer: (@Sendable (any MeshKernel, String, String) throws -> Bool)? = nil,
        cancelPending: (@Sendable (any MeshKernel, String) async throws -> Void)? = nil,
        run: @escaping @Sendable (any MeshKernel) async throws -> Void
    ) {
        guard let id = reservation ?? reserveTurn(chatId: chatId), turnReservations[chatId] == id,
            turnTasks[chatId] == nil, let kernel, isReady
        else { return }
        supersedeTurn(chatId: chatId, next: turnId)
        turns[chatId] = MeshTurnState(turnId: turnId, running: true)
        _ = launchWork(
            chatId: chatId, id: id, kernel: kernel, announcesFailure: announcesFailure, interrupt: interrupt,
            steer: steer, cancelPending: cancelPending,
            operation: { kernel in
                try await run(kernel)
                return nil
            })
    }

    private func launchWork(
        chatId: String, id: UUID, kernel: any MeshKernel, announcesFailure: Bool,
        interrupt: (@Sendable (any MeshKernel, String) throws -> Bool)? = nil,
        steer: (@Sendable (any MeshKernel, String, String) throws -> Bool)? = nil,
        cancelPending: (@Sendable (any MeshKernel, String) async throws -> Void)? = nil,
        operation: @escaping @Sendable (any MeshKernel) async throws -> MeshActResult?
    ) -> MeshTurnWork {
        let session = wakeSession
        let work = MeshTurnWork(
            id: id, kernel: kernel, chatId: chatId, waitForEntry: waitForTurnEntry,
            interrupt: interrupt, steer: steer, cancelPending: cancelPending, operation: operation)
        turnTasks[chatId] = work
        let worker = work.task
        Task { [weak self] in
            let result = await worker.value
            if work.retiring { await work.retire().value }
            guard let self, self.wakeSession == session, self.turnTasks[chatId]?.id == id else { return }
            self.turnTasks[chatId] = nil
            self.turnReservations[chatId] = nil
            if case .failure(let error) = result {
                if announcesFailure, !work.interruptionAccepted { self.notice = Self.describe(error) }
                if !work.interruptionAccepted, self.turns[chatId]?.interrupted != true, var state = self.turns[chatId] {
                    self.record(failure: Self.describe(error), in: &state)
                    self.turns[chatId] = state
                }
                self.turns[chatId]?.running = false
                self.turns[chatId]?.stopRequested = false
            } else if case .success(let action) = result, action != nil || work.retiring {
                self.turns[chatId]?.running = false
                self.turns[chatId]?.stopRequested = false
            }
        }
        return work
    }

    private func recoverOrdinaryTurns(expectedSession: UUID? = nil) async {
        guard expectedSession == nil || expectedSession == wakeSession,
            isReady, status.hasMesh, !status.stopped, recoveryScan != wakeSession
        else { return }
        let session = wakeSession
        recoveryScan = session
        defer { if recoveryScan == session { recoveryScan = nil } }
        let targets = (try? await call({ try await $0.ordinaryResumeTargets() })) ?? []
        guard isReady, wakeSession == session else { return }
        for target in targets {
            guard let id = reserveTurn(chatId: target.chatId, quietly: true) else { continue }
            startTurn(
                chatId: target.chatId, reservation: id, turnId: target.turnId,
                interrupt: { kernel, chat in try kernel.interruptTurn(chatId: chat, turnId: target.turnId) },
                steer: { kernel, chat, text in try kernel.steerTurn(chatId: chat, turnId: target.turnId, text: text) },
                run: {
                    try await $0.resumeTurn(chatId: target.chatId, turnId: target.turnId)
                })
        }
        let pending = (try? await call({ try await $0.pendingOrdinaryMessages() })) ?? []
        guard isReady, wakeSession == session else { return }
        for message in pending {
            guard let id = reserveTurn(chatId: message.chatId, quietly: true) else { continue }
            startTurn(
                chatId: message.chatId, reservation: id,
                interrupt: { kernel, chat in try kernel.interruptMessage(chatId: chat, messageId: message.messageId) },
                steer: { kernel, chat, text in
                    try kernel.steerMessage(chatId: chat, messageId: message.messageId, text: text)
                },
                cancelPending: { kernel, chat in
                    try await kernel.cancelPendingMessage(chatId: chat, messageId: message.messageId)
                },
                run: {
                    try await $0.resumePendingMessage(chatId: message.chatId, messageId: message.messageId)
                })
        }
    }

    private func reloadChat(_ chatId: String) async {
        let session = wakeSession
        guard let view = await attempt({ try $0.chat(chatId: chatId) }) else { return }
        guard wakeSession == session, currentChatId == chatId else { return }
        await resolveHandles(in: view)
        guard wakeSession == session, currentChatId == chatId else { return }
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
        switch view.status {
        case .running(let turnId):
            if turnTasks[chatId] == nil, turns[chatId]?.turnId != turnId {
                supersedeTurn(chatId: chatId, next: turnId)
                turns[chatId] = MeshTurnState(turnId: turnId, running: true, restored: true)
            }
        case .idle:
            if turns[chatId]?.restored == true {
                turns[chatId]?.running = false
                turns[chatId]?.restored = false
            }
        case .outcomeUnknown(let outcome):
            var state = turns[chatId] ?? MeshTurnState(turnId: "", running: false)
            if state.restored {
                state.running = false
                state.restored = false
            }
            if !state.unknown.contains(outcome) { state.unknown.append(outcome) }
            turns[chatId] = state
        }
    }

    private func resolveHandles(in view: MeshChatView) async {
        let session = wakeSession
        let wanted = Set(view.rendered.flatMap(MeshRenderedMapper.handles(in:))).subtracting(resolvedHandles.keys)
        let chatId = view.chatId
        for handle in wanted.sorted() {
            if let value = try? await call({ try $0.resolveHandle(chatId: chatId, handle: handle) }) {
                guard wakeSession == session, isReady else { return }
                resolvedHandles[handle] = value
            }
        }
    }

    private func handle(_ change: MeshKernelChange, session: UUID) async {
        guard kernel != nil, wakeSession == session, isReady else { return }
        switch change {
        case .chatChanged(let chatId):
            await refreshChats()
            await refreshRequests()
            if let current = currentChatId, chatId == nil || chatId == current { await reloadChat(current) }
            await recoverOrdinaryTurns(expectedSession: session)
        case .syncStateChanged:
            await refreshSync()
            await refreshMailbox()
            await recoverOrdinaryTurns(expectedSession: session)
        case .consentRequested:
            await refreshConsents()
        case .rosterChanged:
            await refreshStatus()
            await refreshRoster()
            if isReady, wakeSession == session { meshAuthorityRevision = UUID() }
            await refreshSync()
            await recoverOrdinaryTurns(expectedSession: session)
        case .turnProgress(let progress):
            await apply(progress, session: session)
        case .allowanceChanged:
            await refreshAllowance()
        case .connectionsChanged:
            await refreshConnections()
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
        guard wakeSession == session, isReady else { return }
        switch change {
        case .chatChanged, .rosterChanged, .allowanceChanged, .runProgress: wakeDataRevision = UUID()
        default: break
        }
    }

    private func apply(_ progress: MeshTurnProgress, session: UUID) async {
        guard supersededTurns[progress.chatId]?.contains(progress.turnId) != true else { return }
        var state = turns[progress.chatId] ?? MeshTurnState(turnId: progress.turnId, running: true)
        if !state.turnId.isEmpty, state.turnId != progress.turnId {
            guard progress.event == .started, !state.running else { return }
            supersedeTurn(chatId: progress.chatId, next: progress.turnId)
        }
        state.turnId = progress.turnId
        state.restored = false
        let speaking = speakingChatId == progress.chatId
        switch progress.event {
        case .started:
            state = MeshTurnState(turnId: progress.turnId, running: true, stopRequested: state.stopRequested)
        case .assistantDelta(let text):
            state.streamingText += text
            if speaking { speechSink?.answerDelta(text) }
        case .assistantFinished:
            if speaking { speechSink?.answerFinished() }
        case .notice(let text):
            if state.running { state.notice = text }
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
            turns[progress.chatId] = state
            await refreshConsents()
            guard turns[progress.chatId]?.turnId == progress.turnId else { return }
        case .outcomeUnknown(let outcome):
            if !state.unknown.contains(outcome) { state.unknown.append(outcome) }
        case .incomplete:
            state.completionWarning = "The answer may be incomplete."
        case .finished:
            supersededTurns[progress.chatId, default: []].insert(progress.turnId)
            state.running = false
            state.interrupted = false
            state.stopRequested = false
            state.notice = nil
            state.awaitingConsent = nil
            turns[progress.chatId] = state
            if progress.chatId == currentChatId { await reloadChat(progress.chatId) }
            guard wakeSession == session, isReady, turns[progress.chatId]?.turnId == progress.turnId else { return }
            state.streamingText = ""
            if speaking { speakingChatId = nil }
        case .interrupted:
            supersededTurns[progress.chatId, default: []].insert(progress.turnId)
            state.running = false
            state.stopRequested = false
            state.notice = nil
            state.interrupted = true
            state.awaitingConsent = nil
            if speaking { speakingChatId = nil }
        case .failed(let reason):
            supersededTurns[progress.chatId, default: []].insert(progress.turnId)
            state.running = false
            state.stopRequested = false
            state.notice = nil
            record(failure: reason, in: &state)
            if speaking { speakingChatId = nil }
        case .refused(let code, let reason):
            supersededTurns[progress.chatId, default: []].insert(progress.turnId)
            state.running = false
            state.stopRequested = false
            state.notice = nil
            record(failure: reason, in: &state)
            state.phiOffer = MeshPhiOffer.offer(
                forCode: code, defaultProvider: providers.first { $0.isDefault }?.providerId,
                chatHoldsPhi: currentChat?.chatId == progress.chatId && currentChat?.labels.contains("phi") == true)
            if speaking { speakingChatId = nil }
        }
        guard wakeSession == session, isReady else { return }
        turns[progress.chatId] = state
    }

    private func record(failure text: String, in state: inout MeshTurnState) {
        state.failure = text
    }

    private func supersedeTurn(chatId: String, next: String) {
        guard let previous = turns[chatId]?.turnId, !previous.isEmpty, previous != next else { return }
        supersededTurns[chatId, default: []].insert(previous)
    }

    private func call<T: Sendable>(_ work: @escaping @Sendable (any MeshKernel) async throws -> T) async throws -> T {
        guard let kernel else { throw MeshKernelError.unavailable("The mesh is not open.") }
        return try await Task.detached(priority: .userInitiated) { try await work(kernel) }.value
    }

    private func attempt<T: Sendable>(
        allowRetired: Bool = false, _ work: @escaping @Sendable (any MeshKernel) async throws -> T
    ) async -> T? {
        let session = wakeSession
        do {
            let value = try await call(work)
            guard allowRetired || (wakeSession == session && isReady) else { return nil }
            return value
        } catch {
            guard wakeSession == session, isReady else { return nil }
            notice = Self.describe(error)
            offerPhi(forCode: (error as? MeshKernelError)?.code)
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
        return "Something went wrong. Try again."
    }
}
