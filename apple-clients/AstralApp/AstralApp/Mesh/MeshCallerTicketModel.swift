// The state behind minting, listing and revoking caller tickets: holder line checking, lifetimes, tool choice and plain refusal text.
// MeshCallerTicketEditor and MeshCallersView bind these models and MeshRuntime carries every kernel call, so the Kernel stays the authority.

import Foundation
import Observation

nonisolated enum MeshCallerHolderInput {
    static let keyPrefix = "astral-caller-key:v1:"
    static let privateKeyMessage =
        "That is the private key. Paste the holder line instead, the one that starts with astral-caller-holder."
    static let invalidMessage = "Paste the holder line that starts with astral-caller-holder:v1:."

    enum Verdict: Equatable {
        case empty
        case privateKey
        case invalid
        case holder(String)
    }

    private static func isBareSeed(_ token: Substring) -> Bool {
        token.count == 43 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func judge(_ raw: String) -> Verdict {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        if text.lowercased().contains("astral-caller-key")
            || text.split(whereSeparator: \.isWhitespace).contains(where: isBareSeed)
        {
            return .privateKey
        }
        guard text.hasPrefix(MeshCallerTicketLimits.holderPrefix) else { return .invalid }
        let body = text.dropFirst(MeshCallerTicketLimits.holderPrefix.count)
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        guard body.count == 43, body.allSatisfy(allowed)
        else { return .invalid }
        return .holder(text)
    }
}

nonisolated enum MeshCallerLifetime: CaseIterable, Identifiable, Equatable, Sendable {
    case hour, day, week, month

    var id: Self { self }

    var seconds: UInt64 {
        switch self {
        case .hour: return 3600
        case .day: return 86400
        case .week: return 604_800
        case .month: return MeshCallerTicketLimits.maxLifetimeSeconds
        }
    }

    var title: String {
        switch self {
        case .hour: return "1 hour"
        case .day: return "1 day"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }
}

nonisolated enum MeshCallerText {
    static let generic = "The caller ticket couldn't be changed. Try again."
    static let labelRefused = "The label can't hold control or invisible characters."
    static let labelTooLong = "Use 64 characters or fewer for the label."
    static let tooManyTools = "Choose at most 32 tools."

    static func failure(_ error: MeshKernelError) -> String {
        if let code = error.code { return KernelMapping.plainText(code: code) ?? generic }
        return error.message
    }
}

@MainActor
@Observable
final class MeshCallerTicketModel {
    enum Phase: Equatable {
        case editing
        case minting
        case minted(MeshCallerTicket)
        case failed(String)
    }

    private let runtime: MeshRuntime
    private(set) var nodeId: String?
    private(set) var holderLine = ""
    private(set) var holderNotice: String?
    private(set) var chosenTools: Set<String> = []
    private(set) var phase = Phase.editing
    private(set) var holderResetCount = 0
    var label = ""
    var a2a = false
    var lifetime = MeshCallerLifetime.week

    init(runtime: MeshRuntime) {
        self.runtime = runtime
        nodeId = nodes.first?.memberId
    }

    var nodes: [MeshMember] { runtime.members.filter { $0.kind == .node } }

    var catalog: [String] {
        guard let nodeId else { return [] }
        return Array(Set(runtime.toolEntries.filter { $0.deviceId == nodeId && $0.published }.map(\.name))).sorted()
    }

    var labelLength: Int { label.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count }

    var labelProblem: String? {
        let scalars = label.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        if scalars.count > MeshCallerTicketLimits.maxLabelLength { return MeshCallerText.labelTooLong }
        return scalars.contains(where: MeshCallerLabelClasses.refuses) ? MeshCallerText.labelRefused : nil
    }

    var toolProblem: String? { toolCount > MeshCallerTicketLimits.maxTools ? MeshCallerText.tooManyTools : nil }

    var toolCount: Int { chosenTools.count + (a2a ? 1 : 0) }

    var holderVerdict: MeshCallerHolderInput.Verdict { MeshCallerHolderInput.judge(holderLine) }

    var canMint: Bool {
        guard nodeId != nil, phase != .minting else { return false }
        guard case .holder = holderVerdict else { return false }
        return labelLength >= 1 && labelProblem == nil && (1...MeshCallerTicketLimits.maxTools).contains(toolCount)
    }

    func updateHolder(_ text: String) {
        holderNotice = nil
        if MeshCallerHolderInput.judge(text) == .privateKey {
            holderLine = ""
            holderResetCount += 1
            holderNotice = MeshCallerHolderInput.privateKeyMessage
            return
        }
        holderLine = text
        if case .invalid = holderVerdict { holderNotice = MeshCallerHolderInput.invalidMessage }
    }

    func refreshChoices() async {
        await runtime.refreshRoster()
        await runtime.refreshTools()
        if nodeId == nil || !nodes.contains(where: { $0.memberId == nodeId }) { nodeId = nodes.first?.memberId }
    }

    func selectNode(_ id: String) {
        guard nodes.contains(where: { $0.memberId == id }), id != nodeId else { return }
        nodeId = id
        chosenTools = []
    }

    func setTool(_ name: String, chosen: Bool) {
        guard catalog.contains(name) else { return }
        if chosen { chosenTools.insert(name) } else { chosenTools.remove(name) }
    }

    func mint() async {
        guard canMint, let nodeId, case .holder(let holder) = holderVerdict else { return }
        phase = .minting
        let result = await runtime.mintCallerTicket(
            nodeId: nodeId, holderKey: holder, label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            toolNames: chosenTools.sorted(), a2a: a2a, lifetimeSeconds: lifetime.seconds)
        switch result {
        case .success(let ticket): phase = .minted(ticket)
        case .failure(let error): phase = .failed(MeshCallerText.failure(error))
        }
    }

    func editAgain() { phase = .editing }
}

@MainActor
@Observable
final class MeshCallersModel {
    private let runtime: MeshRuntime
    private(set) var pendingRevoke: MeshCallerTicket?
    private(set) var failure: String?

    init(runtime: MeshRuntime) { self.runtime = runtime }

    var tickets: [MeshCallerTicket] { runtime.callerTickets.sorted { $0.issuedAt > $1.issuedAt } }

    func askRevoke(_ ticket: MeshCallerTicket) {
        guard !ticket.revoked else { return }
        pendingRevoke = ticket
    }

    func cancelRevoke() { pendingRevoke = nil }

    func confirmRevoke(_ ticket: MeshCallerTicket) async {
        pendingRevoke = nil
        guard !ticket.revoked else { return }
        if let error = await runtime.revokeCallerTicket(id: ticket.id) {
            failure = MeshCallerText.failure(error)
        } else {
            failure = nil
        }
    }

    func dismissFailure() { failure = nil }

    func nodeLabel(_ ticket: MeshCallerTicket) -> String { runtime.memberLabel(ticket.nodeId) }
}
