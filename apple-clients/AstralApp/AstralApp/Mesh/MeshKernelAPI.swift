// Swift mirror of the kernel's host interface: the Kernel object, its records, the host callbacks and the change events.
// MeshRuntime talks only to MeshKernel, so an adapter over the generated bindings or an in-memory kernel can stand behind it.

import AstralCore
import Foundation

nonisolated enum MeshKernelError: Error, Equatable, Sendable {
    case unavailable(String)
    case refused(String)
    case notFound
    case consentDenied
    case stopped
    case storage(String)

    var message: String {
        switch self {
        case .unavailable(let reason): return reason
        case .refused(let reason): return reason
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
    var attested: Bool
    var stopped: Bool
    var hardwareBacked: Bool
    var stopLevel: UInt64 = 0

    static let empty = MeshStatus(
        hasMesh: false, meshId: nil, deviceId: nil, attested: false, stopped: false, hardwareBacked: false)
}

nonisolated struct MeshAttestationRequest: Equatable, Sendable {
    let nonce: String
}

nonisolated struct MeshRecoveryKit: Equatable, Sendable {
    let words: [String]
}

nonisolated struct MeshRecovery: Equatable, Sendable {
    let meshId: String
    let deviceId: String
    let eventsImported: Int
}

nonisolated struct MeshPairingOffer: Equatable, Sendable {
    let shortCode: String
    let payload: String
}

nonisolated struct MeshPairingPreview: Equatable, Sendable {
    let comparisonCode: String
    let deviceLabel: String
    let deviceKind: MeshDeviceKind
    let fingerprint: String
}

nonisolated struct MeshMember: Identifiable, Equatable, Sendable {
    let memberId: String
    let label: String
    let kind: MeshDeviceKind
    let isThisDevice: Bool
    let attested: Bool
    let lastSeen: Date?
    let path: MeshPath
    var id: String { memberId }
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
    let queuedCount: Int
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
    var id: String { eventId }
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

nonisolated struct MeshChatView: Equatable, Sendable {
    let chatId: String
    let title: String
    let messages: [MeshChatMessage]
    let branches: [MeshBranch]
    let surfaces: [MeshSurface]
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
}

nonisolated enum MeshTurnEvent: Equatable, Sendable {
    case started
    case assistantDelta(String)
    case assistantFinished
    case toolStarted(id: String, name: String, cancelSafe: Bool)
    case toolFinished(id: String, succeeded: Bool)
    case awaitingConsent(requestId: String)
    case outcomeUnknown(MeshUnknownOutcome)
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
}

nonisolated struct MeshKernelConfig: Sendable {
    let dataDirectory: URL
    let deviceLabel: String
    let deviceKind: MeshDeviceKind
    let operationsSecret: Data
    let wrapSecret: Data
    let installMarker: Data
    let restoredInstall: Bool
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
    var scope: String { effect.scope }
    var grantKey: String { name + "/" + scope }
    var id: String { (deviceId ?? "this-device") + "/" + name }
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

nonisolated protocol MeshLocalTools: Sendable {
    func list() -> [MeshLocalToolSpec]
    func call(name: String, argumentsJSON: String, ticket: Data) throws -> String
}

nonisolated protocol MeshKernelListening: Sendable {
    func onChange(_ change: MeshKernelChange)
}

nonisolated protocol MeshKernel: Sendable {
    func startNetwork() async throws
    func stopNetwork() async
    func version() -> String

    func meshStatus() async throws -> MeshStatus
    func beginMeshCreation() throws -> MeshAttestationRequest
    func completeMeshCreation(idToken: String) throws -> MeshRecoveryKit
    func recoverWithWords(words: String, backupPath: String?) throws -> MeshRecovery
    func createPairingOffer() async throws -> MeshPairingOffer
    func previewPairing(payload: String) throws -> MeshPairingPreview
    func approvePairing(payload: String) async throws
    func roster() async throws -> [MeshMember]
    func removeDevice(memberId: String) throws
    func raiseStop() throws
    func reattest(idToken: String) throws
    func exportBackup(path: String) throws

    func listChats() throws -> [MeshChatSummary]
    func chat(chatId: String) throws -> MeshChatView
    func createChat(title: String) throws -> String
    func sendMessage(chatId: String, text: String, continues: String?) throws -> String
    func fork(chatId: String, eventId: String) throws -> String
    func act(surfaceId: String, componentId: String, action: String) throws

    func runTurn(chatId: String) async throws
    func steer(chatId: String, text: String) throws
    func interrupt(chatId: String) throws
    func pendingConsents() throws -> [MeshPendingConsent]
    func resolveConsent(requestId: String, approve: Bool) throws

    func tools() -> [MeshToolEntry]
    func grantTool(name: String, scope: String) throws
    func revokeTool(name: String, scope: String) throws

    func chatRequests(chatId: String) throws -> [MeshRequest]
    func pendingRequestsForMe() throws -> [MeshRequest]
    func sendRequest(chatId: String, text: String, toMember: String) throws -> String
    func claimRequest(requestId: String) throws
    func refuseRequest(requestId: String, code: String) throws

    func recordSpoken(chatId: String, kind: VoiceSpokenKind, text: String) throws

    func setModelProvider(_ config: MeshModelProviderConfig) throws
    func modelProviders() throws -> [MeshModelProvider]

    func syncState() async throws -> MeshSyncState
    func allowance() throws -> MeshAllowance

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
