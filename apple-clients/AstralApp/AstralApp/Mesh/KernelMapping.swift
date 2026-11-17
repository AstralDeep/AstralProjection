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
            recoveryPending: value.recoveryPending, stopped: value.stopped, hardwareBacked: value.hardwareBacked,
            stopLevel: value.stop)
    }

    static func deviceKind(_ text: String) -> MeshDeviceKind { MeshDeviceKind(rawValue: text) ?? .node }

    static func path(_ text: String) -> MeshPath { MeshPath(rawValue: text) ?? .none }

    static func attachment(_ value: AttachmentInfo) -> MeshAttachment {
        let availability: MeshAttachment.Availability
        switch value.bodyState {
        case .present: availability = .present
        case .absent: availability = .absent
        case .withheldPhi: availability = .withheldPhi
        case .keyUnknown: availability = .keyUnknown
        case .corrupt: availability = .corrupt
        }
        return MeshAttachment(
            id: value.id, handle: value.handle, chatId: value.chatId, name: value.name, mime: value.mime,
            size: value.size, chunks: value.chunks, chunksHeld: value.chunksHeld, complete: value.complete,
            availability: availability)
    }

    static func members(_ roster: RosterInfo, peers: [SyncPeer]) -> [MeshMember] {
        roster.members.map { member in
            let peer = peers.first { $0.deviceId == member.deviceId }
            return MeshMember(
                memberId: member.deviceId, label: member.label, kind: deviceKind(member.kind),
                isThisDevice: member.isLocal,
                lastSeen: peer?.lastSeenMs.map { date(ms: $0) }, path: peer.map { path($0.path) } ?? .none,
                addedAt: member.addedAtS > 0 ? Date(timeIntervalSince1970: Double(member.addedAtS)) : nil)
        }
    }

    static func callerTicket(_ value: AstralKernel.CallerTicket) -> MeshCallerTicket {
        MeshCallerTicket(
            id: value.id, text: value.text, label: value.label, nodeId: value.node, tools: value.tools,
            issuedAt: date(ms: value.issuedMs), expiresAt: date(ms: value.expiresMs), revoked: value.revoked,
            expired: value.expired)
    }

    static func callerRequest(_ value: MeshCallerRequest) -> AstralKernel.CallerRequest {
        AstralKernel.CallerRequest(
            authorization: value.authorization, proof: value.proof, method: value.method, target: value.target,
            bodySha256: value.bodySha256, tool: value.tool)
    }

    static func verifiedCaller(_ value: AstralKernel.VerifiedCaller) -> MeshVerifiedCaller {
        MeshVerifiedCaller(
            id: value.id, meshId: value.mesh, deviceId: value.device, label: value.label, tool: value.tool,
            tools: value.tools, expiresAt: date(ms: value.expiresMs))
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

    static func mailbox(_ state: MailboxState) -> MeshMailboxState {
        MeshMailboxState(
            configured: state.configured, status: MeshMailboxState.Status(rawValue: state.status) ?? .unknown,
            lastError: state.lastError, lastOk: state.lastOkMs.map { date(ms: $0) },
            pendingNotices: Int(clamping: state.pendingNotices), truncated: state.truncated)
    }

    static func pairingOffer(_ offer: PairingOffer, now _: Date = Date()) -> MeshPairingOffer {
        MeshPairingOffer(
            shortCode: offer.code, payload: offer.payload,
            expiresAt: Date(timeIntervalSince1970: Double(offer.expiresS)))
    }

    static func pairingPreview(_ preview: PairingPreview, now _: Date = Date()) -> MeshPairingPreview {
        MeshPairingPreview(
            comparisonCode: preview.code, deviceLabel: preview.label, deviceKind: deviceKind(preview.kind),
            fingerprint: preview.deviceId, expiresAt: Date(timeIntervalSince1970: Double(preview.expiresS)))
    }

    static func invitation(_ value: Invitation, now _: Date = Date()) -> MeshInvitation {
        MeshInvitation(
            code: value.code, payload: value.payload, expiresAt: Date(timeIntervalSince1970: Double(value.expiresS)))
    }

    static func accepted(_ value: InvitationAccepted, now _: Date = Date()) -> MeshInvitationAccepted {
        MeshInvitationAccepted(
            comparisonCode: value.code, invitationCode: value.invitationCode, inviterDeviceId: value.inviterDeviceId,
            expiresAt: Date(timeIntervalSince1970: Double(value.expiresS)))
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

    static func principal(_ info: AstralKernel.MeshPrincipal) -> MeshVerifiedPrincipal {
        MeshVerifiedPrincipal(meshId: info.meshId)
    }

    static func provider(_ info: ModelProviderInfo, lowestOrder: UInt32) -> MeshModelProvider {
        MeshModelProvider(
            providerId: info.name, baseURL: info.baseUrl, model: info.models.first ?? "", hasKey: info.hasCredentials,
            isDefault: info.fallbackOrder == lowestOrder, recipients: info.recipients,
            availableOnDevice: info.availableOnDevice)
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
            fallbackOrder: 0, selfHosted: loopback, strictTools: false, recipients: config.recipients)
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
            case .joinRequested(let code, let label, let kind, let deviceId, let expiresS):
                return [
                    .joinRequested(
                        MeshJoinRequest(
                            comparisonCode: code, deviceLabel: label, deviceKind: deviceKind(kind), deviceId: deviceId,
                            expiresAt: Date(timeIntervalSince1970: Double(expiresS))))
                ]
            case .failed(let code): return [.pairingFailed(code: code)]
            case .offerSeen: return []
            }
        case .allowanceChanged: return [.allowanceChanged]
        case .connectionsChanged: return [.connectionsChanged]
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
        case .notice(let chat, let turn, let text): return [event(chat, turn, .notice(text))]
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
            case "completed":
                return [event(chat, turn, .assistantFinished), event(chat, turn, .finished)]
            case "incomplete":
                return [
                    event(chat, turn, .assistantFinished), event(chat, turn, .incomplete), event(chat, turn, .finished),
                ]
            case "interrupted": return [event(chat, turn, .interrupted)]
            case "repeat_stop": return [event(chat, turn, .failed("The assistant repeated itself, so it was stopped."))]
            case "max_rounds": return [event(chat, turn, .failed("The assistant reached its step limit."))]
            case "fork": return []
            case _ where isPhiRefusal(code ?? reason):
                let refused = code ?? reason
                return [event(chat, turn, .refused(code: refused, message: failureText(code: refused)))]
            default:
                return [
                    event(
                        chat, turn,
                        .failed(
                            failureText(code: code ?? reason, fallback: "The assistant could not finish this turn.")))
                ]
            }
        }
    }

    static func isPhiRefusal(_ code: String) -> Bool {
        code.hasPrefix("phi.") || code == "flow.phi_to_model" || code == "flow.phi_to_service"
            || code == "provider.no_candidate"
    }

    static func plainText(code: String) -> String? {
        codeTexts.first { code.hasPrefix($0.0) }?.1
    }

    static func failureText(code: String, fallback: String = "The mesh refused that request.") -> String {
        plainText(code: code) ?? fallback + " (" + code + ")"
    }

    private static let codeTexts: [(String, String)] = [
        ("attachment.too_large", "Choose a file no larger than 16 MB."),
        ("attachment.too_many", "A message can hold up to eight files."),
        ("attachment.empty", "That file is empty."),
        (
            "attachment.chunks_unavailable",
            "Get the file from its attachment card before continuing. The device holding it must be connected."
        ),
        ("attachment.unavailable", "An attachment in this chat could not be opened. Get the file before continuing."),
        ("attachment.context_too_large", "The selected attachment text exceeds the 256 KiB answer limit."),
        ("attachment.label", "Files cannot be attached to a chat that holds secrets."),
        ("attachment.content_mismatch", "The file contents do not match its type."),
        ("attachment.bad_name", "Rename the file before attaching it."),
        ("attachment.mime", "Choose a PDF, image, text, Markdown, CSV or JSON file."),
        ("attachment.", "The file could not be opened or attached."),
        ("turn.no_provider", "Add a model provider in Settings before asking for an answer."),
        ("provider.changed", "This provider or its devices changed. Refresh and try again."),
        ("provider.unavailable_on_device", "This device no longer has access to this provider."),
        ("provider.not_found", "This provider is no longer available on this device."),
        ("credential.bad_recipients", "Select one or more current mesh devices."),
        ("provider.no_candidate", "No model on this device can take this chat. Check the model provider."),
        ("provider.", "The model provider could not be reached or refused the request."),
        ("tool.name_ambiguous", "Multiple sources offer this tool name. Rename or remove one before using it."),
        ("mcp.version", "This server must support MCP 2026-07-28."),
        ("mcp.server_name", "Use 1 to 64 lowercase letters, digits and hyphens for the server name."),
        ("mcp.server_missing", "That MCP server is not configured on this device."),
        ("mcp.server_limit", "Remove a server before adding another. This device supports 32 MCP servers."),
        ("mcp.approval_limit", "Revoke a tool approval before adding another."),
        ("mcp.tool_changed", "The tool definition changed. Refresh and review it before approving."),
        ("mcp.tool_unapproved", "This tool definition needs your approval."),
        ("mcp.config_changed", "The MCP server configuration changed. Refresh and review its tools again."),
        ("mcp.response_too_large", "The MCP server response exceeds the 4 MB limit."),
        ("mcp.config", "Use a valid endpoint and a bearer token without spaces or line breaks."),
        ("mcp.", "The MCP server could not be reached or refused the request."),
        (
            "egress.",
            "Use HTTPS, or HTTP on a loopback host. URLs cannot contain credentials, a query or a fragment; other private addresses are refused."
        ),
        ("allowance.", "This device has used its allowance for now."),
        ("caller.wrong_minter", "Only a computer, phone or tablet in your mesh can issue caller tickets."),
        ("caller.wrong_node", "Choose a node that belongs to your mesh."),
        ("caller.no_catalog", "That node has not published its tools yet."),
        ("caller.unknown_tool", "One of the chosen tools is not offered by that node."),
        ("caller.malformed", "Check the label, tool list, holder key and lifetime."),
        ("caller.proof_", "The caller's proof was refused."),
        ("caller.mesh_mismatch", "That caller ticket belongs to a different mesh."),
        ("caller.device_removed", "The device that issued this caller ticket is no longer in your mesh."),
        ("caller.bad_signature", "This device could not sign the caller ticket."),
        ("caller.not_yet_valid", "That caller ticket is not valid yet. Check this device's clock."),
        ("caller.tool_changed", "A tool changed since the ticket was issued. Make a new ticket."),
        ("caller.tool_unavailable", "That node cannot run one of the chosen tools."),
        ("caller.replayed", "That caller request was already used."),
        ("caller.revoked", "That caller ticket was revoked."),
        ("caller.expired", "That caller ticket has expired."),
        ("caller.stopped", "The mesh was stopped, so caller tickets are refused."),
        ("caller.tool_not_covered", "That caller ticket does not cover this tool."),
        ("caller.", "The caller ticket was refused."),
        ("connection.keystore_unavailable", "This device cannot store sign-in credentials now. Unlock it and retry."),
        ("connection.credential_unreadable", "The saved sign-in for this connection could not be read. Sign in again."),
        ("connection.credential_unwritable", "The sign-in could not be saved on this device."),
        ("connection.changed", "The connection changed after you reviewed it. Review it again."),
        ("connection.egress_refused", "That address is outside what this connection may reach."),
        ("connection.step_up_unreviewed", "Review and approve the extra permissions before signing in again."),
        ("connection.flow_expired", "That sign-in ran out of time. Start it again."),
        ("connection.flow_unknown", "That sign-in is no longer open. Start it again."),
        ("connection.os_too_old", "Signing in from the browser needs iOS 17.4 or macOS 14.4 or later."),
        ("connection.iss_mismatch", "The sign-in site did not identify itself correctly. The sign-in was stopped."),
        ("connection.iss_missing", "The sign-in site did not identify itself. The sign-in was stopped."),
        ("connection.no_client_id", "This service needs a client ID before it can sign you in."),
        ("connection.redirect_invalid", "That sign-in return address was refused."),
        ("connection.local_elsewhere", "This local server can only be used on the device that added it."),
        ("connection.no_sign_in", "This connection does not use a sign-in."),
        ("connection.too_many_flows", "Too many sign-ins are open. Finish or cancel one first."),
        ("connection.step_up_limit", "This service keeps asking for more permissions. Check it and try again later."),
        ("connection.not_signed_in", "Sign in to this connection first."),
        ("connection.device_code_unavailable", "This device cannot sign in with a code."),
        ("oauth.state_mismatch", "That sign-in did not match the one you started. It was refused."),
        ("connection.", "The connection could not be changed or was refused."),
        ("oauth.browser_failed", "The browser could not open the sign-in or it did not finish."),
        ("oauth.wrong_callback", "The sign-in came back to an unexpected address. It was refused."),
        ("oauth.no_authorization_url", "The service gave no sign-in address."),
        ("oauth.", "The sign-in was refused or did not complete."),
        ("phi.group_not_ready", "Set up PHI on your mesh first. Open the PHI settings to adopt it."),
        ("phi.device_excluded", "This device is excluded from PHI. Use a device that is in the PHI group."),
        ("phi_group.node_device", "A node cannot approve PHI destinations."),
        ("phi_destination.on_device", "That place runs on this device, so it needs no approval."),
        ("phi_destination.contact_unavailable", "Contacts cannot receive PHI yet."),
        ("phi_destination.", "That destination cannot be approved for PHI."),
        ("phi_group.", "The PHI group could not be changed."),
        ("flow.phi_to_model", "PHI cannot go to this model until you approve it."),
        ("flow.phi_to_service", "PHI cannot go to this service until you approve it."),
        ("gate.mesh_stopped", "The mesh was stopped, so this turn was refused."),
        ("gate.", "A safety check refused this step."),
        ("consent.declined", MeshKernelError.consentDenied.message),
        ("signer.denied", MeshKernelError.consentDenied.message),
        ("mesh.already_enrolled", "This device already belongs to a mesh."),
        ("mesh.not_enrolled", "This device has no mesh yet."),
        ("pairing.expired", "The code ran out of time."),
        ("pairing.cancelled", "The invitation was cancelled."),
        ("pairing.used", "That code was already used."),
        ("pairing.wrong_offer", "That code is for a different invitation."),
        ("pairing.", "The code was refused."),
        ("recovery.bad_length", "Enter all 24 recovery words."),
        ("recovery.unknown_word", "One of the words is not on the recovery word list. Check the spelling."),
        ("recovery.bad_checksum", "These words are not a valid recovery key. Check the order and the spelling."),
        ("recovery.mismatch", "These words do not unlock that backup."),
        ("recovery.wrong_mesh", "That backup belongs to a different mesh than this install holds."),
        ("recovery.no_roster", "Choose a backup file. This device holds no copy of your mesh."),
        ("recovery.no_keys", "The words are valid, but no key of this mesh could be opened with them."),
        ("backup.decrypt_failed", "That backup could not be opened with these words."),
        ("backup.malformed", "That file is not a mesh backup."),
        ("config.mailbox", "That mailbox address was not accepted."),
        ("grant.malformed", "That tool name or permission could not be used."),
        ("grant.", "That permission could not be changed."),
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
        ("engine.steer_queue_full", "Too many follow-ups are waiting. Try again after the answer advances."),
        ("chat.empty_message", "Write a message first."),
        ("chat.message_too_large", "Shorten this message and try again."),
        ("chat.unknown_turn", "That message is not part of this chat yet."),
        ("chat.", "That chat action was refused."),
        ("net.", "The network is not available."),
        ("store.", "This device could not read or write its mesh data."),
    ]

    static func connectionTool(_ tool: ConnectionTool) -> MeshConnectionTool {
        MeshConnectionTool(name: tool.name, hash: tool.hash)
    }

    static func connectionDevice(_ state: ConnectionDeviceState) -> MeshConnectionDeviceState {
        MeshConnectionDeviceState(
            device: state.device, label: state.label, state: state.state, reason: state.reason,
            issuer: state.issuer, atMs: state.ms)
    }

    static func connection(_ info: ConnectionInfo) -> MeshConnection {
        MeshConnection(
            id: info.id, server: info.server, name: info.name, kind: info.kind, endpoint: info.endpoint,
            local: info.local, device: info.device, scheme: info.scheme, issuer: info.issuer, scopes: info.scopes,
            clientId: info.clientId, flow: info.flow, egress: info.egress, tools: info.tools.map(connectionTool),
            approvedBy: info.approvedBy, approvedByRemovedDevice: info.approvedByRemovedDevice,
            unsupported: info.unsupported, supportedHere: info.supportedHere,
            thisDevice: connectionDevice(info.thisDevice), attention: info.attention,
            otherDevices: info.otherDevices.map(connectionDevice), pendingTools: info.pendingTools?.map(connectionTool))
    }

    static func connectionProposal(_ value: ConnectionProposal) -> MeshConnectionProposal {
        MeshConnectionProposal(
            proposal: value.proposal, connection: value.connection, name: value.name, endpoint: value.endpoint,
            local: value.local, device: value.device, scheme: value.scheme, issuer: value.issuer,
            issuerHost: value.issuerHost, redirectHost: value.redirectHost, scopes: value.scopes,
            resource: value.resource, clientId: value.clientId, tools: value.tools.map(connectionTool),
            egress: value.egress, flowHint: value.flowHint, replaces: value.replaces, expiresMs: value.expiresMs)
    }

    static func connectionState(_ value: ConnectionState) -> MeshConnectionState {
        MeshConnectionState(
            connection: value.connection, state: value.state, reason: value.reason, toolsPending: value.toolsPending)
    }

    static func signInStart(_ value: SignInStart) -> MeshSignInStart {
        MeshSignInStart(
            flow: value.flow, authorizationURL: value.authorizationUrl, redirectURI: value.redirectUri,
            userCode: value.userCode, verificationURI: value.verificationUri,
            verificationURIComplete: value.verificationUriComplete, intervalSeconds: value.intervalS,
            expiresMs: value.expiresMs)
    }

    static func signInPoll(_ value: SignInPoll) -> MeshSignInPoll {
        switch value {
        case .pending(let interval): return .pending(intervalSeconds: interval)
        case .done(let state): return .done(connectionState(state))
        }
    }

    static func signInRedirect(_ value: MeshSignInRedirect) -> SignInRedirect {
        switch value {
        case .appLink: return .appLink
        case .loopback(let port): return .loopback(port: port)
        case .loopbackV6(let port): return .loopbackV6(port: port)
        case .pasted: return .pasted
        case .deviceCode: return .deviceCode
        }
    }

    static func stepUpPlan(_ value: StepUpPlan) -> MeshStepUpPlan {
        switch value {
        case .review(let scopes): return .review(scopes: scopes)
        case .signIn(let scopes): return .signIn(scopes: scopes)
        }
    }

    static func phiMember(_ value: AstralKernel.PhiMember) -> MeshPhiMember {
        MeshPhiMember(
            deviceId: value.deviceId, label: value.label, kind: deviceKind(value.kind),
            state: MeshPhiState(rawValue: value.state) ?? .notApproved, approvedBy: value.approvedBy,
            upgraded: value.upgraded, isThisDevice: value.isLocal)
    }

    static func phiGroup(_ value: AstralKernel.PhiGroupInfo) -> MeshPhiGroup {
        MeshPhiGroup(
            members: value.members.map(phiMember), localCode: value.localCode, rotateFirst: value.rotateFirst,
            pending: value.pending, keeper: value.keeper)
    }

    static func phiDestinations(_ value: AstralKernel.PhiDestinations) -> MeshPhiDestinations {
        MeshPhiDestinations(
            group: phiGroup(value.group),
            destinations: value.destinations.map { row in
                MeshPhiDestination(
                    subject: row.subject, form: MeshPhiDestinationForm(rawValue: row.form) ?? .invalid,
                    target: row.target, status: MeshPhiDestinationStatus(rawValue: row.status) ?? .invalid,
                    code: row.code, approvedBy: row.approvedBy)
            })
    }

    static func phiProposal(_ value: AstralKernel.PhiDestinationProposal) -> MeshPhiProposal {
        MeshPhiProposal(
            kind: MeshPhiDestinationKind(rawValue: value.kind) ?? .service, target: value.target,
            subject: value.subject, name: value.name, needsApproval: value.needsApproval,
            facts: value.facts.compactMap { MeshPhiFact(rawValue: $0) }, source: value.source)
    }

    static func phiProposal(_ value: MeshPhiProposal) -> AstralKernel.PhiDestinationProposal {
        AstralKernel.PhiDestinationProposal(
            kind: value.kind.rawValue, target: value.target, subject: value.subject, name: value.name,
            needsApproval: value.needsApproval, facts: value.facts.map(\.rawValue), source: value.source)
    }

    static func phiStatus(_ value: AstralKernel.PhiStatus) -> MeshPhiStatus {
        MeshPhiStatus(
            modelPresent: value.modelPresent, screened: value.screened, overBudget: value.overBudget,
            failed: value.failed)
    }

    static func phiQuestion(_ value: AstralKernel.PhiQuestion) -> MeshPhiQuestion {
        MeshPhiQuestion(
            items: value.items.map { MeshPhiQuestionItem(source: $0.source, kind: $0.kind, excerpt: $0.excerpt) })
    }

    static func phiAnswer(_ value: MeshPhiAnswer) -> AstralKernel.PhiAnswer {
        switch value {
        case .send: return .send
        case .treatAsPhi: return .treatAsPhi
        }
    }

    static func refusal(_ code: String) -> MeshKernelError {
        .refused(code: code, message: failureText(code: code))
    }

    static func error(_ error: Error) -> Error {
        switch error {
        case let known as MeshKernelError: return known
        case let kernel as KernelError:
            switch kernel {
            case .Denied(let code, _):
                if code == "gate.mesh_stopped" { return MeshKernelError.stopped }
                return code.hasPrefix("caller.") ? refusal(code) : MeshKernelError.consentDenied
            case .InvalidInput(let code, _), .Verification(let code, _), .Network(let code, _), .Custody(let code, _),
                .State(let code, _), .Mesh(let code, _):
                return refusal(code)
            case .Store(let code, _): return MeshKernelError.storage(failureText(code: code))
            }
        case let turns as TurnsError:
            if case .Failed(let code, _) = turns {
                return code.hasPrefix("consent.declined")
                    ? MeshKernelError.consentDenied
                    : refusal(code)
            }
            return turns
        case let runs as RunsFfiError:
            if case .Failed(let code, _) = runs {
                return code.hasPrefix("signer.denied") || code.hasPrefix("consent.declined")
                    ? MeshKernelError.consentDenied
                    : refusal(code)
            }
            return runs
        default: return error
        }
    }
}
