// iOS/macOS app model, a faithful port of Android's AppViewModel: PKCE sign-in, the WS session, and the full
// reduce() pipeline for conversation snapshots, canvas ops, and voice. Read by ChatView, RootView, and
// Screens.swift.

import AVFoundation
import AstralCore
import AuthenticationServices
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

struct LLMFirstLoginOperation: Equatable {
    enum State: String, Equatable {
        case submitting
        case accepted
        case validating
        case persisting
        case running
        case completed
        case failed
        case cancelled
        case retryable
        case unconfirmed
    }

    let submissionId: String
    let requestGeneration: String
    let connectionGeneration: String
    let requiresAdvance: Bool
    var operationId: String?
    var sequence: UInt64?
    var state: State
    var phase: String
    var label: String
    var retryable: Bool
    var errorCode: String?
    var errorMessage: String?
    var phaseVisible: Bool
    var isAuthoritativelyTerminal: Bool
    var didAdvance: Bool

    var isLoading: Bool {
        !isAuthoritativelyTerminal
            && state != .unconfirmed
            && [.submitting, .accepted, .validating, .persisting, .running].contains(state)
    }

    var fieldsEditable: Bool { true }

    var presentedLabel: String {
        if phaseVisible && [State.submitting, .accepted].contains(state) {
            return "Waiting to check your provider credentials…"
        }
        // An empty Text has no accessibility element and vanishes from AX
        if label.isEmpty && isLoading { return "Submitting…" }
        return label
    }
}

enum LLMOperationReconciliation {
    case operation(OperationProjection)
    case submission(OperationSubmissionProjection)
    case unavailable
}

@MainActor
@Observable
final class AppModel: NSObject {

    enum Screen: Equatable { case chat, agents, history, audit, surface }

    struct ChatTurn: Identifiable, Equatable {
        let id: String
        let role: String
        let text: String
        let components: [AstralComponent]

        init(
            id: String,
            role: String,
            text: String,
            components: [AstralComponent] = []
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.components = components
        }
    }

    struct StagedAttachment: Identifiable, Equatable {
        let uid: Int
        let filename: String
        var category: String
        var attachmentId: String?
        var state: String
        var note: String?
        var id: Int { uid }
    }

    struct CanvasSnapshot: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let components: [AstralComponent]
    }

    struct ActivityRow: Identifiable, Equatable {
        enum Approval: Equatable {
            case none, waiting, withdrawing, submitted, approved, granted, denied, refused, expired, uncertain
        }
        enum State: Equatable { case running, completed, failed, cancelled }

        let id: String
        var tool: String
        var action: String
        var target: String
        var approval: Approval
        var state: State
        var result: String
        var thumbnail: Data?
        var position: Int
        var arguments: String

        var approvalLabel: String? {
            switch approval {
            case .none: return nil
            case .waiting: return "Approval waiting"
            case .submitted: return "Decision submitted"
            case .withdrawing: return nil
            case .refused: return "Not approved"
            case .expired: return "Approval expired"
            case .uncertain: return "Outcome uncertain"
            case .approved: return "Approved"
            case .granted: return "Allowed for this task"
            case .denied: return "Denied"
            }
        }

        var stateLabel: String {
            switch state {
            case .running: return "Running"
            case .completed: return "Done"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        var accessibilityLabel: String { target.isEmpty ? action : "\(action), \(target)" }

        var accessibilityValue: String {
            var parts = [approvalLabel ?? stateLabel]
            if approval != .none && state != .completed { parts.append(stateLabel) }
            if !result.isEmpty && result != parts.last { parts.append(result) }
            if thumbnail != nil { parts.append("Screenshot") }
            return parts.joined(separator: ", ")
        }
    }

    struct SurfaceContent: Equatable {
        let surfaceKey: String
        let title: String
        let components: [AstralComponent]

        var subtitle: String? {
            components.first {
                $0.type == "text" && $0.raw["console_role"]?.stringValue == "surface_subtitle"
            }?.textContent
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    #if os(macOS)
        typealias LocalComputerHost = MacComputerHost
        let macComputerHost: MacComputerHost
        var llmUsage = LLMUsageTally()
        let macBrowser: MacBrowserDriver
    #else
        typealias LocalComputerHost = Never
    #endif
    #if os(iOS)
        var pushNotifications: PushNotificationService?
        @ObservationIgnored private var pushSceneActive = false
    #endif

    var serverBaseText: String {
        didSet {
            if oldValue != serverBaseText {
                #if os(macOS)
                    retireProjectCatalog()
                    macComputerHost.signedOut()
                    macBrowser.bind(owner: nil)
                #endif
                #if os(iOS)
                    configurePushNotifications()
                #endif
                clearActivity()
                retireMeshCustody()
                retireServerSession()
            }
            defaults.set(serverBaseText, forKey: "serverBase")
            #if os(iOS)
                WatchOverrideSync.shared.push(serverBaseText)
            #endif
        }
    }
    var authorityText: String {
        didSet {
            if oldValue != authorityText {
                #if os(macOS)
                    releaseComputerBypass()
                    retireProjectCatalog()
                    macComputerHost.signedOut()
                    macBrowser.bind(owner: nil)
                #endif
                #if os(iOS)
                    configurePushNotifications()
                #endif
                clearActivity()
                retireMeshCustody()
                retireServerSession()
            }
            defaults.set(authorityText, forKey: "authority")
        }
    }

    #if os(macOS)
        let clientId = AstralConfig.macosClientId
    #else
        let clientId = AstralConfig.iosClientId
    #endif
    let redirectURI = AstralConfig.redirectURI
    let voiceDeviceId: String
    @ObservationIgnored let voice: AppleVoiceSessionController

    var signedIn = false {
        didSet {
            #if os(macOS)
                if oldValue && !signedIn {
                    retireProjectCatalog()
                }
            #endif
        }
    }
    var accountName = ""
    var connected = false {
        didSet {
            guard signedIn, everConnected, connected != oldValue else { return }
            announce(connected ? "Reconnected" : "Connection lost")
        }
    }
    var everConnected = false
    var initialConnectionFailed = false
    var surfaceFailureMessage: String?
    var meshPublicIdentity: String?
    @ObservationIgnored private var meshCustody: MeshEnrollmentCustody?
    @ObservationIgnored private var meshOperation: Task<Void, Never>?
    @ObservationIgnored private var meshOperationEpoch = 0
    @ObservationIgnored var meshKeyStorage: any MeshKeyStorage = KeychainMeshKeyStorage()
    @ObservationIgnored var meshTransport: (URLRequest) async throws -> JSONValue = MeshEnrollmentHTTP.request
    private var ordinarySurfaceRequests: [String: OrdinarySurfaceRequest] = [:]
    private var ordinarySurfaceGeneration: String?
    var evidenceReadGeneration: String? { pendingSurfaceKey == "evidence" ? ordinarySurfaceGeneration : nil }
    var terminalReadGeneration: String? { pendingSurfaceKey == "terminal" ? ordinarySurfaceGeneration : nil }
    var safetyRequestGeneration: String? { pendingSurfaceKey == "safety" ? ordinarySurfaceGeneration : nil }
    private var ordinaryReadIntent: (generation: String, owner: DownloadOwner)?
    private var surfaceNavigationScope: (owner: DownloadOwner, connection: String?, render: UUID)?
    private struct ConversationNavigationBinding {
        let render = UUID()
        let owner: DownloadOwner
        let connection: String?
        let request: String?
    }
    private var acceptingTransientNavigationRender = false
    private var conversationNavigationBindings: [String: ConversationNavigationBinding] = [:]
    private var parameterRequests: [String: String] = [:]
    private var parameterFailures: Set<String> = []
    var screen: Screen = .chat {
        didSet { if oldValue != screen { cancelMeshPresentation() } }
    }
    #if os(macOS)
        let projects = MacProjectCatalog()
        private(set) var projectChooserPresented = false
        @ObservationIgnored private var projectChoice: (() -> Void)?
        @ObservationIgnored private var projectChoiceAfterDismissal: (() -> Void)?
        @ObservationIgnored private var projectChoiceEpoch = UUID()
        @ObservationIgnored private var projectCreationTask: Task<Void, Never>?
        @ObservationIgnored private var projectCreationEpoch = UUID()
        var projectPendingDeletion: ProjectRecord?
        @ObservationIgnored private var projectDeletionAction: (() async -> Void)?
    #endif
    var activeChatId: String?

    var composerDraft = ""
    var composerAccessoryPresented = false
    var runInBackground = false
    var workspaceStarted = false
    var turns: [ChatTurn] = [] {
        didSet {
            bindConversationNavigationRender("transcript")
            if !turns.isEmpty { workspaceStarted = true }
            observeActivityComponents()
        }
    }
    var canvas: [AstralComponent] = [] {
        didSet {
            bindConversationNavigationRender("canvas")
            if WorkspaceWelcome.containsWork(canvas) { workspaceStarted = true }
            observeActivityComponents()
        }
    }
    var transientTurns: [ChatTurn] = [] {
        didSet {
            bindConversationNavigationRender("transient-transcript")
            if !transientTurns.isEmpty { workspaceStarted = true }
            observeActivityComponents()
        }
    }
    var transientCanvas: [AstralComponent]? {
        didSet {
            bindConversationNavigationRender("transient-canvas")
            if WorkspaceWelcome.containsWork(transientCanvas ?? []) { workspaceStarted = true }
            observeActivityComponents()
        }
    }
    var pendingCanvas: [AstralComponent] = []
    var turnActive = false
    var pendingReplace = false
    var liveOpsThisTurn = false
    var canvasLabel = ""
    var pendingLabel = ""
    var canvasHistory: [CanvasSnapshot] = []
    var viewingIndex: Int?

    var staged: [StagedAttachment] = []
    var statusText: String?
    var errorBanner: String? {
        didSet { if let errorBanner, errorBanner != oldValue { announce(errorBanner) } }
    }
    var bannerIsError = true
    private var warningBannerText: String?
    var bannerIsWarning: Bool { errorBanner != nil && errorBanner == warningBannerText }
    var stepTrail: [String] = []
    private(set) var activityLog: [String: [ActivityRow]] = [:]
    @ObservationIgnored private var activityAliases: [String: String] = [:]
    @ObservationIgnored private var activityOrder: [String] = []
    private struct SubmittedApproval {
        let owner: DownloadOwner
        let connection: String?
        let chat: String?
        let row: String?
        let decision: String
        let expectsReceipt: Bool
        let submissionId: String?
        let requestGeneration: String?
    }
    private var approvalReceiptsSupported: Bool {
        #if os(macOS)
            return projects.enabled
        #else
            return false
        #endif
    }
    @ObservationIgnored private var submittedApprovals: [String: SubmittedApproval] = [:]
    @ObservationIgnored private var decidedApprovals: Set<String> = []
    @ObservationIgnored private var screenThumbnailSource: String?
    @ObservationIgnored private var approvalRows: [String: String] = [:]
    @ObservationIgnored private var approvalOrigins: [String: SubmittedApproval] = [:]
    @ObservationIgnored private var approvalHosts: [String: String] = [:]
    @ObservationIgnored private var withdrawingApprovals: Set<String> = []
    #if os(macOS)
        private struct RetiredComputerReviewKey: Hashable {
            let chat: String?
            let request: String
        }
        @ObservationIgnored private var retiredComputerReviews: [RetiredComputerReviewKey: SubmittedApproval] = [:]
        @ObservationIgnored private var reviewRetirementOverflow: SubmittedApproval?
    #endif
    @ObservationIgnored private var redispatchable: Set<String> = []
    @ObservationIgnored private var activityObservationPaused = false
    static let maximumActivityRows = 200
    static let maximumActivityChats = 32
    var activity: [ActivityRow] { activityLog[activityKey(activeChatId)] ?? [] }
    var canCancelTurn: Bool { signedIn && connected && turnBusy }
    private static let turnOperations: Set<String> = ["chat_message", "authorize_action", "remote_op_decision"]
    var turnBusy: Bool {
        if turnActive || activity.contains(where: { $0.state == .running && $0.approval != .waiting }) { return true }
        if operationStatuses.values.contains(where: {
            !$0.terminal && Self.turnOperations.contains($0.action)
                && $0.connectionGeneration == continuity.connectionGeneration
                && ($0.chatId == nil || $0.chatId == activeChatId)
        }) {
            return true
        }
        #if os(macOS)
            return macComputerHost.working
        #else
            return false
        #endif
    }
    var asyncDetached = false
    var operationStatuses: [String: OperationStatus] = [:]
    var agentLifecycles: [String: AgentLifecycle] = [:]
    var localOperationSubmissions: [String: LocalOperationSubmission] = [:]

    var pendingSurfaceRequestGenerations: Set<String> {
        Set(
            localOperationSubmissions.values.compactMap { submission in
                submission.chatId == nil ? submission.requestGeneration : nil
            })
    }
    var pendingChatRequestGenerations: Set<String> {
        Set(
            localOperationSubmissions.values.compactMap { submission in
                submission.chatId == activeChatId ? submission.requestGeneration : nil
            })
    }

    var agents: [Agent] = []
    var history: [ChatSummary] = []
    var historyTitle = "Recent chats"
    var audit: [AuditEvent] = []
    var agentsLoading = false
    var historyLoading = false
    var historyLoaded = false
    var auditLoading = false

    var chromeMenu: ChromeMenuModel?
    var consolePresentation: ConsolePresentation?
    var consoleDashboardVisible = true
    var consoleDrawerOpen = false
    var consoleFullscreen = false
    var consoleResultCollapsed = false
    var turnSelection: TurnSelection?
    var console: ConsoleModel? { chromeMenu?.console }
    var pendingSurfaceKey = ""
    var pendingSurfaceParams: JSONValue = .object([:])
    var pendingSurface: SurfaceContent? {
        didSet { if oldValue != pendingSurface { cancelMeshPresentation() } }
    }
    var workReadState = WorkReadState()
    var guidanceUpdate: GuidanceSurfaceUpdate?
    var guidanceState = GuidanceRequestState()
    var guidanceFailed = false
    private var guidanceEpoch = UUID().uuidString.lowercased()
    @ObservationIgnored private var guidanceTask: Task<Void, Never>?
    var workReadFailed = false
    private var workReadUpdate: WorkSurfaceUpdate?
    private var workReadEpoch = UUID().uuidString.lowercased()
    @ObservationIgnored private var workReadTask: Task<Void, Never>?
    var mandatorySurface = false
    var timelineReadOnly = false

    var signInError: String?

    var llmFirstLoginOperation: LLMFirstLoginOperation?

    let themeStore = ThemeStore()
    @ObservationIgnored let canvasCapture = CanvasCaptureRegistry()
    @ObservationIgnored var canvasExportTimeouts = CanvasExportTimeouts.standard

    var visibleCanvas: [AstralComponent] {
        if let idx = viewingIndex, canvasHistory.indices.contains(idx) {
            return canvasHistory[idx].components
        }
        return transientCanvas ?? canvas
    }
    var workspaceCanvas: [AstralComponent] {
        workspaceStarted || console != nil ? WorkspaceWelcome.workComponents(visibleCanvas) : visibleCanvas
    }
    var visibleTurns: [ChatTurn] { turns + transientTurns }
    var isViewingHistory: Bool { viewingIndex != nil }
    var showSkeleton: Bool { pendingReplace && !liveOpsThisTurn && viewingIndex == nil }
    var mutationsLocked: Bool { timelineReadOnly }
    var statusShowsActivity: Bool {
        guard statusText != nil else { return false }
        if localOperationSubmissions.values.contains(where: localSubmissionShowsActivity) {
            return true
        }
        var pendingGenerations = pendingChatRequestGenerations.union(
            pendingSurfaceRequestGenerations)
        if let currentRequest = continuity.requestGeneration {
            pendingGenerations.insert(currentRequest)
        }
        let acceptedOperationIsActive = operationStatuses.values.contains {
            !$0.terminal && pendingGenerations.contains($0.requestGeneration)
        }
        return acceptedOperationIsActive || turnActive || asyncDetached
    }

    private let store: TokenStorage
    @ObservationIgnored private let credentialClock: @Sendable () -> Date
    @ObservationIgnored private var tokens: TokenSet?
    @ObservationIgnored private var serverSession: ServerSession?
    @ObservationIgnored private var restoringServerSession: ServerSession?
    @ObservationIgnored private var serverCustodyRequired = false
    @ObservationIgnored var serverSessionStorage: any MeshKeyStorage = KeychainMeshKeyStorage(
        service: "com.personalailabs.astraldeep.server-session")
    @ObservationIgnored var serverSessionTransport: @Sendable (URLRequest) async throws -> ServerSessionReply = {
        try await ServerSessionHTTP.request($0)
    }
    @ObservationIgnored private var ws: WSClient?
    @ObservationIgnored private var initialWebSocket: WSClient?
    #if os(macOS)
        @ObservationIgnored var socketLiveness: LivenessPolicy? = .standard
    #else
        @ObservationIgnored var socketLiveness: LivenessPolicy?
    #endif
    @ObservationIgnored let connectionActivity: ConnectionActivity
    @ObservationIgnored private var registeredAccessToken: String?
    @ObservationIgnored private var refreshedWithinMarginAccessToken: String?
    @ObservationIgnored private var wsTask: Task<Void, Never>?
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private var seqState: [String: Int] = [:]
    @ObservationIgnored private var attachSeq = 0
    @ObservationIgnored private var statusLifecycle = StatusLifecycleReducer()
    @ObservationIgnored private var refreshTask: Task<RefreshResult, Never>?
    @ObservationIgnored private var refreshTaskGeneration = -1
    @ObservationIgnored private var refreshContext: CredentialRefreshContext?
    @ObservationIgnored private var authenticationReadIntent: AuthenticationReadIntent?
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var conversationNavigationGeneration = 0
    @ObservationIgnored private var conversationResumeStore: ConversationResumeStore
    @ObservationIgnored private var conversationAccount: ConversationAccount?
    @ObservationIgnored private var continuity = ConversationContinuityReducer()
    private(set) var viewportRefreshFailed = false
    private var viewportSnapshotSupported = false
    private var pendingViewportDevice: DeviceDescriptor?
    private var viewportRequest: ViewportSnapshotRequest?
    private var viewportSettledSnapshot: ConversationSnapshot?
    private var viewportPresentation: ConsolePresentation?
    private var viewportDeadline = Date.distantFuture
    private var viewportRetryBudget = 0
    private var viewportSubmissionIds: [String] = []
    @ObservationIgnored private var viewportRefreshTask: Task<Void, Never>?
    @ObservationIgnored var viewportRefreshInterval: UInt64 = 250_000_000
    @ObservationIgnored var viewportRefreshTimeout: TimeInterval = 10
    @ObservationIgnored var viewportSendOverride: ((String) async -> Bool)?
    private var directEditingOwners: Set<UUID> = []
    @ObservationIgnored private var pendingCommitRequestGeneration: String?
    @ObservationIgnored private var llmPhaseTask: Task<Void, Never>?
    @ObservationIgnored private var llmWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var llmReconciliationRunning = false
    @ObservationIgnored var llmFirstLoginPhaseDelay = AppModel.llmFirstLoginPhaseDelayNanoseconds
    @ObservationIgnored var llmFirstLoginWatchdogDelay = AppModel.llmFirstLoginWatchdogNanoseconds
    @ObservationIgnored var llmOperationReconciler: ((String?, String) async -> LLMOperationReconciliation)?

    private let docMarker = "full write-up is on the canvas"
    private let maxTrail = 20
    private let timelineMutations: Set<String> = [
        "chat_message", "component_action", "table_paginate",
        "save_theme", "component_refine", "component_restore",
    ]
    private let conversationMutationActions: Set<String> = [
        "save_component", "delete_saved_component", "combine_components",
        "condense_components", "component_action", "component_refine",
        "component_restore", "table_paginate",
    ]

    static let llmFirstLoginPhaseDelayNanoseconds: UInt64 = 1_000_000_000
    static let llmFirstLoginWatchdogNanoseconds: UInt64 = 10_000_000_000

    @ObservationIgnored var outboundTap: ((String) -> Void)?
    @ObservationIgnored var announcer: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    @ObservationIgnored var currentConnectionVoiceSendOverride: ((String) -> Void)?
    @ObservationIgnored var currentApprovalDecisionSendOverride: (@Sendable (String, String) -> Bool)?

    var serverBase: URL {
        URL(string: serverBaseText) ?? URL(string: AstralConfig.serverBaseURL)!
    }

    var oidc: OIDCConfig? {
        guard let authority = URL(string: authorityText), !authorityText.isEmpty else { return nil }
        return OIDCConfig(authority: authority, clientId: clientId, redirectURI: redirectURI)
    }

    var rest: RestClient {
        RestClient(serverBase: serverBase) { [weak self] in
            await self?.freshAccessToken()
        }
    }

    override convenience init() {
        #if canImport(Security)
            self.init(tokenStore: KeychainTokenStore())
        #else
            self.init(tokenStore: InMemoryTokenStore())
        #endif
    }

    init(
        conversationResumeStore: ConversationResumeStore = ConversationResumeStore(),
        tokenStore: TokenStorage,
        defaults: UserDefaults = .standard,
        webSocket: WSClient? = nil,
        voiceController: AppleVoiceSessionController? = nil,
        credentialClock: @escaping @Sendable () -> Date = { Date() },
        computerHost: LocalComputerHost? = nil,
        processActivity: (any ProcessActivityScheduling)? = nil
    ) {
        connectionActivity = ConnectionActivity(scheduler: processActivity ?? ProcessInfo.processInfo)
        #if os(macOS)
            let host = computerHost ?? MacComputerHost()
            macComputerHost = host
            macBrowser = MacBrowserDriver(host: host, defaults: defaults)
        #endif
        self.voice = voiceController ?? AppleVoiceSessionController()
        self.store = tokenStore
        if tokenStore is InMemoryTokenStore {
            meshKeyStorage = InMemoryMeshKeyStorage()
            serverSessionStorage = InMemoryMeshKeyStorage()
        }
        self.credentialClock = credentialClock
        self.ws = webSocket
        self.initialWebSocket = webSocket
        self.conversationResumeStore = conversationResumeStore
        self.defaults = defaults
        let voiceDeviceKey = "astraldeep.voice.device-id.v1"
        if let stored = defaults.string(forKey: voiceDeviceKey),
            let parsed = UUID(uuidString: stored), parsed.uuidString.lowercased() == stored,
            stored[stored.index(stored.startIndex, offsetBy: 14)] == "4",
            "89ab".contains(stored[stored.index(stored.startIndex, offsetBy: 19)])
        {
            voiceDeviceId = stored
        } else {
            let fresh = UUID().uuidString.lowercased()
            defaults.set(fresh, forKey: voiceDeviceKey)
            voiceDeviceId = fresh
        }
        var storedBase = defaults.string(forKey: "serverBase") ?? ""
        var storedAuthority = defaults.string(forKey: "authority") ?? ""
        // Equal to the default could be an old seeded value, not a real override
        if storedBase == AstralConfig.serverBaseURL {
            defaults.removeObject(forKey: "serverBase")
            storedBase = ""
        }
        if storedAuthority == AstralConfig.keycloakAuthority {
            defaults.removeObject(forKey: "authority")
            storedAuthority = ""
        }
        serverBaseText = storedBase.isEmpty ? AstralConfig.serverBaseURL : storedBase
        authorityText = storedAuthority.isEmpty ? AstralConfig.keycloakAuthority : storedAuthority
        super.init()
        #if os(macOS)
            macComputerHost.bypassDidEnable = { [weak self] host in self?.withdrawLocalComputerReviews(host) }
            projects.onReconciled = { [weak self] ids in
                guard let self else { return }
                try self.macComputerHost.reconcileProjects(ids)
                if let chat = self.activeChatId, let project = self.projects.project(for: chat),
                    self.projects.selectedId == nil
                {
                    self.projects.select(project)
                }
            }
        #endif
        canvasCapture.currentComponents = { [weak self] in self?.workspaceCanvas ?? [] }
        canvasCapture.currentScope = { [weak self] in
            guard let self, self.signedIn, self.screen == .chat, !self.isViewingHistory,
                !self.timelineReadOnly, !self.mandatorySurface, self.workspaceStarted,
                let chat = self.activeChatId, !chat.isEmpty
            else { return nil }
            return CanvasCaptureScope(owner: self.downloadOwner, server: self.serverBase, chat: chat)
        }
        voice.setFrameSender { [weak self] text in
            self?.sendVoiceWire(text) ?? false
        }
        voice.setChatAdopter { [weak self] chatId in
            self?.adoptChat(chatId)
            return self?.refreshActiveChat()
        }
        #if os(iOS)
            configurePushNotifications()
            WatchOverrideSync.shared.activate()
            if !storedBase.isEmpty { WatchOverrideSync.shared.push(serverBaseText) }
        #else
            trackConnectionActivity()
        #endif
    }

    var connectionActivityLevel: ConnectionActivity.Level {
        guard signedIn else { return .idle }
        #if os(macOS)
            if turnBusy || macComputerHost.taskActive { return .active }
        #else
            if turnActive { return .active }
        #endif
        return .signedIn
    }

    private func trackConnectionActivity() {
        let level = withObservationTracking {
            connectionActivityLevel
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackConnectionActivity() }
        }
        connectionActivity.update(level)
    }

    #if os(iOS)
        private func configurePushNotifications() {
            pushNotifications?.ownerSessionEnded(access: tokens?.accessToken)
            let service = PushNotificationService(
                identity: PushIdentity(deviceId: voiceDeviceId, label: "Astral phone"),
                rest: PushRest(
                    serverBase: serverBase,
                    sessionHeaders: { [weak self] token in await self?.pushSessionHeaders(token) ?? [:] }),
                tokenProvider: { [weak self] in await self?.freshAccessToken() },
                incarnationProvider: { [weak self] token in self?.pushSessionIncarnation(token) }
            )
            service.setInAppPresent { [weak self] payload in self?.presentPushInApp(payload) }
            service.setSourceOpen { [weak self] source in
                guard let self, self.signedIn, self.connected, !self.mandatorySurface, !self.timelineReadOnly else {
                    return false
                }
                if let chat = source.chatId {
                    self.openChat(chat)
                } else {
                    self.openSurface("notifications", params: .object(["entry_id": .string(source.notificationId)]))
                }
                return true
            }
            service.start()
            pushNotifications = service
            trackPushConnection()
        }

        private func pushSessionIncarnation(_ access: String) -> String? {
            guard let session = serverSession, session.scope.server == serverBase,
                pushOwnerScope(serverBase: serverBase, accessToken: session.accessToken)
                    == pushOwnerScope(serverBase: serverBase, accessToken: access),
                session.cookieExpiresAt > credentialClock()
            else { return nil }
            return session.pushIncarnation
        }

        private func pushSessionHeaders(_ access: String) -> [String: String] {
            guard pushSessionIncarnation(access) != nil, let session = serverSession, session.accessToken == access
            else { return [:] }
            return ["Cookie": session.cookie, "Origin": session.scope.server.absoluteString]
        }

        private func trackPushConnection() {
            let ready = withObservationTracking {
                (signedIn, connected, mandatorySurface, timelineReadOnly)
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.trackPushConnection() }
            }
            pushNotifications?.sceneChanged(
                active: pushSceneActive,
                connectionGeneration: ready.0 && ready.1 ? continuity.connectionGeneration : nil)
        }
    #endif

    func verifyConnection() {
        guard signedIn, let socket = ws else { return }
        Task { _ = await socket.confirmLive() }
    }

    func bindConversationAccount(_ account: ConversationAccount) {
        if conversationAccount != account {
            #if os(macOS)
                releaseComputerBypass()
                macComputerHost.signedOut()
                macBrowser.bind(owner: nil)
            #endif
            clearActivity()
            #if os(iOS)
                if conversationAccount != nil {
                    pushNotifications?.ownerSessionEnded(access: nil)
                }
            #endif
            if conversationAccount != nil {
                if let session = serverSession,
                    session.owner != account.subject || session.scope.issuer != account.issuer
                {
                    retireServerSession()
                }
                retireMeshCustody()
            } else if serverSession?.owner == account.subject, serverSession?.scope.issuer == account.issuer {
                do {
                    let scope = try MeshEnrollmentScope(server: serverBase, account: account)
                    try meshKeyStorage.retainOnly(scope.storageKey)
                } catch {
                    surfaceFailureMessage = "The protected device identity could not be restored. Retry sign-in."
                }
            }
            retireOrdinarySurfaceRequests()
            parameterRequests = [:]
            parameterFailures = []
            resetViewportRefresh(clearSubmissionHistory: true)
            continuity.clear()
            resetChatState()
        }
        conversationAccount = account
        activeChatId = conversationResumeStore.load(for: account)?.chatId
    }

    struct DownloadOwner: Equatable, Sendable {
        let account: ConversationAccount?
        let generation: Int
        let signedIn: Bool
    }

    private struct OrdinarySurfaceRequest {
        let surface: String
        let connection: String?
        let owner: DownloadOwner
        let socket: WSClient?
        let conversation: String?
    }

    private struct CredentialRefreshContext {
        let id = UUID()
        let owner: DownloadOwner
        let authentication: ASWebAuthenticationSession?
        let authority: URL
        let original: TokenSet
    }

    private struct SocketAuthenticationContext {
        let owner: DownloadOwner
        let socket: WSClient
        let connection: String
        let token: String
    }

    private struct AuthenticationReadIntent {
        let owner: DownloadOwner
        let socket: WSClient?
        let surface: String
        let params: JSONValue
        let generation: String?
    }

    var downloadOwner: DownloadOwner {
        DownloadOwner(account: conversationAccount, generation: sessionGeneration, signedIn: signedIn)
    }

    struct ComponentActionContext: Identifiable, Equatable {
        let id = UUID()
        let action: ComponentActionKind
        let owner: DownloadOwner
        let server: URL
        let chatId: String
        let componentId: String
        let component: AstralComponent
    }

    private var componentActionsInFlight: [ComponentActionContext] = []
    private var componentPendingOperations: [String: ComponentActionContext] = [:]

    func componentActionContext(for action: ComponentActionKind, component: AstralComponent) -> ComponentActionContext?
    {
        guard signedIn, downloadOwner.account != nil, screen == .chat, !mandatorySurface, workspaceStarted,
            let chatId = activeChatId, !chatId.isEmpty,
            let componentId = ComponentChromeModel.canonicalIdentity(of: component),
            ComponentChromeModel.actions(from: component.raw["component_chrome"]).contains(where: { $0.kind == action }
            ),
            !action.requiresLiveCanvas || (!isViewingHistory && !timelineReadOnly)
        else { return nil }
        let matches = workspaceCanvas.filter { $0.raw["component_id"]?.stringValue == componentId }
        guard matches.count == 1, matches.first == component else { return nil }
        return ComponentActionContext(
            action: action, owner: downloadOwner, server: serverBase, chatId: chatId,
            componentId: componentId, component: component)
    }

    func componentActionIsCurrent(_ context: ComponentActionContext) -> Bool {
        guard let current = componentActionContext(for: context.action, component: context.component) else {
            return false
        }
        return current.owner == context.owner && current.server == context.server
            && current.chatId == context.chatId && current.componentId == context.componentId
    }

    func componentActionInFlight(_ context: ComponentActionContext) -> Bool {
        let contexts =
            componentActionsInFlight
            + componentPendingOperations.compactMap { submission, context in
                localOperationSubmissions[submission] == nil ? nil : context
            }
        return contexts.contains {
            $0.action == context.action && $0.owner == context.owner && $0.server == context.server
                && $0.chatId == context.chatId && $0.componentId == context.componentId
                && $0.component == context.component
        }
    }

    func componentAccessToken(
        _ context: ComponentActionContext, resolve: (() async -> String?)? = nil
    ) async -> String? {
        guard !Task.isCancelled, componentActionIsCurrent(context) else { return nil }
        let token: String?
        if let resolve { token = await resolve() } else { token = await freshAccessToken() }
        guard !Task.isCancelled, componentActionIsCurrent(context) else { return nil }
        return token
    }

    private func componentRest(_ context: ComponentActionContext) -> RestClient {
        RestClient(serverBase: context.server) { [weak self] in await self?.componentAccessToken(context) }
    }

    func refineComponent(_ context: ComponentActionContext, instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.action == .refine, componentActionIsCurrent(context), !trimmed.isEmpty else { return }
        sendComponentEvent(
            context, action: "component_refine",
            payload: .object([
                "component_id": .string(context.componentId), "chat_id": .string(context.chatId),
                "instruction": .string(trimmed),
            ]))
    }

    func restoreComponent(_ context: ComponentActionContext, version: UInt64) {
        guard context.action == .history, componentActionIsCurrent(context),
            ComponentChromeModel.versions(from: context.component.raw["versions"]).contains(where: {
                $0.number == version
            })
        else { return }
        sendComponentEvent(
            context, action: "component_restore",
            payload: .object([
                "component_id": .string(context.componentId), "chat_id": .string(context.chatId),
                "version_no": .number(Double(version)),
            ]))
    }

    private func sendComponentEvent(_ context: ComponentActionContext, action: String, payload: JSONValue) {
        guard componentActionIsCurrent(context), !componentActionInFlight(context) else { return }
        guard connected, let socket = ws, let connection = continuity.connectionGeneration else {
            bannerIsError = true
            errorBanner = "Reconnect before changing this component."
            return
        }
        let identity = ClientOperationIdentity.fresh()
        let wire = Outbound.uiEvent(
            action: action, sessionId: context.chatId, payload: payload,
            submissionId: identity.submissionId, requestGeneration: identity.requestGeneration)
        beginLocalOperationSubmission(identity: identity, action: action, surface: "chat", chatId: context.chatId)
        componentPendingOperations[identity.submissionId] = context
        componentActionsInFlight.append(context)
        Task { @MainActor in
            defer { componentActionsInFlight.removeAll { $0.id == context.id } }
            let sent = await socket.sendCurrentComponentEvent(wire) { [weak self] in
                await self?.componentSendIsCurrent(context, socket: socket, connection: connection) ?? false
            }
            if sent {
                outboundTap?(wire)
            } else {
                localOperationSubmissions.removeValue(forKey: identity.submissionId)
                componentPendingOperations.removeValue(forKey: identity.submissionId)
                if componentActionIsCurrent(context) {
                    statusText = latestActiveOperationStatusText()
                    bannerIsError = true
                    errorBanner = "Couldn't send this component change. Reopen the action after reconnecting."
                }
            }
        }
    }

    private func componentSendIsCurrent(_ context: ComponentActionContext, socket: WSClient, connection: String) -> Bool
    {
        connected && ws === socket && continuity.connectionGeneration == connection && componentActionIsCurrent(context)
    }

    func downloadComponentCSV(
        _ context: ComponentActionContext, operation: (() async throws -> URL)? = nil
    ) async throws -> URL {
        guard context.action == .csv, componentActionIsCurrent(context) else { throw CancellationError() }
        guard !componentActionInFlight(context) else { throw WorkspaceActionError.alreadyRunning }
        componentActionsInFlight.append(context)
        defer { componentActionsInFlight.removeAll { $0.id == context.id } }
        let file: URL
        if let operation {
            file = try await operation()
        } else {
            file = try await componentRest(context).downloadComponentCSV(
                chatId: context.chatId, componentId: context.componentId)
        }
        guard !Task.isCancelled, componentActionIsCurrent(context) else {
            RestClient.removeTemporaryDownload(file)
            throw CancellationError()
        }
        return file
    }

    func shareComponent(
        _ context: ComponentActionContext, operation: (() async throws -> URL)? = nil
    ) async throws -> URL {
        guard context.action == .share, componentActionIsCurrent(context) else { throw CancellationError() }
        guard !componentActionInFlight(context) else { throw WorkspaceActionError.alreadyRunning }
        componentActionsInFlight.append(context)
        defer { componentActionsInFlight.removeAll { $0.id == context.id } }
        let url: URL
        if let operation {
            url = try await operation()
        } else {
            url = try await componentRest(context).shareComponent(
                chatId: context.chatId, componentId: context.componentId)
        }
        guard !Task.isCancelled, componentActionIsCurrent(context) else { throw CancellationError() }
        return url
    }

    struct WorkspaceActionContext: Identifiable, Equatable {
        let id = UUID()
        let action: WorkspaceAction
        let owner: DownloadOwner
        let server: URL
        let chatId: String
        let renderRevision: UInt64
    }

    enum WorkspaceActionError: Error { case alreadyRunning }
    private var workspaceActionsInFlight: Set<String> = []

    func workspaceActionInFlight(_ action: WorkspaceAction) -> Bool {
        workspaceActionsInFlight.contains(action.rawValue)
    }

    func workspaceActionContext(for action: WorkspaceAction) -> WorkspaceActionContext? {
        guard signedIn, screen == .chat, !mandatorySurface,
            !isViewingHistory, !timelineReadOnly, workspaceStarted,
            !workspaceCanvas.isEmpty,
            let chatId = activeChatId, !chatId.isEmpty,
            chromeMenu?.topbarActions.contains(where: { $0.workspaceAction == action }) == true
        else { return nil }
        return WorkspaceActionContext(
            action: action, owner: downloadOwner, server: serverBase, chatId: chatId,
            renderRevision: lastCommittedRenderRevision)
    }

    func workspaceActionIsCurrent(_ context: WorkspaceActionContext) -> Bool {
        guard let current = workspaceActionContext(for: context.action),
            current.owner == context.owner, current.server == context.server, current.chatId == context.chatId
        else { return false }
        return context.action == .shareCanvas || current.renderRevision == context.renderRevision
    }

    func workspaceAccessToken(
        _ context: WorkspaceActionContext,
        resolve: (() async -> String?)? = nil
    ) async -> String? {
        guard !Task.isCancelled, workspaceActionIsCurrent(context) else { return nil }
        let token: String?
        if let resolve { token = await resolve() } else { token = await freshAccessToken() }
        guard !Task.isCancelled, workspaceActionIsCurrent(context) else { return nil }
        return token
    }

    func workspaceExportURL(_ context: WorkspaceActionContext) -> URL? {
        guard context.action == .exportCanvas, workspaceActionIsCurrent(context),
            context.chatId.utf8.count <= 256,
            let segment = context.chatId.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))),
            var components = URLComponents(url: serverBase, resolvingAgainstBaseURL: false)
        else { return nil }
        components.percentEncodedPath = "/api/export/canvas/\(segment).html"
        components.queryItems = [URLQueryItem(name: "render_revision", value: String(context.renderRevision))]
        components.fragment = nil
        return components.url
    }

    private func workspaceRest(_ context: WorkspaceActionContext) -> RestClient {
        RestClient(serverBase: serverBase) { [weak self] in
            await self?.workspaceAccessToken(context)
        }
    }

    func downloadWorkspaceCanvas(
        _ context: WorkspaceActionContext,
        operation: (() async throws -> URL)? = nil
    ) async throws -> URL {
        guard context.action == .exportCanvas, workspaceActionIsCurrent(context) else { throw CancellationError() }
        guard !workspaceActionInFlight(context.action) else { throw WorkspaceActionError.alreadyRunning }
        guard let url = workspaceExportURL(context) else { throw URLError(.badURL) }
        workspaceActionsInFlight.insert(context.action.rawValue)
        defer { workspaceActionsInFlight.remove(context.action.rawValue) }
        let file: URL
        if let operation {
            file = try await operation()
        } else {
            file = try await exportWorkspacePresentation(
                context,
                authorize: {
                    try await self.workspaceRest(context).downloadFile(
                        from: url.absoluteString, suggestedFilename: "astraldeep-canvas.html",
                        expectedRenderRevision: context.renderRevision)
                },
                capture: {
                    let visible = self.workspaceCanvas
                    return try await self.canvasCapture.capture(visible) {
                        self.workspaceActionIsCurrent(context) && self.workspaceCanvas == visible
                    }
                },
                present: { capture in
                    try await self.workspaceRest(context).canvasPresentation(
                        chatId: context.chatId, renderRevision: context.renderRevision, capture: capture)
                },
                render: { presentation in
                    try await OfflineCanvasExport.render(
                        presentation: presentation, timeouts: self.canvasExportTimeouts
                    ) {
                        self.workspaceActionIsCurrent(context)
                    }
                })
        }
        guard !Task.isCancelled, workspaceActionIsCurrent(context) else {
            RestClient.removeTemporaryDownload(file)
            throw CancellationError()
        }
        return file
    }

    func exportWorkspacePresentation(
        _ context: WorkspaceActionContext,
        authorize: () async throws -> URL,
        capture: () async throws -> Data,
        present: (Data) async throws -> Data,
        render: (Data) async throws -> Data
    ) async throws -> URL {
        func check() throws {
            try Task.checkCancellation()
            guard workspaceActionIsCurrent(context) else { throw CancellationError() }
        }
        try check()
        let authorized = try await authorize()
        RestClient.removeTemporaryDownload(authorized)
        try check()
        let capture = try await capture()
        try check()
        let presentation = try await present(capture)
        try check()
        let html = try await render(presentation)
        try check()
        let file = try CanvasCaptureFile.write(html)
        do { try check() } catch {
            RestClient.removeTemporaryDownload(file)
            throw error
        }
        return file
    }

    func shareWorkspaceCanvas(
        _ context: WorkspaceActionContext,
        operation: (() async throws -> URL)? = nil
    ) async throws -> URL {
        guard context.action == .shareCanvas, workspaceActionIsCurrent(context) else { throw CancellationError() }
        guard !workspaceActionInFlight(context.action) else { throw WorkspaceActionError.alreadyRunning }
        workspaceActionsInFlight.insert(context.action.rawValue)
        defer { workspaceActionsInFlight.remove(context.action.rawValue) }
        let url: URL
        if let operation {
            url = try await operation()
        } else {
            url = try await workspaceRest(context).shareCanvas(chatId: context.chatId)
        }
        guard !Task.isCancelled, workspaceActionIsCurrent(context) else { throw CancellationError() }
        return url
    }

    func downloadArtifact(
        from url: String, suggestedFilename: String?,
        operation: (() async throws -> URL)? = nil
    ) async throws -> URL {
        let owner = downloadOwner
        guard owner.signedIn else { throw CancellationError() }
        let file: URL
        if let operation {
            file = try await operation()
        } else {
            file = try await rest.downloadFile(from: url, suggestedFilename: suggestedFilename)
        }
        guard !Task.isCancelled, downloadOwner == owner else {
            RestClient.removeTemporaryDownload(file)
            throw CancellationError()
        }
        return file
    }

    func registrationFrame(token: String, resumed: Bool) -> String {
        let connection = UUID().uuidString.lowercased()
        guard beginConversationConnection(connection) else { return "{}" }

        var resume: ConversationResumeRegistration?
        if let account = conversationAccount,
            let chatId = conversationResumeStore.load(for: account)?.chatId
        {
            guard conversationResumeStore.save(chatId: chatId, for: account) else {
                return "{}"
            }
            activeChatId = chatId
            let request = UUID().uuidString.lowercased()
            if openConversationRequest(
                chatId: chatId,
                requestGeneration: request,
                purpose: .hydration)
            {
                resume = ConversationResumeRegistration(
                    activeChatId: chatId,
                    requestGeneration: request)
            }
        }
        #if os(macOS)
            let voiceDeviceKind = "macos"
        #else
            let voiceDeviceKind = "ios"
        #endif
        voice.installUIConnection(
            token: token, serverBase: serverBase, deviceId: voiceDeviceId,
            deviceKind: voiceDeviceKind, connectionGeneration: connection,
            visibleChatId: activeChatId)
        #if os(macOS)
            let socket = ws
            let hostOwner = downloadOwner
            let hostScope =
                signedIn ? hostOwner.account.map { serverBase.absoluteString + "|" + $0.locatorStorageKey } : nil
            macBrowser.bind(owner: hostScope)
            macComputerHost.bind(owner: hostScope) { [weak self] text in
                guard let self, let socket, self.ws === socket, self.downloadOwner == hostOwner,
                    self.continuity.connectionGeneration == connection,
                    let bound = ComputerHostOutbound.bindToConnection(text, connectionGeneration: connection)
                else { return false }
                return await socket.sendCurrentComputerEvent(bound, connectionGeneration: connection) { [weak self] in
                    guard let self else { return false }
                    return await self.computerChannelIsCurrent(socket: socket, owner: hostOwner, connection: connection)
                }
            }
            macComputerHost.beginWorkspaceNegotiation(server: serverBase, account: hostOwner.account?.locatorStorageKey)
            let projectClient = RestClient(
                serverBase: serverBase,
                projectConnection: .init(deviceId: voiceDeviceId, generation: connection),
                tokenProvider: { [weak self] in
                    guard let self else { return nil }
                    return await self.projectAccessToken(owner: hostOwner, connection: connection)
                })
            projectCreationTask?.cancel()
            projectCreationTask = nil
            projectCreationEpoch = UUID()
            cancelProjectDeletion()
            projects.bind(scope: hostScope, client: projectClient)
            let hostDescriptor: ComputerHostDescriptor? = nil
            let hostCapable = macComputerHost.available
            let macWorkbench = true
        #else
            let hostDescriptor: ComputerHostDescriptor? = nil
            let hostCapable = false
            let macWorkbench = false
        #endif
        return Outbound.registerUI(
            token: token,
            sessionId: activeChatId,
            device: device,
            resumed: resumed,
            connectionGeneration: connection,
            resume: resume, workReadSupported: true, guidanceNotesSupported: true,
            computerHost: hostDescriptor, computerHostCapable: hostCapable, macWorkbenchSupported: macWorkbench)
    }

    @discardableResult
    func beginConversationConnection(_ generation: String) -> Bool {
        if ["evidence", "terminal"].contains(pendingSurfaceKey) { closeSurface() }
        if pendingSurfaceKey == "safety" {
            retireOrdinarySurfaceRequests()
            surfaceFailureMessage = "Reload Safety to check current stop status before trying again."
        }
        if continuity.connectionGeneration != generation {
            retireSubmittedApprovals()
            #if os(macOS)
                retiredComputerReviews.removeAll()
                reviewRetirementOverflow = nil
            #endif
        }
        resetViewportRefresh(clearSubmissionHistory: true)
        invalidateWorkRead()
        clearPendingOperationSubmissions()
        transientTurns = []
        transientCanvas = nil
        let accepted = continuity.beginConnection(generation)
        #if os(iOS)
            pushNotifications?.sceneChanged(active: pushSceneActive, connectionGeneration: connected ? generation : nil)
        #endif
        return accepted
    }

    @discardableResult
    func openConversationRequest(
        chatId: String,
        requestGeneration: String,
        purpose: ConversationGenerationPurpose
    ) -> Bool {
        cancelViewportRefresh(requeue: true)
        let resetRevision =
            continuity.activeChatId != nil
            && continuity.activeChatId != chatId
        guard continuity.selectChat(chatId, resetRevision: resetRevision),
            continuity.openRequest(
                chatId: chatId,
                requestGeneration: requestGeneration,
                purpose: purpose)
        else { return false }
        workspaceStarted = true
        consoleDashboardVisible = false
        activeChatId = chatId
        transientTurns = []
        transientCanvas = nil
        return true
    }

    var lastCommittedRenderRevision: UInt64 {
        continuity.lastCommittedRenderRevision
    }

    func bootstrap() async {
        let generation = sessionGeneration
        let owner = downloadOwner
        let authentication = authSession
        if let oidc, let scope = try? ServerSessionScope(server: serverBase, oidc: oidc) {
            do {
                if let data = try serverSessionStorage.load(scope.storageKey) {
                    let restored = try JSONDecoder().decode(ServerSession.self, from: data)
                    guard restored.scope == scope, restored.cookieExpiresAt > credentialClock() else {
                        throw ServerSessionError.retired
                    }
                    restoringServerSession = restored
                    let refreshed = try await ServerSessionTransport(scope: scope, transport: serverSessionTransport)
                        .refresh(restored)
                    if restoringServerSession == restored { restoringServerSession = nil }
                    guard !Task.isCancelled, generation == sessionGeneration, owner == downloadOwner,
                        authentication === authSession, self.oidc?.authority == oidc.authority,
                        (try? ServerSessionScope(server: serverBase, oidc: oidc)) == scope
                    else { return }
                    try serverSessionStorage.save(JSONEncoder().encode(refreshed), key: scope.storageKey)
                    serverSession = refreshed
                    serverCustodyRequired = true
                    tokens = refreshed.tokenSet
                    enterSignedIn(resumedSession: true)
                    return
                }
            } catch {
                guard !Task.isCancelled, generation == sessionGeneration, owner == downloadOwner,
                    authentication === authSession
                else { return }
                retireServerSession()
                store.wipe()
                signInError = "The saved server session could not be resumed. Sign in again."
                return
            }
        }
        let loaded = await Task.detached { [store] in store.load() }.value
        guard !Task.isCancelled, generation == sessionGeneration, owner == downloadOwner,
            authentication === authSession, let stored = loaded
        else { return }
        tokens = stored.tokenSet
        enterSignedIn(resumedSession: true)
        let resumedOwner = downloadOwner
        if case .rejected = await refreshOutcome(), resumedOwner == downloadOwner {
            await signOut(revokeRemote: false)
        }
    }

    func signIn() {
        guard let oidc else {
            signInError = "Set the Keycloak realm URL first."
            return
        }
        retireMeshCustody()
        retireServerSession()
        authSession?.cancel()
        signInError = nil
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        let generation = sessionGeneration
        let url = oidc.authorizeURL(state: state, challenge: PKCE.challenge(for: verifier))

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: AstralConfig.redirectScheme) {
            [weak self] callback, error in
            guard let self else { return }
            Task { @MainActor in
                guard generation == self.sessionGeneration else { return }
                if let error {
                    self.signInError = error.localizedDescription
                    return
                }
                guard let callback,
                    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                    items.first(where: { $0.name == "state" })?.value == state,
                    let code = items.first(where: { $0.name == "code" })?.value
                else {
                    self.signInError = "Sign-in was cancelled."
                    return
                }
                await self.exchange(code: code, verifier: verifier, oidc: oidc)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    private func exchange(code: String, verifier: String, oidc: OIDCConfig) async {
        let generation = sessionGeneration
        let authentication = authSession
        let server = serverBase
        do {
            let scope = try ServerSessionScope(server: server, oidc: oidc)
            let transport = ServerSessionTransport(scope: scope, transport: serverSessionTransport)
            let result = try await transport.exchange(code: code, verifier: verifier)
            guard !Task.isCancelled, generation == sessionGeneration, authSession === authentication,
                serverBase == server, self.oidc?.authority == oidc.authority
            else { return }
            try serverSessionStorage.retainOnly(scope.storageKey)
            try serverSessionStorage.save(JSONEncoder().encode(result), key: scope.storageKey)
            serverSession = result
            serverCustodyRequired = true
            tokens = result.tokenSet
            store.wipe()
            enterSignedIn(resumedSession: false)
        } catch {
            if generation == sessionGeneration, authSession === authentication, serverBase == server {
                signInError = "The server could not establish this session. Start sign-in again."
            }
        }
    }

    private func retireServerSession(revokeRemote: Bool = true) {
        let retired = serverSession ?? restoringServerSession
        let retiredTransport = serverSessionTransport
        #if os(iOS)
            pushNotifications?.ownerSessionEnded(access: tokens?.accessToken)
        #endif
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshContext = nil
        serverSession = nil
        restoringServerSession = nil
        do { try serverSessionStorage.retainOnly(nil) } catch {
            signInError = "The protected server session could not be cleared. Retry sign-out."
        }
        if revokeRemote, let retired {
            let captured = sessionGeneration
            Task { [weak self] in
                let outcome = try? await ServerSessionTransport(scope: retired.scope, transport: retiredTransport)
                    .logoutOutcome(retired)
                if outcome != .revoked {
                    NSLog("AstralDeep previous server session retirement unconfirmed or queued")
                    guard let self, self.sessionGeneration == captured, self.serverSession == nil,
                        !self.signedIn, self.signInError == nil
                    else { return }
                    self.signInError =
                        outcome == .queued
                        ? "Previous server session revocation is queued."
                        : "The server could not confirm previous session revocation."
                }
            }
        }
    }

    private func refreshServerSession() async -> RefreshResult {
        guard let session = serverSession, let oidc,
            let scope = try? ServerSessionScope(server: serverBase, oidc: oidc), scope == session.scope
        else { return .rejected("server session required") }
        let generation = sessionGeneration
        do {
            let transport = ServerSessionTransport(scope: scope, transport: serverSessionTransport)
            let result = try await transport.refresh(session)
            guard !Task.isCancelled, generation == sessionGeneration, serverSession == session,
                self.oidc.map({ try? ServerSessionScope(server: serverBase, oidc: $0) }) == scope
            else { return .transient("session changed") }
            try serverSessionStorage.save(JSONEncoder().encode(result), key: scope.storageKey)
            serverSession = result
            return .ok(result.tokenSet)
        } catch ServerSessionError.retired { return .rejected("server session expired") } catch ServerSessionError
            .invalid
        { return .rejected("server session invalid") } catch { return .transient("server session unavailable") }
    }

    private func serverSocketHeaders(url: URL, owner: DownloadOwner, server: URL) async -> [String: String]? {
        guard !Task.isCancelled, downloadOwner == owner, serverBase == server else { return nil }
        guard serverCustodyRequired else { return [:] }
        guard case .ok = await refreshOutcome(renewSocket: false),
            !Task.isCancelled, downloadOwner == owner, serverBase == server
        else { return nil }
        guard let session = serverSession, let oidc,
            let scope = try? ServerSessionScope(server: serverBase, oidc: oidc), scope == session.scope,
            let token = tokens?.accessToken
        else { return nil }
        return try? session.socketHeaders(url: url, token: token, now: credentialClock())
    }

    private func credentialNeedsRefresh(_ set: TokenSet) -> Bool {
        credentialHasExpired(set)
            || (refreshedWithinMarginAccessToken != set.accessToken && credentialIsWithinRefreshMargin(set))
    }

    private func credentialHasExpired(_ set: TokenSet) -> Bool {
        let now = credentialClock()
        return now >= set.expiresAt
            || set.claims?["exp"]?.numberValue.map { $0 <= now.timeIntervalSince1970 } == true
    }

    private func credentialIsWithinRefreshMargin(_ set: TokenSet) -> Bool {
        let now = credentialClock()
        return set.needsRefresh(now: now)
            || set.claims?["exp"]?.numberValue.map { $0 <= now.addingTimeInterval(60).timeIntervalSince1970 } == true
    }

    private func refreshOutcome(force: Bool = false, renewSocket: Bool = true) async -> RefreshResult {
        guard let current = tokens else { return .rejected("no session") }
        guard !signedIn || current.conversationAccount == conversationAccount else {
            return .rejected("credentials do not match the session")
        }
        if refreshTask == nil, !force, !credentialNeedsRefresh(current) {
            if renewSocket { renewRegisteredSocket(ifChanged: current) }
            return .ok(current)
        }
        guard let oidc, serverCustodyRequired || current.refreshToken != nil else {
            return .rejected("no session renewal")
        }
        let context: CredentialRefreshContext
        let attempt: Task<RefreshResult, Never>
        if let inFlight = refreshTask, let active = refreshContext,
            active.owner == downloadOwner, active.authentication === authSession,
            active.authority == oidc.authority, refreshTaskGeneration == sessionGeneration
        {
            context = active
            attempt = inFlight
        } else {
            refreshTask?.cancel()
            context = CredentialRefreshContext(
                owner: downloadOwner, authentication: authSession,
                authority: oidc.authority, original: current)
            if serverCustodyRequired {
                attempt = Task { await self.refreshServerSession() }
            } else {
                attempt = Task { await RefreshStrategy.direct(oidc).attempt(refreshToken: current.refreshToken!) }
            }
            refreshTask = attempt
            refreshTaskGeneration = sessionGeneration
            refreshContext = context
        }
        let result = await attempt.value
        guard !Task.isCancelled, context.owner == downloadOwner,
            context.authentication === authSession, context.authority == self.oidc?.authority
        else { return .transient("session changed") }
        if case .ok(let set) = result {
            guard set.conversationAccount == context.original.conversationAccount,
                !context.owner.signedIn || set.conversationAccount == context.owner.account,
                !credentialHasExpired(set)
            else {
                if refreshContext?.id == context.id {
                    refreshTask = nil
                    refreshContext = nil
                }
                return .rejected("refreshed credentials do not match the session")
            }
            guard tokens == context.original || tokens == set else { return .transient("session changed") }
            if refreshContext?.id == context.id {
                refreshTask = nil
                refreshContext = nil
                tokens = set
                refreshedWithinMarginAccessToken = credentialIsWithinRefreshMargin(set) ? set.accessToken : nil
                if !serverCustodyRequired { store.save(StoredTokens(from: set)) }
            }
            if renewSocket { renewRegisteredSocket(ifChanged: set) }
        } else if refreshContext?.id == context.id {
            refreshTask = nil
            refreshContext = nil
        }
        return result
    }

    private func freshAccessToken() async -> String? {
        if case .ok(let set) = await refreshOutcome() { return set.accessToken }
        return nil
    }

    private var socketAuthenticationContext: SocketAuthenticationContext? {
        guard signedIn, let socket = ws, let connection = continuity.connectionGeneration,
            let token = registeredAccessToken
        else { return nil }
        return SocketAuthenticationContext(owner: downloadOwner, socket: socket, connection: connection, token: token)
    }

    private func socketAuthenticationIsCurrent(_ context: SocketAuthenticationContext) -> Bool {
        context.owner == downloadOwner && ws === context.socket
            && continuity.connectionGeneration == context.connection && registeredAccessToken == context.token
    }

    private func authenticatedSocketIsCurrent(
        _ socket: WSClient, owner: DownloadOwner, connection: String?
    ) async -> Bool {
        guard let context = socketAuthenticationContext, context.socket === socket,
            context.owner == owner, context.connection == connection, connected
        else { return false }
        let result = await refreshOutcome()
        guard !Task.isCancelled, socketAuthenticationIsCurrent(context), connected else { return false }
        switch result {
        case .ok(let set): return set.accessToken == context.token
        case .rejected:
            await signOut(revokeRemote: false)
            return false
        case .transient: return false
        }
    }

    private func handleAuthRequired(_ context: SocketAuthenticationContext) async {
        guard socketAuthenticationIsCurrent(context) else { return }
        let result = await refreshOutcome(force: tokens?.accessToken == context.token)
        guard !Task.isCancelled, socketAuthenticationIsCurrent(context) else { return }
        switch result {
        case .ok(let set) where set.accessToken != context.token:
            renewRegisteredSocket(ifChanged: set)
        case .ok, .rejected:
            await signOut(revokeRemote: false)
        case .transient:
            surfaceFailureMessage = "The session could not reconnect. Retry when the connection is available."
        }
    }

    private func renewRegisteredSocket(ifChanged set: TokenSet) {
        guard signedIn, connected, let registeredAccessToken, registeredAccessToken != set.accessToken else { return }
        let owner = downloadOwner
        let surface = screen == .surface ? pendingSurfaceKey : ""
        let params = pendingSurfaceParams
        let canReload =
            !["evidence", "safety", "terminal"].contains(surface) && pendingSurface == nil
            && (params == .object([:]) || params == .object(["mode": .string("list")])
                || (surface == "guidance" && params == GuidanceRequest.selection.payload["params"]))
        let interrupted = !localOperationSubmissions.isEmpty || llmFirstLoginOperation?.isLoading == true
        connectWS(resumed: true)
        if canReload, !surface.isEmpty {
            let generation =
                surface == "guidance" ? guidanceEpoch : surface == "work" ? workReadEpoch : ordinarySurfaceGeneration
            authenticationReadIntent = AuthenticationReadIntent(
                owner: owner, socket: ws, surface: surface, params: params, generation: generation)
        } else if !surface.isEmpty, interrupted {
            surfaceFailureMessage = "The session refreshed. Review your entries and retry the action."
        }
    }

    private func resumeAuthenticatedRead() {
        guard let intent = authenticationReadIntent else { return }
        authenticationReadIntent = nil
        let generation =
            intent.surface == "guidance"
            ? guidanceEpoch : intent.surface == "work" ? workReadEpoch : ordinarySurfaceGeneration
        guard intent.owner == downloadOwner, intent.socket === ws, screen == .surface,
            pendingSurfaceKey == intent.surface, !["evidence", "safety", "terminal"].contains(intent.surface),
            generation == intent.generation,
            !mandatorySurface
        else { return }
        if intent.surface == "guidance" {
            retryGuidance()
        } else {
            openSurface(intent.surface, params: intent.params)
        }
    }

    private func authenticationSurfaceGeneration(_ surface: String) -> String? {
        surface == "guidance" ? guidanceEpoch : surface == "work" ? workReadEpoch : ordinarySurfaceGeneration
    }

    private func enterSignedIn(resumedSession: Bool) {
        accountName = tokens?.displayName ?? ""
        if let account = tokens?.conversationAccount {
            bindConversationAccount(account)
        } else {
            conversationAccount = nil
            resetViewportRefresh(clearSubmissionHistory: true)
            continuity.clear()
            resetChatState()
        }
        signedIn = true
        #if os(iOS)
            if let access = tokens?.accessToken { pushNotifications?.ownerAuthenticated(access: access) }
            if pushNotifications?.shouldOfferPermissionRequest() == true {
                pushNotifications?.requestAuthorizationIfNeeded()
            }
        #endif
        connectWS(resumed: resumedSession)
    }

    func presentPushInApp(_ payload: PushPayload) {
        let text = [payload.title, payload.body]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
        guard !text.isEmpty else { return }
        bannerIsError = payload.level == "error"
        warningBannerText = payload.level == "warning" ? text : nil
        errorBanner = text
    }

    func signOut(revokeRemote: Bool = true) async {
        #if os(macOS)
            releaseComputerBypass()
            macComputerHost.signedOut()
            macBrowser.bind(owner: nil)
            llmUsage = LLMUsageTally()
        #endif
        clearActivity()
        #if os(iOS)
            pushNotifications?.ownerSessionEnded(access: tokens?.accessToken)
        #endif
        retireMeshCustody()
        // Local wipe must precede the async revoke call, before any suspension
        let access = tokens?.accessToken
        let refresh = tokens?.refreshToken
        let custody = serverSession ?? restoringServerSession
        retireServerSession(revokeRemote: false)
        serverCustodyRequired = false
        let logoutClient = RestClient(serverBase: serverBase) { access }
        let socket = ws
        if let account = conversationAccount {
            _ = conversationResumeStore.clear(.signOut, for: account)
        }
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshContext = nil
        registeredAccessToken = nil
        refreshedWithinMarginAccessToken = nil
        authenticationReadIntent = nil
        initialWebSocket = nil
        wsTask?.cancel()
        wsTask = nil
        ws = nil
        if pendingSurfaceKey == "terminal" { closeSurface() }
        store.wipe()
        tokens = nil
        conversationAccount = nil
        signedIn = false
        connected = false
        everConnected = false
        initialConnectionFailed = false
        retireOrdinarySurfaceRequests()
        parameterRequests = [:]
        historyLoaded = false
        voice.close()
        resetViewportRefresh(clearSubmissionHistory: true)
        continuity.clear()
        resetChatState()
        clearPendingOperationSubmissions()
        statusLifecycle.clear()
        operationStatuses = [:]
        agentLifecycles = [:]
        chromeMenu = nil
        consolePresentation = nil
        mandatorySurface = false
        clearLLMFirstLoginOperation()
        agents = []
        history = []
        historyTitle = "Recent chats"
        audit = []

        let logoutGeneration = sessionGeneration
        await socket?.stop()
        if revokeRemote, let custody {
            let outcome = try? await ServerSessionTransport(scope: custody.scope, transport: serverSessionTransport)
                .logoutOutcome(custody)
            guard sessionGeneration == logoutGeneration, !signedIn, signInError == nil else { return }
            if outcome == .queued {
                signInError = "Signed out on this device. Server session revocation is queued."
            } else if outcome != .revoked {
                signInError = "Signed out on this device. The server could not confirm session revocation."
            }
        } else if revokeRemote, let refresh {
            _ = try? await logoutClient.logout(clientId: clientId, refreshToken: refresh)
        }
    }

    func clearConversationForAccountRemoval() {
        #if os(macOS)
            macComputerHost.signedOut()
            macBrowser.bind(owner: nil)
        #endif
        clearActivity()
        retireMeshCustody()
        retireServerSession()
        retireOrdinarySurfaceRequests()
        parameterRequests = [:]
        if let account = conversationAccount {
            _ = conversationResumeStore.clear(.accountRemoval, for: account)
        }
        conversationAccount = nil
        invalidateGuidance()
        pendingSurface = nil
        pendingSurfaceKey = ""
        pendingSurfaceParams = .object([:])
        mandatorySurface = false
        screen = .chat
        chromeMenu = nil
        consolePresentation = nil
        resetViewportRefresh(clearSubmissionHistory: true)
        continuity.clear()
        resetChatState()
        clearPendingOperationSubmissions()
        statusLifecycle.clear()
        operationStatuses = [:]
        agentLifecycles = [:]
        voice.close()
    }

    @ObservationIgnored private var lastReportedViewport: (width: Int, height: Int)?
    @ObservationIgnored private var reportedDevice: DeviceDescriptor?
    @ObservationIgnored private var reportedPixelRatio: Double?
    @ObservationIgnored private var networkConnectionType = "unknown"

    private var device: DeviceDescriptor {
        #if os(macOS)
            let (w, h) = lastReportedViewport ?? (1280, 800)
            var descriptor = DeviceDescriptor.macos(viewportWidth: w, viewportHeight: h)
            descriptor.macWorkbenchSupported = true
            descriptor.projectWorkspacesSupported = true
        #else
            let size = UIScreen.main.bounds.size
            let (w, h) = lastReportedViewport ?? (Int(size.width), Int(size.height))
            var descriptor = DeviceDescriptor.ios(viewportWidth: w, viewportHeight: h)
        #endif
        descriptor.deviceId = voiceDeviceId
        descriptor.pixelRatio = reportedPixelRatio ?? descriptor.pixelRatio
        descriptor.hasCamera = AVCaptureDevice.default(for: .video) != nil
        descriptor.connectionType = networkConnectionType
        #if os(macOS)
            let audioAvailability = AppleVoicePermission.macOSHardwareAvailability(
                AppleVoicePermission.currentAudioRouteSnapshot())
            descriptor.hasMicrophone = audioAvailability.hasMicrophone
            descriptor.hasAudioOutput = audioAvailability.hasAudioOutput
        #else
            descriptor.hasMicrophone = AVCaptureDevice.default(for: .audio) != nil
            descriptor.hasAudioOutput = true
        #endif
        descriptor.microphonePermission = AppleVoicePermission.status
        descriptor.fullDuplex = true
        descriptor.voiceTransport = "livekit"
        #if os(macOS)
            descriptor.reducedMotion =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
            descriptor.reducedMotion = UIAccessibility.isReduceMotionEnabled
        #endif
        return descriptor
    }

    func viewportChanged(width: Int, height: Int, pixelRatio: Double? = nil) {
        guard width > 0, height > 0 else { return }
        lastReportedViewport = (width, height)
        if let pixelRatio, pixelRatio.isFinite, pixelRatio > 0, pixelRatio <= 16 {
            reportedPixelRatio = pixelRatio
        }
        reportDeviceCapabilities()
    }

    func networkCapabilitiesChanged(_ connectionType: String) {
        networkConnectionType =
            ["wifi", "cellular", "ethernet", "none"].contains(connectionType)
            ? connectionType : "unknown"
        reportDeviceCapabilities()
    }

    private func consumeViewportStatus(_ frame: InboundFrame) -> Bool {
        if let refusal = AdmissionRefusal(frame: frame), viewportSubmissionIds.contains(refusal.submissionId) {
            if let request = viewportRequest, refusal.submissionId == request.submissionId,
                request.isCurrent(in: continuity)
            {
                failViewportRefresh()
            }
            return true
        }
        guard let status = OperationStatus(frame: frame), status.action == "update_device",
            status.connectionGeneration == continuity.connectionGeneration,
            status.chatId == activeChatId
        else { return false }
        guard let request = viewportRequest else {
            return continuity.acceptedSnapshot?.requestGeneration == status.requestGeneration
        }
        guard status.requestGeneration == request.requestGeneration, request.isCurrent(in: continuity) else {
            return false
        }
        if status.terminal, status.state != "completed" {
            let retry = status.retryable && viewportRetryBudget > 0
            viewportRetryBudget -= retry ? 1 : 0
            if retry { cancelViewportRefresh(requeue: true) } else { failViewportRefresh() }
        }
        return true
    }

    private func reduceViewportConfiguration(_ frame: InboundFrame) {
        if ["chat_id", "connection_generation", "request_generation"].contains(where: { frame.payload[$0] != nil }) {
            guard let request = viewportRequest,
                frame.payload["chat_id"]?.stringValue == request.chatId,
                frame.payload["connection_generation"]?.stringValue == request.connectionGeneration,
                frame.payload["request_generation"]?.stringValue == request.requestGeneration,
                request.isCurrent(in: continuity)
            else { return }
            guard !viewportRefreshBusy else {
                cancelViewportRefresh(requeue: true)
                return
            }
            viewportPresentation = ConsolePresentation(frame: frame)
            return
        }
        consolePresentation = ConsolePresentation(frame: frame)
        #if os(macOS)
            let projectAck = frame.payload["device_profile"]?["console"]?["project_workspaces"]
            let accepted = projectAck?["version"] == .number(1) && projectAck?["mode"] == .string("projects_only")
            projects.negotiate(accepted)
            macComputerHost.workspaceNegotiated(projects: accepted)
            if accepted, connected { Task { await projects.refresh() } }
        #endif
        viewportSnapshotSupported = frame.payload["viewport_snapshot_supported"]?.boolValue == true
    }

    private var viewportRefreshAvailable: Bool {
        viewportSnapshotSupported && signedIn && connected && conversationAccount != nil
    }

    private var viewportRefreshBusy: Bool {
        screen != .chat || mandatorySurface || timelineReadOnly || isViewingHistory
            || turnActive || asyncDetached || pendingReplace || pendingCommitRequestGeneration != nil
            || voice.active || !workspaceActionsInFlight.isEmpty || !componentActionsInFlight.isEmpty
            || !directEditingOwners.isEmpty
            || composerAccessoryPresented || staged.contains(where: { $0.state == "uploading" })
            || !transientTurns.isEmpty || transientCanvas != nil
    }

    private func queueViewportRefresh(_ device: DeviceDescriptor) {
        viewportRefreshFailed = false
        pendingViewportDevice = device
        viewportRetryBudget = 2
        guard viewportRefreshTask == nil else { return }
        viewportRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.viewportRefreshInterval else { return }
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard let self else { return }
                guard self.viewportRefreshAvailable else {
                    self.cancelViewportRefresh(requeue: false)
                    self.pendingViewportDevice = nil
                    self.viewportRefreshTask = nil
                    return
                }
                await self.flushViewportRefresh()
                if self.pendingViewportDevice == nil && self.viewportRequest == nil {
                    self.viewportRefreshTask = nil
                    return
                }
            }
        }
    }

    func flushViewportRefresh() async {
        if let request = viewportRequest {
            if !request.isCurrent(in: continuity) {
                cancelViewportRefresh(requeue: true)
            } else if viewportRefreshBusy {
                cancelViewportRefresh(requeue: true)
            } else if Date() >= viewportDeadline {
                failViewportRefresh()
            } else {
                return
            }
        }
        guard viewportRefreshAvailable, !viewportRefreshBusy,
            let device = pendingViewportDevice, let settled = continuity.acceptedSnapshot,
            settled.chatId == activeChatId,
            let request = ViewportSnapshotRequest(device: device, snapshot: settled),
            ws != nil || viewportSendOverride != nil,
            continuity.beginViewportHydration(request)
        else { return }
        viewportRefreshFailed = false
        viewportSubmissionIds.append(request.submissionId)
        if viewportSubmissionIds.count > 128 { viewportSubmissionIds.removeFirst(viewportSubmissionIds.count - 128) }
        viewportRequest = request
        viewportSettledSnapshot = settled
        viewportDeadline = Date().addingTimeInterval(viewportRefreshTimeout)
        pendingViewportDevice = nil
        let sent: Bool
        if let viewportSendOverride {
            sent = await viewportSendOverride(request.frameText)
        } else if let socket = ws {
            sent = await socket.sendCurrentViewportEvent(request.frameText) { [weak self] in
                await self?.viewportRequestIsCurrent(request, socket: socket) == true
            }
        } else {
            sent = false
        }
        if !sent, viewportRequest == request { failViewportRefresh() }
    }

    private func viewportRequestIsCurrent(_ request: ViewportSnapshotRequest, socket: WSClient) -> Bool {
        ws === socket && viewportRefreshAvailable && !viewportRefreshBusy
            && viewportRequest == request && request.isCurrent(in: continuity)
    }

    private func cancelViewportRefresh(requeue: Bool) {
        guard let request = viewportRequest else { return }
        if let settled = viewportSettledSnapshot {
            _ = continuity.cancelViewportHydration(request, restoring: settled)
        }
        viewportRequest = nil
        viewportSettledSnapshot = nil
        viewportPresentation = nil
        if requeue, pendingViewportDevice == nil { pendingViewportDevice = device }
    }

    private func failViewportRefresh() {
        guard let request = viewportRequest, request.isCurrent(in: continuity) else { return }
        cancelViewportRefresh(requeue: false)
        viewportRefreshFailed = true
    }

    func retryViewportRefresh() {
        guard viewportRefreshAvailable else { return }
        queueViewportRefresh(device)
    }

    var viewportRefreshFailureMessage: String {
        if canvas.dropWelcome().isEmpty, !turns.contains(where: { $0.role == "assistant" }) {
            return "The dashboard layout could not update. Retry to refresh it."
        }
        return "The layout could not update. Your result is still available."
    }

    private func resetViewportRefresh(clearSubmissionHistory: Bool = false) {
        if clearSubmissionHistory { viewportSubmissionIds.removeAll() }
        viewportRefreshFailed = false
        cancelViewportRefresh(requeue: false)
        pendingViewportDevice = nil
        viewportSnapshotSupported = false
        viewportRefreshTask?.cancel()
        viewportRefreshTask = nil
    }

    func setDirectEditing(_ owner: UUID, active: Bool) {
        if active {
            directEditingOwners.insert(owner)
            cancelViewportRefresh(requeue: true)
        } else {
            directEditingOwners.remove(owner)
        }
    }

    func reportDeviceCapabilities() {
        let current = device
        guard reportedDevice != current else { return }
        reportedDevice = current
        guard signedIn else { return }
        if viewportSnapshotSupported, activeChatId != nil {
            queueViewportRefresh(current)
            return
        }
        let identity = ClientOperationIdentity.fresh()
        beginLocalOperationSubmission(
            identity: identity,
            action: "update_device",
            surface: "operation",
            chatId: nil,
            exposeStatus: false)
        rawSend(
            Outbound.updateDevice(
                sessionId: nil,
                device: current,
                submissionId: identity.submissionId,
                requestGeneration: identity.requestGeneration))
    }

    private func connectWS(resumed initialResumed: Bool) {
        invalidateWorkRead()
        retireOrdinarySurfaceRequests()
        authenticationReadIntent = nil
        registeredAccessToken = nil
        connected = false
        wsTask?.cancel()
        let socketURL = rest.webSocketURL
        let socketOwner = downloadOwner
        let socketServer = serverBase
        let client =
            initialWebSocket
            ?? WSClient(
                url: socketURL, liveness: socketLiveness,
                requestHeaders: { [weak self] in
                    await self?.serverSocketHeaders(url: socketURL, owner: socketOwner, server: socketServer)
                })
        initialWebSocket = nil
        if let previous = ws, previous !== client {
            Task { await previous.stop() }
        }
        ws = client
        let owner = downloadOwner
        let server = serverBase
        let resumeState = AppRegistrationResumeState(initial: initialResumed)
        wsTask = Task {
            let events = await client.events()
            #if os(macOS)
                let onRegistration: (@Sendable (InboundFrame, String) async -> Bool)? = {
                    [weak self] frame, generation in
                    guard let self else { return false }
                    return await self.acceptRegistrationConfiguration(
                        frame, socket: client, owner: owner, generation: generation)
                }
            #else
                let onRegistration: (@Sendable (InboundFrame, String) async -> Bool)? = nil
            #endif
            await client.start(
                onConnect: { [weak self] in
                    guard let self else { return nil }
                    guard let token = await self.registrationToken(for: client, owner: owner, server: server) else {
                        return nil
                    }
                    let resumed = await resumeState.consume()
                    return await self.currentRegistrationFrame(
                        token: token, resumed: resumed, socket: client, owner: owner)
                },
                onReplay: { [weak self] replay in
                    guard let self else { return false }
                    return await self.replayQueuedOperation(replay, socket: client, owner: owner)
                }, onRegistration: onRegistration)
            for await event in events {
                guard !Task.isCancelled, self.ws === client, self.downloadOwner == owner else { break }
                await self.handle(event)
            }
            await client.stop()
        }
    }

    private func registrationToken(for socket: WSClient, owner: DownloadOwner, server: URL) async -> String? {
        guard !Task.isCancelled, ws === socket, downloadOwner == owner, serverBase == server else { return nil }
        let result = await refreshOutcome(renewSocket: false)
        guard !Task.isCancelled, ws === socket, downloadOwner == owner, serverBase == server else { return nil }
        switch result {
        case .ok(let set): return set.accessToken
        case .rejected:
            await signOut(revokeRemote: false)
            return nil
        case .transient: return nil
        }
    }

    private func currentRegistrationFrame(
        token: String, resumed: Bool, socket: WSClient, owner: DownloadOwner
    ) -> String? {
        guard !Task.isCancelled, ws === socket, downloadOwner == owner, tokens?.accessToken == token else { return nil }
        let intent = authenticationReadIntent.flatMap { current in
            current.owner == owner && current.socket === socket
                && current.generation == authenticationSurfaceGeneration(current.surface) ? current : nil
        }
        registeredAccessToken = token
        let frame = registrationFrame(token: token, resumed: resumed)
        if let intent {
            authenticationReadIntent = AuthenticationReadIntent(
                owner: owner, socket: socket, surface: intent.surface, params: intent.params,
                generation: authenticationSurfaceGeneration(intent.surface))
        }
        return frame
    }

    #if os(macOS)
        private func acceptRegistrationConfiguration(
            _ frame: InboundFrame, socket: WSClient, owner: DownloadOwner, generation: String
        ) -> Bool {
            guard !Task.isCancelled, ws === socket, downloadOwner == owner,
                continuity.connectionGeneration == generation
            else { return false }
            handleFrame(frame)
            return true
        }
    #endif

    private func replayQueuedOperation(_ replay: QueuedOperationReplay, socket: WSClient, owner: DownloadOwner) -> Bool
    {
        guard !Task.isCancelled, ws === socket, downloadOwner == owner else { return false }
        return replayQueuedOperation(replay)
    }

    func handle(_ event: WSEvent) async {
        switch event {
        case .connected:
            connected = true
            #if os(macOS)
                if projects.enabled { Task { await projects.refresh() } }
            #endif
            everConnected = true
            initialConnectionFailed = false
            resumeAuthenticatedRead()
            if continuity.connectionGeneration == nil {
                refreshActiveChat()
            }
            if let attempt = llmFirstLoginOperation,
                !attempt.isAuthoritativelyTerminal
            {
                Task { await self.reconcileLLMFirstLoginOperation() }
            }
        case .disconnected:
            retireSubmittedApprovals()
            #if os(macOS)
                macComputerHost.disconnect()
                projects.awaitNegotiation()
                cancelProjectChoice()
            #endif
            resetViewportRefresh()
            invalidateWorkRead()
            connected = false
            initialConnectionFailed = !everConnected
            if screen == .surface, !["guidance", "work"].contains(pendingSurfaceKey) {
                surfaceFailureMessage = "The connection was lost. Reconnect and retry this screen."
            }
            retireOrdinarySurfaceRequests(preservingReadIntent: true)
            voice.controlTransportDisconnected()
            clearPendingOperationSubmissions()
            turnActive = false
            pendingReplace = false
            pendingCanvas = []
            transientTurns = []
            transientCanvas = nil
            agentsLoading = false
            historyLoading = false
            auditLoading = false
            statusText = nil
        case .sendDropped(let total):
            bannerIsError = true
            errorBanner = "Not sent while offline (queue full: \(total) dropped)"
        case .queuedOperationDropped(let replay, let reason):
            localOperationSubmissions.removeValue(forKey: replay.identity.submissionId)
            if statusText == "Submitting…" {
                statusText =
                    localOperationSubmissions.values.contains(
                        where: localSubmissionShowsActivity) ? "Submitting…" : nil
            }
            bannerIsError = true
            errorBanner = "Not sent while offline: \(replay.action) (\(reason))"
        case .sendRejected(let action):
            clearPendingOperationSubmissions()
            bannerIsError = true
            errorBanner = "Not sent while offline: \(action) (invalid queued identity)"
        case .frame(let frame):
            handleFrame(frame)
        }
    }

    func handleFrame(_ incoming: InboundFrame) {
        #if os(macOS)
            let frame = sanitizedComputerReviews(incoming)
        #else
            let frame = incoming
        #endif
        if frame.name == "chat_status", frame.payload["approval_decision"] != nil {
            consumeApprovalReceipt(frame)
            return
        }
        #if os(macOS)
            if macComputerHost.consume(frame) {
                if ["computer_host", "computer_session"].contains(frame.name),
                    screen == .surface, pendingSurfaceKey == "my_computers"
                {
                    openSurface("my_computers")
                }
                return
            }
        #endif
        if frame.name == "ui_render", frame.renderTarget == "chat",
            !approvalPrompts.isEmpty
                || submittedApprovals.values.contains(where: { $0.chat == activeChatId && $0.owner == downloadOwner }),
            frame.chatId == nil || frame.chatId == activeChatId,
            frame.payload["connection_generation"] == nil
                || frame.payload["connection_generation"]?.stringValue == continuity.connectionGeneration,
            let alert = frame.renderComponents.first(where: { $0.type == "alert" }),
            let message = alert.raw["message"]?.stringValue, !message.isEmpty
        {
            errorBanner = message
            bannerIsError = alert.raw["variant"]?.stringValue != "success"
        }
        if consumeViewportStatus(frame) { return }
        if frame.name == "error",
            ["viewport_snapshot_rejected", "viewport_snapshot_retryable"].contains(
                frame.payload["code"]?.stringValue ?? "")
        {
            if let request = viewportRequest, request.matchesFailure(frame), request.isCurrent(in: continuity) {
                let retry = frame.payload["retryable"]?.boolValue == true && viewportRetryBudget > 0
                viewportRetryBudget -= retry ? 1 : 0
                if retry { cancelViewportRefresh(requeue: true) } else { failViewportRefresh() }
            }
            return
        }
        if guidanceState.matchesFailure(frame, connectionGeneration: continuity.connectionGeneration),
            let generation = guidanceState.generation
        {
            surfaceFailureMessage =
                AdmissionRefusal(frame: frame)?.message
                ?? OperationStatus(frame: frame)?.error["message"]?.stringValue
                ?? "Private notes could not be loaded. Retry this screen."
            failGuidanceRequest(generation: generation)
            return
        }
        if workReadState.matchesFailure(frame, connectionGeneration: continuity.connectionGeneration),
            let generation = workReadState.generation
        {
            failWorkRead(generation: generation)
            return
        }

        voice.consume(frame)
        if frame.name == "ui_render", frame.renderTarget == "history" {
            let conversationFields = [
                "chat_id", "chatId", "connection_generation", "request_generation",
                "base_render_revision", "frame_sequence",
            ]
            guard !conversationFields.contains(where: { frame.payload[$0] != nil }) else { return }
            if let list = frame.renderComponents.first(where: { $0.type == "chat_history" }),
                let items = list.raw["items"]?.arrayValue
            {
                history = items.compactMap { ChatSummary(historyItem: $0) }
                historyTitle = list.raw["title"]?.stringValue ?? "Recent chats"
                historyLoading = false
                historyLoaded = true
            } else if frame.renderComponents.contains(where: { $0.type == "skeleton" }) {
                historyLoading = true
            }
            return
        }
        if !workspaceStarted, continuity.requestGeneration == nil,
            let components = WorkspaceWelcome.unscopedComponents(in: frame)
        {
            canvas = components
            transientCanvas = nil
            return
        }
        if workspaceStarted, ["ui_render", "ui_update"].contains(frame.name),
            frame.renderTarget != "chat", !frame.renderComponents.isEmpty,
            !WorkspaceWelcome.containsWork(frame.renderComponents)
        {
            return
        }
        if continuity.connectionGeneration != nil,
            ["ui_render", "ui_update", "ui_upsert", "ui_append", "ui_stream_data"]
                .contains(frame.name)
        {
            reduceTransient(frame)
            return
        }
        switch frame.name {
        case "conversation_snapshot":
            reduceConversationSnapshot(frame)
        case "conversation_commit_ready":
            if let ready = ConversationCommitReady(frame: frame), continuity.accept(ready) {
                transientTurns = []
                transientCanvas = nil
            }
        case "ui_render":
            reduceUiRender(frame)
        case "ui_upsert":
            reduceUiUpsert(frame)
        case "chat_created":
            if let chatId = nestedChatId(frame) { adoptChat(chatId) }
        case "user_message_acked":
            if let chatId = nestedChatId(frame) { adoptChat(chatId) }
            turnActive = true
            pendingReplace = true
            pendingCanvas = []
            liveOpsThisTurn = false
        case "chat_loaded":
            if continuity.connectionGeneration == nil {
                reduceChatLoaded(frame)
            }
        case "chat_deleted":
            if let chatId = nestedChatId(frame) { clearConfirmedDeletion(chatId) }
        case "chat_status":
            if let target = frame.payload["chat_id"]?.stringValue, let active = activeChatId, target != active { break }
            if frame.payload["status"]?.stringValue == "done", frame.payload["message"]?.stringValue == "Cancelled" {
                recordActivityCancellation(chatId: nestedChatId(frame) ?? activeChatId)
            }
            if ["done", "idle"].contains(frame.payload["status"]?.stringValue ?? "") { finishActivityProgress() }
            reduceStatus(frame)
        case "agent_list":
            agents = Agent.list(from: frame.payload["agents"])
            agentsLoading = false
        case "history_list":
            let summaries = (frame.payload["chats"]?.arrayValue ?? []).compactMap { ChatSummary(json: $0) }
            #if os(macOS)
                if projects.enabled {
                    projects.mergeRecentActivity(summaries)
                    if frame.payload["projects_changed"]?.boolValue == true {
                        Task { await projects.refresh() }
                    }
                }
            #endif
            history = summaries
            historyTitle = "Recent chats"
            historyLoading = false
            historyLoaded = true
        case "ui_stream_data", "stream_data":
            if continuity.connectionGeneration == nil {
                applyCanvasOps(streamFrameToOps(frame, activeChat: activeChatId, seqState: &seqState))
            }
        case "stream_subscribed":
            if continuity.connectionGeneration == nil {
                applyCanvasOps(
                    subscribeAckOps(
                        frame,
                        existingIds: Set(canvas.compactMap(\.componentId))))
            }
        case "stream_error":
            if continuity.connectionGeneration != nil {
                transientTurns = []
                transientCanvas = nil
                statusText = nil
                bannerIsError = true
                errorBanner = frame.errorMessage
            } else {
                applyCanvasOps(streamErrorOps(frame))
            }
        case "chrome_menu":
            chromeMenu = ChromeMenuModel.fromJSON(frame.payload["model"])
            if pendingSurfaceKey == "guidance", !guidanceMenuAvailable {
                invalidateGuidance()
            }
            if pendingSurfaceKey == "work", WorkReadRequest.watchControls(in: chromeMenu).isEmpty {
                invalidateWorkRead()
                workReadFailed = true
            }
        case "rote_config":
            reduceViewportConfiguration(frame)
        case "chrome_surface":
            reduceChromeSurface(frame)
        case "operation_status":
            reduceOperationStatus(frame)
            reduceLLMOperationStatus(frame)
        case "agent_lifecycle":
            reduceAgentLifecycle(frame)
        #if os(macOS)
            case "llm_usage_report":
                if let report = LLMUsageReport(frame: frame) { llmUsage.record(report) }
        #endif
        case "user_preferences":
            themeStore.applyPreferences(frame.payload)
        case "theme_apply":
            themeStore.apply(spec: frame.payload["theme"] ?? frame.payload)
        case "workspace_timeline_mode":
            timelineReadOnly = frame.payload["active"]?.boolValue ?? frame.payload["on"]?.boolValue ?? false
        case "error":
            let admissionRefused = reduceAdmissionRefusal(frame)
            let llmAdmissionRefused = reduceLLMAdmissionRefusal(frame)
            if !admissionRefused && !llmAdmissionRefused {
                reduceError(frame)
            }
        case "chat_step":
            let step = frame.payload["step"]
            let name = step?["name"]?.stringValue ?? step?["kind"]?.stringValue
            stepTrail = trailUpsert(stepTrail, stepLine(name: name, status: step?["status"]?.stringValue))
            recordActivityStep(frame)
        case "tool_progress":
            let head = [frame.payload["tool_name"]?.stringValue, frame.payload["message"]?.stringValue]
                .compactMap { $0 }.joined(separator: ": ")
            // Int(Double) traps out-of-range — bounds-check before converting
            let pct =
                frame.payload["percentage"]
                .flatMap { value -> String? in
                    if let s = value.stringValue { return s }
                    guard let n = value.numberValue, n.isFinite, n >= 0, n <= 999
                    else { return nil }
                    return String(Int(n))
                }
                .map { " (\($0)%)" } ?? ""
            let label = (head + pct).isEmpty ? "Working…" : head + pct
            stepTrail = trailUpsert(stepTrail, "• \(label)")
            recordActivityProgress(frame, percent: pct)
        case "task_started":
            if frameTargetsActiveChat(frame) {
                statusText = "Working in the background…"
                asyncDetached = true
            }
        case "task_completed":
            if frameTargetsActiveChat(frame) {
                if continuity.connectionGeneration == nil {
                    commitTurn()
                    refreshActiveChat()
                } else {
                    turnActive = false
                    statusText = nil
                }
                bannerIsError = false
                errorBanner = "Background task finished"
            }
        case "notification":
            var text = [frame.payload["title"]?.stringValue, frame.payload["body"]?.stringValue]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
            if !text.isEmpty {
                if let chatId = nestedChatId(frame), chatId != activeChatId {
                    text += " — open it from History"
                }
                bannerIsError = frame.payload["level"]?.stringValue == "error"
                warningBannerText = frame.payload["level"]?.stringValue == "warning" ? text : nil
                errorBanner = text
            }
            if let chatId = nestedChatId(frame), chatId == activeChatId {
                refreshActiveChat()
            }
        case "component_saved":
            bannerIsError = false
            errorBanner = "Component saved"
        case "component_save_error":
            bannerIsError = true
            errorBanner = frame.payload["error"]?.stringValue ?? "Couldn't save component"
        case "component_deleted":
            if continuity.connectionGeneration == nil,
                let cid = frame.payload["component_id"]?.stringValue,
                !cid.isEmpty
            {
                applyCanvasOps([UpsertOp(op: "remove", componentId: cid, component: nil)])
            }
        case "combine_status":
            statusText = frame.payload["message"]?.stringValue ?? frame.payload["status"]?.stringValue
        case "combine_error":
            statusText = nil
            bannerIsError = true
            errorBanner = frame.payload["error"]?.stringValue ?? "Couldn't combine components"
        case "components_combined", "components_condensed":
            statusText = nil
            if continuity.connectionGeneration == nil {
                applyCanvasOps(replacementOps(frame))
            }
        case "saved_components_list":
            break
        case "auth_required":
            resetViewportRefresh()
            retireOrdinarySurfaceRequests()
            if pendingSurfaceKey == "safety" {
                surfaceFailureMessage = "Reload Safety to check current stop status before trying again."
            }
            if pendingSurfaceKey == "terminal" {
                surfaceFailureMessage = "The session could not update. Reconnect and retry this screen."
            }
            if let context = socketAuthenticationContext {
                Task { await self.handleAuthRequired(context) }
            }
        default:
            break
        }
    }

    private func reduceLLMOperationStatus(_ frame: InboundFrame) {
        guard let status = OperationStatus(frame: frame),
            status.action == "chrome_llm_save",
            status.surface == "llm_settings",
            continuity.connectionGeneration == status.connectionGeneration,
            var current = llmFirstLoginOperation,
            current.requestGeneration == status.requestGeneration,
            !current.isAuthoritativelyTerminal
        else { return }
        if let operationId = current.operationId, operationId != status.operationId {
            return
        }
        if let sequence = current.sequence, status.sequence <= sequence {
            return
        }
        current.operationId = status.operationId
        current.sequence = status.sequence
        current.phase = status.phase
        current.phaseVisible = current.phaseVisible || status.state != "accepted"

        let authoritativeState = LLMFirstLoginOperation.State(rawValue: status.state)
        guard let authoritativeState, authoritativeState != .submitting,
            authoritativeState != .unconfirmed
        else { return }
        if current.state == .unconfirmed && !status.terminal {
            current.label = "Unable to confirm; reconnecting"
            current.retryable = true
            llmFirstLoginOperation = current
            return
        }

        current.state = authoritativeState
        current.label = status.label
        current.retryable = status.retryable
        current.errorCode = status.error.objectValue?["code"]?.stringValue
        current.errorMessage = status.error.objectValue?["message"]?.stringValue
        current.isAuthoritativelyTerminal = status.terminal
        llmFirstLoginOperation = current
        if status.terminal {
            if status.state != "completed" {
                failOrdinarySurface(
                    generation: status.requestGeneration,
                    message: status.error["message"]?.stringValue ?? status.label)
            }
            cancelLLMTimers()
            if authoritativeState == .completed {
                advanceAfterLLMCompletionIfNeeded()
            }
        }
    }

    private func reduceOperationStatus(_ frame: InboundFrame) {
        guard let status = OperationStatus(frame: frame),
            statusLifecycle.accept(
                operation: status,
                connectionGeneration: continuity.connectionGeneration,
                conversationRequestGeneration: continuity.requestGeneration,
                activeChatId: activeChatId,
                pendingChatRequestGenerations: pendingChatRequestGenerations,
                pendingSurfaceRequestGenerations: pendingSurfaceRequestGenerations)
        else { return }
        operationStatuses = statusLifecycle.operations
        if status.terminal {
            if status.state != "completed" {
                failOrdinarySurface(
                    generation: status.requestGeneration,
                    message: status.error["message"]?.stringValue ?? status.label)
            }
            let ownsActiveChatTurn = operationOwnsActiveChatTurn(
                action: status.action,
                requestGeneration: status.requestGeneration)
            if status.state != "completed" {
                _ = continuity.retireUncommittedCommit(requestGeneration: status.requestGeneration)
            }
            clearLocalOperationSubmission(requestGeneration: status.requestGeneration)
            if ownsActiveChatTurn {
                settleActiveChatTurn(
                    requestGeneration: status.requestGeneration,
                    discardUncommitted: status.state != "completed")
            }
            if let message = status.error.objectValue?["message"]?.stringValue {
                bannerIsError = true
                errorBanner = message
                transientTurns = []
                transientCanvas = nil
            }
            statusText = latestActiveOperationStatusText()
        } else {
            statusText = status.label
        }
    }

    private func latestActiveOperationStatusText() -> String? {
        var pendingGenerations = pendingChatRequestGenerations.union(
            pendingSurfaceRequestGenerations)
        if let currentRequest = continuity.requestGeneration {
            pendingGenerations.insert(currentRequest)
        }
        let active = operationStatuses.values.filter {
            !$0.terminal && pendingGenerations.contains($0.requestGeneration)
        }.max {
            ($0.updatedAt, $0.sequence) < ($1.updatedAt, $1.sequence)
        }
        if let active {
            return active.label
        }
        return localOperationSubmissions.values.contains(where: localSubmissionShowsActivity)
            ? "Submitting…" : nil
    }

    private func reduceAgentLifecycle(_ frame: InboundFrame) {
        guard let lifecycle = AgentLifecycle(frame: frame),
            statusLifecycle.accept(lifecycle: lifecycle)
        else { return }
        agentLifecycles = statusLifecycle.agents
        bannerIsError = lifecycle.state == "failed"
        errorBanner = "\(lifecycle.agentId): \(lifecycle.label)"
    }

    @discardableResult
    private func reduceAdmissionRefusal(_ frame: InboundFrame) -> Bool {
        guard let refusal = AdmissionRefusal(frame: frame),
            let submission = localOperationSubmissions.removeValue(forKey: refusal.submissionId)
        else { return false }
        componentPendingOperations.removeValue(forKey: refusal.submissionId)
        failOrdinarySurface(generation: submission.requestGeneration, message: refusal.message)
        if operationOwnsActiveChatTurn(
            action: submission.action,
            requestGeneration: submission.requestGeneration)
        {
            settleActiveChatTurn(
                requestGeneration: submission.requestGeneration,
                discardUncommitted: true)
        }
        _ = continuity.retireUncommittedCommit(requestGeneration: submission.requestGeneration)
        statusText = latestActiveOperationStatusText()
        bannerIsError = true
        errorBanner = refusal.message
        return true
    }

    @discardableResult
    private func reduceLLMAdmissionRefusal(_ frame: InboundFrame) -> Bool {
        guard let refusal = AdmissionRefusal(frame: frame),
            var current = llmFirstLoginOperation,
            current.submissionId == refusal.submissionId,
            current.operationId == nil,
            !current.isAuthoritativelyTerminal
        else { return false }
        current.state = refusal.retryable ? .retryable : .failed
        current.phase = refusal.code
        current.label = refusal.message
        current.retryable = refusal.retryable
        current.errorCode = refusal.code
        current.errorMessage = current.label
        current.phaseVisible = true
        current.isAuthoritativelyTerminal = true
        llmFirstLoginOperation = current
        cancelLLMTimers()
        return true
    }

    private func advanceAfterLLMCompletionIfNeeded() {
        guard var current = llmFirstLoginOperation,
            current.requiresAdvance,
            !current.didAdvance
        else { return }
        current.didAdvance = true
        llmFirstLoginOperation = current
        mandatorySurface = false
        if screen == .surface {
            screen = .chat
            pendingSurface = nil
            pendingSurfaceKey = ""
            pendingSurfaceParams = .object([:])
        }
    }

    private func cancelLLMTimers() {
        llmPhaseTask?.cancel()
        llmPhaseTask = nil
        llmWatchdogTask?.cancel()
        llmWatchdogTask = nil
    }

    private func clearLLMFirstLoginOperation() {
        cancelLLMTimers()
        llmFirstLoginOperation = nil
        llmReconciliationRunning = false
    }

    private func armLLMFirstLoginTimers(submissionId: String) {
        cancelLLMTimers()
        let phaseDelay = llmFirstLoginPhaseDelay
        llmPhaseTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: phaseDelay)
            } catch {
                return
            }
            guard let self, var current = self.llmFirstLoginOperation,
                current.submissionId == submissionId,
                current.isLoading
            else { return }
            current.phaseVisible = true
            self.llmFirstLoginOperation = current
        }

        let watchdogDelay = llmFirstLoginWatchdogDelay
        llmWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: watchdogDelay)
            } catch {
                return
            }
            guard let self, var current = self.llmFirstLoginOperation,
                current.submissionId == submissionId,
                !current.isAuthoritativelyTerminal
            else { return }
            current.state = .unconfirmed
            current.phase = "awaiting_reconciliation"
            current.label = "Unable to confirm; reconnecting"
            current.retryable = true
            current.errorCode = "deadline_exceeded"
            current.errorMessage = "Unable to confirm; reconnecting"
            current.phaseVisible = true
            self.llmFirstLoginOperation = current
            self.llmPhaseTask?.cancel()
            self.llmPhaseTask = nil
            if self.connected {
                Task { await self.reconcileLLMFirstLoginOperation() }
            }
        }
    }

    func reconcileLLMFirstLoginOperation() async {
        guard !llmReconciliationRunning,
            let current = llmFirstLoginOperation,
            !current.isAuthoritativelyTerminal
        else { return }
        llmReconciliationRunning = true
        defer { llmReconciliationRunning = false }

        let result: LLMOperationReconciliation
        if let llmOperationReconciler {
            result = await llmOperationReconciler(current.operationId, current.submissionId)
        } else {
            do {
                let client = rest
                if let operationId = current.operationId {
                    if let operation = try await client.operation(id: operationId) {
                        result = .operation(operation)
                    } else {
                        result = .unavailable
                    }
                } else if let submission = try await client.operationSubmission(id: current.submissionId) {
                    result = .submission(submission)
                } else {
                    result = .unavailable
                }
            } catch {
                result = .unavailable
            }
        }

        guard let latest = llmFirstLoginOperation,
            latest.submissionId == current.submissionId,
            !latest.isAuthoritativelyTerminal
        else { return }
        switch result {
        case .operation(let operation):
            applyReconciledLLMOperation(operation)
        case .submission(.accepted(let operation)):
            applyReconciledLLMOperation(operation)
        case .submission(.refused(let code, let retryable, _)):
            var refused = latest
            refused.state = retryable ? .retryable : .failed
            refused.phase = code
            refused.label =
                retryable
                ? "The request was not accepted. Try again."
                : "The request was not accepted. Check the form."
            refused.retryable = retryable
            refused.errorCode = code
            refused.errorMessage = refused.label
            refused.phaseVisible = true
            refused.isAuthoritativelyTerminal = true
            llmFirstLoginOperation = refused
            cancelLLMTimers()
        case .unavailable:
            if latest.state == .unconfirmed {
                var unavailable = latest
                unavailable.label = "Unable to confirm; reconnecting"
                llmFirstLoginOperation = unavailable
            }
        }
    }

    private func applyReconciledLLMOperation(_ projection: OperationProjection) {
        guard projection.operationKind == "llm_credential_save",
            var current = llmFirstLoginOperation,
            projection.requestGeneration == current.requestGeneration,
            current.operationId == nil || current.operationId == projection.operationId,
            current.sequence == nil || projection.stateRevision > current.sequence!,
            !current.isAuthoritativelyTerminal
        else { return }
        current.operationId = projection.operationId
        current.sequence = projection.stateRevision
        current.phase = projection.phaseCode ?? projection.state
        let mapped: LLMFirstLoginOperation.State
        switch projection.state {
        case "queued":
            mapped = .accepted
        case "running":
            if current.phase == "validating_credentials" {
                mapped = .validating
            } else if current.phase == "saving_credentials" {
                mapped = .persisting
            } else {
                mapped = .running
            }
        case "completed":
            mapped = .completed
        case "failed":
            mapped = .failed
        case "cancelled":
            mapped = .cancelled
        case "retryable":
            mapped = .retryable
        default:
            return
        }
        let terminal = [.completed, .failed, .cancelled, .retryable].contains(mapped)
        if current.state != .unconfirmed || terminal {
            current.state = mapped
            current.label = projection.safeSummary ?? reconciledLLMLabel(for: mapped)
            current.retryable = mapped == .retryable
        }
        current.errorCode = projection.terminalCode
        current.errorMessage = terminal && mapped != .completed ? current.label : nil
        current.phaseVisible = current.phaseVisible || mapped != .accepted
        current.isAuthoritativelyTerminal = terminal
        llmFirstLoginOperation = current
        if terminal {
            cancelLLMTimers()
            if mapped == .completed {
                advanceAfterLLMCompletionIfNeeded()
            }
        }
    }

    private func reconciledLLMLabel(for state: LLMFirstLoginOperation.State) -> String {
        switch state {
        case .accepted:
            return "Accepted"
        case .validating:
            return "Checking your provider credentials…"
        case .persisting:
            return "Saving credentials…"
        case .running:
            return "Finishing provider setup…"
        case .completed:
            return "Provider setup complete"
        case .failed:
            return "Check your provider credentials"
        case .cancelled:
            return "Provider setup cancelled"
        case .retryable:
            return "Provider unavailable. Try again."
        case .submitting:
            return "Submitting…"
        case .unconfirmed:
            return "Unable to confirm; reconnecting"
        }
    }

    private func reduceConversationSnapshot(_ frame: InboundFrame) {
        guard let snapshot = ConversationSnapshot(frame: frame) else { return }
        if let request = viewportRequest, request.matches(snapshot) {
            guard !viewportRefreshBusy else {
                cancelViewportRefresh(requeue: true)
                return
            }
            guard continuity.apply(snapshot) == .applied else { return }
            viewportRefreshFailed = false
            viewportRequest = nil
            viewportSettledSnapshot = nil
            if let viewportPresentation { consolePresentation = viewportPresentation }
            viewportPresentation = nil
            canvas = snapshot.canvasComponents
            turns = turns.map { turn in
                guard let message = snapshot.messages.first(where: { $0.messageId == turn.id }) else { return turn }
                return ChatTurn(id: turn.id, role: turn.role, text: turn.text, components: message.components)
            }
            return
        }
        guard continuity.apply(snapshot) == .applied else { return }
        viewportRefreshFailed = false

        if let account = conversationAccount {
            _ = conversationResumeStore.save(chatId: snapshot.chatId, for: account)
        }
        let restoredTurns = snapshot.messages.map { message in
            var text = message.visibleText
            if !message.attachmentNames.isEmpty {
                let attachments = "📎 " + message.attachmentNames.joined(separator: ", ")
                text = text.isEmpty ? attachments : text + "\n" + attachments
            }
            return ChatTurn(
                id: message.messageId,
                role: message.role,
                text: text,
                components: message.components)
        }
        activeChatId = snapshot.chatId
        turns = restoredTurns
        canvas = snapshot.canvasComponents
        transientTurns = []
        transientCanvas = nil
        pendingCanvas = []
        canvasHistory = []
        viewingIndex = nil
        turnActive = false
        pendingReplace = false
        liveOpsThisTurn = false
        statusText = nil
        stepTrail = []
        asyncDetached = false
        pendingCommitRequestGeneration = nil
        voice.conversationDidHydrate(snapshot)
    }

    private func chatPreviewTurn(
        _ components: [AstralComponent], frame: InboundFrame
    ) -> ChatTurn? {
        let text = flattenText(components)
        guard !text.isEmpty else { return nil }
        return ChatTurn(
            id: "preview-\(frame.payload["frame_sequence"]?.numberValue ?? 0)",
            role: "assistant",
            text: text,
            components: [])
    }

    private func canvasPreviewComponents(
        _ components: [AstralComponent]
    ) -> [AstralComponent] {
        components.filter {
            !isReasoning($0) && !isDocCard($0.componentId) && !isSkeleton($0)
        }
    }

    private func reduceTransient(_ frame: InboundFrame) {
        guard viewportRequest == nil, continuity.acceptTransient(frame) else { return }
        acceptingTransientNavigationRender = true
        defer { acceptingTransientNavigationRender = false }
        switch frame.name {
        case "ui_render", "ui_update":
            let components = frame.renderComponents
            if frame.renderTarget == "chat" {
                let pendingUsers = transientTurns.filter { $0.role == "user" }
                let response = chatPreviewTurn(components, frame: frame).map { [$0] } ?? []
                transientTurns = pendingUsers + response
            } else {
                transientCanvas = canvasPreviewComponents(components)
            }
        case "ui_append":
            let components = frame.renderComponents
            if frame.renderTarget == "chat" {
                if let turn = chatPreviewTurn(components, frame: frame) {
                    transientTurns.append(turn)
                }
            } else {
                transientCanvas =
                    (transientCanvas ?? canvas) + canvasPreviewComponents(components)
            }
        case "ui_upsert":
            transientCanvas = Canvas.apply(transientCanvas ?? canvas, frame.upsertOps)
        case "ui_stream_data":
            transientCanvas = Canvas.apply(
                transientCanvas ?? canvas,
                streamFrameToOps(frame, activeChat: activeChatId, seqState: &seqState))
        default:
            break
        }
    }

    private func adoptChat(_ chatId: String) {
        if let account = conversationAccount {
            _ = conversationResumeStore.save(chatId: chatId, for: account)
        }
        if activeChatId == nil, let pending = activityLog.removeValue(forKey: activityKey(nil)) {
            activityLog[chatId] = Array(((activityLog[chatId] ?? []) + pending).suffix(Self.maximumActivityRows))
            touchActivityChat(chatId)
        }
        activeChatId = chatId
        voice.updateVisibleChatLocally(chatId)
        guard let request = pendingCommitRequestGeneration else { return }
        if openConversationRequest(
            chatId: chatId,
            requestGeneration: request,
            purpose: .commit)
        {
            pendingCommitRequestGeneration = nil
        }
    }

    private func clearConfirmedDeletion(_ chatId: String) {
        if let account = conversationAccount {
            _ = conversationResumeStore.clear(
                .confirmedDeletion,
                for: account,
                chatId: chatId)
        }
        activityLog.removeValue(forKey: chatId)
        activityOrder.removeAll { $0 == chatId }
        guard activeChatId == chatId else { return }
        clearContinuityChatKeepingConnection()
        resetChatState()
    }

    private func clearContinuityChatKeepingConnection() {
        continuity.clearChatKeepingConnection()
    }

    private func nestedChatId(_ frame: InboundFrame) -> String? {
        frame.payload["payload"]?["chat_id"]?.stringValue ?? frame.payload["chat_id"]?.stringValue
    }

    private func frameTargetsActiveChat(_ frame: InboundFrame) -> Bool {
        guard let chatId = nestedChatId(frame), !chatId.isEmpty else { return true }
        return chatId == activeChatId
    }

    @discardableResult
    private func refreshActiveChat() -> String? {
        guard let chatId = activeChatId, !chatId.isEmpty else { return nil }
        let identity = ClientOperationIdentity.fresh()
        let request = identity.requestGeneration
        if continuity.connectionGeneration != nil {
            guard
                openConversationRequest(
                    chatId: chatId,
                    requestGeneration: request,
                    purpose: .hydration)
            else { return nil }
        }
        beginLocalOperationSubmission(
            identity: identity,
            action: "load_chat",
            surface: "chat",
            chatId: chatId)
        rawSend(
            Outbound.loadChat(
                sessionId: activeChatId,
                chatId: chatId,
                submissionId: identity.submissionId,
                requestGeneration: request))
        return request
    }

    private func reduceUiRender(_ frame: InboundFrame) {
        let comps = frame.renderComponents
        if frame.renderTarget == "chat" {
            if frame.chatId == nil || frame.chatId == activeChatId,
                let alert = comps.first(where: { $0.type == "alert" }),
                let message = alert.raw["message"]?.stringValue, !message.isEmpty
            {
                errorBanner = message
                bannerIsError = alert.raw["variant"]?.stringValue != "success"
            }
            let text = flattenText(comps)
            if text.isEmpty || text.range(of: docMarker, options: .caseInsensitive) != nil { return }
            appendTurn(role: "assistant", text: text)
            return
        }
        let reasoning = comps.filter { isReasoning($0) }
        let canvasComps = comps.filter { !isReasoning($0) && !isDocCard($0.componentId) && !isSkeleton($0) }
        for r in reasoning {
            let text = flattenText(r.children).isEmpty ? flattenText([r]) : flattenText(r.children)
            if !text.isEmpty { appendTurn(role: "reasoning", text: text) }
        }
        if pendingReplace {
            if canvasComps.isEmpty { return }
            pendingCanvas = Canvas.apply(pendingCanvas, renderToOps(canvasComps))
        } else {
            canvas = canvasComps
            pendingCanvas = []
        }
    }

    private func reduceUiUpsert(_ frame: InboundFrame) {
        if let chatId = frame.chatId, let active = activeChatId, chatId != active { return }
        let ops = frame.upsertOps
        for op in ops where op.op != "remove" && isDocCard(op.componentId) {
            if let comp = op.component {
                let text = flattenText([comp])
                if !text.isEmpty { appendTurn(role: "assistant", text: text) }
            }
        }
        let canvasOps = ops.filter { !isDocCard($0.componentId) && !isSkeleton($0.component) }
        applyCanvasOps(canvasOps)
    }

    private func reduceChatLoaded(_ frame: InboundFrame) {
        let chat = frame.payload["chat"]
        activeChatId = chat?["id"]?.stringValue ?? activeChatId
        if let account = conversationAccount, let activeChatId {
            _ = conversationResumeStore.save(chatId: activeChatId, for: account)
        }
        let messages = chat?["messages"]?.arrayValue ?? chat?["history"]?.arrayValue ?? []
        turns = messages.enumerated().map { index, m in
            let content = m["content"]?.stringValue ?? m["text"]?.stringValue ?? ""
            let role = m["role"]?.stringValue ?? (m["is_user"]?.boolValue == true ? "user" : "assistant")
            return ChatTurn(id: "hist-\(index)", role: role, text: content)
        }
        canvas = []
        pendingCanvas = []
        canvasHistory = []
        viewingIndex = nil
        turnActive = false
        pendingReplace = false
        canvasLabel = ""
        pendingLabel = ""
        statusText = nil
        stepTrail = []
        asyncDetached = false
    }

    private func reduceChromeSurface(_ frame: InboundFrame) {
        let surfaceKey = frame.payload["surface_key"]?.stringValue ?? ""
        if pendingSurfaceKey == "safety" || surfaceKey == "safety" {
            guard screen == .surface, pendingSurfaceKey == "safety", frame.surfaceMode == "replace",
                let generation = frame.payload["request_generation"]?.stringValue,
                generation == ordinarySurfaceGeneration
            else { return }
        }
        if pendingSurfaceKey == "evidence" || surfaceKey == "evidence" {
            guard screen == .surface, pendingSurfaceKey == "evidence",
                let fields = frame.payload.objectValue,
                Set(fields.keys) == [
                    "type", "surface_key", "region", "title", "admin_only", "components", "mode", "request_generation",
                ],
                fields["type"] == .string("chrome_surface"), ["evidence", ""].contains(surfaceKey),
                fields["surface_key"] == .string(surfaceKey),
                fields["region"] == .string("modal"), fields["mode"] == .string("replace"),
                fields["admin_only"] == .bool(false), fields["title"]?.stringValue != nil,
                let generation = fields["request_generation"]?.stringValue,
                UUID(uuidString: generation)?.uuidString.lowercased() == generation,
                generation.range(
                    of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\z",
                    options: .regularExpression) != nil,
                generation == ordinarySurfaceGeneration,
                let components = fields["components"]?.arrayValue,
                components.allSatisfy({
                    ["alert", "badge", "keyvalue", "button"].contains($0["type"]?.stringValue ?? "")
                })
            else { return }
        }
        if surfaceKey == "terminal" {
            let allowed: Set<String> = [
                "alert", "badge", "button", "card", "code", "keyvalue", "text",
            ]
            guard signedIn, connected, screen == .surface, pendingSurfaceKey == "terminal",
                let fields = frame.payload.objectValue,
                Set(fields.keys) == [
                    "type", "surface_key", "region", "title", "admin_only", "components", "mode",
                    "request_generation",
                ],
                fields["type"] == .string("chrome_surface"), fields["surface_key"] == .string("terminal"),
                fields["region"] == .string("modal"), fields["mode"] == .string("replace"),
                fields["admin_only"] == .bool(false), fields["title"]?.stringValue != nil,
                let generation = fields["request_generation"]?.stringValue,
                UUID(uuidString: generation)?.uuidString.lowercased() == generation,
                generation == ordinarySurfaceGeneration,
                let components = fields["components"]?.arrayValue,
                components.allSatisfy({
                    allowed.contains($0["type"]?.stringValue ?? "")
                })
            else { return }
        }
        if surfaceKey == "guidance" {
            guard signedIn, connected, screen == .surface, pendingSurfaceKey == "guidance",
                let update = GuidanceSurfaceUpdate(frame: frame), guidanceState.accepts(update)
            else { return }
            if let selection = frame.payload["selection"], let decoded = TurnSelection(json: selection) {
                turnSelection = decoded.isEmpty ? nil : decoded
            }
            retireGuidanceTicket()
            if update.components.isEmpty {
                invalidateGuidance()
                guidanceFailed = false
                pendingSurfaceKey = ""
                screen = .chat
            } else {
                guidanceUpdate = update
                guidanceFailed = false
                pendingSurface = SurfaceContent(
                    surfaceKey: "guidance", title: update.title, components: update.components)
            }
            return
        }
        if screen == .surface && pendingSurfaceKey == "guidance" { return }
        if surfaceKey == "work" {
            guard signedIn, connected, screen == .surface, pendingSurfaceKey == "work",
                let update = WorkSurfaceUpdate(frame: frame), workReadState.accepts(update)
            else { return }
            retireWorkTicket()
            if update.components.isEmpty {
                invalidateWorkRead()
                screen = .chat
            } else {
                workReadUpdate = update
                workReadFailed = false
                pendingSurface = SurfaceContent(surfaceKey: "work", title: update.title, components: update.components)
                surfaceNavigationScope = (downloadOwner, continuity.connectionGeneration, UUID())
            }
            return
        }
        if screen == .surface && pendingSurfaceKey == "work" { return }
        let title = frame.payload["title"]?.stringValue ?? ""
        let components = AstralComponent.list(from: frame.payload["components"])
        if surfaceKey.isEmpty && components.isEmpty {
            if frame.payload["request_generation"] != nil {
                guard !mandatorySurface, screen == .surface, !pendingSurfaceKey.isEmpty,
                    frame.payload["surface_key"] == .string(""), frame.payload["title"] == .string(""),
                    frame.payload["region"] == .string("modal"), frame.payload["mode"] == .string("replace"),
                    frame.payload["admin_only"] == .bool(false), frame.payload["components"] == .array([]),
                    frame.payload["selection"] == nil,
                    acceptsOrdinarySurface(frame, surface: pendingSurfaceKey)
                else { return }
                closeSurface()
                return
            }
            mandatorySurface = false
            if screen == .surface {
                screen = .chat
                pendingSurface = nil
                pendingSurfaceKey = ""
                pendingSurfaceParams = .object([:])
            }
            return
        }
        if frame.surfaceMode == "mandatory" {
            if frame.payload["request_generation"] != nil {
                guard acceptsOrdinarySurface(frame, surface: surfaceKey) else { return }
            }
            invalidateWorkRead()
            retireOrdinarySurfaceRequests()
            surfaceFailureMessage = nil
            mandatorySurface = true
            screen = .surface
            pendingSurfaceKey = surfaceKey
            pendingSurfaceParams = .object([:])
            replaceOrdinarySurface(key: surfaceKey, title: title, components: components)
            applySurfaceTheme(components)
            return
        }
        if screen == .surface && pendingSurfaceKey == surfaceKey {
            guard acceptsOrdinarySurface(frame, surface: surfaceKey) else { return }
            replaceOrdinarySurface(key: surfaceKey, title: title, components: components)
            surfaceFailureMessage = nil
            applySurfaceTheme(components)
            return
        }
        if frame.payload["request_generation"] != nil { return }
        let text = [title, noticeText(components)].filter { !$0.isEmpty }.joined(separator: ": ")
        if !text.isEmpty {
            bannerIsError = true
            errorBanner = text
        }
    }

    private func applySurfaceTheme(_ components: [AstralComponent]) {
        for component in components {
            if component.type == "theme_apply" {
                themeStore.apply(spec: component.raw["attributes"] ?? component.raw)
            }
            applySurfaceTheme(component.children)
        }
    }

    private func replaceOrdinarySurface(key: String, title: String, components: [AstralComponent]) {
        let retained =
            key != "safety" && surfaceContainsError(components) && components.allSatisfy { $0.type == "alert" }
                && pendingSurface?.surfaceKey == key
            ? pendingSurface?.components.filter { $0.type != "alert" } ?? [] : []
        pendingSurface = SurfaceContent(surfaceKey: key, title: title, components: components + retained)
    }

    private func acceptsOrdinarySurface(_ frame: InboundFrame, surface: String) -> Bool {
        guard signedIn, connected, let current = ordinarySurfaceGeneration,
            let request = ordinarySurfaceRequests[current], request.surface == surface,
            request.owner == downloadOwner, request.connection == continuity.connectionGeneration,
            request.socket === ws, !["evidence", "terminal"].contains(surface) || request.conversation == activeChatId
        else { return false }
        if let generation = frame.payload["request_generation"] {
            guard generation.stringValue == current else { return false }
        } else {
            guard ordinarySurfaceRequests.count == 1 else { return false }
        }
        if surfaceContainsError(AstralComponent.list(from: frame.payload["components"])) {
            parameterFailures.insert(current)
        } else {
            parameterFailures.remove(current)
        }
        ordinarySurfaceRequests.removeValue(forKey: current)
        ordinarySurfaceGeneration = nil
        surfaceNavigationScope = (downloadOwner, continuity.connectionGeneration, UUID())
        return true
    }

    private func surfaceContainsError(_ components: [AstralComponent]) -> Bool {
        components.contains {
            ($0.type == "alert" && ["error", "danger"].contains($0.variant ?? ""))
                || surfaceContainsError($0.children)
        }
    }

    private func retireOrdinarySurfaceRequests(preservingReadIntent: Bool = false) {
        surfaceNavigationScope = nil
        ordinarySurfaceRequests = [:]
        ordinarySurfaceGeneration = nil
        if ["evidence", "safety", "terminal"].contains(pendingSurfaceKey) { pendingSurface = nil }
        if !preservingReadIntent || ["evidence", "safety", "terminal"].contains(pendingSurfaceKey) {
            ordinaryReadIntent = nil
        }
    }

    private func failOrdinarySurface(generation: String, message: String) {
        guard ordinarySurfaceGeneration == generation,
            let request = ordinarySurfaceRequests[generation], request.owner == downloadOwner,
            request.surface == pendingSurfaceKey, screen == .surface
        else { return }
        ordinarySurfaceRequests.removeValue(forKey: generation)
        ordinarySurfaceGeneration = nil
        if ["safety", "terminal"].contains(pendingSurfaceKey) { pendingSurface = nil }
        if pendingSurfaceKey == "terminal" { ordinaryReadIntent = nil }
        surfaceFailureMessage = message
    }

    private func bindOrdinarySurfaceRequest(identity: ClientOperationIdentity, action: String, payload: JSONValue) {
        let surface = action == "chrome_open" ? payload["surface"]?.stringValue : pendingSurfaceKey
        guard let surface, !surface.isEmpty, !["guidance", "work"].contains(surface), action != "chrome_close",
            action == "chrome_open" || screen == .surface
        else { return }
        if action == "chrome_open" {
            ordinaryReadIntent = (identity.requestGeneration, downloadOwner)
        }
        ordinarySurfaceRequests = ordinarySurfaceRequests.filter { entry in
            localOperationSubmissions.values.contains { $0.requestGeneration == entry.key }
        }
        ordinarySurfaceRequests[identity.requestGeneration] = OrdinarySurfaceRequest(
            surface: surface, connection: continuity.connectionGeneration, owner: downloadOwner, socket: ws,
            conversation: activeChatId)
        ordinarySurfaceGeneration = identity.requestGeneration
        surfaceFailureMessage = nil
    }

    private func reduceError(_ frame: InboundFrame) {
        let code = frame.payload["code"]?.stringValue
        let safeErrorClasses: Set<String> = [
            "auth_failed", "model_not_found", "transport_error",
            "contract_violation", "provider_unavailable", "other",
        ]
        let specificCode = frame.payload["error_class"]?.stringValue.flatMap {
            safeErrorClasses.contains($0) ? $0 : nil
        }
        let displayedCode = specificCode ?? code
        let message =
            frame.payload["message"]?.stringValue
            ?? frame.payload["payload"]?["message"]?.stringValue ?? "Something went wrong."
        errorBanner =
            (displayedCode != nil && displayedCode != "internal")
            ? "\(message) (\(displayedCode!))" : message
        bannerIsError = true
        turnActive = false
        pendingReplace = false
        pendingCanvas = []
        transientTurns = []
        transientCanvas = nil
        agentsLoading = false
        historyLoading = false
        auditLoading = false
        statusText = nil
        asyncDetached = false
        if code == "chat_not_found" || code == "conversation_not_found" {
            let deletedChat = nestedChatId(frame) ?? activeChatId
            if let deletedChat {
                clearConfirmedDeletion(deletedChat)
                errorBanner = (code != "internal") ? "\(message) (\(code!))" : message
                bannerIsError = true
            }
        }
    }

    private func reduceStatus(_ frame: InboundFrame) {
        let status = frame.payload["status"]?.stringValue
        let message = frame.payload["message"]?.stringValue
        let label = (message?.isEmpty == false) ? message : status
        switch status {
        case "done":
            if continuity.connectionGeneration == nil {
                commitTurn()
            } else {
                turnActive = false
                statusText = nil
                stepTrail = []
                asyncDetached = false
                pendingReplace = false
                liveOpsThisTurn = false
            }
        case "idle":
            turnActive = false
            statusText = nil
            stepTrail = []
            asyncDetached = false
        case "thinking", "executing", "fixing", "processing_async":
            turnActive = true
            statusText = label
        default:
            statusText = label
        }
    }

    private func commitTurn() {
        if !pendingReplace {
            turnActive = false
            statusText = nil
            stepTrail = []
            asyncDetached = false
            return
        }
        if pendingCanvas.isEmpty {
            canvas = canvas.dropWelcome()
            turnActive = false
            pendingReplace = false
            statusText = nil
            stepTrail = []
            asyncDetached = false
            return
        }
        let archived = canvas.dropWelcome()
        if !archived.isEmpty {
            let label = canvasLabel.isEmpty ? "Canvas \(canvasHistory.count + 1)" : canvasLabel
            canvasHistory.append(CanvasSnapshot(label: label, components: archived))
        }
        canvas = pendingCanvas
        pendingCanvas = []
        canvasLabel = pendingLabel
        pendingLabel = ""
        turnActive = false
        pendingReplace = false
        statusText = nil
        stepTrail = []
        asyncDetached = false
    }

    private func applyCanvasOps(_ ops: [UpsertOp]) {
        if ops.isEmpty { return }
        canvas = Canvas.apply(canvas, ops)
        if pendingReplace {
            liveOpsThisTurn = true
            if !pendingCanvas.isEmpty {
                pendingCanvas = Canvas.apply(pendingCanvas, ops)
            }
        }
    }

    private func appendTurn(role: String, text: String) {
        turns.append(ChatTurn(id: "\(role)-\(turns.count)", role: role, text: text))
    }

    private func renderToOps(_ components: [AstralComponent]) -> [UpsertOp] {
        components.enumerated().map { i, c in
            let id = c.componentId ?? "xr-\(c.type)-\(i)"
            return UpsertOp(
                op: "upsert", componentId: id,
                component: c.componentId == nil ? c.withComponentId(id) : c)
        }
    }

    private func replacementOps(_ frame: InboundFrame) -> [UpsertOp] {
        let removed = frame.payload["removed_ids"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        var ops: [UpsertOp] = removed.map { UpsertOp(op: "remove", componentId: $0, component: nil) }
        for row in frame.payload["new_components"]?.arrayValue ?? [] {
            guard let comp = row["component_data"].flatMap({ AstralComponent(json: $0) }) else { continue }
            let cid = comp.componentId ?? row["id"]?.stringValue ?? "combined-\(ops.count)"
            ops.append(
                UpsertOp(
                    op: "upsert", componentId: cid,
                    component: comp.componentId == nil ? comp.withComponentId(cid) : comp))
        }
        return ops
    }

    private func stepLine(name: String?, status: String?) -> String {
        let icon: String
        switch status {
        case "completed": icon = "✓"
        case "errored": icon = "✗"
        default: icon = "•"
        }
        return "\(icon) \(name ?? "step")"
    }

    private func trailKey(_ line: String) -> String {
        let afterSpace = line.contains(" ") ? String(line[line.index(after: line.firstIndex(of: " ")!)...]) : line
        return afterSpace.replacingOccurrences(of: #"\s*\(\d+(\.\d+)?%\)$"#, with: "", options: .regularExpression)
    }

    private func trailUpsert(_ trail: [String], _ line: String) -> [String] {
        let key = trailKey(line)
        var next = trail
        if let idx = trail.lastIndex(where: { trailKey($0) == key }) {
            next[idx] = line
        } else {
            next.append(line)
        }
        return Array(next.suffix(maxTrail))
    }

    struct PendingApproval: Equatable {
        let requestId: String
        let tool: String
        let summary: String
        let image: String?
    }

    @discardableResult
    func cancelCurrentTurn() -> Bool {
        guard canCancelTurn else { return false }
        endRunningActivity(chatId: activeChatId)
        rawSend(Outbound.uiEvent(action: "cancel_task", sessionId: activeChatId, payload: .object([:])))
        return true
    }

    #if os(macOS)
        func computerApplicationWillTerminate() {
            releaseComputerBypass()
            macComputerHost.applicationWillTerminate()
        }

        private func releaseComputerBypass() {
            guard let frame = macComputerHost.releaseBypass() else { return }
            outboundTap?(frame)
            guard let socket = ws, let connection = continuity.connectionGeneration,
                let bound = ComputerHostOutbound.bindToConnection(frame, connectionGeneration: connection)
            else { return }
            Task { _ = await socket.sendCurrentComputerEvent(bound, connectionGeneration: connection) { true } }
        }

        func stopComputerTask() {
            cancelCurrentTurn()
            macComputerHost.stop()
        }
    #endif

    struct ApprovalPrompt: Equatable, Identifiable {
        struct Choice: Equatable {
            let action: String
            let payload: [String: JSONValue]
        }
        let requestId: String
        let site: String?
        let summary: String
        let allow: Choice
        let deny: Choice
        var id: String { requestId }
    }

    private(set) var approvalPrompts: [ApprovalPrompt] = []
    var waitingApprovals: Int { max(activity.filter { $0.approval == .waiting }.count, approvalPrompts.count) }

    func decideApproval(_ prompt: ApprovalPrompt, allow: Bool) {
        guard approvalPrompts.contains(prompt) else { return }
        let choice = allow ? prompt.allow : prompt.deny
        emit(choice.action, payload: choice.payload)
    }

    static func pendingComputerApprovals(in components: [AstralComponent]) -> [PendingApproval] {
        approvalCards(in: components).map(\.approval)
    }

    private static func approvalCards(in components: [AstralComponent]) -> [(
        card: AstralComponent, approval: PendingApproval
    )] {
        var found: [(card: AstralComponent, approval: PendingApproval)] = []
        func visit(_ component: AstralComponent, depth: Int) {
            if component.type == "card", let approval = computerApproval(component) {
                found.append((component, approval))
                return
            }
            guard depth < 3 else { return }
            for child in component.children { visit(child, depth: depth + 1) }
        }
        for component in components { visit(component, depth: 0) }
        return found
    }

    private static func approvalPrompt(_ card: AstralComponent, _ approval: PendingApproval) -> ApprovalPrompt? {
        let choices = card.children.compactMap { child -> (decision: String, choice: ApprovalPrompt.Choice)? in
            guard child.type == "button", child.raw["disabled"]?.boolValue != true,
                let action = child.raw["action"]?.stringValue, let payload = child.raw["payload"]?.objectValue,
                let decision = payload["decision"]?.stringValue
            else { return nil }
            return (decision, ApprovalPrompt.Choice(action: action, payload: payload))
        }
        guard
            let allow = choices.first(where: { $0.decision == "approve" })
                ?? choices.first(where: { $0.decision == "approve_and_resume" }),
            let deny = choices.first(where: { $0.decision == "decline" })
        else { return nil }
        let texts = card.children.filter { $0.type == "text" }.compactMap(\.textContent)
        let summary = activityLine(texts.first { !$0.hasPrefix("Tool: ") } ?? approval.summary, limit: 300)
        return ApprovalPrompt(
            requestId: approval.requestId, site: approvalSite(summary), summary: summary, allow: allow.choice,
            deny: deny.choice)
    }

    private static func bypassApproved(_ card: AstralComponent) -> Bool {
        ["bypass", "project_grant"].contains(card.raw["approval_source"]?.stringValue ?? "")
            || card.children.contains {
                ["bypass", "project_grant"].contains($0.raw["payload"]?["approval_source"]?.stringValue ?? "")
            }
    }

    static func approvalSite(_ summary: String) -> String? {
        guard summary.hasPrefix("Open "), summary.contains(" browser pane") else { return nil }
        let token = String(summary.dropFirst(5).prefix { !$0.isWhitespace })
        guard let url = URL(string: token), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty
        else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    private static func computerApproval(_ card: AstralComponent) -> PendingApproval? {
        let children = card.children
        let requests = children.compactMap { child -> String? in
            guard child.type == "button", child.raw["disabled"]?.boolValue != true,
                ["authorize_action", "remote_op_decision"].contains(child.raw["action"]?.stringValue ?? ""),
                let payload = child.raw["payload"],
                let id = (payload["hitl_request_id"] ?? payload["proposal_id"])?.stringValue,
                !id.isEmpty, id.count <= 200
            else { return nil }
            return id
        }
        guard let requestId = requests.first, requests.allSatisfy({ $0 == requestId }) else { return nil }
        let texts = children.filter { $0.type == "text" }.compactMap(\.textContent)
        let image = children.first { $0.type == "image" && $0.url?.hasPrefix("data:image/") == true }?.url
        if card.componentId == "hitl_\(requestId)",
            let review = texts.first(where: { $0.hasPrefix("Tool: ") && $0.contains(" · Agent: computer-use-1") })
        {
            let tool = String(review.dropFirst(6).prefix { $0 != " " })
            let summary = texts.drop { $0 != review }.dropFirst().first ?? ""
            return PendingApproval(requestId: requestId, tool: tool, summary: activityLine(summary), image: image)
        }
        if card.componentId == "au_approval_\(requestId)", card.title?.hasPrefix("Confirm an action on ") == true {
            return PendingApproval(
                requestId: requestId, tool: "", summary: activityLine(texts.first ?? ""), image: image)
        }
        return nil
    }

    static func activityLine(_ text: String, limit: Int = 120) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    static func activityAction(_ tool: String) -> String {
        tool.isEmpty ? "Action" : tool.replacingOccurrences(of: "_", with: " ")
    }

    static func activityTarget(_ arguments: String) -> String {
        guard !arguments.isEmpty else { return "" }
        guard let object = (try? JSONValue.parse(Data(arguments.utf8)))?.objectValue else {
            return arguments.hasPrefix("{") ? "" : activityLine(arguments)
        }
        func text(_ value: JSONValue?) -> String? {
            guard let value else { return nil }
            if let items = value.arrayValue { return items.map(\.displayText).joined(separator: "+") }
            let shown = value.displayText
            return shown.isEmpty ? nil : shown
        }
        if let x = text(object["x"]), let y = text(object["y"]) { return "at \(x), \(y)" }
        if let x = text(object["x1"]), let y = text(object["y1"]), let x2 = text(object["x2"]),
            let y2 = text(object["y2"])
        {
            return "from \(x), \(y) to \(x2), \(y2)"
        }
        for key in [
            "command", "url", "app", "app_name", "bundle_id", "path", "text", "keys", "query", "ref", "title", "name",
            "job_id", "direction",
        ] {
            if let value = text(object[key]) { return activityLine(value) }
        }
        let pairs = object.keys.filter { !$0.hasPrefix("_") }.sorted().prefix(3).compactMap { key in
            text(object[key]).map { "\(key) \($0)" }
        }
        return activityLine(pairs.joined(separator: ", "))
    }

    static func activityResult(_ summary: String?) -> (text: String, waiting: Bool) {
        guard let summary, !summary.isEmpty else { return ("", false) }
        guard let parsed = try? JSONValue.parse(Data(summary.utf8)) else {
            if summary.contains("\"confirmation_required\"") { return ("", true) }
            return (summary.hasPrefix("{") || summary.hasPrefix("[") ? "" : activityLine(summary), false)
        }
        guard let object = parsed.objectValue else { return (activityLine(parsed.displayText), false) }
        let data = object["_data"]?.objectValue ?? object
        if data["status"]?.stringValue == "confirmation_required" { return ("", true) }
        if let error = data["error"]?["message"]?.stringValue ?? data["error"]?.stringValue {
            return (activityLine(error), false)
        }
        if let code = data["exit_code"]?.numberValue, code.isFinite, abs(code) < 1e6 {
            return (data["timed_out"]?.boolValue == true ? "Timed out" : "Exit \(Int(code))", false)
        }
        if let message = data["message"]?.stringValue { return (activityLine(message), false) }
        if let status = data["status"]?.stringValue {
            return (activityLine(status.replacingOccurrences(of: "_", with: " ")), false)
        }
        return ("", false)
    }

    nonisolated static func activityThumbnail(_ source: String) -> Data? {
        guard source.hasPrefix("data:image/"), source.utf8.count <= 12_000_000,
            let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"),
            let bytes = Data(
                base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters),
            let image = CGImageSourceCreateWithData(bytes as CFData, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                image, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private func activityKey(_ chatId: String?) -> String { chatId ?? "" }

    private func touchActivityChat(_ key: String) {
        activityOrder.removeAll { $0 == key }
        activityOrder.append(key)
        while activityOrder.count > Self.maximumActivityChats {
            activityLog.removeValue(forKey: activityOrder.removeFirst())
        }
    }

    private func updateActivity(_ chatId: String?, _ change: (inout [ActivityRow]) -> Void) {
        let key = activityKey(chatId)
        var rows = activityLog[key] ?? []
        let before = rows
        change(&rows)
        if rows.count > Self.maximumActivityRows {
            let dropped = Set(rows.prefix(rows.count - Self.maximumActivityRows).map(\.id))
            rows.removeFirst(rows.count - Self.maximumActivityRows)
            activityAliases = activityAliases.filter { !dropped.contains($0.value) }
            approvalRows = approvalRows.filter { !dropped.contains($0.value) }
            approvalOrigins = approvalOrigins.filter { approvalRows[$0.key] != nil }
            redispatchable.subtract(dropped)
        }
        guard rows != before else { return }
        activityLog[key] = rows
        touchActivityChat(key)
    }

    private func activityPosition(_ chatId: String?) -> Int {
        chatId == activeChatId ? visibleTurns.count : Int.max
    }

    private func recordActivityStep(_ frame: InboundFrame) {
        guard let step = frame.payload["step"], (step["kind"]?.stringValue ?? "tool_call") == "tool_call",
            let stepId = step["id"]?.stringValue, !stepId.isEmpty, stepId.count <= 128,
            let tool = step["name"]?.stringValue, !tool.isEmpty
        else { return }
        let chatId = frame.payload["chat_id"]?.stringValue ?? step["chat_id"]?.stringValue ?? activeChatId
        let status = step["status"]?.stringValue ?? "in_progress"
        let arguments = step["args_truncated"]?.stringValue ?? ""
        let position = activityPosition(chatId)
        updateActivity(chatId) { rows in
            var index = rows.firstIndex { $0.id == (activityAliases[stepId] ?? stepId) }
            if index == nil,
                let reuse = rows.lastIndex(where: {
                    redispatchable.contains($0.id) && $0.tool == tool && $0.arguments == arguments
                })
            {
                activityAliases[stepId] = rows[reuse].id
                redispatchable.remove(rows[reuse].id)
                index = reuse
            }
            if index == nil {
                rows.append(
                    ActivityRow(
                        id: stepId, tool: tool, action: Self.activityAction(tool),
                        target: Self.activityTarget(arguments), approval: .none, state: .running, result: "",
                        thumbnail: nil, position: position, arguments: arguments))
                index = rows.count - 1
            }
            guard let index else { return }
            switch status {
            case "completed":
                let outcome = Self.activityResult(step["result_summary"]?.stringValue)
                if outcome.waiting {
                    rows[index].approval = .waiting
                    rows[index].state = .running
                } else {
                    rows[index].state = .completed
                    rows[index].result = outcome.text
                }
            case "errored":
                rows[index].state = .failed
                rows[index].result = Self.activityLine(step["error_message"]?.stringValue ?? "")
            case "cancelled", "interrupted":
                rows[index].state = .cancelled
                if rows[index].approval == .waiting { rows[index].approval = .none }
            default:
                rows[index].state = .running
            }
        }
    }

    private func recordActivityProgress(_ frame: InboundFrame, percent: String) {
        guard let tool = frame.payload["tool_name"]?.stringValue, !tool.isEmpty, tool.count <= 128 else { return }
        let message = Self.activityLine((frame.payload["message"]?.stringValue ?? "") + percent)
        let terminal = frame.payload["terminal"]?.boolValue == true
        let failed = frame.payload["phase"]?.stringValue == "failed"
        let position = activityPosition(activeChatId)
        updateActivity(activeChatId) { rows in
            if !rows.contains(where: { $0.tool == tool && $0.state == .running }) {
                rows.append(
                    ActivityRow(
                        id: "progress-\(UUID().uuidString.lowercased())", tool: tool,
                        action: Self.activityAction(tool), target: "", approval: .none, state: .running,
                        result: "", thumbnail: nil, position: position, arguments: ""))
            }
            guard let index = rows.lastIndex(where: { $0.tool == tool && $0.state == .running }) else { return }
            if !message.isEmpty { rows[index].result = message }
            if terminal { rows[index].state = failed ? .failed : .completed }
        }
    }

    private func finishActivityProgress() {
        let unconfirmed = submittedApprovals.filter {
            !$0.value.expectsReceipt && $0.value.owner == downloadOwner
                && $0.value.connection == continuity.connectionGeneration && $0.value.chat == activeChatId
        }
        let unconfirmedRows = Set(unconfirmed.values.compactMap(\.row))
        for id in unconfirmed.keys {
            if let pending = submittedApprovals.removeValue(forKey: id), let submissionId = pending.submissionId {
                clearLocalOperationSubmission(submissionId: submissionId)
            }
            decidedApprovals.insert(id)
        }
        updateActivity(activeChatId) { rows in
            for index in rows.indices
            where rows[index].state == .running
                && (rows[index].id.hasPrefix("progress-") || unconfirmedRows.contains(rows[index].id))
            {
                rows[index].state = .completed
                redispatchable.remove(rows[index].id)
            }
        }
    }

    private func endRunningActivity(chatId: String?) {
        updateActivity(chatId) { rows in
            for index in rows.indices where rows[index].state == .running {
                rows[index].state = .cancelled
                if rows[index].approval == .waiting { rows[index].approval = .none }
                redispatchable.remove(rows[index].id)
            }
        }
    }

    private func recordActivityCancellation(chatId: String?) {
        endRunningActivity(chatId: chatId)
        let position = activityPosition(chatId)
        updateActivity(chatId) { rows in
            guard rows.last?.id.hasPrefix("cancel-") != true else { return }
            rows.append(
                ActivityRow(
                    id: "cancel-\(UUID().uuidString.lowercased())", tool: "", action: "Turn cancelled", target: "",
                    approval: .none, state: .cancelled, result: "", thumbnail: nil, position: position,
                    arguments: ""))
        }
    }

    private func noteApprovalDecision(_ text: String) -> Bool {
        guard text.contains("authorize_action") || text.contains("remote_op_decision"),
            let frame = InboundFrame.parse(text), frame.name == "ui_event",
            ["authorize_action", "remote_op_decision"].contains(frame.payload["action"]?.stringValue ?? ""),
            let payload = frame.payload["payload"],
            let requestId = (payload["hitl_request_id"] ?? payload["proposal_id"])?.stringValue, !requestId.isEmpty
        else { return true }
        guard let decision = payload["decision"]?.stringValue,
            ["approve", "approve_and_resume", "grant_task", "decline"].contains(decision),
            !decidedApprovals.contains(requestId), !withdrawingApprovals.contains(requestId),
            submittedApprovals[requestId] == nil
        else { return false }
        #if !os(macOS)
            let approval: ActivityRow.Approval
            switch decision {
            case "approve", "approve_and_resume": approval = .approved
            case "grant_task": approval = .granted
            default: approval = .denied
            }
            if decidedApprovals.count >= 512 { decidedApprovals.removeAll() }
            decidedApprovals.insert(requestId)
            let linked = approvalRows[requestId]
            updateActivity(activeChatId) { rows in
                guard
                    let index = linked.flatMap({ id in rows.firstIndex { $0.id == id } })
                        ?? rows.lastIndex(where: { $0.approval == .waiting })
                else { return }
                rows[index].approval = approval
                if approval == .denied {
                    rows[index].state = .cancelled
                } else {
                    redispatchable.insert(rows[index].id)
                }
            }
            observeActivityComponents()
            return true
        #else
            let submissionId = frame.payload["submission_id"]?.stringValue
            let requestGeneration = frame.payload["request_generation"]?.stringValue
            guard let submissionId, let requestGeneration,
                payload["submission_id"] == .string(submissionId),
                payload["request_generation"] == .string(requestGeneration),
                let submission = localOperationSubmissions[submissionId],
                submission.action == frame.payload["action"]?.stringValue,
                submission.requestGeneration == requestGeneration,
                submission.connectionGeneration == continuity.connectionGeneration,
                submission.chatId == activeChatId,
                frame.payload["session_id"]?.stringValue == activeChatId
            else {
                if let submissionId, let requestGeneration,
                    let submission = localOperationSubmissions[submissionId],
                    submission.action == frame.payload["action"]?.stringValue,
                    submission.requestGeneration == requestGeneration,
                    submission.chatId == activeChatId
                {
                    clearLocalOperationSubmission(submissionId: submissionId)
                }
                bannerIsError = true
                errorBanner = "Reconnect and reopen this review before sending a decision."
                return false
            }
            guard submittedApprovals.count < 512 else { return false }
            if let origin = approvalOrigins[requestId],
                origin.owner != downloadOwner || origin.connection != continuity.connectionGeneration
                    || origin.chat != activeChatId
            {
                errorBanner = "Open the original conversation to answer this review."
                return false
            }
            let linked = approvalRows[requestId]
            submittedApprovals[requestId] = SubmittedApproval(
                owner: downloadOwner, connection: continuity.connectionGeneration,
                chat: activeChatId, row: linked, decision: decision, expectsReceipt: approvalReceiptsSupported,
                submissionId: submissionId, requestGeneration: requestGeneration)
            updateActivity(activeChatId) { rows in
                guard let index = linked.flatMap({ id in rows.firstIndex { $0.id == id } }) else { return }
                if approvalReceiptsSupported {
                    rows[index].approval = .submitted
                } else {
                    rows[index].approval = .uncertain
                    rows[index].result =
                        "Decision sent. This server does not confirm review outcomes. Inspect the action result."
                    if decision != "decline" { redispatchable.insert(rows[index].id) }
                }
            }
            observeActivityComponents()
            return true
        #endif
    }

    #if os(macOS)
        private func currentReviewScope(_ origin: SubmittedApproval) -> Bool {
            origin.owner == downloadOwner && origin.connection == continuity.connectionGeneration
        }

        private func retireComputerReview(_ id: String, chat: String?) {
            retiredComputerReviews = retiredComputerReviews.filter { currentReviewScope($0.value) }
            if let overflow = reviewRetirementOverflow, !currentReviewScope(overflow) { reviewRetirementOverflow = nil }
            let key = RetiredComputerReviewKey(chat: chat, request: id)
            guard retiredComputerReviews[key] == nil else { return }
            let origin = SubmittedApproval(
                owner: downloadOwner, connection: continuity.connectionGeneration, chat: chat, row: nil,
                decision: "withdraw", expectsReceipt: true, submissionId: nil, requestGeneration: nil)
            guard retiredComputerReviews.count < 512 else {
                reviewRetirementOverflow = origin
                return
            }
            retiredComputerReviews[key] = origin
        }

        private func suppressComputerReview(_ card: AstralComponent, chat: String?) -> Bool {
            guard let approval = Self.computerApproval(card) else { return false }
            let id = approval.requestId
            if macComputerHost.bypass,
                let host = card.raw["computer_host_id"]?.stringValue, macComputerHost.isLocalReviewHost(host)
            {
                retireComputerReview(id, chat: chat)
                return true
            }
            if let overflow = reviewRetirementOverflow, currentReviewScope(overflow) { return true }
            return retiredComputerReviews[RetiredComputerReviewKey(chat: chat, request: id)].map(currentReviewScope)
                == true
        }

        private func sanitizedComputerReviews(_ frame: InboundFrame) -> InboundFrame {
            guard
                ["ui_render", "ui_update", "ui_append", "ui_upsert", "ui_stream_data", "conversation_snapshot"]
                    .contains(frame.name),
                frame.payload["connection_generation"]?.stringValue == continuity.connectionGeneration
            else { return frame }
            let chat = frame.chatId ?? activeChatId
            func stripped(_ value: JSONValue) -> JSONValue? {
                if let values = value.arrayValue { return .array(values.compactMap(stripped)) }
                guard var object = value.objectValue else { return value }
                if object["type"] == .string("card"),
                    suppressComputerReview(AstralComponent(type: "card", raw: value), chat: chat)
                {
                    return nil
                }
                for (key, child) in object { object[key] = stripped(child) }
                return .object(object)
            }
            return InboundFrame(name: frame.name, payload: stripped(frame.payload) ?? .object([:]))
        }
    #endif

    private func withdrawLocalComputerReviews(_ host: String) {
        let ids = Set(
            approvalHosts.compactMap { id, value -> String? in
                guard value == host, !decidedApprovals.contains(id), let origin = approvalOrigins[id],
                    origin.owner == downloadOwner, origin.connection == continuity.connectionGeneration
                else { return nil }
                return id
            })
        withdrawingApprovals.formUnion(ids)
        for id in ids {
            guard let origin = approvalOrigins[id] else { continue }
            updateActivity(origin.chat) { rows in
                if let index = rows.firstIndex(where: { $0.id == origin.row }) {
                    rows[index].approval = .withdrawing
                    if submittedApprovals[id] == nil {
                        rows[index].action = "Review closed on this Mac"
                        rows[index].state = .completed
                        rows[index].result =
                            "Approval mode changed. This closes only the local review; check the action outcome before retrying."
                    } else {
                        rows[index].result = "Computer approval mode changed; the server outcome is not yet known."
                    }
                }
            }
        }
        removeApprovalCards(ids)
        observeActivityComponents()
    }

    private func removeApprovalCards(_ ids: Set<String>) {
        func stripped(_ value: JSONValue) -> JSONValue? {
            guard var object = value.objectValue else { return value }
            if let id = object["id"]?.stringValue,
                ids.contains(where: { id == "hitl_" + $0 || id == "au_approval_" + $0 })
            {
                return nil
            }
            for (key, child) in object {
                if let values = child.arrayValue { object[key] = .array(values.compactMap(stripped)) }
            }
            return .object(object)
        }
        func components(_ values: [AstralComponent]) -> [AstralComponent] {
            values.compactMap { item in stripped(item.raw).map { AstralComponent(type: item.type, raw: $0) } }
        }
        func cleaned(_ turn: ChatTurn) -> ChatTurn {
            ChatTurn(id: turn.id, role: turn.role, text: turn.text, components: components(turn.components))
        }
        activityObservationPaused = true
        canvas = components(canvas)
        transientCanvas = transientCanvas.map(components)
        turns = turns.map(cleaned)
        transientTurns = transientTurns.map(cleaned)
        activityObservationPaused = false
    }

    private func retireSubmittedApprovals() {
        let interrupted = submittedApprovals.merging(approvalOrigins.filter { withdrawingApprovals.contains($0.key) }) {
            submitted, _ in submitted
        }
        for (id, pending) in interrupted {
            decidedApprovals.insert(id)
            updateActivity(pending.chat) { rows in
                guard let index = pending.row.flatMap({ id in rows.firstIndex { $0.id == id } }) else { return }
                rows[index].approval = pending.decision.isEmpty ? .expired : .uncertain
                rows[index].state = .failed
                rows[index].result =
                    pending.decision.isEmpty
                    ? "This local review was interrupted by a connection change. Check the action outcome before retrying."
                    : "The connection changed before the decision outcome arrived. Inspect the action before retrying."
            }
        }
        submittedApprovals.removeAll()
        withdrawingApprovals.removeAll()
        removeApprovalCards(Set(interrupted.keys))
        observeActivityComponents()
    }

    private func consumeApprovalReceipt(_ frame: InboundFrame) {
        #if os(macOS)
            guard projects.enabled else { return }
            if let value = frame.payload["approval_decision"], value["decision"] == .string("withdraw"),
                value["state"] == .string("cancelled"), value["revision"] == .number(1),
                let id = value["request_id"]?.stringValue, !id.isEmpty, id.count <= 200,
                let connection = continuity.connectionGeneration,
                frame.payload["connection_generation"] == .string(connection),
                let chat = frame.chatId, !chat.isEmpty, chat.count <= 512,
                let message = value["message"]?.stringValue, message.unicodeScalars.count <= 1000
            {
                retireComputerReview(id, chat: chat)
            }
        #else
            return
        #endif
        guard let value = frame.payload["approval_decision"], let id = value["request_id"]?.stringValue,
            let pending = submittedApprovals[id]
                ?? (value["decision"] == .string("withdraw") ? approvalOrigins[id] : nil),
            !decidedApprovals.contains(id), pending.expectsReceipt, pending.owner == downloadOwner,
            let connection = pending.connection, connection == continuity.connectionGeneration,
            frame.payload["connection_generation"] == .string(connection),
            frame.payload["chat_id"]?.stringValue == pending.chat,
            value["decision"]?.stringValue == pending.decision
                || value["decision"] == .string("withdraw") && value["state"] == .string("cancelled"),
            value["revision"] == .number(1),
            let state = value["state"]?.stringValue,
            ["accepted", "refused", "expired", "cancelled", "error", "uncertain"].contains(state),
            let message = value["message"]?.stringValue, message.unicodeScalars.count <= 1000
        else { return }
        submittedApprovals.removeValue(forKey: id)
        withdrawingApprovals.remove(id)
        decidedApprovals.insert(id)
        if let submissionId = pending.submissionId,
            let submission = localOperationSubmissions[submissionId],
            submission.requestGeneration == pending.requestGeneration,
            submission.connectionGeneration == connection,
            submission.chatId == pending.chat
        {
            clearLocalOperationSubmission(submissionId: submissionId)
        }
        updateActivity(pending.chat) { rows in
            guard let index = pending.row.flatMap({ id in rows.firstIndex { $0.id == id } }) else { return }
            switch state {
            case "accepted":
                rows[index].approval = pending.decision == "grant_task" ? .granted : .approved
                redispatchable.insert(rows[index].id)
            case "expired":
                rows[index].approval = .expired
                rows[index].state = .failed
            case "uncertain":
                rows[index].approval = .uncertain
                rows[index].state = .failed
            case "cancelled":
                rows[index].approval =
                    pending.decision == "decline" && value["decision"] != .string("withdraw") ? .denied : .refused
                rows[index].state = .cancelled
            default:
                rows[index].approval = .refused
                rows[index].state = .failed
            }
            if value["decision"] == .string("withdraw") {
                rows[index].approval = .none
                rows[index].action = "Review closed on this Mac"
                rows[index].state = .completed
            }
            if state != "accepted" { rows[index].result = message }
        }
        if state != "accepted", value["decision"] != .string("withdraw"), pending.chat == activeChatId {
            errorBanner = message
            bannerIsError = state != "cancelled"
        }
        removeApprovalCards([id])
        observeActivityComponents()
    }

    private func observeActivityComponents() {
        guard !activityObservationPaused else { return }
        let live = transientCanvas ?? canvas
        let observed = Self.approvalCards(in: visibleTurns.suffix(8).flatMap(\.components) + live)
        var retired = Set(observed.map(\.approval.requestId)).intersection(decidedApprovals.union(withdrawingApprovals))
        #if os(macOS)
            retired.formUnion(
                observed.filter { suppressComputerReview($0.card, chat: activeChatId) }.map(\.approval.requestId))
        #endif
        if !retired.isEmpty { removeApprovalCards(retired) }
        let cards =
            observed
            .filter {
                !retired.contains($0.approval.requestId)
                    && !withdrawingApprovals.contains($0.approval.requestId)
                    && submittedApprovals[$0.approval.requestId] == nil
            }
            .filter { !Self.bypassApproved($0.card) }
        let pending = cards.map(\.approval)
        let prompts = cards.compactMap { Self.approvalPrompt($0.card, $0.approval) }
        if prompts != approvalPrompts { approvalPrompts = prompts }
        for item in cards where approvalRows[item.approval.requestId] == nil {
            linkApproval(item.approval)
            approvalHosts[item.approval.requestId] = item.card.raw["computer_host_id"]?.stringValue
        }
        #if os(macOS)
            if macComputerHost.awaitingApproval == pending.isEmpty { macComputerHost.approvalWaiting(!pending.isEmpty) }
        #endif
        guard
            let shot = live.first(where: {
                $0.type == "image" && ($0.componentId ?? "").hasPrefix("au_cuview_")
            })?.url, shot != screenThumbnailSource
        else { return }
        screenThumbnailSource = shot
        if let row = activity.last, row.thumbnail == nil, !row.id.hasPrefix("cancel-") {
            attachActivityThumbnail(shot, to: row.id, chatId: activeChatId)
        }
    }

    private func linkApproval(_ approval: PendingApproval) {
        if approvalRows.count >= 512 {
            approvalRows.removeAll()
            approvalOrigins.removeAll()
            approvalHosts.removeAll()
        }
        let chatId = activeChatId
        let position = activityPosition(chatId)
        var linked: String?
        updateActivity(chatId) { rows in
            let claimed = Set(approvalRows.values)
            if let index = rows.lastIndex(where: { $0.approval == .waiting && !claimed.contains($0.id) }) {
                linked = rows[index].id
                if rows[index].target.isEmpty { rows[index].target = approval.summary }
            } else {
                let row = ActivityRow(
                    id: "approval-\(approval.requestId)", tool: approval.tool,
                    action: Self.activityAction(approval.tool), target: approval.summary, approval: .waiting,
                    state: .running, result: "", thumbnail: nil, position: position, arguments: "")
                rows.append(row)
                linked = row.id
            }
        }
        guard let linked else { return }
        approvalRows[approval.requestId] = linked
        approvalOrigins[approval.requestId] = SubmittedApproval(
            owner: downloadOwner,
            connection: continuity.connectionGeneration, chat: chatId, row: linked, decision: "",
            expectsReceipt: approvalReceiptsSupported, submissionId: nil, requestGeneration: nil)
        announce(approval.summary.isEmpty ? "Approval waiting" : "Approval waiting: \(approval.summary)")
        if let image = approval.image { attachActivityThumbnail(image, to: linked, chatId: chatId) }
    }

    private func attachActivityThumbnail(_ source: String, to rowId: String, chatId: String?) {
        Task.detached(priority: .utility) { [weak self] in
            guard let data = AppModel.activityThumbnail(source) else { return }
            await self?.setActivityThumbnail(data, rowId: rowId, chatId: chatId)
        }
    }

    private func setActivityThumbnail(_ data: Data, rowId: String, chatId: String?) {
        guard activityLog[activityKey(chatId)] != nil else { return }
        updateActivity(chatId) { rows in
            if let index = rows.firstIndex(where: { $0.id == rowId }) { rows[index].thumbnail = data }
        }
    }

    private func clearActivity() {
        activityLog = [:]
        approvalPrompts = []
        activityAliases = [:]
        activityOrder = []
        decidedApprovals = []
        submittedApprovals = [:]
        approvalRows = [:]
        approvalOrigins = [:]
        approvalHosts = [:]
        withdrawingApprovals = []
        redispatchable = []
        screenThumbnailSource = nil
        #if os(macOS)
            macComputerHost.approvalWaiting(false)
        #endif
    }

    private func isReasoning(_ c: AstralComponent) -> Bool {
        c.type.lowercased() == "collapsible" && (c.raw["title"]?.stringValue ?? "").lowercased() == "reasoning"
    }

    private func isDocCard(_ id: String?) -> Bool { id?.hasPrefix("doc_") ?? false }

    private func isSkeleton(_ c: AstralComponent?) -> Bool { c?.type.lowercased() == "skeleton" }

    private func flattenText(_ components: [AstralComponent]) -> String {
        components.map { c in
            let own = c.raw["content"]?.stringValue ?? c.raw["text"]?.stringValue ?? ""
            return (own + "\n" + flattenText(c.children)).trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func noticeText(_ components: [AstralComponent]) -> String {
        components.map { c in
            let own =
                c.raw["message"]?.stringValue ?? c.raw["content"]?.stringValue
                ?? c.raw["text"]?.stringValue ?? ""
            return (own + "\n" + noticeText(c.children)).trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parserNote(_ status: String?) -> String? {
        switch status {
        case "preparing": return "preparing reader…"
        case "pending_admin_approval": return "reader pending admin"
        case "unavailable": return "no reader yet"
        default: return nil
        }
    }

    private func resetChatState() {
        activityObservationPaused = true
        defer {
            activityObservationPaused = false
            observeActivityComponents()
        }
        if ["evidence", "terminal"].contains(pendingSurfaceKey) { closeSurface() }
        conversationNavigationGeneration += 1
        consoleFullscreen = false
        consoleResultCollapsed = false
        turnSelection = nil
        consoleDashboardVisible = true
        consoleDrawerOpen = false
        invalidateWorkRead()
        if pendingSurfaceKey == "work" {
            pendingSurfaceKey = ""
            pendingSurfaceParams = .object([:])
            screen = .chat
        }
        canvasCapture.clear()
        activityLog.removeValue(forKey: activityKey(nil))
        activeChatId = nil
        voice.updateVisibleChatLocally(nil)
        turns = []
        canvas = []
        transientTurns = []
        transientCanvas = nil
        pendingCanvas = []
        canvasHistory = []
        viewingIndex = nil
        turnActive = false
        pendingReplace = false
        canvasLabel = ""
        pendingLabel = ""
        staged = []
        statusText = nil
        errorBanner = nil
        stepTrail = []
        asyncDetached = false
        pendingCommitRequestGeneration = nil
        composerDraft = ""
        runInBackground = false
        workspaceStarted = false
    }

    private func beginLocalOperationSubmission(
        identity: ClientOperationIdentity,
        action: String,
        surface: String,
        chatId: String?,
        exposeStatus: Bool = true
    ) {
        guard let connectionGeneration = continuity.connectionGeneration,
            let submission = LocalOperationSubmission(
                identity: identity,
                action: action,
                surface: surface,
                chatId: chatId,
                connectionGeneration: connectionGeneration)
        else { return }
        localOperationSubmissions[submission.submissionId] = submission
        let approvalDuringActiveTurn = turnActive && ["authorize_action", "remote_op_decision"].contains(action)
        if exposeStatus && !approvalDuringActiveTurn { statusText = submission.label }
    }

    private func localSubmissionShowsActivity(_ submission: LocalOperationSubmission) -> Bool {
        submission.action != "update_device" && submission.action != "chrome_llm_save"
    }

    @discardableResult
    func replayQueuedOperation(_ replay: QueuedOperationReplay) -> Bool {
        #if os(macOS)
            if projects.negotiating { return false }
            if projects.enabled, replay.conversationPurpose != nil, replay.chatId == nil {
                bannerIsError = true
                errorBanner = "Select a project and resend this message."
                return false
            }
        #endif
        guard !["evidence", "terminal"].contains(replay.surface),
            let connectionGeneration = continuity.connectionGeneration
        else {
            return false
        }
        if let purpose = replay.conversationPurpose {
            if let chatId = replay.chatId {
                guard
                    openConversationRequest(
                        chatId: chatId,
                        requestGeneration: replay.identity.requestGeneration,
                        purpose: purpose)
                else { return false }
            } else if purpose == .commit {
                pendingCommitRequestGeneration = replay.identity.requestGeneration
            } else {
                return false
            }
        }
        guard
            let submission = LocalOperationSubmission(
                identity: replay.identity,
                action: replay.action,
                surface: replay.surface,
                chatId: replay.chatId,
                connectionGeneration: connectionGeneration)
        else { return false }
        localOperationSubmissions[submission.submissionId] = submission
        if replay.action == "chrome_open", screen == .surface, replay.surface == pendingSurfaceKey,
            !["guidance", "work"].contains(replay.surface),
            ordinaryReadIntent?.generation == replay.identity.requestGeneration,
            ordinaryReadIntent?.owner == downloadOwner
        {
            ordinarySurfaceRequests[replay.identity.requestGeneration] = OrdinarySurfaceRequest(
                surface: replay.surface, connection: connectionGeneration, owner: downloadOwner, socket: ws,
                conversation: activeChatId)
            ordinarySurfaceGeneration = replay.identity.requestGeneration
            surfaceFailureMessage = nil
        }
        if localSubmissionShowsActivity(submission) { statusText = submission.label }
        return true
    }

    private func clearLocalOperationSubmission(requestGeneration: String) {
        if ordinarySurfaceGeneration != requestGeneration {
            ordinarySurfaceRequests.removeValue(forKey: requestGeneration)
        }
        for (submission, local) in localOperationSubmissions where local.requestGeneration == requestGeneration {
            componentPendingOperations.removeValue(forKey: submission)
        }
        localOperationSubmissions = localOperationSubmissions.filter {
            $0.value.requestGeneration != requestGeneration
        }
    }

    private func clearLocalOperationSubmission(submissionId: String) {
        guard let submission = localOperationSubmissions.removeValue(forKey: submissionId) else { return }
        componentPendingOperations.removeValue(forKey: submissionId)
        if statusText == submission.label { statusText = latestActiveOperationStatusText() }
    }

    private func operationOwnsActiveChatTurn(
        action: String,
        requestGeneration: String
    ) -> Bool {
        action == "chat_message"
            && (continuity.requestGeneration == requestGeneration
                || pendingCommitRequestGeneration == requestGeneration)
    }

    private func settleActiveChatTurn(
        requestGeneration: String,
        discardUncommitted: Bool
    ) {
        turnActive = false
        pendingReplace = false
        liveOpsThisTurn = false
        stepTrail = []
        asyncDetached = false
        if discardUncommitted {
            pendingCanvas = []
            transientTurns = []
            transientCanvas = nil
            if pendingCommitRequestGeneration == requestGeneration {
                pendingCommitRequestGeneration = nil
            }
        }
    }

    private func clearPendingOperationSubmissions() {
        let wasSubmitting = statusText == "Submitting…"
        localOperationSubmissions.removeAll()
        componentPendingOperations.removeAll()
        if wasSubmitting { statusText = nil }
    }

    private func operationSurface(action: String, payload: JSONValue) -> String {
        if let surface = payload["surface"]?.stringValue,
            surface.range(
                of: "^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$",
                options: .regularExpression) != nil
        {
            return surface
        }
        if action == "chat_message" || action == "load_chat" { return "chat" }
        return "operation"
    }

    private func operationChatId(action: String, payload: JSONValue) -> String? {
        #if os(macOS)
            if ["authorize_action", "remote_op_decision"].contains(action) { return activeChatId }
        #endif
        if action == "chat_message" || action == "load_chat"
            || conversationMutationActions.contains(action)
        {
            return payload["chat_id"]?.stringValue ?? activeChatId
        }
        return nil
    }

    func dismissBanner() { errorBanner = nil }

    func announce(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { announcer(text) }
    }

    func consoleLabel(_ key: String) -> String { console?.labels[key] ?? "" }

    func showConsoleDashboard() {
        guard !mandatorySurface else { return }
        closeSurface()
        screen = .chat
        consoleDashboardVisible = true
        consoleDrawerOpen = false
    }

    func useConsoleScenario(_ scenario: ConsoleScenario, run: Bool) {
        guard signedIn, connected, !mandatorySurface, !mutationsLocked,
            console?.catalog.scenarios.contains(scenario) == true
        else { return }
        closeSurface()
        composerDraft = scenario.prompt
        if run {
            sendChat(scenario.prompt)
            composerDraft = ""
        }
    }

    private func bindConversationNavigationRender(_ source: String) {
        guard continuity.acceptedSnapshot != nil || acceptingTransientNavigationRender else {
            conversationNavigationBindings[source] = nil
            return
        }
        conversationNavigationBindings[source] = ConversationNavigationBinding(
            owner: downloadOwner, connection: continuity.connectionGeneration, request: continuity.requestGeneration)
    }

    func navigationCallback(
        _ component: AstralComponent, surface: Bool, transcript: String? = nil
    ) -> ([String: JSONValue]) -> Void {
        let owner = downloadOwner
        let connection = continuity.connectionGeneration
        let request = continuity.requestGeneration
        let chat = activeChatId
        let source: String
        let components: [AstralComponent]
        if surface {
            source = "surface"
            components = pendingSurface?.components ?? []
        } else if let transcript {
            if let turn = transientTurns.first(where: { $0.id == transcript }) {
                source = "transient-transcript"
                components = turn.components
            } else {
                source = "transcript"
                components = turns.first(where: { $0.id == transcript })?.components ?? []
            }
        } else {
            source = transientCanvas == nil ? "canvas" : "transient-canvas"
            components = visibleCanvas
        }
        let binding = conversationNavigationBindings[source]
        let surfaceRender = surfaceNavigationScope?.render
        let offered = components.contains { navigationComponentPresent(component.raw, in: $0.raw) }
        return { [weak self] fields in
            guard let self, offered, self.signedIn, self.connected, !self.mandatorySurface,
                !self.mutationsLocked, !self.isViewingHistory, self.downloadOwner == owner,
                connection != nil, self.continuity.connectionGeneration == connection,
                self.continuity.requestGeneration == request, self.activeChatId == chat,
                fields.count == 1, let target = fields["chat_id"]?.stringValue,
                target.range(
                    of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                    options: .regularExpression) != nil,
                self.navigationOffered(component, target: target, surface: surface)
            else { return }
            if surface {
                guard self.screen == .surface, self.ordinarySurfaceGeneration == nil,
                    self.surfaceFailureMessage == nil, surfaceRender != nil,
                    self.surfaceNavigationScope?.render == surfaceRender,
                    self.surfaceNavigationScope?.owner == owner,
                    self.surfaceNavigationScope?.connection == connection
                else { return }
                self.closeSurface()
            } else {
                guard self.screen == .chat, let binding,
                    self.conversationNavigationBindings[source]?.render == binding.render,
                    binding.owner == owner, binding.connection == connection, binding.request == request
                else { return }
            }
            self.openChat(target)
        }
    }

    private func navigationComponentPresent(_ selected: JSONValue, in value: JSONValue) -> Bool {
        if value == selected { return true }
        if let values = value.arrayValue { return values.contains { navigationComponentPresent(selected, in: $0) } }
        return value.objectValue?.values.contains { navigationComponentPresent(selected, in: $0) } == true
    }

    private func navigationOffered(_ component: AstralComponent, target: String, surface: Bool) -> Bool {
        if component.type == "chat_history" {
            return (component.raw["items"]?.arrayValue ?? []).compactMap { ChatSummary(historyItem: $0) }
                .contains { $0.id == target }
        }
        return surface && component.type == "button" && component.raw["action"] == .string("load_chat")
            && component.raw["payload"] == .object(["chat_id": .string(target)])
            && component.raw["disabled"] != .bool(true) && component.raw["enabled"] != .bool(false)
    }

    private func surfaceConversationOffered(_ component: AstralComponent, payload: JSONValue) -> Bool {
        if component.type == "button", component.raw["action"] == .string("load_chat"),
            component.raw["payload"] == payload, component.raw["disabled"] != .bool(true)
        {
            return true
        }
        return component.children.contains { surfaceConversationOffered($0, payload: payload) }
    }

    private func permitsIntroPrompt(_ component: AstralComponent, action: String, payload: JSONValue) -> Bool {
        if component.raw["action"]?.stringValue == action, component.raw["payload"] == payload {
            return true
        }
        return component.children.contains { permitsIntroPrompt($0, action: action, payload: payload) }
    }

    func sendChat(_ text: String) {
        #if os(macOS)
            if projects.negotiating {
                composerDraft = text
                return
            }
            if projects.enabled, activeChatId.flatMap({ projects.project(for: $0) }) == nil {
                composerDraft = text
                let attachments = staged
                createProjectChat { [weak self] in
                    guard let self, self.composerDraft == text, self.staged == attachments else { return }
                    self.sendChat(text)
                    if self.composerDraft == text { self.composerDraft = "" }
                }
                return
            }
        #endif
        if timelineReadOnly { return }
        if mandatorySurface {
            composerDraft = text
            return
        }
        let ready = staged.filter { $0.state == "ready" && $0.attachmentId != nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && ready.isEmpty { return }
        if ["evidence", "terminal"].contains(pendingSurfaceKey) { closeSurface() }
        let identity = ClientOperationIdentity.fresh()
        let request = identity.requestGeneration
        if continuity.connectionGeneration != nil {
            if let chatId = activeChatId {
                guard
                    openConversationRequest(
                        chatId: chatId,
                        requestGeneration: request,
                        purpose: .commit)
                else { return }
            } else {
                pendingCommitRequestGeneration = request
            }
        }
        let bubble =
            ready.isEmpty
            ? text
            : (text + "\n📎 " + ready.map(\.filename).joined(separator: ", ")).trimmingCharacters(in: .whitespaces)
        if continuity.connectionGeneration == nil {
            appendTurn(role: "user", text: bubble)
        } else {
            transientTurns.append(
                ChatTurn(
                    id: "pending-user-\(UUID().uuidString.lowercased())",
                    role: "user",
                    text: bubble))
        }
        workspaceStarted = true
        let background = runInBackground
        runInBackground = false
        turnActive = true
        pendingReplace = !background
        pendingCanvas = []
        liveOpsThisTurn = false
        if continuity.connectionGeneration == nil {
            canvas = canvas.dropWelcome()
        }
        pendingLabel = String((text.isEmpty ? (ready.first?.filename ?? "") : text).prefix(80))
        staged = []
        viewingIndex = nil
        statusText = nil
        errorBanner = nil
        stepTrail = []
        asyncDetached = false

        beginLocalOperationSubmission(
            identity: identity,
            action: "chat_message",
            surface: "chat",
            chatId: activeChatId)

        var payload: [String: JSONValue] = ["message": .string(text)]
        if let turnSelection, !turnSelection.isEmpty { payload["selection"] = turnSelection.json }
        consoleDashboardVisible = false
        if background { payload["async_mode"] = .bool(true) }
        if let cid = activeChatId { payload["chat_id"] = .string(cid) }
        if !ready.isEmpty {
            payload["attachments"] = .array(
                ready.map { att in
                    .object([
                        "attachment_id": .string(att.attachmentId!),
                        "filename": .string(att.filename),
                        "category": .string(att.category),
                    ])
                })
        }
        rawSend(
            Outbound.uiEvent(
                action: "chat_message",
                sessionId: activeChatId,
                payload: .object(payload),
                submissionId: identity.submissionId,
                requestGeneration: request,
                snapshotPurpose: .commit))
    }

    private func cancelMeshPresentation() {
        meshOperationEpoch += 1
        meshOperation?.cancel()
        meshOperation = nil
        meshPublicIdentity = nil
    }

    private func retireMeshCustody() {
        cancelMeshPresentation()
        do { try meshKeyStorage.retainOnly(nil) } catch {
            surfaceFailureMessage = "The local device identity could not be cleared. Retry sign-out."
        }
        meshCustody = nil
    }

    private func meshActionOffered(_ action: String, payload: JSONValue) -> Bool {
        func matches(_ raw: JSONValue) -> Bool {
            raw["action"] == .string(action)
                && (raw["payload"]?.objectValue ?? [:]).allSatisfy { payload[$0.key] == $0.value }
        }
        func offered(_ component: AstralComponent) -> Bool {
            if component.type == "button", component.raw["disabled"] != .bool(true), matches(component.raw) {
                return true
            }
            if component.type == "param_picker", payload["fields"]?.objectValue != nil,
                component.raw["submit_action"] == .string(action)
                    || component.raw["actions"]?.arrayValue?.contains(where: matches) == true
            {
                return true
            }
            return component.children.contains(where: offered)
        }
        return pendingSurface?.components.contains(where: offered) == true
    }

    private func performMeshAction(_ action: String, payload: JSONValue) {
        guard meshOperation == nil, let account = conversationAccount, let socket = ws,
            let scope = try? MeshEnrollmentScope(server: serverBase, account: account)
        else {
            surfaceFailureMessage = "Connect securely before using device enrollment."
            return
        }
        let owner = downloadOwner
        let server = serverBase
        let connection = continuity.connectionGeneration
        let navigation = conversationNavigationGeneration
        let surface = pendingSurface
        let surfaceGeneration = ordinarySurfaceGeneration
        meshOperationEpoch += 1
        let operation = meshOperationEpoch
        if let custody = meshCustody, custody.scope != scope {
            retireMeshCustody()
            return
        }
        let custody = meshCustody ?? MeshEnrollmentCustody(scope: scope, storage: meshKeyStorage)
        meshCustody = custody
        meshOperation = Task { [weak self] in
            guard let self else { return }
            defer { if self.meshOperationEpoch == operation { self.meshOperation = nil } }
            @MainActor func current() -> Bool {
                !Task.isCancelled && self.meshOperationEpoch == operation && self.downloadOwner == owner
                    && self.serverBase == server && self.ws === socket
                    && self.pendingSurface == surface && self.ordinarySurfaceGeneration == surfaceGeneration
                    && self.connected && self.screen == .surface && self.pendingSurfaceKey == "mesh"
                    && self.continuity.connectionGeneration == connection
                    && self.conversationNavigationGeneration == navigation
            }
            guard await self.authenticatedSocketIsCurrent(socket, owner: owner, connection: connection), current()
            else { return }
            do {
                if action == "chrome_mesh_redeem" {
                    guard Set(payload.objectValue?.keys.map { $0 } ?? []) == ["fields"],
                        let fields = payload["fields"]?.objectValue, Set(fields.keys) == ["link"],
                        let link = fields["link"]?.stringValue
                    else { throw MeshEnrollmentError.invalid }
                    _ = try await custody.redeem(link: link, current: current, transport: self.meshTransport)
                    guard current() else { return }
                    self.errorBanner = "This device joined your mesh."
                    self.bannerIsError = false
                    self.openSurface("mesh")
                } else {
                    let identity = try custody.publicIdentity(current: current)
                    guard current() else { return }
                    if action == "chrome_mesh_identity" {
                        guard payload.objectValue?.isEmpty == true else { throw MeshEnrollmentError.invalid }
                        self.meshPublicIdentity = String(decoding: try identity.encoded(), as: UTF8.self)
                    } else {
                        guard Set(payload.objectValue?.keys.map { $0 } ?? []) == ["fields"],
                            var fields = payload["fields"]?.objectValue,
                            Set(fields.keys) == ["label", "device_key", "scopes", "ttl_seconds"]
                        else { throw MeshEnrollmentError.invalid }
                        fields["device_key"] = .string(String(decoding: try identity.encoded(), as: UTF8.self))
                        self.sendEvent(action, .object(["fields": .object(fields)]))
                    }
                }
            } catch {
                if current() {
                    self.surfaceFailureMessage = "Device enrollment was not completed. Check approval and retry."
                }
            }
        }
    }

    func sendEvent(_ action: String, _ payload: JSONValue = .object([:])) {
        #if os(macOS)
            if projects.negotiating, ["chat_message", "new_chat", "load_chat"].contains(action) { return }
            if projects.enabled, action == "new_chat" {
                newChat()
                return
            }
            if projects.enabled, action == "chat_message", activeChatId.flatMap({ projects.project(for: $0) }) == nil {
                createProjectChat { [weak self] in self?.sendEvent(action, payload) }
                return
            }
        #endif
        if action == "computer_host_consent" {
            #if os(macOS)
                guard signedIn, connected, macComputerHost.available, screen == .surface,
                    pendingSurfaceKey == "my_computers", pendingSurface?.surfaceKey == "my_computers",
                    ordinarySurfaceGeneration == nil, !mandatorySurface,
                    let fields = payload.objectValue, Set(fields.keys) == ["enabled"],
                    let enabled = fields["enabled"]?.boolValue
                else {
                    bannerIsError = true
                    errorBanner = "Open My computers on an eligible Mac before changing local computer access."
                    return
                }
                macComputerHost.refreshPermissions()
                macComputerHost.setEnabled(enabled)
                if enabled && !macComputerHost.enabled { macComputerHost.showControls() }
                let owner = downloadOwner
                let connection = continuity.connectionGeneration
                Task { [weak self] in
                    guard let self, await self.macComputerHost.flushCurrentSends(), self.downloadOwner == owner,
                        self.continuity.connectionGeneration == connection, self.screen == .surface,
                        self.pendingSurfaceKey == "my_computers"
                    else { return }
                    self.openSurface("my_computers")
                }
            #else
                bannerIsError = true
                errorBanner = "This client controls other computers and cannot host local computer tasks."
            #endif
            return
        }
        if action.hasPrefix("chrome_mesh_") {
            guard signedIn, connected, screen == .surface, pendingSurfaceKey == "mesh", !mandatorySurface,
                ordinarySurfaceGeneration == nil, !paramPickerPending(action: action),
                meshActionOffered(action, payload: payload)
            else { return }
            guard serverSession?.owner == conversationAccount?.subject else {
                surfaceFailureMessage = "Sign in again to confirm this server session before managing mesh devices."
                return
            }
            if ["chrome_mesh_identity", "chrome_mesh_redeem"].contains(action)
                || (action == "chrome_mesh_create" && payload["fields"]?["device_key"]?.stringValue?.isEmpty == true)
            {
                performMeshAction(action, payload: payload)
                return
            }
            if action == "chrome_mesh_create" {
                guard let raw = payload["fields"]?["device_key"]?.stringValue,
                    let identity = try? JSONValue.parse(Data(raw.utf8)),
                    (try? MeshEnrollmentCustody.validatePublicIdentity(identity)) != nil
                else {
                    surfaceFailureMessage = "The public device identity is invalid."
                    return
                }
            }
        }
        if SafetySurfaceRequest.actions.contains(action) || payload["surface"]?.stringValue == "safety" {
            guard signedIn, connected, SafetySurfaceRequest(action: action, payload: payload) != nil else {
                surfaceFailureMessage = "Safety controls were not sent. Reconnect and check current stop status."
                return
            }
            if SafetySurfaceRequest.actions.contains(action) {
                guard screen == .surface, pendingSurfaceKey == "safety", let surface = pendingSurface,
                    surface.surfaceKey == "safety", !surfaceContainsError(surface.components),
                    ordinarySurfaceGeneration == nil, surfaceFailureMessage == nil
                else {
                    surfaceFailureMessage = "Reload Safety to check current stop status before trying again."
                    return
                }
            }
        }
        if action == "chrome_close",
            ["evidence", "terminal"].contains(pendingSurfaceKey)
                || ["evidence", "terminal"].contains(payload["surface"]?.stringValue ?? "")
        {
            if ["evidence", "terminal"].contains(pendingSurfaceKey) { closeSurface() }
            return
        }
        if action == "chat_message", ["evidence", "terminal"].contains(pendingSurfaceKey) { closeSurface() }
        if action == "chrome_open", mandatorySurface, payload["surface"]?.stringValue != "safety" { return }
        if action == "compose_prompt" || (action == "chat_message" && pendingSurfaceKey == "agent_intro") {
            guard signedIn, connected, screen == .surface, !mandatorySurface, !mutationsLocked,
                pendingSurfaceKey == "agent_intro",
                let message = payload["message"]?.stringValue, !message.isEmpty, message.count <= 8000,
                Set(payload.objectValue?.keys.map { $0 } ?? []) == ["message"],
                pendingSurface?.components.contains(where: { permitsIntroPrompt($0, action: action, payload: payload) })
                    == true
            else { return }
            closeSurface()
            if action == "chat_message" {
                sendChat(message)
                composerDraft = ""
            } else {
                composerDraft = message
            }
            return
        }
        if action.hasPrefix("chrome_note_")
            || action == "chrome_turn_selection_set"
            || (action == "chrome_open" && payload["surface"]?.stringValue == "guidance")
        {
            _ = sendGuidanceRequest(action: action, payload: payload)
            return
        }
        if action == "chrome_open", payload["surface"]?.stringValue == "work" {
            beginWorkRead(payload)
            return
        }
        if action == WorkContinuityRequest.action {
            beginWorkContinuity(payload)
            return
        }
        if action == "chrome_open" || action == "chrome_close" { invalidateWorkRead() }
        if action == "chrome_open", let surface = payload["surface"]?.stringValue {
            let current = screen == .surface && pendingSurfaceKey == surface ? pendingSurface : nil
            if pendingSurfaceKey != surface {
                parameterRequests = [:]
                parameterFailures = []
            }
            retireOrdinarySurfaceRequests()
            screen = .surface
            pendingSurfaceKey = surface
            pendingSurfaceParams = payload["params"] ?? .object([:])
            pendingSurface = current
            if ["evidence", "terminal"].contains(surface) { pendingSurface = nil }
            surfaceFailureMessage = nil
            if !signedIn || !connected {
                surfaceFailureMessage = "Connect before opening settings, then retry this screen."
            }
        }
        if screen == .surface, action != "chrome_open", action != "chrome_close",
            action.hasPrefix("chrome_") || action == "save_theme", paramPickerPending(action: action)
        {
            return
        }
        var payload = payload
        if action == "attach_existing" {
            if stageExistingAttachment(payload) { screen = .chat }
            return
        }
        if timelineReadOnly && timelineMutations.contains(action) { return }
        if action == "chat_message" {
            consoleDashboardVisible = false
            if let turnSelection, !turnSelection.isEmpty {
                var fields = payload.objectValue ?? [:]
                fields["selection"] = turnSelection.json
                payload = .object(fields)
            }
            workspaceStarted = true
            let background = runInBackground
            runInBackground = false
            if background {
                var fields = payload.objectValue ?? [:]
                fields["async_mode"] = .bool(true)
                payload = .object(fields)
            }
            turnActive = true
            pendingReplace = !background
            pendingCanvas = []
            liveOpsThisTurn = false
            if continuity.connectionGeneration == nil {
                canvas = canvas.dropWelcome()
            }
            viewingIndex = nil
            errorBanner = nil
            stepTrail = []
            asyncDetached = false
        }
        if action == "chat_message" {
            let identity = ClientOperationIdentity.fresh()
            let request = identity.requestGeneration
            if let chatId = activeChatId, continuity.connectionGeneration != nil {
                guard
                    openConversationRequest(
                        chatId: chatId,
                        requestGeneration: request,
                        purpose: .commit)
                else { return }
            } else if activeChatId == nil {
                pendingCommitRequestGeneration = request
            }
            beginLocalOperationSubmission(
                identity: identity,
                action: action,
                surface: "chat",
                chatId: activeChatId)
            rawSend(
                Outbound.uiEvent(
                    action: action,
                    sessionId: activeChatId,
                    payload: payload,
                    submissionId: identity.submissionId,
                    requestGeneration: request,
                    snapshotPurpose: .commit))
            return
        }
        if action == "load_chat" {
            guard signedIn, connected, screen == .surface, !mandatorySurface, !mutationsLocked,
                ordinarySurfaceGeneration == nil, surfaceFailureMessage == nil,
                let connection = continuity.connectionGeneration, surfaceNavigationScope?.connection == connection,
                surfaceNavigationScope?.owner == downloadOwner,
                let chatId = payload["chat_id"]?.stringValue,
                chatId.range(
                    of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                    options: .regularExpression) != nil,
                pendingSurface?.components.contains(where: { surfaceConversationOffered($0, payload: payload) }) == true
            else { return }
            closeSurface()
            openChat(chatId)
            return
        }

        let identity = ClientOperationIdentity.fresh()
        if screen == .surface, !["guidance", "work"].contains(pendingSurfaceKey),
            action != "chrome_close", payload["surface"] == nil,
            action.hasPrefix("chrome_") || action == "save_theme"
        {
            var fields = payload.objectValue ?? [:]
            fields["surface"] = .string(pendingSurfaceKey)
            payload = .object(fields)
        }
        bindOrdinarySurfaceRequest(identity: identity, action: action, payload: payload)
        if screen == .surface, action != "chrome_open", action != "chrome_close" {
            parameterRequests[action] = identity.requestGeneration
            parameterFailures.formIntersection(Set(parameterRequests.values))
        }
        let chatId = operationChatId(action: action, payload: payload)
        beginLocalOperationSubmission(
            identity: identity,
            action: action,
            surface: operationSurface(action: action, payload: payload),
            chatId: chatId)
        rawSend(
            Outbound.uiEvent(
                action: action,
                sessionId: chatId,
                payload: payload,
                submissionId: identity.submissionId,
                requestGeneration: identity.requestGeneration))
    }

    @discardableResult
    func submitParamPicker(
        action: String,
        fields: [String: JSONValue],
        payload: [String: JSONValue]
    ) -> Bool {
        guard signedIn, connected, !timelineReadOnly, continuity.connectionGeneration != nil else {
            bannerIsError = true
            errorBanner = "Reconnect before changing settings. Your entered values are still available."
            return false
        }
        guard !paramPickerPending(action: action) else { return false }
        var submittedPayload = payload
        submittedPayload["fields"] = .object(fields)
        if action.hasPrefix("chrome_note_") {
            return sendGuidanceRequest(action: action, payload: .object(submittedPayload))
        }
        guard action == "chrome_llm_save" else {
            emit(action, payload: submittedPayload)
            return true
        }

        if let current = llmFirstLoginOperation,
            !current.isAuthoritativelyTerminal
        {
            if current.state == .unconfirmed {
                Task { await self.reconcileLLMFirstLoginOperation() }
            } else if !current.phaseVisible {
                var focused = current
                focused.phaseVisible = true
                llmFirstLoginOperation = focused
            }
            return false
        }
        guard let connectionGeneration = continuity.connectionGeneration else {
            bannerIsError = true
            errorBanner = "Reconnect before saving your provider settings."
            return false
        }

        let identity = ClientOperationIdentity.fresh()
        bindOrdinarySurfaceRequest(identity: identity, action: action, payload: .object(submittedPayload))
        parameterRequests[action] = identity.requestGeneration
        let submissionId = identity.submissionId
        let requestGeneration = identity.requestGeneration
        llmFirstLoginOperation = LLMFirstLoginOperation(
            submissionId: submissionId,
            requestGeneration: requestGeneration,
            connectionGeneration: connectionGeneration,
            requiresAdvance: mandatorySurface && pendingSurfaceKey == "llm",
            operationId: nil,
            sequence: nil,
            state: .submitting,
            phase: "submitting",
            label: "Submitting…",
            retryable: false,
            errorCode: nil,
            errorMessage: nil,
            phaseVisible: false,
            isAuthoritativelyTerminal: false,
            didAdvance: false)
        armLLMFirstLoginTimers(submissionId: submissionId)

        beginLocalOperationSubmission(
            identity: identity,
            action: action,
            surface: "llm_settings",
            chatId: nil,
            exposeStatus: false)

        submittedPayload["surface"] = .string("llm_settings")
        rawSend(
            Outbound.uiEvent(
                action: action,
                sessionId: nil,
                payload: .object(submittedPayload),
                submissionId: submissionId,
                requestGeneration: requestGeneration))
        return true
    }

    func paramPickerPending(action: String) -> Bool {
        if action == "chrome_llm_save" { return llmFirstLoginOperation?.isLoading == true }
        return localOperationSubmissions.values.contains {
            $0.action == action && $0.chatId == nil && $0.requestGeneration == parameterRequests[action]
                && ordinarySurfaceRequests[$0.requestGeneration] != nil
        }
    }

    func paramPickerStatus(action: String) -> String? {
        if action == "chrome_llm_save", let operation = llmFirstLoginOperation { return operation.presentedLabel }
        if let request = parameterRequests[action], parameterFailures.contains(request) { return nil }
        if let pending = localOperationSubmissions.values.first(where: {
            $0.action == action && $0.chatId == nil && $0.requestGeneration == parameterRequests[action]
        }) {
            guard ordinarySurfaceRequests[pending.requestGeneration] != nil else {
                return operationStatuses.values.first {
                    $0.requestGeneration == pending.requestGeneration && $0.terminal
                }?.label
            }
            return operationStatuses.values.first(where: { $0.requestGeneration == pending.requestGeneration })?.label
                ?? pending.label
        }
        return operationStatuses.values.filter {
            $0.action == action && $0.chatId == nil && $0.requestGeneration == parameterRequests[action]
        }.max {
            ($0.updatedAt, $0.sequence) < ($1.updatedAt, $1.sequence)
        }?.label
    }

    func paramPickerCompleted(action: String) -> Bool {
        if action == "chrome_llm_save" { return llmFirstLoginOperation?.state == .completed }
        return operationStatuses.values.contains {
            $0.action == action && $0.requestGeneration == parameterRequests[action] && $0.state == "completed"
                && !parameterFailures.contains($0.requestGeneration)
        }
    }

    @discardableResult
    func saveThemeColor(key: String, value: String) -> Bool {
        guard signedIn, connected, continuity.connectionGeneration != nil, !timelineReadOnly,
            pendingSurfaceKey == "theme", screen == .surface,
            ["bg", "surface", "primary", "secondary", "text", "muted", "accent"].contains(key),
            Color(cssHex: value) != nil, !paramPickerPending(action: "save_theme")
        else { return false }
        sendEvent(
            "save_theme", .object(["theme": .object(["color_key": .string(key), "color_value": .string(value)])]))
        return true
    }

    func emit(_ action: String, payload: [String: JSONValue] = [:]) {
        sendEvent(action, .object(payload))
    }

    private func rawSend(_ text: String) {
        guard noteApprovalDecision(text) else { return }
        let computerReview = ComputerHostOutbound.isReviewDecision(text)
        let approvalRequestId = trackedApprovalRequestId(text)
        #if os(macOS)
            let localComputerSession = computerReview ? macComputerHost.recordApprovalInteraction() : nil
        #else
            let localComputerSession: String? = nil
        #endif
        outboundTap?(text)
        let owner = downloadOwner
        let connection = continuity.connectionGeneration
        let navigation = conversationNavigationGeneration
        let chatId = activeChatId
        if let approvalRequestId, !computerReview {
            guard let pending = submittedApprovals[approvalRequestId], let connection,
                pending.connection == connection, pending.chat == chatId, pending.owner == owner
            else {
                retireUnsentOperation(text)
                return
            }
            if let sendOverride = currentApprovalDecisionSendOverride {
                if !sendOverride(text, connection) { retireUnsentOperation(text) }
                return
            }
            guard let socket = ws, connected else {
                retireUnsentOperation(text)
                return
            }
            Task { [weak self] in
                guard let self,
                    await self.authenticatedSocketIsCurrent(socket, owner: owner, connection: connection)
                else {
                    self?.retireUnsentOperation(text)
                    return
                }
                let sent = await socket.sendCurrentApprovalDecision(text, connectionGeneration: connection) {
                    [weak self] in
                    await MainActor.run {
                        guard let self, self.signedIn, self.connected, self.downloadOwner == owner,
                            self.ws === socket, self.continuity.connectionGeneration == connection,
                            self.activeChatId == chatId,
                            let current = self.submittedApprovals[approvalRequestId]
                        else { return false }
                        return current.submissionId == pending.submissionId
                            && current.requestGeneration == pending.requestGeneration
                            && current.connection == connection && current.chat == chatId
                            && current.owner == owner
                    }
                }
                if !sent { self.retireUnsentOperation(text) }
            }
            return
        }
        guard let socket = ws else {
            if approvalRequestId != nil { retireUnsentOperation(text) }
            return
        }
        let safety = SafetySurfaceRequest.claimsCurrentConnectionSemantics(frameText: text)
        let mesh =
            InboundFrame.parse(text)?.payload["action"]?.stringValue?.hasPrefix("chrome_mesh_") == true
            || InboundFrame.parse(text)?.payload["payload"]?["surface"]?.stringValue == "mesh"
        let currentChrome = ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: text) || safety || mesh
        let surface = InboundFrame.parse(text)?.payload["payload"]?["surface"]?.stringValue ?? ""
        let requestGeneration = InboundFrame.parse(text)?.payload["request_generation"]?.stringValue
        Task {
            let allowed: Bool
            if currentChrome && !connected {
                retireUnsentOperation(text)
                return
            } else if connected {
                allowed = await authenticatedSocketIsCurrent(socket, owner: owner, connection: connection)
            } else {
                let result = await refreshOutcome(renewSocket: false)
                if case .ok = result {
                    allowed = owner == downloadOwner && ws === socket && !Task.isCancelled
                } else {
                    allowed = false
                }
            }
            guard allowed else {
                if owner == downloadOwner {
                    if await sendOnRenewedSocket(text, replacing: socket, navigation: navigation, chatId: chatId) {
                        return
                    }
                    retireUnsentOperation(text)
                    restoreUnsentQuery(text, navigation: navigation, chatId: chatId)
                }
                return
            }
            if computerReview {
                #if os(macOS)
                    guard await macComputerHost.flushApprovalPause(localComputerSession) else {
                        retireUnsentOperation(text)
                        errorBanner = "The computer session changed. Review the current task before approving again."
                        bannerIsError = true
                        return
                    }
                #endif
                let sent = await socket.sendCurrentComputerDecision(text) { [weak self] in
                    guard let self else { return false }
                    return await self.computerDecisionIsCurrent(
                        socket: socket, owner: owner, connection: connection,
                        chatId: chatId, navigation: navigation, localSession: localComputerSession)
                }
                if !sent { retireUnsentOperation(text) }
                return
            }
            if currentChrome {
                let sent = await socket.sendCurrentChromeEvent(text) { [weak self] in
                    await MainActor.run {
                        guard let self else { return false }
                        return self.signedIn && self.connected && self.downloadOwner == owner && self.ws === socket
                            && self.continuity.connectionGeneration == connection && self.activeChatId == chatId
                            && self.conversationNavigationGeneration == navigation
                            && self.pendingSurfaceKey == (mesh ? "mesh" : safety ? "safety" : surface)
                            && self.screen == .surface && self.ordinarySurfaceGeneration == requestGeneration
                    }
                }
                if !sent && owner == downloadOwner { retireUnsentOperation(text) }
            } else {
                _ = await socket.confirmLive()
                await socket.send(text)
            }
        }
    }

    private func sendOnRenewedSocket(_ text: String, replacing original: WSClient, navigation: Int, chatId: String?)
        async -> Bool
    {
        guard signedIn, let current = ws, current !== original, navigation == conversationNavigationGeneration,
            activeChatId == chatId, screen == .chat,
            InboundFrame.parse(text)?.payload["action"]?.stringValue == "chat_message"
        else { return false }
        await current.sendThroughReplay(text)
        return true
    }

    private func computerChannelIsCurrent(socket: WSClient, owner: DownloadOwner, connection: String?) -> Bool {
        ws === socket && downloadOwner == owner && continuity.connectionGeneration == connection
    }

    private func computerDecisionIsCurrent(
        socket: WSClient, owner: DownloadOwner, connection: String?,
        chatId: String?, navigation: Int, localSession: String?
    ) -> Bool {
        let current =
            computerChannelIsCurrent(socket: socket, owner: owner, connection: connection)
            && activeChatId == chatId && conversationNavigationGeneration == navigation && connected
        #if os(macOS)
            return current && macComputerHost.approvalStillCurrent(localSession)
        #else
            return current
        #endif
    }

    private func retireUnsentOperation(_ text: String) {
        guard let frame = InboundFrame.parse(text), let request = frame.payload["request_generation"]?.stringValue
        else {
            return
        }
        let approvalRetired = retireUnsentApproval(frame)
        if parameterRequests.values.contains(request) {
            parameterFailures.insert(request)
            surfaceFailureMessage = "The action was not sent. Review your entries and retry after reconnecting."
        }
        if llmFirstLoginOperation?.submissionId == frame.payload["submission_id"]?.stringValue {
            clearLLMFirstLoginOperation()
        }
        failOrdinarySurface(
            generation: request, message: "The session could not update. Reconnect and retry this screen.")
        clearLocalOperationSubmission(requestGeneration: request)
        if approvalRetired {
            bannerIsError = true
            errorBanner = "The approval decision was not confirmed. Check the action before trying again."
        }
    }

    private func trackedApprovalRequestId(_ text: String) -> String? {
        guard let frame = InboundFrame.parse(text),
            ["authorize_action", "remote_op_decision"].contains(frame.payload["action"]?.stringValue ?? ""),
            let payload = frame.payload["payload"],
            let requestId = (payload["hitl_request_id"] ?? payload["proposal_id"])?.stringValue,
            let submissionId = frame.payload["submission_id"]?.stringValue,
            let pending = submittedApprovals[requestId]
        else { return nil }
        guard pending.submissionId == submissionId,
            pending.requestGeneration == frame.payload["request_generation"]?.stringValue,
            pending.connection == continuity.connectionGeneration,
            pending.chat == activeChatId,
            pending.owner == downloadOwner
        else { return nil }
        return requestId
    }

    private func retireUnsentApproval(_ frame: InboundFrame) -> Bool {
        guard let payload = frame.payload["payload"],
            let requestId = (payload["hitl_request_id"] ?? payload["proposal_id"])?.stringValue,
            let pending = submittedApprovals[requestId],
            pending.submissionId == frame.payload["submission_id"]?.stringValue,
            pending.requestGeneration == frame.payload["request_generation"]?.stringValue
        else { return false }
        submittedApprovals.removeValue(forKey: requestId)
        withdrawingApprovals.remove(requestId)
        if decidedApprovals.count >= 512 { decidedApprovals.removeAll() }
        decidedApprovals.insert(requestId)
        updateActivity(pending.chat) { rows in
            guard let index = pending.row.flatMap({ id in rows.firstIndex { $0.id == id } }) else { return }
            rows[index].approval = .uncertain
            rows[index].state = .failed
            rows[index].result = "The decision could not be confirmed. Inspect the action before trying again."
        }
        removeApprovalCards([requestId])
        if let submissionId = pending.submissionId { clearLocalOperationSubmission(submissionId: submissionId) }
        observeActivityComponents()
        return true
    }

    private func restoreUnsentQuery(_ text: String, navigation: Int, chatId: String?) {
        guard navigation == conversationNavigationGeneration, activeChatId == chatId, screen == .chat,
            let frame = InboundFrame.parse(text), frame.payload["action"]?.stringValue == "chat_message",
            let message = frame.payload["payload"]?["message"]?.stringValue
        else { return }
        if composerDraft.isEmpty { composerDraft = message }
        turnActive = false
        statusText = nil
        bannerIsError = true
        errorBanner = "The message was not sent. Review it and try again after reconnecting."
    }

    @discardableResult
    func sendVoiceWire(_ text: String) -> Bool {
        guard signedIn, connected,
            currentConnectionVoiceSendOverride != nil || ws != nil,
            VoiceCurrentConnectionFrame(frameText: text) != nil,
            let frame = InboundFrame.parse(text)
        else { return false }
        if frame.name == "ui_event", frame.payload["action"]?.stringValue == "chat_message",
            let submission = frame.payload["submission_id"]?.stringValue,
            let request = frame.payload["request_generation"]?.stringValue,
            let identity = ClientOperationIdentity(
                submissionId: submission, requestGeneration: request),
            let chatId = frame.payload["session_id"]?.stringValue
        {
            if localOperationSubmissions[submission] == nil {
                guard
                    continuity.connectionGeneration == nil
                        || openConversationRequest(
                            chatId: chatId, requestGeneration: request, purpose: .commit)
                else { return false }
                beginLocalOperationSubmission(
                    identity: identity, action: "chat_message", surface: "chat",
                    chatId: chatId)
                let message = frame.payload["payload"]?["message"]?.stringValue ?? ""
                if continuity.connectionGeneration == nil {
                    appendTurn(role: "user", text: message)
                } else {
                    transientTurns.append(
                        ChatTurn(
                            id: "pending-voice-\(submission)", role: "user",
                            text: message))
                }
                turnActive = true
                workspaceStarted = true
                consoleDashboardVisible = false
                pendingReplace = true
                pendingCanvas = []
                liveOpsThisTurn = false
            }
        }
        outboundTap?(text)
        if let override = currentConnectionVoiceSendOverride {
            override(text)
        } else if let ws {
            Task { _ = await ws.sendCurrentConnectionVoice(text) }
        }
        return true
    }

    func activateVoice() async {
        #if os(macOS)
            if needsProjectSelection() {
                requestProjectChoice { [weak self] in Task { await self?.activateVoice() } }
                return
            }
            guard await prepareProjectChat() else { return }
        #endif
        await voice.activate()
    }

    func performVoiceControl(_ action: VoiceControlAction) async {
        if action == .start {
            await activateVoice()
            return
        }
        await voice.perform(action)
    }

    func voiceSceneBecameActive() {
        #if os(iOS)
            pushSceneActive = true
            pushNotifications?.sceneChanged(
                active: true, connectionGeneration: connected ? continuity.connectionGeneration : nil)
        #endif
        voice.sceneBecameActive()
        reportDeviceCapabilities()
    }

    func voiceSceneBecameInactive() {
        #if os(iOS)
            pushSceneActive = false
            pushNotifications?.sceneChanged(
                active: false, connectionGeneration: connected ? continuity.connectionGeneration : nil)
        #endif
        voice.sceneBecameInactive()
    }

    func voiceAudioSessionInterrupted() { voice.audioSessionInterrupted() }

    func voiceAudioSessionInterruptionEnded() { voice.audioSessionInterruptionEnded() }

    func voiceAudioRouteChanged() {
        voice.audioRouteChanged()
        reportDeviceCapabilities()
    }

    func voiceAudioEngineConfigurationChanged() { voice.audioEngineConfigurationChanged() }

    func voiceSessionLocked() { voice.sessionLocked() }

    func voiceSessionUnlocked() { voice.sessionUnlocked() }

    func voiceApplicationWillTerminate() { voice.close() }

    func refineComponent(_ componentId: String, instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !componentId.isEmpty, !trimmed.isEmpty else { return }
        sendEvent(
            "component_refine",
            .object([
                "component_id": .string(componentId),
                "instruction": .string(trimmed),
            ]))
    }

    func exportComponentURL(_ componentId: String) -> URL? {
        guard let chatId = activeChatId, !chatId.isEmpty, !componentId.isEmpty else { return nil }
        let base = serverBase.appendingPathComponent("api/export/component/\(componentId).csv")
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "chat_id", value: chatId)]
        return comps?.url
    }

    func exportCanvasURL() -> URL? {
        guard let chatId = activeChatId, !chatId.isEmpty else { return nil }
        return serverBase.appendingPathComponent("api/export/canvas/\(chatId).html")
    }

    #if os(macOS)
        private func projectAccessToken(owner: DownloadOwner, connection: String) async -> String? {
            guard downloadOwner == owner, continuity.connectionGeneration == connection else { return nil }
            let token = await freshAccessToken()
            guard downloadOwner == owner, continuity.connectionGeneration == connection else { return nil }
            return token
        }
        func selectProject(_ id: String) { projects.select(id) }
        func requestProjectDeletion(_ project: ProjectRecord) {
            guard projects.enabled, !mandatorySurface, projects.projects.contains(where: { $0.id == project.id }) else {
                return
            }
            let owner = downloadOwner
            let connection = continuity.connectionGeneration
            let requestedChats = Set(projects.chats[project.id]?.map(\.id) ?? [])
            projectPendingDeletion = project
            projectDeletionAction = { [weak self] in
                guard let self, self.downloadOwner == owner, self.continuity.connectionGeneration == connection,
                    self.projects.enabled
                else { return }
                let chats = requestedChats.union(self.projects.chats[project.id]?.map(\.id) ?? [])
                guard let deletedChats = await self.projects.delete(project), self.downloadOwner == owner,
                    self.continuity.connectionGeneration == connection
                else { return }
                for chat in chats.union(deletedChats) { self.clearConfirmedDeletion(chat) }
            }
        }
        func cancelProjectDeletion() {
            projectPendingDeletion = nil
            projectDeletionAction = nil
        }
        func confirmProjectDeletion() {
            let action = projectDeletionAction
            cancelProjectDeletion()
            Task { await action?() }
        }
        func presentProjectCreation() {
            guard projects.enabled, !mandatorySurface else { return }
            cancelProjectChoice()
            projectChooserPresented = true
        }
        private func retireProjectCatalog() {
            cancelProjectChoice()
            cancelProjectDeletion()
            projectCreationTask?.cancel()
            projectCreationTask = nil
            projectCreationEpoch = UUID()
            projects.bind(scope: nil, client: nil)
        }
        private func needsProjectSelection(force: Bool = false) -> Bool {
            projects.enabled && projects.selectedId == nil
                && (force || activeChatId.flatMap { projects.project(for: $0) } == nil)
        }
        private func requestProjectChoice(_ action: @escaping () -> Void) {
            let owner = downloadOwner
            let connection = continuity.connectionGeneration
            let navigation = conversationNavigationGeneration
            let chat = activeChatId
            projectChoiceAfterDismissal = nil
            projectChoiceEpoch = UUID()
            projectChoice = { [weak self] in
                guard let self, self.downloadOwner == owner, self.continuity.connectionGeneration == connection,
                    self.conversationNavigationGeneration == navigation, self.activeChatId == chat,
                    self.projects.enabled
                else { return }
                action()
            }
            projectChooserPresented = true
        }
        func cancelProjectChoice() {
            projectChoiceEpoch = UUID()
            projectChooserPresented = false
            projectChoice = nil
            projectChoiceAfterDismissal = nil
        }
        func projectChoiceDidDismiss() {
            guard !projectChooserPresented else { return }
            let action = projectChoiceAfterDismissal
            projectChoiceAfterDismissal = nil
            action?()
        }
        func chooseProjectForPendingChat(_ id: String) {
            guard projectChooserPresented, projects.enabled, projects.projects.contains(where: { $0.id == id }) else {
                return
            }
            projects.select(id)
            let action = projectChoice
            cancelProjectChoice()
            action?()
        }
        func createProject(name: String, chooseFolders: Bool) async {
            let owner = downloadOwner
            let server = serverBase
            let connection = continuity.connectionGeneration
            let navigation = conversationNavigationGeneration
            let chat = activeChatId
            let choice = projectChoiceEpoch
            guard let id = await projects.createProject(name: name), !Task.isCancelled, downloadOwner == owner,
                serverBase == server, activeChatId == chat,
                continuity.connectionGeneration == connection, conversationNavigationGeneration == navigation,
                projectChoiceEpoch == choice, projects.selectedId == id
            else { return }
            let finish = { [weak self] in
                guard let self, self.downloadOwner == owner, self.serverBase == server, self.activeChatId == chat,
                    self.continuity.connectionGeneration == connection,
                    self.conversationNavigationGeneration == navigation, self.projectChoiceEpoch == choice,
                    self.projects.enabled, self.projects.selectedId == id,
                    self.projects.projects.contains(where: { $0.id == id })
                else { return }
                if chooseFolders {
                    self.macComputerHost.updateProjectFolders {
                        try self.macComputerHost.projectGrants.choose(project: id)
                    }
                }
                guard self.downloadOwner == owner, self.serverBase == server, self.activeChatId == chat,
                    self.continuity.connectionGeneration == connection,
                    self.conversationNavigationGeneration == navigation, self.projectChoiceEpoch == choice,
                    self.projects.enabled, self.projects.selectedId == id,
                    self.projects.projects.contains(where: { $0.id == id })
                else { return }
                let action = self.projectChoice
                self.cancelProjectChoice()
                action?()
            }
            projectChoiceAfterDismissal = finish
            projectChooserPresented = false
        }
        private func createProjectChat(force: Bool = false, then action: (() -> Void)? = nil) {
            if needsProjectSelection(force: force) {
                requestProjectChoice { [weak self] in self?.createProjectChat(force: force, then: action) }
                return
            }
            guard projectCreationTask == nil else { return }
            let operation = UUID()
            projectCreationEpoch = operation
            projectCreationTask = Task { [weak self] in
                guard let self else { return }
                let ready = await self.prepareProjectChat(force: force)
                guard self.projectCreationEpoch == operation else { return }
                self.projectCreationTask = nil
                if ready { action?() }
            }
        }
        private func prepareProjectChat(force: Bool = false) async -> Bool {
            guard !projects.negotiating else { return false }
            guard projects.enabled else { return true }
            guard !mandatorySurface, !timelineReadOnly else { return false }
            if !force, let activeChatId, projects.project(for: activeChatId) != nil { return true }
            let owner = downloadOwner
            let connection = continuity.connectionGeneration
            let navigation = conversationNavigationGeneration
            do {
                let chat = try await projects.createChat()
                guard !Task.isCancelled, downloadOwner == owner, continuity.connectionGeneration == connection,
                    conversationNavigationGeneration == navigation
                else { return false }
                if force {
                    let draft = composerDraft
                    let attachments = staged
                    clearContinuityChatKeepingConnection()
                    resetChatState()
                    composerDraft = draft
                    staged = attachments
                }
                openChat(chat)
                return activeChatId == chat
            } catch {
                guard !Task.isCancelled, downloadOwner == owner, continuity.connectionGeneration == connection,
                    conversationNavigationGeneration == navigation
                else { return false }
                if !(error is CancellationError) {
                    bannerIsError = true
                    errorBanner = error.localizedDescription
                }
                return false
            }
        }
    #endif

    func newChat() {
        if mandatorySurface { return }
        #if os(macOS)
            if projects.negotiating { return }
            if projects.enabled {
                createProjectChat(force: true)
                return
            }
        #endif
        invalidateGuidance()
        if let account = conversationAccount {
            _ = conversationResumeStore.clear(.newChat, for: account)
        }
        seqState.removeAll()
        clearContinuityChatKeepingConnection()
        resetChatState()
        screen = .chat
        sendEvent("new_chat")
    }

    func openChat(_ chatId: String) {
        #if os(macOS)
            if projects.negotiating { return }
            if projects.enabled {
                guard let project = projects.project(for: chatId) else {
                    errorBanner = "This chat is not in the current project catalog. Refresh projects and retry."
                    bannerIsError = true
                    return
                }
                projects.select(project)
            }
        #endif
        if ["evidence", "terminal"].contains(pendingSurfaceKey) { closeSurface() }
        consoleFullscreen = false
        consoleResultCollapsed = false
        invalidateGuidance()
        turnSelection = nil
        consoleDashboardVisible = false
        consoleDrawerOpen = false
        workspaceStarted = true
        if let account = conversationAccount {
            guard conversationResumeStore.save(chatId: chatId, for: account) else { return }
        }
        conversationNavigationGeneration += 1
        activeChatId = chatId
        voice.updateVisibleChatLocally(chatId)
        let identity = ClientOperationIdentity.fresh()
        let request = identity.requestGeneration
        if continuity.connectionGeneration != nil {
            guard
                openConversationRequest(
                    chatId: chatId,
                    requestGeneration: request,
                    purpose: .hydration)
            else { return }
        }
        beginLocalOperationSubmission(
            identity: identity,
            action: "load_chat",
            surface: "chat",
            chatId: chatId)
        rawSend(
            Outbound.loadChat(
                sessionId: chatId,
                chatId: chatId,
                submissionId: identity.submissionId,
                requestGeneration: request))
        screen = .chat
        viewingIndex = nil
    }

    func deleteChat(_ chatId: String) {
        Task {
            guard (try? await rest.deleteChat(id: chatId)) == true else { return }
            history.removeAll { $0.id == chatId }
            clearConfirmedDeletion(chatId)
            sendEvent("get_history")
        }
    }

    func goTo(_ target: Screen) {
        if mandatorySurface { return }
        retireOrdinarySurfaceRequests()
        if ["work", "guidance", "terminal"].contains(pendingSurfaceKey) { closeSurface() }
        screen = target
        agentsLoading = target == .agents || agentsLoading
        historyLoading = target == .history || historyLoading
        auditLoading = target == .audit || auditLoading
        switch target {
        case .agents: sendEvent("discover_agents")
        case .history: sendEvent("get_history")
        case .audit: loadAudit()
        case .chat, .surface: break
        }
    }

    func toggleHistory() {
        guard !mandatorySurface else { return }
        if screen == .history {
            screen = .chat
        } else {
            goTo(.history)
        }
    }

    func openMenuItem(_ item: ChromeMenuItem) { openSurface(item.surface, params: item.params) }

    func openSurface(_ surface: String, params: JSONValue = .object([:])) {
        cancelMeshPresentation()
        sendEvent("chrome_open", .object(["surface": .string(surface), "params": params]))
    }

    func retryPendingSurface() {
        guard !pendingSurfaceKey.isEmpty else { return }
        if pendingSurfaceKey == "guidance" {
            retryGuidance()
            return
        }
        retireOrdinarySurfaceRequests()
        surfaceFailureMessage = nil
        sendEvent("chrome_open", .object(["surface": .string(pendingSurfaceKey), "params": pendingSurfaceParams]))
    }

    func failEvidenceRead(generation: String?) {
        guard let generation, pendingSurfaceKey == "evidence", ordinarySurfaceGeneration == generation else { return }
        retireOrdinarySurfaceRequests()
        clearLocalOperationSubmission(requestGeneration: generation)
        surfaceFailureMessage = "The server didn't send it in time. Check your connection and try again."
    }

    func failTerminalRead(generation: String?) {
        guard let generation, pendingSurfaceKey == "terminal", ordinarySurfaceGeneration == generation else { return }
        retireOrdinarySurfaceRequests()
        clearLocalOperationSubmission(requestGeneration: generation)
        surfaceFailureMessage = "The server didn't send it in time. Check your connection and try again."
    }

    func failSafetyRequest(generation: String?) {
        guard let generation, pendingSurfaceKey == "safety", ordinarySurfaceGeneration == generation else { return }
        failOrdinarySurface(
            generation: generation, message: "The server didn't send it in time. Check your connection and try again.")
        clearLocalOperationSubmission(requestGeneration: generation)
    }

    func closeSurface() {
        if mandatorySurface { return }
        guard screen == .surface else { return }
        if pendingSurfaceKey == "guidance" { closeGuidance() }
        if pendingSurfaceKey == "work" { closeWorkRead() }
        screen = .chat
        retireOrdinarySurfaceRequests()
        parameterRequests = [:]
        parameterFailures = []
        surfaceFailureMessage = nil
        pendingSurface = nil
        pendingSurfaceKey = ""
        pendingSurfaceParams = .object([:])
    }

    private var guidanceMenuAvailable: Bool {
        chromeMenu?.allItems.contains { $0.surface == "guidance" } == true
            || !GuidanceRequest.controls(in: chromeMenu).isEmpty
            || console?.composerActions.contains { $0.action?.surface == "guidance" } == true
    }

    private func retireGuidanceTicket() {
        guidanceTask?.cancel()
        guidanceTask = nil
        guidanceState.invalidate()
        guidanceEpoch = UUID().uuidString.lowercased()
    }

    private func invalidateGuidance() {
        retireGuidanceTicket()
        guidanceUpdate = nil
        guidanceFailed = pendingSurfaceKey == "guidance"
        if pendingSurfaceKey == "guidance" { pendingSurface = nil }
    }

    func failGuidanceRequest(generation: String?) {
        guard let generation, guidanceState.generation == generation else { return }
        invalidateGuidance()
        guidanceFailed = true
        if surfaceFailureMessage == nil {
            surfaceFailureMessage = "Private notes could not be loaded. Reconnect or retry without changing your notes."
        }
    }

    func retryGuidance() {
        guard screen == .surface, pendingSurfaceKey == "guidance" else { return }
        let request: GuidanceRequest =
            pendingSurfaceParams == GuidanceRequest.selection.payload["params"] ? .selection : .list
        if !sendGuidanceRequest(action: request.action, payload: request.payload), surfaceFailureMessage == nil {
            guidanceFailed = true
            surfaceFailureMessage = "This screen is no longer available. Reopen it from the current menu."
        }
    }

    @discardableResult
    func sendGuidanceRequest(action: String, payload: JSONValue) -> Bool {
        guard !mandatorySurface, let request = GuidanceRequest(action: action, payload: payload),
            request.action != "chrome_close",
            guidanceUpdate?.permits(request) == true
                || (request == .list && pendingSurfaceKey == "guidance")
                || chromeMenu?.allItems.contains(where: {
                    GuidanceRequest(
                        action: "chrome_open", payload: .object(["surface": .string($0.surface), "params": $0.params]))
                        == request
                }) == true
                || GuidanceRequest.controls(in: chromeMenu).contains(where: {
                    GuidanceRequest(action: "chrome_open", payload: .object($0.chromeOpenPayload)) == request
                })
                || console?.composerActions.contains(where: {
                    guard let action = $0.action else { return false }
                    return GuidanceRequest(
                        action: "chrome_open",
                        payload: .object([
                            "surface": .string(action.surface), "params": action.params,
                        ])) == request
                }) == true
        else { return false }
        retireOrdinarySurfaceRequests()
        invalidateWorkRead()
        let generation = guidanceEpoch
        guidanceFailed = false
        surfaceFailureMessage = nil
        _ = guidanceState.begin(request, generation: generation)
        screen = .surface
        pendingSurfaceKey = "guidance"
        if action == "chrome_open" {
            pendingSurfaceParams = payload["params"] ?? .object(["mode": .string("list")])
        }
        pendingSurface = nil
        guard signedIn, connected, conversationAccount != nil, let socket = ws else {
            failGuidanceRequest(generation: generation)
            return false
        }
        let owner = downloadOwner
        let connection = continuity.connectionGeneration
        let text = request.frameText(requestGeneration: generation)
        guard guidanceState.bindSubmission(text) else {
            failGuidanceRequest(generation: generation)
            return false
        }
        guidanceTask = Task { [weak self] in
            guard let self, await self.authenticatedSocketIsCurrent(socket, owner: owner, connection: connection) else {
                if let self, self.guidanceEpoch == generation, self.downloadOwner == owner {
                    self.failGuidanceRequest(generation: generation)
                }
                return
            }
            let sent = await socket.sendCurrentGuidanceEvent(text) { [weak self] in
                await MainActor.run {
                    guard let self else { return false }
                    return self.downloadOwner == owner && self.ws === socket && self.connected
                        && self.guidanceEpoch == generation && self.screen == .surface
                        && self.pendingSurfaceKey == "guidance"
                        && self.continuity.connectionGeneration == connection
                }
            }
            guard !Task.isCancelled, self.guidanceEpoch == generation,
                self.downloadOwner == owner, self.ws === socket
            else { return }
            if !sent { self.failGuidanceRequest(generation: generation) }
        }
        return true
    }

    private func closeGuidance() {
        invalidateGuidance()
        let generation = guidanceEpoch
        guard signedIn, connected, let socket = ws else { return }
        let owner = downloadOwner
        let request = GuidanceRequest(action: "chrome_close", payload: .object(["surface": .string("guidance")]))!
        let text = request.frameText(requestGeneration: generation)
        guidanceTask = Task { [weak self] in
            _ = await socket.sendCurrentGuidanceEvent(text) { [weak self] in
                await MainActor.run {
                    guard let self else { return false }
                    return self.guidanceEpoch == generation && self.downloadOwner == owner && self.ws === socket
                }
            }
        }
    }

    private func retireWorkTicket() {
        workReadTask?.cancel()
        workReadTask = nil
        workReadState.invalidate()
        workReadEpoch = UUID().uuidString.lowercased()
    }

    func failWorkRead(generation: String?) {
        guard let generation, workReadState.generation == generation else { return }
        invalidateWorkRead()
        workReadFailed = true
    }

    private func invalidateWorkRead() {
        invalidateGuidance()
        retireWorkTicket()
        workReadUpdate = nil
        workReadFailed = false
        if pendingSurfaceKey == "work" {
            pendingSurface = nil
            surfaceNavigationScope = nil
        }
    }

    private func beginWorkRead(_ payload: JSONValue) {
        guard !mandatorySurface, let request = WorkReadRequest(payload: payload),
            workReadState.request == request || workReadUpdate?.permits(request) == true
                || (pendingSurfaceKey == "work" && pendingSurfaceParams == request.params)
                || chromeMenu?.topbarActions.contains(where: {
                    WorkReadRequest(payload: .object($0.chromeOpenPayload)) == request
                }) == true
        else { return }
        retireOrdinarySurfaceRequests()
        invalidateWorkRead()
        let generation = workReadEpoch
        workReadState.begin(request, generation: generation)
        screen = .surface
        pendingSurfaceKey = "work"
        pendingSurfaceParams = request.params
        pendingSurface = nil
        guard signedIn, connected, conversationAccount != nil, let socket = ws else {
            failWorkRead(generation: generation)
            return
        }
        let owner = downloadOwner
        let connection = continuity.connectionGeneration
        let text = request.frameText(requestGeneration: generation)
        guard workReadState.bindSubmission(frameText: text) else {
            failWorkRead(generation: generation)
            return
        }
        outboundTap?(text)
        workReadTask = Task { [weak self] in
            guard let self, await self.authenticatedSocketIsCurrent(socket, owner: owner, connection: connection) else {
                if let self, self.workReadEpoch == generation, self.downloadOwner == owner {
                    self.failWorkRead(generation: generation)
                }
                return
            }
            let sent = await socket.sendCurrentWorkEvent(text) { [weak self] in
                await MainActor.run {
                    guard let self else { return false }
                    return self.downloadOwner == owner && self.ws === socket && self.connected
                        && self.workReadEpoch == generation && self.screen == .surface
                        && self.continuity.connectionGeneration == connection
                }
            }
            guard !Task.isCancelled, self.workReadEpoch == generation,
                self.downloadOwner == owner, self.ws === socket
            else { return }
            if !sent { self.failWorkRead(generation: generation) }
        }
    }

    private func beginWorkContinuity(_ payload: JSONValue) {
        guard signedIn, connected, !mandatorySurface, !mutationsLocked, screen == .surface,
            pendingSurfaceKey == "work", conversationAccount != nil,
            let command = WorkContinuityRequest(payload: payload), workReadUpdate?.permits(command) == true,
            let socket = ws, let connection = continuity.connectionGeneration
        else { return }
        retireOrdinarySurfaceRequests()
        invalidateWorkRead()
        let generation = workReadEpoch
        guard workReadState.beginContinuity(command, generation: generation), let request = workReadState.request else {
            return
        }
        pendingSurfaceParams = request.params
        pendingSurface = nil
        let owner = downloadOwner
        let text = command.frameText(requestGeneration: generation, connectionGeneration: connection)
        guard workReadState.bindSubmission(frameText: text) else {
            failWorkRead(generation: generation)
            return
        }
        outboundTap?(text)
        workReadTask = Task { [weak self] in
            guard let self, await self.authenticatedSocketIsCurrent(socket, owner: owner, connection: connection) else {
                if let self, self.workReadEpoch == generation, self.downloadOwner == owner {
                    self.failWorkRead(generation: generation)
                }
                return
            }
            let sent = await socket.sendCurrentWorkEvent(text) { [weak self] in
                await MainActor.run {
                    guard let self else { return false }
                    return self.downloadOwner == owner && self.ws === socket && self.connected
                        && self.workReadEpoch == generation && self.screen == .surface
                        && self.pendingSurfaceKey == "work" && !self.mandatorySurface && !self.mutationsLocked
                        && self.continuity.connectionGeneration == connection
                }
            }
            guard !Task.isCancelled, self.workReadEpoch == generation,
                self.downloadOwner == owner, self.ws === socket
            else { return }
            if !sent { self.failWorkRead(generation: generation) }
        }
    }

    private func closeWorkRead() {
        invalidateWorkRead()
        let generation = workReadEpoch
        guard signedIn, connected, let socket = ws else { return }
        let owner = downloadOwner
        let text = Outbound.uiEvent(
            action: "chrome_close", sessionId: nil,
            payload: .object(["surface": .string("work")]), requestGeneration: generation)
        workReadTask = Task { [weak self] in
            _ = await socket.sendCurrentWorkEvent(text) { [weak self] in
                await MainActor.run {
                    guard let self else { return false }
                    return self.workReadEpoch == generation && self.downloadOwner == owner && self.ws === socket
                }
            }
        }
    }

    func setToolEnabled(_ agent: Agent, tool: String, enabled: Bool) {
        patchAgent(agent.id) { a in
            var perms = a.permissions
            perms[tool] = enabled
            var copy = a
            copy.permissions = perms
            return copy
        }
        let kind = agent.toolScopeMap[tool] ?? "tools:read"
        Task {
            _ = await rest.setToolPermission(agentId: agent.id, tool: tool, kind: kind, enabled: enabled)
            sendEvent("discover_agents")
        }
    }

    func setAgentEnabled(_ agent: Agent, enabled: Bool) {
        patchAgent(agent.id) { a in
            var copy = a
            copy.permissions = Dictionary(uniqueKeysWithValues: a.tools.map { ($0, enabled) })
            return copy
        }
        let kinds = agent.toolScopeMap.values.isEmpty ? Array(agent.scopes.keys) : Array(Set(agent.toolScopeMap.values))
        var scopes: [String: JSONValue] = [:]
        for k in kinds { scopes[k] = .bool(enabled) }
        var overrides: [String: JSONValue] = [:]
        for t in agent.tools { overrides[t] = .bool(enabled) }
        sendEvent(
            "set_agent_permissions",
            .object([
                "agent_id": .string(agent.id),
                "scopes": .object(scopes),
                "tool_overrides": .object(overrides),
            ]))
        sendEvent("discover_agents")
    }

    private func patchAgent(_ agentId: String, _ transform: (Agent) -> Agent) {
        agents = agents.map { $0.id == agentId ? transform($0) : $0 }
    }

    func enableRecommended() {
        sendEvent("enable_recommended_agents")
        sendEvent("discover_agents")
    }

    private func loadAudit() {
        Task {
            let events = await rest.audit()
            audit = events
            auditLoading = false
        }
    }

    func viewCanvasSnapshot(_ index: Int) {
        if canvasHistory.indices.contains(index) { viewingIndex = index }
    }

    func backToLiveCanvas() { viewingIndex = nil }

    func stageAttachment(filename: String, mimeType: String?, data: Data) {
        attachSeq += 1
        let uid = attachSeq
        staged.append(
            StagedAttachment(
                uid: uid, filename: filename, category: "file",
                attachmentId: nil, state: "uploading", note: nil))
        Task {
            let up = await rest.uploadAttachment(filename: filename, mimeType: mimeType, data: data)
            staged = staged.map { a in
                guard a.uid == uid else { return a }
                var copy = a
                if let up {
                    copy.attachmentId = up.attachmentId
                    copy.category = up.category
                    copy.state = "ready"
                    copy.note = parserNote(up.parserStatus)
                } else {
                    copy.state = "failed"
                    copy.note = "upload failed"
                }
                return copy
            }
        }
    }

    func stageFile(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            bannerIsError = true
            errorBanner = "Couldn't read \(url.lastPathComponent)"
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        stageAttachment(filename: url.lastPathComponent, mimeType: mime, data: data)
    }

    func removeAttachment(_ uid: Int) {
        staged.removeAll { $0.uid == uid }
    }

    private func stageExistingAttachment(_ payload: JSONValue) -> Bool {
        guard let id = payload["attachment_id"]?.stringValue, !id.isEmpty else { return false }
        if staged.contains(where: { $0.attachmentId == id }) { return true }
        attachSeq += 1
        staged.append(
            StagedAttachment(
                uid: attachSeq,
                filename: payload["filename"]?.stringValue ?? "attachment",
                category: payload["category"]?.stringValue ?? "file",
                attachmentId: id, state: "ready", note: nil))
        return true
    }

    var connectionStripLabel: String? {
        guard signedIn, !connected else { return nil }
        if everConnected { return "Reconnecting…" }
        return initialConnectionFailed ? "Couldn't connect." : "Connecting…"
    }

    func retryConnection() {
        guard signedIn, !connected else { return }
        initialConnectionFailed = false
        connectWS(resumed: true)
    }
}

private actor AppRegistrationResumeState {
    private var next: Bool

    init(initial: Bool) {
        next = initial
    }

    func consume() -> Bool {
        let value = next
        next = true
        return value
    }
}

extension AppModel: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
                NSApplication.shared.mainWindow ?? ASPresentationAnchor()
            #else
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first ?? ASPresentationAnchor()
            #endif
        }
    }
}
