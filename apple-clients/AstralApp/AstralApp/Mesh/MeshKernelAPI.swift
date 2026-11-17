// Swift mirror of the kernel's host interface: the Kernel object, its records, the host callbacks and the change events.
// MeshRuntime talks only to MeshKernel, so an adapter over the generated bindings or an in-memory kernel can stand behind it.

import AstralCore
import Foundation

nonisolated enum MeshKernelError: Error, Equatable, Sendable {
    case unavailable(String)
    case refused(code: String?, message: String)
    case notFound
    case meshKeyBindingUnavailable
    case consentDenied
    case stopped
    case storage(String)

    static func refused(_ message: String) -> MeshKernelError { .refused(code: nil, message: message) }

    var code: String? {
        if case .refused(let code, _) = self { return code }
        return nil
    }

    var message: String {
        switch self {
        case .unavailable(let reason): return reason
        case .refused(_, let message): return message
        case .meshKeyBindingUnavailable: return "Open the mesh this Watch belongs to on your iPhone."
        case .notFound: return "That item is no longer on this device."
        case .consentDenied: return "The approval was denied."
        case .stopped: return "The mesh is stopped."
        case .storage(let reason): return reason
        }
    }
}

nonisolated enum MeshDeviceKind: String, Equatable, Sendable {
    case desktop, pocket, satellite, node
}

nonisolated enum MeshPath: String, Equatable, Sendable {
    case direct, relay, mailbox, none
}

nonisolated struct MeshStatus: Equatable, Sendable {
    var hasMesh: Bool
    var meshId: String?
    var deviceId: String?
    var recoveryPending: Bool = false
    var stopped: Bool
    var hardwareBacked: Bool
    var stopLevel: UInt64 = 0

    static let empty = MeshStatus(
        hasMesh: false, meshId: nil, deviceId: nil, stopped: false, hardwareBacked: false)
}

nonisolated struct MeshVerifiedPrincipal: Equatable, Sendable {
    let meshId: String
}

nonisolated struct MeshRecoveryKit: Equatable, Sendable {
    let words: [String]
}

nonisolated struct MeshRecovery: Equatable, Sendable {
    let meshId: String
    let deviceId: String
    let eventsImported: Int
}

nonisolated struct MeshMailboxState: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case disabled, idle, ok, waiting, removed, unreachable, error, unknown
    }
    let configured: Bool
    let status: Status
    let lastError: String?
    let lastOk: Date?
    let pendingNotices: Int
    let truncated: Bool

    static let off = MeshMailboxState(
        configured: false, status: .disabled, lastError: nil, lastOk: nil, pendingNotices: 0, truncated: false)
}

nonisolated struct MeshActResult: Equatable, Sendable {
    let status: String
    let code: String?
    let text: String

    var refused: Bool { code != nil || status != "ok" }
}

nonisolated struct MeshPairingOffer: Equatable, Sendable {
    let shortCode: String
    let payload: String
    var expiresAt: Date?
}

nonisolated struct MeshPairingPreview: Equatable, Sendable {
    let comparisonCode: String
    let deviceLabel: String
    let deviceKind: MeshDeviceKind
    let fingerprint: String
    var expiresAt: Date?
}

nonisolated struct MeshInvitation: Equatable, Sendable {
    let code: String
    let payload: String
    let expiresAt: Date
}

nonisolated struct MeshInvitationAccepted: Equatable, Sendable {
    let comparisonCode: String
    let invitationCode: String
    let inviterDeviceId: String
    let expiresAt: Date
}

nonisolated struct MeshJoinRequest: Equatable, Sendable {
    let comparisonCode: String
    let deviceLabel: String
    let deviceKind: MeshDeviceKind
    let deviceId: String
    let expiresAt: Date
}

nonisolated struct MeshMember: Identifiable, Equatable, Sendable {
    let memberId: String
    let label: String
    let kind: MeshDeviceKind
    let isThisDevice: Bool
    let lastSeen: Date?
    let path: MeshPath
    var addedAt: Date?
    var id: String { memberId }
}

nonisolated struct MeshCallerTicket: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let label: String
    let nodeId: String
    let tools: [String]
    let issuedAt: Date
    let expiresAt: Date
    let revoked: Bool
    let expired: Bool
}

nonisolated struct MeshCallerRequest: Equatable, Sendable {
    let authorization: String
    let proof: String?
    let method: String
    let target: String
    let bodySha256: String
    let tool: String?
}

nonisolated struct MeshVerifiedCaller: Equatable, Sendable {
    let id: String
    let meshId: String
    let deviceId: String
    let label: String
    let tool: String?
    let tools: [String]
    let expiresAt: Date
}

nonisolated enum MeshCallerTicketLimits {
    static let maxTools = 32
    static let maxLabelLength = 64
    static let maxLifetimeSeconds: UInt64 = 2_592_000
    static let a2aTool = "a2a.message"
    static let holderPrefix = "astral-caller-holder:v1:"
}

nonisolated struct MeshDeviceSync: Equatable, Sendable {
    enum State: String, Equatable, Sendable { case synced, behind, unreachable }
    let memberId: String
    let label: String
    let state: State
    let lastSeen: Date?
    let path: MeshPath
}

nonisolated struct MeshSyncState: Equatable, Sendable {
    let devices: [MeshDeviceSync]
    let updatedAt: Date?

    static let empty = MeshSyncState(devices: [], updatedAt: nil)
}

nonisolated enum MeshSyncSummary: Equatable, Sendable {
    case alone
    case synced
    case waiting(device: String, since: Date?)
    case unknown
}

nonisolated struct MeshChatSummary: Identifiable, Equatable, Sendable {
    let chatId: String
    let title: String
    let updatedAt: Date
    let preview: String
    let branchCount: Int
    var queuedCount: Int
    var id: String { chatId }
}

nonisolated enum MeshAuthor: String, Equatable, Sendable {
    case owner, assistant, tool, system
}

nonisolated enum MeshDelivery: String, Equatable, Sendable {
    case queued, recorded
}

nonisolated struct MeshChatMessage: Identifiable, Equatable, Sendable {
    let eventId: String
    let parentId: String?
    let author: MeshAuthor
    let authorDevice: String?
    let text: String
    let createdAt: Date
    let delivery: MeshDelivery
    let surfaceIds: [String]
    var attachments: [MeshAttachment] = []
    var confidentiality = "private"
    var integrity = "owner"
    var id: String { eventId }
}

nonisolated struct MeshAttachment: Identifiable, Equatable, Sendable {
    enum Availability: Equatable, Sendable { case present, absent, withheldPhi, keyUnknown, corrupt }
    let id: String
    let handle: String
    let chatId: String
    let name: String
    let mime: String
    let size: UInt64
    let chunks: UInt64
    let chunksHeld: UInt64
    let complete: Bool
    let availability: Availability
}

nonisolated struct MeshBranch: Identifiable, Equatable, Sendable {
    let headId: String
    let forkId: String?
    let messageCount: Int
    let updatedAt: Date
    var id: String { headId }
}

nonisolated struct MeshSurfaceNode: Equatable, Sendable {
    let id: String
    let type: String
    let props: [String: JSONValue]
    let children: [String]
    let provenance: String
}

nonisolated struct MeshSurface: Identifiable, Equatable, Sendable {
    let surfaceId: String
    let root: String
    let nodes: [String: MeshSurfaceNode]
    var id: String { surfaceId }
}

nonisolated enum MeshChatStatus: Equatable, Sendable {
    case idle
    case running(turnId: String)
    case outcomeUnknown(MeshUnknownOutcome)
}

nonisolated struct MeshUnknownOutcome: Identifiable, Equatable, Sendable {
    let stepId: String
    let tool: String
    let summary: String
    var id: String { stepId }
}

nonisolated struct MeshRenderedSurface: Identifiable, Equatable, Sendable {
    let surfaceId: String
    let tree: [JSONValue]
    let untrusted: Bool
    let rejected: [String]
    var id: String { surfaceId }
}

nonisolated struct MeshResolvedHandle: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case url, image }
    let kind: Kind
    let value: String
    let mime: String?
}

nonisolated struct MeshChatView: Equatable, Sendable {
    let chatId: String
    let title: String
    let messages: [MeshChatMessage]
    let branches: [MeshBranch]
    let surfaces: [MeshSurface]
    var rendered: [MeshRenderedSurface] = []
    let labels: [String]
    let status: MeshChatStatus
}

nonisolated enum MeshRequestState: String, Equatable, Sendable {
    case pending, claimed, answered, refused, cancelled
}

nonisolated struct MeshRequest: Identifiable, Equatable, Sendable {
    let requestId: String
    let chatId: String
    let fromMember: String?
    let toMember: String
    let state: MeshRequestState
    let text: String
    let refusalCode: String?
    let tool: String?
    let createdAt: Date
    var id: String { requestId }
}

nonisolated struct MeshPendingConsent: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case action, roster }
    let requestId: String
    let chatId: String?
    let kind: Kind
    let canonicalAction: Data
    let canonicalArguments: Data
    let signingInput: Data
    var id: String { requestId }
}

nonisolated struct MeshAllowance: Equatable, Sendable {
    enum Share: String, Equatable, Sendable { case fresh, solo }
    enum Refusal: String, Equatable, Sendable {
        case periodExhausted, effectClassExhausted, modelSpendExhausted, soloNeedsConsent, stale, stopped, notAMember
    }
    struct Line: Identifiable, Equatable, Sendable {
        let effectClass: String
        let remaining: Int64
        let limit: Int64
        var id: String { effectClass }
    }
    let share: Share
    let periodEndsAt: Date?
    let lines: [Line]
    let modelTokensRemaining: Int64?
    let modelTokensLimit: Int64?
    let blocked: Refusal?
}

nonisolated struct MeshModelProvider: Identifiable, Equatable, Sendable {
    let providerId: String
    let baseURL: String
    let model: String
    let hasKey: Bool
    let isDefault: Bool
    var recipients: [String]? = nil
    var availableOnDevice = false
    var id: String { providerId }
}

nonisolated struct MeshRun: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case goal, schedule, watch }
    enum Status: String, Equatable, Sendable { case active, paused, done, stopped }
    enum Role: String, Equatable, Sendable { case executor, watcher, contested, unassigned }
    let runId: String
    let chatId: String
    let kind: Kind
    let goal: String
    let status: Status
    let reason: String?
    let rounds: Int
    let tokensSpent: Int64
    let role: Role
    let executor: String?
    let unknownSteps: Int
    var id: String { runId }
}

nonisolated struct MeshTakeOver: Equatable, Sendable {
    let unknownSteps: Int
}

nonisolated struct MeshProposal: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case staged, gated, replayed, waitingOwner, rejected, declined, adopted, reversed
    }
    let proposalId: String
    let kind: String
    let name: String
    let content: String
    let status: Status
    let detail: [String]
    let tools: [String]
    let untrusted: Bool
    let gatePassed: Bool?
    let replayPassed: Bool?
    let ownerReasons: [String]
    let hygiene: [String]
    var id: String { proposalId }
}

nonisolated enum MeshEvaluation: Equatable, Sendable {
    case adopted
    case waitingOwner
    case declined(String)
}

nonisolated struct MeshModelProviderConfig: Equatable, Sendable {
    let baseURL: String
    let model: String
    let apiKey: String
    var recipients: [String]? = nil
}

nonisolated enum MeshTurnEvent: Equatable, Sendable {
    case started
    case assistantDelta(String)
    case assistantFinished
    case notice(String)
    case toolStarted(id: String, name: String, cancelSafe: Bool)
    case toolFinished(id: String, succeeded: Bool)
    case awaitingConsent(requestId: String)
    case outcomeUnknown(MeshUnknownOutcome)
    case incomplete
    case finished
    case interrupted
    case failed(String)
}

nonisolated struct MeshTurnProgress: Equatable, Sendable {
    let chatId: String
    let turnId: String
    let event: MeshTurnEvent
}

nonisolated enum MeshKernelChange: Equatable, Sendable {
    case chatChanged(chatId: String?)
    case syncStateChanged
    case consentRequested(requestId: String)
    case rosterChanged
    case turnProgress(MeshTurnProgress)
    case allowanceChanged
    case runProgress(runId: String)
    case joinRequested(MeshJoinRequest)
    case pairingFailed(code: String)
    case connectionsChanged
}

nonisolated struct MeshKernelConfig: Sendable {
    let dataDirectory: URL
    let deviceLabel: String
    let deviceKind: MeshDeviceKind
    let operationsSecret: Data
    let wrapSecret: Data
    let installMarker: Data
    let restoredInstall: Bool
    var mailbox: String?
    var deviceProfileJSON: String?
}

nonisolated enum MeshToolEffect: Equatable, Sendable {
    case meshRead, meshWrite, outwardRead, outsideEffect
}

nonisolated enum MeshToolConfidentiality: Equatable, Sendable {
    case `public`, `private`, phi, secret
}

nonisolated struct MeshLocalToolSpec: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    let schemaJSON: String
    var annotationsJSON = "{}"
    var effect = MeshToolEffect.meshRead
    var confidentiality = MeshToolConfidentiality.private
    var id: String { name }
}

nonisolated struct MeshPeerTool: Equatable, Sendable {
    let deviceId: String
    let spec: MeshLocalToolSpec
}

nonisolated struct MeshToolEntry: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    let effect: MeshToolEffect
    let deviceId: String?
    var grantName: String?
    var published = false
    var annotations = MeshToolAnnotations()
    var scope: String { effect.scope }
    var grantTarget: String { grantName ?? name }
    var grantKey: String { grantTarget + "/" + scope }
    var id: String { (deviceId ?? "this-device") + "/" + name }
}

nonisolated struct MeshToolAnnotations: Equatable, Sendable {
    var title: String?
    var note: String?
    var readOnly: Bool?

    init(title: String? = nil, note: String? = nil, readOnly: Bool? = nil) {
        self.title = title
        self.note = note
        self.readOnly = readOnly
    }

    init(json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
        title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        note = (object["effectNote"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        readOnly = object["readOnlyHint"] as? Bool
    }
}

nonisolated struct MeshGrant: Identifiable, Equatable, Sendable {
    let grantId: String
    let tool: String
    let scope: String
    let grantedBy: String?
    let consented: Bool
    let refusal: String?
    var key: String { tool + "/" + scope }
    var id: String { grantId }
}

extension MeshToolEffect {
    var scope: String {
        switch self {
        case .meshRead: return "mesh_read"
        case .meshWrite: return "mesh_write"
        case .outwardRead: return "outward_read"
        case .outsideEffect: return "outside_effect"
        }
    }
}

nonisolated enum MeshToolScope {
    static func description(_ scope: String) -> String {
        switch scope {
        case "mesh_read": return "read your mesh"
        case "mesh_write": return "change your mesh"
        case "outward_read": return "read from outside your mesh"
        case "outside_effect": return "act outside your mesh"
        case "*": return "every kind of action"
        default: return scope
        }
    }
}

nonisolated struct MeshConnectionTool: Hashable, Sendable {
    let name: String
    let hash: String
}

nonisolated struct MeshConnectionDeviceState: Equatable, Sendable {
    let device: String
    let label: String
    let state: String
    let reason: String?
    let issuer: String?
    let atMs: UInt64
}

nonisolated struct MeshConnection: Identifiable, Equatable, Sendable {
    let id: String
    let server: String
    let name: String
    let kind: String
    let endpoint: String
    let local: Bool
    let device: String?
    let scheme: String?
    let issuer: String?
    let scopes: [String]
    let clientId: String?
    let flow: String
    let egress: [String]
    let tools: [MeshConnectionTool]
    let approvedBy: String
    let approvedByRemovedDevice: Bool
    let unsupported: String?
    let supportedHere: Bool
    let thisDevice: MeshConnectionDeviceState
    let attention: String?
    let otherDevices: [MeshConnectionDeviceState]
    let pendingTools: [MeshConnectionTool]?
}

nonisolated struct MeshConnectionProposal: Equatable, Sendable {
    let proposal: String
    let connection: String
    let name: String
    let endpoint: String
    let local: Bool
    let device: String?
    let scheme: String
    let issuer: String?
    let issuerHost: String?
    let redirectHost: String?
    let scopes: [String]
    let resource: String?
    let clientId: String?
    let tools: [MeshConnectionTool]
    let egress: [String]
    let flowHint: String
    let replaces: String?
    let expiresMs: UInt64
}

nonisolated struct MeshConnectionState: Equatable, Sendable {
    let connection: String
    let state: String
    let reason: String?
    let toolsPending: Bool
}

nonisolated struct MeshSignInStart: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let flow: String
    let authorizationURL: String?
    let redirectURI: String
    let userCode: String?
    let verificationURI: String?
    let verificationURIComplete: String?
    let intervalSeconds: UInt64?
    let expiresMs: UInt64

    var description: String { "MeshSignInStart(flow: \(flow))" }
    var debugDescription: String { description }
}

nonisolated enum MeshSignInPoll: Equatable, Sendable {
    case pending(intervalSeconds: UInt64)
    case done(MeshConnectionState)
}

nonisolated enum MeshSignInRedirect: Equatable, Sendable {
    case appLink
    case loopback(port: UInt16)
    case loopbackV6(port: UInt16)
    case pasted
    case deviceCode
}

nonisolated enum MeshStepUpPlan: Equatable, Sendable {
    case review(scopes: [String])
    case signIn(scopes: [String])
}

nonisolated protocol MeshLocalTools: Sendable {
    func list() -> [MeshLocalToolSpec]
    func call(name: String, argumentsJSON: String, ticket: Data) throws -> String
}

nonisolated protocol MeshKernelListening: Sendable {
    func onChange(_ change: MeshKernelChange)
}

nonisolated struct MeshResumeTarget: Hashable, Sendable {
    let chatId: String
    let turnId: String
}

nonisolated struct MeshPendingMessage: Hashable, Sendable {
    let chatId: String
    let messageId: String
}

nonisolated protocol MeshKernel: Sendable {
    func startNetwork() async throws
    func stopNetwork() async
    func syncNow() async throws
    func version() -> String
    func close() async

    func meshStatus() async throws -> MeshStatus
    func meshPrincipal() throws -> MeshVerifiedPrincipal
    func setWakeRoute(expectedMeshId: String, expectedDeviceId: String, route: MeshWakeRoute?) async throws
    func wakeRoutes() async throws -> [MeshDeviceWakeRoute]
    func createMesh() throws -> MeshRecoveryKit
    func confirmMeshRecovery() throws
    func recoverWithWords(words: String, backupPath: String?) throws -> MeshRecovery
    func createInvitation() async throws -> MeshInvitation
    func acceptInvitation(payload: String) async throws -> MeshInvitationAccepted
    func approveInvitation() async throws
    func cancelInvitation() async
    func cancelPairingOffer()
    func renameDevice(memberId: String, label: String) throws
    func createPairingOffer() async throws -> MeshPairingOffer
    func previewPairing(payload: String) throws -> MeshPairingPreview
    func approvePairing(payload: String) async throws
    func roster() async throws -> [MeshMember]
    func removeDevice(memberId: String) throws
    func mintCallerTicket(
        nodeId: String, holderKey: String, label: String, toolNames: [String], a2a: Bool, lifetimeSeconds: UInt64
    ) throws -> MeshCallerTicket
    func callerTickets() throws -> [MeshCallerTicket]
    func revokeCallerTicket(id: String) throws
    func verifyCallerRequest(_ request: MeshCallerRequest) throws -> MeshVerifiedCaller
    func raiseStop() throws
    func resumeStop() throws
    func exportBackup(path: String) throws

    func listChats() throws -> [MeshChatSummary]
    func chat(chatId: String) throws -> MeshChatView
    func chatForDevice(chatId: String, deviceProfileJson: String) throws -> MeshChatView
    func createChat(title: String) throws -> String
    func sendMessage(chatId: String, text: String, continues: String?) throws -> String
    func addAttachment(chatId: String, bytes: Data, mime: String, name: String) throws -> MeshAttachment
    func fetchAttachment(handle: String) async throws -> Data
    func sendMessage(chatId: String, text: String, continues: String?, attachments: [String]) throws -> String
    func fork(chatId: String, eventId: String) throws -> String
    func act(surfaceId: String, componentId: String, capability: String, args: [String: JSONValue]) async throws
        -> MeshActResult

    func pendingOrdinaryMessages() async throws -> [MeshPendingMessage]
    func resumePendingMessage(chatId: String, messageId: String) async throws
    func cancelPendingMessage(chatId: String, messageId: String) async throws
    func ordinaryResumeTargets() async throws -> [MeshResumeTarget]
    func resumeTurn(chatId: String, turnId: String) async throws
    func steerTurn(chatId: String, turnId: String, text: String) throws -> Bool
    func steerMessage(chatId: String, messageId: String, text: String) throws -> Bool
    func steerRequest(requestId: String, text: String) throws -> Bool
    func runMessage(chatId: String, messageId: String) async throws
    func interruptTurn(chatId: String, turnId: String) throws -> Bool
    func interruptMessage(chatId: String, messageId: String) throws -> Bool
    func interruptRequest(requestId: String) throws -> Bool
    func runTurn(chatId: String) async throws
    func steer(chatId: String, text: String) throws
    func interrupt(chatId: String) throws
    func pendingConsents() throws -> [MeshPendingConsent]
    func resolveConsent(requestId: String, approve: Bool) throws

    func tools() -> [MeshToolEntry]
    func publishToolCatalog() throws
    func grants() throws -> [MeshGrant]
    func resolveHandle(chatId: String, handle: String) throws -> MeshResolvedHandle
    func answerRequest(requestId: String) async throws
    func grantTool(name: String, scope: String) throws
    func revokeTool(name: String, scope: String) throws

    func chatRequests(chatId: String) throws -> [MeshRequest]
    func pendingRequestsForMe() throws -> [MeshRequest]
    func sendRequest(chatId: String, text: String, toMember: String) throws -> String
    func claimRequest(requestId: String) throws
    func refuseRequest(requestId: String, code: String) throws

    func recordSpoken(chatId: String, kind: VoiceSpokenKind, text: String) throws

    func setModelProvider(_ config: MeshModelProviderConfig) throws
    func setModelProviderRecipients(name: String, recipients: [String]?) throws -> MeshModelProvider
    func modelProviders() throws -> [MeshModelProvider]
    func setRemoteMCPServer(_ config: MeshRemoteMCPConfig) throws
    func remoteMCPServers() throws -> [MeshRemoteMCPServer]
    func removeRemoteMCPServer(_ name: String) throws
    func refreshRemoteMCPTools(_ server: String) async throws -> [MeshRemoteMCPTool]
    func approveRemoteMCPTool(_ tool: MeshRemoteMCPTool) async throws
    func revokeRemoteMCPTool(server: String, tool: String) throws

    func mailboxState() throws -> MeshMailboxState
    func syncState() async throws -> MeshSyncState
    func allowance() throws -> MeshAllowance

    func proposeConnection(endpoint: String, name: String, local: Bool) async throws -> MeshConnectionProposal
    func reviewConnection(id: String) async throws -> MeshConnectionProposal
    func approveConnection(proposal: String, flow: String, toolNames: [String], clientId: String?) throws
        -> MeshConnection
    func removeConnection(id: String) throws
    func connections() throws -> [MeshConnection]
    func beginConnectionSignIn(id: String, redirect: MeshSignInRedirect) async throws -> MeshSignInStart
    func completeConnectionSignIn(flow: String, redirectURL: String) async throws -> MeshConnectionState
    func pollConnectionSignIn(flow: String) async throws -> MeshSignInPoll
    func cancelConnectionSignIn(flow: String) throws
    func refreshConnection(id: String) async throws -> MeshConnectionState
    func connectionStepUp(id: String, challenge: [String]) throws -> MeshStepUpPlan
    func noteConnectionCallSucceeded(id: String) throws

    func runs() async throws -> [MeshRun]
    func handOffRun(runId: String, memberId: String) async throws
    func takeOverRun(runId: String) async throws -> MeshTakeOver
    func learningProposals() async throws -> [MeshProposal]
    func reviewProposal(id: String, adopt: Bool) async throws -> MeshEvaluation
    func undoAdoption(id: String) async throws
}

typealias MeshKernelFactory =
    @Sendable (
        _ config: MeshKernelConfig, _ signer: any AstralHostSigning, _ model: any AstralOnDeviceModel,
        _ tools: any MeshLocalTools, _ listener: any MeshKernelListening
    ) async throws -> any MeshKernel
