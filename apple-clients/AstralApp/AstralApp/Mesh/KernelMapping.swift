// Maps the generated kernel records, enums, change events and error codes onto the host's Mesh types.
// RealMeshKernel is the only caller, so the generated names appear here with their module prefix wherever the host declares a type of the same name.

import AstralKernel
import Foundation

nonisolated enum KernelMapping {
    static func date(_ stamp: ClockStamp) -> Date { Date(timeIntervalSince1970: Double(stamp.ms) / 1000) }

    static func date(ms: UInt64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func status(_ value: AstralKernel.MeshStatus) -> MeshStatus {
        let enrolled = value.state == .enrolled
        return MeshStatus(
            hasMesh: enrolled, meshId: value.meshId, deviceId: value.deviceId.isEmpty ? nil : value.deviceId,
            attested: !value.unattested, stopped: false, hardwareBacked: value.hardwareBacked, stopLevel: value.stop)
    }

    static func deviceKind(_ text: String) -> MeshDeviceKind { MeshDeviceKind(rawValue: text) ?? .node }

    static func path(_ text: String) -> MeshPath { MeshPath(rawValue: text) ?? .none }

    static func members(_ roster: RosterInfo, peers: [SyncPeer]) -> [MeshMember] {
        roster.members.map { member in
            let peer = peers.first { $0.deviceId == member.deviceId }
            return MeshMember(
                memberId: member.deviceId, label: member.label, kind: deviceKind(member.kind),
                isThisDevice: member.isLocal, attested: !member.unattested,
                lastSeen: peer?.lastSeenMs.map { date(ms: $0) }, path: peer.map { path($0.path) } ?? .none)
        }
    }

    static func sync(_ peers: [SyncPeer], now: Date) -> MeshSyncState {
        MeshSyncState(
            devices: peers.map { peer in
                let state: MeshDeviceSync.State
                switch (peer.status, peer.connected) {
                case ("synced", true): state = .synced
                case (_, false): state = .unreachable
                default: state = .behind
                }
                return MeshDeviceSync(
                    memberId: peer.deviceId, label: peer.label, state: state,
                    lastSeen: peer.lastSeenMs.map { date(ms: $0) }, path: path(peer.path))
            }, updatedAt: now)
    }

    static func pairingOffer(_ offer: PairingOffer) -> MeshPairingOffer {
        MeshPairingOffer(shortCode: offer.code, payload: offer.payload)
    }

    static func pairingPreview(_ preview: PairingPreview) -> MeshPairingPreview {
        MeshPairingPreview(
            comparisonCode: preview.code, deviceLabel: preview.label, deviceKind: deviceKind(preview.kind),
            fingerprint: preview.deviceId)
    }

    static func allowance(_ view: AllowanceView) -> MeshAllowance {
        let model = view.dimensions.first { $0.name == "model_tokens" }
        let lines = view.dimensions.filter { $0.name != "model_tokens" }.map {
            MeshAllowance.Line(effectClass: lineName($0.name), remaining: $0.remaining, limit: $0.cap)
        }
        let periodEnd =
            view.periodIndex >= 0 ? Date(timeIntervalSince1970: Double(view.periodIndex + 1) * 86_400) : nil
        return MeshAllowance(
            share: view.mode == "fresh" ? .fresh : .solo, periodEndsAt: periodEnd, lines: lines,
            modelTokensRemaining: model?.remaining, modelTokensLimit: model?.cap,
            blocked: refusal(view.refusals, dimensions: view.dimensions))
    }

    private static func lineName(_ name: String) -> String {
        switch name {
        case "notes_write": return "Notes and memory"
        case "outside_effect": return "Outside actions"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func refusal(_ codes: [String], dimensions: [AllowanceDimension]) -> MeshAllowance.Refusal? {
        guard let code = codes.first else { return nil }
        switch code {
        case "allowance.solo_cap_reached": return .soloNeedsConsent
        case "allowance.lapsed": return .stale
        case "allowance.not_a_member": return .notAMember
        case "allowance.share_spent":
            let spent = dimensions.filter { $0.remaining == 0 }.map(\.name)
            if spent.count == dimensions.count { return .periodExhausted }
            return spent == ["model_tokens"] ? .modelSpendExhausted : .effectClassExhausted
        default: return nil
        }
    }

    static func provider(_ info: ModelProviderInfo, lowestOrder: UInt32) -> MeshModelProvider {
        MeshModelProvider(
            providerId: info.name, baseURL: info.baseUrl, model: info.models.first ?? "", hasKey: true,
            isDefault: info.fallbackOrder == lowestOrder)
    }

    static func providerConfig(_ config: MeshModelProviderConfig) throws -> ModelProviderConfig {
        guard let url = URL(string: config.baseURL), let host = url.host, !host.isEmpty else {
            throw MeshKernelError.refused("provider.invalid_url")
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        let name = String(
            host.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "-" || $0 == "_" ? $0 : "-" }
                .prefix(64))
        return ModelProviderConfig(
            name: name, baseUrl: config.baseURL, models: [config.model], apiKeys: [config.apiKey],
            fallbackOrder: 0, selfHosted: loopback, strictTools: false)
    }

    static func run(_ info: RunInfo) -> MeshRun {
        MeshRun(
            runId: info.runId, chatId: info.chatId, kind: runKind(info.kind),
            goal: info.goal, status: MeshRun.Status(rawValue: info.status) ?? .paused, reason: info.reason,
            rounds: Int(info.rounds), tokensSpent: Int64(clamping: info.tokensSpent),
            role: MeshRun.Role(rawValue: info.role) ?? .unassigned, executor: info.executor,
            unknownSteps: info.unknownSteps.count)
    }

    private static func runKind(_ kind: RunKindInfo) -> MeshRun.Kind {
        switch kind {
        case .goal: return .goal
        case .schedule: return .schedule
        case .watch: return .watch
        }
    }

    static func proposal(_ info: ProposalInfo) -> MeshProposal {
        let status: MeshProposal.Status
        switch info.status {
        case "staged": status = .staged
        case "gated": status = .gated
        case "replayed": status = .replayed
        case "waiting_owner": status = .waitingOwner
        case "rejected": status = .rejected
        case "declined": status = .declined
        case "adopted": status = .adopted
        case "reversed": status = .reversed
        default: status = .rejected
        }
        return MeshProposal(
            proposalId: info.id, kind: info.kind, name: info.name, content: info.content, status: status,
            detail: info.statusDetail, tools: info.tools, untrusted: info.integrity != "owner",
            gatePassed: info.gatePassed, replayPassed: info.replayPassed, ownerReasons: info.ownerReasons,
            hygiene: info.hygiene)
    }

    static func evaluation(_ value: EvaluationInfo) -> MeshEvaluation {
        switch value {
        case .adopted: return .adopted
        case .waitingOwner: return .waitingOwner
        case .declined(let reason): return .declined(reason)
        }
    }

    static func request(_ view: RequestView) -> MeshRequest {
        let state: MeshRequestState
        switch view.state {
        case .pending: state = .pending
        case .claimed: state = .claimed
        case .answered: state = .answered
        case .refused: state = .refused
        case .cancelled: state = .cancelled
        }
        return MeshRequest(
            requestId: view.id, chatId: view.chatId, fromMember: view.fromDevice, toMember: view.toDevice,
            state: state, text: view.text, refusalCode: view.code, tool: view.call?.tool, createdAt: date(view.clock))
    }

    static func unknownOutcome(_ info: UnknownOutcomeInfo) -> MeshUnknownOutcome {
        unknownOutcome(callId: info.callId, tool: info.toolName)
    }

    static func unknownOutcome(callId: String, tool: String) -> MeshUnknownOutcome {
        MeshUnknownOutcome(stepId: callId, tool: tool, summary: "The result of \(tool) is not known.")
    }

    static func isEnrollmentComplete(_ change: KernelChange) -> Bool {
        switch change {
        case .enrollment(let state): return state == .enrolled
        case .pairing(let progress):
            if case .joined = progress { return true }
            return false
        default: return false
        }
    }

    static func changes(_ change: KernelChange) -> [MeshKernelChange] {
        switch change {
        case .chatChanged(let chatId): return [.chatChanged(chatId: chatId)]
        case .rosterChanged: return [.rosterChanged]
        case .syncStateChanged, .endpoint: return [.syncStateChanged]
        case .enrollment: return [.rosterChanged]
        case .pairing(let progress):
            switch progress {
            case .approved, .joined: return [.rosterChanged]
            case .offerSeen, .failed: return []
            }
        case .allowanceChanged: return [.allowanceChanged]
        case .turn(let progress): return turn(progress)
        }
    }

    static func turn(_ progress: TurnProgress) -> [MeshKernelChange] {
        func event(_ chat: String, _ turn: String, _ value: MeshTurnEvent) -> MeshKernelChange {
            .turnProgress(MeshTurnProgress(chatId: chat, turnId: turn, event: value))
        }
        switch progress {
        case .started(let chat, let turn): return [event(chat, turn, .started)]
        case .textDelta(let chat, let turn, let text): return [event(chat, turn, .assistantDelta(text))]
        case .notice: return []
        case .toolProposed(let chat, let turn, let call, let tool, _):
            return [event(chat, turn, .toolStarted(id: call, name: tool, cancelSafe: false))]
        case .toolResult(let chat, let turn, let call, let status, _):
            return [event(chat, turn, .toolFinished(id: call, succeeded: status == "ok"))]
        case .consentRequested(let consent):
            return [
                event(consent.chatId, consent.turnId, .awaitingConsent(requestId: consent.requestId)),
                .consentRequested(requestId: consent.requestId),
            ]
        case .consentResolved(let request, _): return [.consentRequested(requestId: request)]
        case .consentSigningFailed(let request, _, _, _): return [.consentRequested(requestId: request)]
        case .outcomeUnknown(let chat, let turn, let call, let tool):
            return [event(chat, turn, .outcomeUnknown(unknownOutcome(callId: call, tool: tool)))]
        case .ended(let chat, let turn, let reason, let code):
            switch reason {
            case "completed", "incomplete":
                return [event(chat, turn, .assistantFinished), event(chat, turn, .finished)]
            case "interrupted": return [event(chat, turn, .interrupted)]
            case "repeat_stop": return [event(chat, turn, .failed("The assistant repeated itself, so it was stopped."))]
            case "max_rounds": return [event(chat, turn, .failed("The assistant reached its step limit."))]
            case "fork": return []
            default:
                return [
                    event(
                        chat, turn,
                        .failed(failureText(code: code ?? reason, fallback: "The assistant could not finish this turn.")))
                ]
            }
        }
    }

    static func failureText(code: String, fallback: String = "The mesh refused that request.") -> String {
        for (prefix, text) in codeTexts where code.hasPrefix(prefix) { return text }
        return fallback + " (" + code + ")"
    }

    private static let codeTexts: [(String, String)] = [
        ("turn.no_provider", "Add a model provider in Settings before asking for an answer."),
        ("provider.", "The model provider could not be reached or refused the request."),
        ("allowance.", "This device has used its allowance for now."),
        ("gate.mesh_stopped", "The mesh was stopped, so this turn was refused."),
        ("gate.", "A safety check refused this step."),
        ("consent.declined", MeshKernelError.consentDenied.message),
        ("signer.denied", MeshKernelError.consentDenied.message),
        ("config.no_issuer", "The sign-in service could not be reached when the app started. Open the app again with a connection."),
        ("mesh.already_enrolled", "This device already belongs to a mesh."),
        ("mesh.not_enrolled", "This device has no mesh yet."),
        ("attestation.", "The sign-in could not be verified for this mesh."),
        ("pairing.expired", "The pairing code expired. Start again on the new device."),
        ("pairing.", "The pairing code was refused. Start again on the new device."),
        ("recovery.bad_length", "Enter all 24 recovery words."),
        ("recovery.unknown_word", "One of the words is not on the recovery word list. Check the spelling."),
        ("recovery.bad_checksum", "These words are not a valid recovery key. Check the order and the spelling."),
        ("recovery.mismatch", "These words do not unlock that backup."),
        ("recovery.wrong_mesh", "That backup belongs to a different mesh than this install holds."),
        ("recovery.no_roster", "Choose a backup file. This device holds no copy of your mesh."),
        ("recovery.no_keys", "The words are valid, but no key of this mesh could be opened with them."),
        ("backup.decrypt_failed", "That backup could not be opened with these words."),
        ("backup.malformed", "That file is not a mesh backup."),
        ("request.empty", "Write the request first."),
        ("request.too_large", "That request is too long."),
        ("request.unknown_member", "That device is not in your mesh."),
        ("request.self_addressed", "Choose another device. This one cannot ask itself."),
        ("request.not_target", "That request is addressed to another device."),
        ("request.already_claimed", "That request is already claimed."),
        ("request.unknown", "That request is no longer in this chat."),
        ("request.", "That request can no longer change."),
        ("custody.restore_needs_new_keys", "This install was restored from a backup. Join your mesh again to use it."),
        ("custody.", "This device's keys do not match its stored mesh."),
        ("chat.empty_message", "Write a message first."),
        ("chat.unknown_turn", "That message is not part of this chat yet."),
        ("chat.", "That chat action was refused."),
        ("net.", "The network is not available."),
        ("store.", "This device could not read or write its mesh data."),
    ]

    static func error(_ error: Error) -> Error {
        switch error {
        case let known as MeshKernelError: return known
        case let kernel as KernelError:
            switch kernel {
            case .Denied: return MeshKernelError.consentDenied
            case .InvalidInput(let code, _), .Verification(let code, _), .Network(let code, _), .Custody(let code, _),
                .State(let code, _), .Mesh(let code, _):
                return MeshKernelError.refused(failureText(code: code))
            case .Store(let code, _): return MeshKernelError.storage(failureText(code: code))
            }
        case let turns as TurnsError:
            if case .Failed(let code, _) = turns {
                return code.hasPrefix("consent.declined") ? MeshKernelError.consentDenied
                    : MeshKernelError.refused(failureText(code: code))
            }
            return turns
        case let runs as RunsFfiError:
            if case .Failed(let code, _) = runs {
                return code.hasPrefix("signer.denied") || code.hasPrefix("consent.declined")
                    ? MeshKernelError.consentDenied
                    : MeshKernelError.refused(failureText(code: code))
            }
            return runs
        default: return error
        }
    }
}
