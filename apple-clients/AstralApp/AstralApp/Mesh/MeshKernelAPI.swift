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

    static let empty = MeshStatus(
        hasMesh: false, meshId: nil, deviceId: nil, attested: false, stopped: false, hardwareBacked: false)
}

nonisolated struct MeshAttestationRequest: Equatable, Sendable {
    let nonce: String
}

nonisolated struct MeshRecoveryKit: Equatable, Sendable {
    let words: [String]
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
    case chatChanged(chatId: String)
    case syncStateChanged
    case consentRequested(requestId: String)
    case rosterChanged
    case turnProgress(MeshTurnProgress)
    case allowanceChanged
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

nonisolated struct MeshLocalToolSpec: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    let schemaJSON: String
    var id: String { name }
}

nonisolated protocol MeshLocalTools: Sendable {
    func list() -> [MeshLocalToolSpec]
    func call(name: String, argumentsJSON: String, ticket: Data) throws -> String
}

nonisolated protocol MeshKernelListening: Sendable {
    func onChange(_ change: MeshKernelChange)
}

nonisolated protocol MeshKernel: Sendable {
    func startNetwork() throws
    func stopNetwork()
    func version() -> String

    func meshStatus() throws -> MeshStatus
    func beginMeshCreation() throws -> MeshAttestationRequest
    func completeMeshCreation(idToken: String) throws -> MeshRecoveryKit
    func createPairingOffer() throws -> MeshPairingOffer
    func previewPairing(payload: String) throws -> MeshPairingPreview
    func approvePairing(payload: String) throws
    func roster() throws -> [MeshMember]
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

    func runTurn(chatId: String) throws
    func steer(chatId: String, text: String) throws
    func interrupt(chatId: String) throws
    func pendingConsents() throws -> [MeshPendingConsent]
    func resolveConsent(requestId: String, approve: Bool) throws

    func recordSpoken(chatId: String, kind: VoiceSpokenKind, text: String) throws

    func setModelProvider(_ config: MeshModelProviderConfig) throws
    func modelProviders() throws -> [MeshModelProvider]

    func syncState() throws -> MeshSyncState
    func allowance() throws -> MeshAllowance
}

typealias MeshKernelFactory =
    @Sendable (
        _ config: MeshKernelConfig, _ signer: any AstralHostSigning, _ model: any AstralOnDeviceModel,
        _ tools: any MeshLocalTools, _ listener: any MeshKernelListening
    ) throws -> any MeshKernel
