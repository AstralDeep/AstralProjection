// Client-local (client_local/v1) voice state machine for the Apple app: owns the ready
// handshake, recognition turns, canonical finals with bounded retry, announcement playout with
// echo suppression, and playout telemetry, all fenced by the current owner device, connection,
// session, generation, speech revision, chat and context revision. Driven by
// AppleVoiceSessionController over the injected AppleLocalSpeechEngine; keeps every transcript
// and announcement byte in memory only and scrubs it on completion.

import AstralCore
import CryptoKit
import Foundation

struct AppleLocalVoiceFence: Sendable, Equatable {
    let deviceId: String
    let connectionGeneration: String
    let sessionId: String
    let generation: Int
    let speechRevision: Int
}

@MainActor
final class AppleLocalVoiceRuntime {
    static let bindingTimeoutMilliseconds: UInt64 = 120_000
    static let finalRetryMilliseconds: UInt64 = 2_500
    static let finalAckTimeoutMilliseconds: UInt64 = 120_000
    static let echoSuppressionMilliseconds: UInt64 = 500
    static let maximumPendingFailures = 4
    static let maximumAnnouncements = 8
    static let reportableFailureReasons: Set<String> = [
        "local_recognition_unavailable", "local_recognition_failed",
        "local_recognition_cancelled", "local_audio_interrupted", "local_engine_lost",
        "local_final_empty", "local_final_oversized", "local_final_malformed",
        "stopped_by_user",
    ]

    struct Wiring {
        let send: @MainActor (String) -> Bool
        let feedback: @MainActor (String, String, String?) -> Void
        let failClosed: @MainActor () -> Void
        let bindingFresh: @MainActor () -> Bool
        let uuid: @MainActor () -> String
        let now: @MainActor () -> Date
        let transcript: @MainActor (String) -> Void
        var schedule: (@MainActor (UInt64, @MainActor @escaping () -> Void) -> Void)? = nil
    }

    private struct LocalTurn {
        var common: [String: JSONValue]
        var clientTurnId: String
        var chatId: String
        var chatContextRevision: Int
        var recognitionSequence: Int
        var recognitionEpoch: Int
        var turnId: String?
        var submissionId: String?
        var requestGeneration: String?
        var bindingExpiresAt: Date?
        var pendingFinal: String?
        var finalReceived: Bool
        var finalSent: Bool
        var failureSent: Bool
    }

    private struct LocalPendingFinal {
        var frame: [String: JSONValue]
        var expiresAt: Date
    }

    private struct LocalPendingFailure {
        var common: [String: JSONValue]
        var clientTurnId: String
        var chatId: String
        var chatContextRevision: Int
        var recognitionSequence: Int
        var reason: String
        var expiresAt: Date
    }

    private struct LocalPlayout {
        var epoch: Int
        var common: [String: JSONValue]
        var payload: [String: JSONValue]
        var started: Bool
        var terminal: Bool
        var resumeEpoch: Int?
    }

    private let engine: AppleLocalSpeechEngine
    private let wiring: Wiring
    private(set) var fence: AppleLocalVoiceFence?
    private(set) var closed = false

    private var chatId: String?
    private var chatContextRevision = 0
    private var foregroundActive = true
    private var microphoneEnabled = true
    private var speechMuted = false
    private var readyPending = false
    private var readyAuthorized = false
    private var clientSequence = 0
    private var announcementSequence = 0
    private var muteRevision = 0
    private var consentRevision = 0
    private var recognitionEpoch = 0
    private var playoutEpoch = 0
    private var recognitionSequenceCounter = 0
    private var resumeRequestedEpoch: Int?
    private var turn: LocalTurn?
    private var pendingFinal: LocalPendingFinal?
    private var pendingFailures: [LocalPendingFailure] = []
    private var playout: LocalPlayout?
    private var announcementQueue: [[String: JSONValue]] = []
    private var stopInFlight = false
    private var stopResetPending = false
    private var initialCapability: [String: JSONValue]?

    init(engine: AppleLocalSpeechEngine, wiring: Wiring) {
        self.engine = engine
        self.wiring = wiring
    }

    var isActive: Bool { fence != nil && !closed }

    func activate(
        fence: AppleLocalVoiceFence, chatId: String, chatContextRevision: Int,
        microphoneEnabled: Bool, speechMuted: Bool, foregroundActive: Bool,
        capability: [String: JSONValue]
    ) {
        self.fence = fence
        self.chatId = chatId
        self.chatContextRevision = chatContextRevision
        self.microphoneEnabled = microphoneEnabled
        self.speechMuted = speechMuted
        self.foregroundActive = foregroundActive
        initialCapability = capability
        closed = false
        clientSequence = 0
        recognitionEpoch += 1
        playoutEpoch += 1
        turn = nil
        pendingFinal = nil
        pendingFailures.removeAll()
        playout = nil
        announcementQueue.removeAll()
        announcementSequence = 0
        muteRevision = 0
        consentRevision = 0
        resumeRequestedEpoch = nil
        readyAuthorized = false
        stopInFlight = false
        stopResetPending = false
        readyPending = false
        recognitionSequenceCounter = 0
        requestReady()
    }

    func applySessionState(
        chatId: String, chatContextRevision: Int, foregroundActive: Bool,
        microphoneEnabled: Bool, speechMuted: Bool, chatContextSynced: Bool
    ) {
        guard isActive else { return }
        let blocked =
            !foregroundActive || !microphoneEnabled || speechMuted || !chatContextSynced
            || chatId != self.chatId
        if blocked { stopOwners("local_audio_interrupted") }
        self.chatId = chatId
        self.chatContextRevision = chatContextRevision
        self.foregroundActive = foregroundActive
        self.microphoneEnabled = microphoneEnabled
        self.speechMuted = speechMuted
        if !blocked && !readyAuthorized { reconcile() }
    }

    func controlChanging(
        foregroundActive: Bool? = nil, microphoneEnabled: Bool? = nil,
        speechMuted: Bool? = nil, chatChanged: Bool = false
    ) {
        guard isActive else { return }
        if let microphoneEnabled { self.microphoneEnabled = microphoneEnabled }
        if let speechMuted { self.speechMuted = speechMuted }
        if let foregroundActive { self.foregroundActive = foregroundActive }
        if foregroundActive == false || microphoneEnabled == false || speechMuted == true
            || chatChanged
        {
            let reason =
                (microphoneEnabled == false || speechMuted == true)
                ? "stopped_by_user" : "local_audio_interrupted"
            stopOwners(reason)
        } else if foregroundActive == true || microphoneEnabled == true || speechMuted == false {
            readyAuthorized = false
            readyPending = false
        }
    }

    func applyControlChange(
        foregroundActive: Bool? = nil, microphoneEnabled: Bool? = nil,
        speechMuted: Bool? = nil, chatChanged: Bool = false
    ) {
        controlChanging(
            foregroundActive: foregroundActive, microphoneEnabled: microphoneEnabled,
            speechMuted: speechMuted, chatChanged: chatChanged)
        reconcile()
    }

    func updateSpeechRevision(_ speechRevision: Int) {
        guard let current = fence, speechRevision >= current.speechRevision else { return }
        fence = AppleLocalVoiceFence(
            deviceId: current.deviceId, connectionGeneration: current.connectionGeneration,
            sessionId: current.sessionId, generation: current.generation,
            speechRevision: speechRevision)
    }

    func reconcile() {
        guard isActive, !stopInFlight else { return }
        if !foregroundActive || !microphoneEnabled || speechMuted {
            readyPending = false
            readyAuthorized = false
            stopOwners("local_audio_interrupted")
            return
        }
        if readyAuthorized {
            startRecognition()
        } else {
            requestReady()
        }
    }

    func stopSpeech() {
        guard isActive, !stopInFlight, !stopResetPending else { return }
        stopInFlight = true
        stopResetPending = false
        stopOwners("stopped_by_user")
    }

    func stopSpeechConfirmed() {
        guard isActive else { return }
        stopInFlight = false
        stopResetPending = true
        readyAuthorized = false
        readyPending = false
        if foregroundActive && microphoneEnabled && !speechMuted {
            readyPending = false
            requestReady()
        }
    }

    func stopSpeechFailed() {
        stopInFlight = false
        feedback("error", "speech_error")
    }

    func suspend(reason: String) {
        guard isActive else { return }
        foregroundActive = false
        readyPending = false
        readyAuthorized = false
        stopOwners(reason)
    }

    func close() {
        guard !closed else { return }
        closed = true
        fence = nil
        readyPending = false
        readyAuthorized = false
        stopOwners("local_audio_interrupted", reportRecognition: false, reportPlayout: true)
        scrubEphemeralText()
    }

    func consume(_ frame: VoiceLocalFrame) -> Bool {
        guard !closed, fence != nil, let object = frame.payload.objectValue,
            authorityMatches(object)
        else { return false }
        switch frame.type {
        case "voice_local_session_ready": return consumeSessionReady(object)
        case "voice_local_turn_bound": return consumeTurnBound(object)
        case "voice_local_final_rejected": return consumeFinalRejected(object)
        case "voice_local_announcement": return consumeAnnouncement(object)
        default: return false
        }
    }

    func consumeAcknowledgement(_ value: VoiceMessageAcknowledgement) -> Bool {
        guard let pending = pendingFinal, let current = fence else { return false }
        guard value.connectionGeneration == current.connectionGeneration,
            value.chatId == pending.frame["chat_id"]?.stringValue,
            value.submissionId == pending.frame["submission_id"]?.stringValue,
            value.requestGeneration == pending.frame["request_generation"]?.stringValue,
            value.voiceTurnId == pending.frame["turn_id"]?.stringValue
        else { return false }
        clearPendingFinal()
        maybeResumeRequested()
        startRecognition()
        return true
    }

    private func consumeSessionReady(_ object: [String: JSONValue]) -> Bool {
        guard readyPending, !stopInFlight,
            object["contract"]?.stringValue == "client_local/v1",
            object["configured_locale"]?.stringValue == "en-US",
            let lease = localTimestamp(object["lease_expires_at"]), lease > wiring.now(),
            let chat = object["chat_id"]?.stringValue, chat == chatId,
            let context = localPositive(object["chat_context_revision"]),
            context == chatContextRevision,
            object["applied_chat_context_revision"]?.numberValue
                == object["chat_context_revision"]?.numberValue,
            object["foreground_active"]?.boolValue == true,
            object["microphone_enabled"]?.boolValue == true,
            object["speech_muted"]?.boolValue == false,
            foregroundActive, microphoneEnabled, !speechMuted
        else { return false }
        readyPending = false
        readyAuthorized = true
        if stopResetPending {
            announcementSequence = 0
            muteRevision = 0
            consentRevision = 0
            stopResetPending = false
        }
        feedback("listening", "ready")
        startRecognition()
        return true
    }

    private func consumeTurnBound(_ object: [String: JSONValue]) -> Bool {
        guard let bindingExpiry = localTimestamp(object["binding_expires_at"]) else { return false }
        let now = wiring.now()
        guard bindingExpiry > now,
            bindingExpiry.timeIntervalSince(now) * 1_000
                <= Double(Self.bindingTimeoutMilliseconds) + 1_000
        else { return false }
        if var current = turn, current.turnId == nil,
            object["client_turn_id"]?.stringValue == current.clientTurnId,
            object["recognition_sequence"]?.numberValue == Double(current.recognitionSequence),
            object["chat_id"]?.stringValue == current.chatId,
            object["chat_context_revision"]?.numberValue == Double(current.chatContextRevision),
            frozenAuthorityMatches(current.common, object)
        {
            current.turnId = object["turn_id"]?.stringValue
            current.submissionId = object["submission_id"]?.stringValue
            current.requestGeneration = object["request_generation"]?.stringValue
            current.bindingExpiresAt = bindingExpiry
            let finalText = current.pendingFinal
            current.pendingFinal = nil
            turn = current
            if let finalText { sendFinal(clientTurnId: current.clientTurnId, text: finalText) }
            return true
        }
        prunePendingFailures()
        for (index, pending) in pendingFailures.enumerated() {
            guard object["client_turn_id"]?.stringValue == pending.clientTurnId,
                object["recognition_sequence"]?.numberValue == Double(pending.recognitionSequence),
                object["chat_id"]?.stringValue == pending.chatId,
                object["chat_context_revision"]?.numberValue == Double(pending.chatContextRevision),
                frozenAuthorityMatches(pending.common, object)
            else { continue }
            let bound = pending
            pendingFailures.remove(at: index)
            sendRecognitionFailure(
                common: bound.common, clientTurnId: bound.clientTurnId,
                turnId: object["turn_id"]?.stringValue,
                submissionId: object["submission_id"]?.stringValue,
                requestGeneration: object["request_generation"]?.stringValue,
                chatId: bound.chatId, chatContextRevision: bound.chatContextRevision,
                recognitionSequence: bound.recognitionSequence,
                bindingExpiresAt: bindingExpiry, reason: bound.reason)
            return true
        }
        return false
    }

    private func consumeFinalRejected(_ object: [String: JSONValue]) -> Bool {
        guard let pending = pendingFinal else { return false }
        for name in [
            "device_id", "connection_generation", "session_id", "generation", "speech_revision",
            "client_turn_id", "turn_id", "submission_id", "request_generation", "chat_id",
            "chat_context_revision", "recognition_sequence",
        ] where object[name] != pending.frame[name] {
            return false
        }
        clearPendingFinal()
        feedback("error", object["reason"]?.stringValue ?? "local_recognition_failed")
        maybeResumeRequested()
        startRecognition()
        return true
    }

    private func consumeAnnouncement(_ object: [String: JSONValue]) -> Bool {
        guard let text = object["text"]?.stringValue,
            let expiry = localTimestamp(object["expires_at"]),
            let sequence = localPositive(object["announcement_sequence"])
        else { return false }
        let now = wiring.now()
        guard Self.sha256Hex(text) == object["text_digest_sha256"]?.stringValue,
            expiry > now, expiry.timeIntervalSince(now) <= 11,
            sequence == announcementSequence + 1,
            object["locale"]?.stringValue == "en-US",
            object["foreground_required"]?.boolValue == true,
            (localPositive(object["mute_revision"]) ?? 0) >= muteRevision,
            (localPositive(object["consent_revision"]) ?? 0) >= consentRevision,
            readyAuthorized, !stopInFlight, !speechMuted, foregroundActive, microphoneEnabled,
            announcementQueue.count + (playout == nil ? 0 : 1) < Self.maximumAnnouncements
        else { return false }
        announcementSequence = sequence
        muteRevision = localPositive(object["mute_revision"]) ?? muteRevision
        consentRevision = localPositive(object["consent_revision"]) ?? consentRevision
        if playout != nil {
            announcementQueue.append(object)
            return true
        }
        startPlayout(object)
        return true
    }

    private func startPlayout(_ payload: [String: JSONValue], resumeEpoch: Int? = nil) {
        playoutEpoch += 1
        let epoch = playoutEpoch
        var common: [String: JSONValue] = [:]
        for name in [
            "schema_version", "speech_backend", "device_id", "connection_generation",
            "session_id", "generation", "speech_revision",
        ] {
            if let value = payload[name] { common[name] = value }
        }
        var active = LocalPlayout(
            epoch: epoch, common: common, payload: payload, started: false, terminal: false,
            resumeEpoch: resumeEpoch)
        let expiry = localTimestamp(payload["expires_at"])
        if !announcementAuthorityCurrent(payload) {
            if let expiry, expiry <= wiring.now(), authorityMatches(common) {
                sendPlayoutEvent(active, phase: "failed", reason: "local_announcement_expired")
            }
            active.payload["text"] = .string("")
            if !announcementQueue.isEmpty {
                startPlayout(announcementQueue.removeFirst(), resumeEpoch: resumeEpoch)
            } else if let resumeEpoch {
                scheduleRecognitionResume(resumeEpoch)
            }
            return
        }
        cancelRecognition("local_audio_interrupted")
        active.resumeEpoch = recognitionEpoch
        playout = active
        let text = payload["text"]?.stringValue ?? ""
        Task { @MainActor [weak self] in
            await self?.engine.stopRecognition()
            guard let self else { return }
            let started = await self.engine.speak(text) { phase in
                self.finishPlayoutPhase(epoch: epoch, phase: phase)
            }
            if !started { self.finishPlayoutPhase(epoch: epoch, phase: "failed") }
        }
        if let expiry {
            let remainingMilliseconds = max(1, Int(expiry.timeIntervalSince(wiring.now()) * 1_000))
            scheduleMilliseconds(UInt64(remainingMilliseconds)) { [weak self] in
                self?.expireAnnouncement(epoch: epoch)
            }
        }
    }

    private func announcementAuthorityCurrent(_ payload: [String: JSONValue]) -> Bool {
        guard let expiry = localTimestamp(payload["expires_at"]), expiry > wiring.now(),
            authorityMatches(payload), readyAuthorized, !stopInFlight,
            foregroundActive, microphoneEnabled, !speechMuted,
            payload["foreground_required"]?.boolValue == true,
            payload["locale"]?.stringValue == "en-US"
        else { return false }
        return true
    }

    private func finishPlayoutPhase(epoch: Int, phase: String, reason: String? = nil) {
        guard let active = playout, active.epoch == epoch, !active.terminal else { return }
        let resolved = ["started", "finished", "interrupted", "failed"].contains(phase)
            ? phase : "failed"
        if let expiry = localTimestamp(active.payload["expires_at"]), expiry <= wiring.now() {
            expireAnnouncement(epoch: epoch)
            return
        }
        if resolved == "started" {
            guard !active.started else { return }
            if !announcementAuthorityCurrent(active.payload) {
                engineStopAll()
                completePlayout(epoch: epoch, phase: "failed", reason: "local_audio_interrupted")
                return
            }
            playout?.started = true
            sendPlayoutEvent(active, phase: "started")
            return
        }
        var terminalPhase = resolved
        if ["finished", "interrupted"].contains(terminalPhase), !active.started {
            terminalPhase = "failed"
        }
        let resolvedReason =
            reason
            ?? (terminalPhase == "failed" ? "local_synthesis_failed" : nil)
            ?? (terminalPhase == "interrupted" ? "local_audio_interrupted" : nil)
        completePlayout(epoch: epoch, phase: terminalPhase, reason: resolvedReason)
    }

    private func completePlayout(epoch: Int, phase: String, reason: String?) {
        guard let active = playout, active.epoch == epoch else { return }
        playout?.terminal = true
        sendPlayoutEvent(active, phase: phase, reason: reason)
        playout?.payload["text"] = .string("")
        if playout?.epoch == epoch { playout = nil }
        engineStopAll()
        let resumeEpoch = active.resumeEpoch
        if !announcementQueue.isEmpty {
            startPlayout(announcementQueue.removeFirst(), resumeEpoch: resumeEpoch)
        } else if let resumeEpoch {
            scheduleRecognitionResume(resumeEpoch)
        }
    }

    private func expireAnnouncement(epoch: Int) {
        guard let active = playout, active.epoch == epoch, !active.terminal else { return }
        guard let expiry = localTimestamp(active.payload["expires_at"]), expiry <= wiring.now()
        else { return }
        playout?.terminal = true
        engineStopAll()
        completePlayout(epoch: epoch, phase: "failed", reason: "local_announcement_expired")
    }

    private func sendPlayoutEvent(
        _ active: LocalPlayout, phase: String, reason: String? = nil
    ) {
        guard active.epoch == playoutEpoch, authorityMatches(active.common),
            var fields = common("voice_local_playout_event")
        else { return }
        fields["announcement_id"] = active.payload["announcement_id"]
        fields["announcement_sequence"] = active.payload["announcement_sequence"]
        fields["turn_id"] = active.payload["turn_id"]
        fields["kind"] = active.payload["kind"]
        fields["phase"] = .string(phase)
        clientSequence += 1
        fields["client_sequence"] = .number(Double(clientSequence))
        fields["observed_at"] = .string(Self.wireTimestamp(wiring.now()))
        if let reason { fields["reason"] = .string(reason) }
        sendFrame(fields)
    }

    private func reportStoppedPlayout(
        _ payload: [String: JSONValue], phase: String, reason: String
    ) {
        var commonFields: [String: JSONValue] = [:]
        for name in [
            "schema_version", "speech_backend", "device_id", "connection_generation",
            "session_id", "generation", "speech_revision",
        ] {
            if let value = payload[name] { commonFields[name] = value }
        }
        guard authorityMatches(commonFields), var fields = common("voice_local_playout_event")
        else { return }
        fields["announcement_id"] = payload["announcement_id"]
        fields["announcement_sequence"] = payload["announcement_sequence"]
        fields["turn_id"] = payload["turn_id"]
        fields["kind"] = payload["kind"]
        fields["phase"] = .string(phase)
        clientSequence += 1
        fields["client_sequence"] = .number(Double(clientSequence))
        fields["observed_at"] = .string(Self.wireTimestamp(wiring.now()))
        fields["reason"] = .string(reason)
        sendFrame(fields)
    }

    private func scheduleRecognitionResume(_ epoch: Int) {
        scheduleMilliseconds(Self.echoSuppressionMilliseconds) { [weak self] in
            self?.resumeRecognition(epoch)
        }
    }

    private func resumeRecognition(_ epoch: Int) {
        guard epoch == recognitionEpoch, isActive else { return }
        if turn != nil || pendingFinal != nil {
            resumeRequestedEpoch = epoch
            return
        }
        startRecognition()
    }

    private func maybeResumeRequested() {
        guard let epoch = resumeRequestedEpoch else { return }
        resumeRequestedEpoch = nil
        resumeRecognition(epoch)
    }

    private func startRecognition() {
        guard readyAuthorized, !readyPending, !stopInFlight, pendingFinal == nil,
            playout == nil, announcementQueue.isEmpty, !closed,
            !speechMuted, microphoneEnabled, foregroundActive, turn == nil,
            let chatId
        else { return }
        resumeRequestedEpoch = nil
        recognitionEpoch += 1
        let epoch = recognitionEpoch
        recognitionSequenceCounter += 1
        let recognitionSequence = recognitionSequenceCounter
        guard var fields = common("voice_local_recognition_started") else { return }
        let clientTurnId = wiring.uuid()
        fields["client_turn_id"] = .string(clientTurnId)
        fields["chat_id"] = .string(chatId)
        fields["chat_context_revision"] = .number(Double(chatContextRevision))
        fields["recognition_sequence"] = .number(Double(recognitionSequence))
        let newTurn = LocalTurn(
            common: fields, clientTurnId: clientTurnId, chatId: chatId,
            chatContextRevision: chatContextRevision, recognitionSequence: recognitionSequence,
            recognitionEpoch: epoch, turnId: nil, submissionId: nil, requestGeneration: nil,
            bindingExpiresAt: nil, pendingFinal: nil, finalReceived: false, finalSent: false,
            failureSent: false)
        turn = newTurn
        guard sendFrame(fields) else {
            turn = nil
            recognitionEpoch += 1
            readyAuthorized = false
            readyPending = false
            feedback("unavailable", "local_recognition_unavailable")
            return
        }
        scheduleMilliseconds(Self.bindingTimeoutMilliseconds) { [weak self] in
            self?.expireTurnBinding(epoch: epoch, clientTurnId: clientTurnId)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await self.engine.startRecognition(
                onFinal: { [weak self] text in
                    self?.handleLocalFinal(epoch: epoch, text: text)
                },
                onError: { [weak self] reason in
                    self?.handleLocalError(epoch: epoch, reason: reason)
                })
            guard started == false, self.recognitionEpoch == epoch,
                self.turn?.recognitionEpoch == epoch
            else { return }
            self.handleLocalError(epoch: epoch, reason: "local_recognition_unavailable")
        }
    }

    private func expireTurnBinding(epoch: Int, clientTurnId: String) {
        guard let current = turn, current.recognitionEpoch == epoch,
            current.clientTurnId == clientTurnId, current.turnId == nil
        else { return }
        turn = nil
        recognitionEpoch += 1
        engineStopCapture()
        startRecognition()
    }

    private func handleLocalFinal(epoch: Int, text: String) {
        guard var current = turn, epoch == recognitionEpoch,
            epoch == current.recognitionEpoch, !current.finalReceived, !current.finalSent,
            !current.failureSent
        else { return }
        current.finalReceived = true
        turn = current
        engineStopCapture()
        guard let canonical = canonicalizeLocalFinal(text) else {
            if current.turnId != nil {
                current.failureSent = true
                turn = current
                sendRecognitionFailure(
                    common: current.common, clientTurnId: current.clientTurnId,
                    turnId: current.turnId, submissionId: current.submissionId,
                    requestGeneration: current.requestGeneration, chatId: current.chatId,
                    chatContextRevision: current.chatContextRevision,
                    recognitionSequence: current.recognitionSequence,
                    bindingExpiresAt: current.bindingExpiresAt,
                    reason: "local_final_malformed")
            } else {
                retainPendingFailure(
                    common: current.common, clientTurnId: current.clientTurnId,
                    chatId: current.chatId, chatContextRevision: current.chatContextRevision,
                    recognitionSequence: current.recognitionSequence,
                    reason: "local_final_malformed")
            }
            turn = nil
            feedback("unavailable", "local_final_malformed")
            return
        }
        if current.turnId == nil {
            turn?.pendingFinal = canonical
            return
        }
        sendFinal(clientTurnId: current.clientTurnId, text: canonical)
    }

    private func sendFinal(clientTurnId: String, text: String) {
        guard var current = turn, current.clientTurnId == clientTurnId, !current.finalSent,
            !current.failureSent, authorityMatches(current.common),
            let expiry = current.bindingExpiresAt, expiry > wiring.now(),
            let turnId = current.turnId, let submissionId = current.submissionId,
            let requestGeneration = current.requestGeneration
        else { turn?.pendingFinal = nil; return }
        guard var fields = common("voice_local_final") else { return }
        for (key, value) in current.common where key != "type" { fields[key] = value }
        fields["client_turn_id"] = .string(current.clientTurnId)
        fields["turn_id"] = .string(turnId)
        fields["submission_id"] = .string(submissionId)
        fields["request_generation"] = .string(requestGeneration)
        fields["chat_id"] = .string(current.chatId)
        fields["chat_context_revision"] = .number(Double(current.chatContextRevision))
        fields["recognition_sequence"] = .number(Double(current.recognitionSequence))
        fields["final"] = .bool(true)
        fields["recognized_locale"] = .string("en-US")
        fields["text"] = .string(text)
        fields["text_digest_sha256"] = .string(Self.sha256Hex(text))
        current.finalSent = true
        current.pendingFinal = nil
        turn = current
        let ackExpiry = min(
            expiry,
            wiring.now().addingTimeInterval(
                Double(Self.finalAckTimeoutMilliseconds) / 1_000))
        pendingFinal = LocalPendingFinal(frame: fields, expiresAt: ackExpiry)
        turn = nil
        sendFrame(fields)
        transcript(text)
        feedback("acknowledging", "ready", "On it!")
        scheduleFinalRetry()
    }

    private func scheduleFinalRetry() {
        guard let pending = pendingFinal else { return }
        let remainingMilliseconds = UInt64(
            max(0, pending.expiresAt.timeIntervalSince(wiring.now()) * 1_000))
        guard remainingMilliseconds > 0 else {
            expirePendingFinal()
            return
        }
        scheduleMilliseconds(min(Self.finalRetryMilliseconds, remainingMilliseconds)) {
            [weak self] in
            self?.retryPendingFinal()
        }
    }

    private func retryPendingFinal() {
        guard let pending = pendingFinal else { return }
        guard pending.expiresAt > wiring.now(), authorityMatches(pending.frame) else {
            expirePendingFinal()
            return
        }
        sendFrame(pending.frame)
        scheduleFinalRetry()
    }

    private func clearPendingFinal() {
        pendingFinal?.frame["text"] = .string("")
        pendingFinal?.frame["text_digest_sha256"] = .string("")
        pendingFinal = nil
    }

    private func expirePendingFinal() {
        guard pendingFinal != nil else { return }
        clearPendingFinal()
        transcript("")
        feedback(
            "unavailable", "local_session_not_ready",
            "Voice stopped because request acceptance could not be confirmed. Typed chat remains available.")
        wiring.failClosed()
    }

    static func failureReason(_ reason: String) -> String {
        reportableFailureReasons.contains(reason) ? reason : "local_recognition_failed"
    }

    private func sendRecognitionFailure(
        common base: [String: JSONValue], clientTurnId: String, turnId: String?,
        submissionId: String?, requestGeneration: String?, chatId: String,
        chatContextRevision: Int, recognitionSequence: Int, bindingExpiresAt: Date?,
        reason: String
    ) {
        guard !closed, authorityMatches(base), let bindingExpiry = bindingExpiresAt,
            bindingExpiry > wiring.now(), var fields = common("voice_local_recognition_failed")
        else { return }
        for (key, value) in base where key != "type" { fields[key] = value }
        fields["client_turn_id"] = .string(clientTurnId)
        fields["turn_id"] = turnId.map { .string($0) } ?? .null
        fields["submission_id"] = submissionId.map { .string($0) } ?? .null
        fields["request_generation"] = requestGeneration.map { .string($0) } ?? .null
        fields["chat_id"] = .string(chatId)
        fields["chat_context_revision"] = .number(Double(chatContextRevision))
        fields["recognition_sequence"] = .number(Double(recognitionSequence))
        fields["reason"] = .string(Self.failureReason(reason))
        sendFrame(fields)
    }

    private func handleLocalError(epoch: Int, reason: String) {
        guard let current = turn, epoch == recognitionEpoch,
            epoch == current.recognitionEpoch, !current.finalReceived, !current.finalSent,
            !current.failureSent
        else { return }
        let canonical = Self.failureReason(reason)
        recognitionEpoch += 1
        var finished = current
        finished.pendingFinal = nil
        if finished.turnId != nil {
            finished.failureSent = true
            sendRecognitionFailure(
                common: finished.common, clientTurnId: finished.clientTurnId,
                turnId: finished.turnId, submissionId: finished.submissionId,
                requestGeneration: finished.requestGeneration, chatId: finished.chatId,
                chatContextRevision: finished.chatContextRevision,
                recognitionSequence: finished.recognitionSequence,
                bindingExpiresAt: finished.bindingExpiresAt, reason: canonical)
        } else {
            retainPendingFailure(
                common: finished.common, clientTurnId: finished.clientTurnId,
                chatId: finished.chatId, chatContextRevision: finished.chatContextRevision,
                recognitionSequence: finished.recognitionSequence, reason: canonical)
        }
        turn = nil
        readyAuthorized = false
        readyPending = false
        cancelPlayout(reason: "local_audio_interrupted")
        engineStopAll()
        feedback("unavailable", canonical)
    }

    private func cancelRecognition(reason: String) {
        resumeRequestedEpoch = nil
        recognitionEpoch += 1
        guard var current = turn else { return }
        if !current.finalSent && !current.failureSent {
            if current.turnId != nil {
                current.failureSent = true
                turn = current
                sendRecognitionFailure(
                    common: current.common, clientTurnId: current.clientTurnId,
                    turnId: current.turnId, submissionId: current.submissionId,
                    requestGeneration: current.requestGeneration, chatId: current.chatId,
                    chatContextRevision: current.chatContextRevision,
                    recognitionSequence: current.recognitionSequence,
                    bindingExpiresAt: current.bindingExpiresAt, reason: reason)
            } else {
                retainPendingFailure(
                    common: current.common, clientTurnId: current.clientTurnId,
                    chatId: current.chatId, chatContextRevision: current.chatContextRevision,
                    recognitionSequence: current.recognitionSequence, reason: reason)
            }
        }
        turn = nil
    }

    private func cancelPlayout(reason: String) {
        if let active = playout, !active.terminal {
            let phase = active.started ? "interrupted" : "failed"
            let playoutReason =
                reason == "stopped_by_user" ? "stopped_by_user" : "local_audio_interrupted"
            finishPlayoutPhase(epoch: active.epoch, phase: phase, reason: playoutReason)
        }
        playoutEpoch += 1
        playout = nil
    }

    func stopOwners(
        _ reason: String, reportRecognition: Bool = true, reportPlayout: Bool = true
    ) {
        readyAuthorized = false
        readyPending = false
        var stoppedEvents: [(payload: [String: JSONValue], phase: String, reason: String)] = []
        if var active = playout {
            let phase = active.started ? "interrupted" : "failed"
            let playoutReason =
                reason == "stopped_by_user" ? "stopped_by_user" : "local_audio_interrupted"
            if !active.terminal {
                active.terminal = true
                if reportPlayout { stoppedEvents.append((active.payload, phase, playoutReason)) }
            }
            playoutEpoch += 1
            active.epoch = playoutEpoch
            playout = nil
        }
        let queued = announcementQueue
        announcementQueue = []
        if reportPlayout {
            for payload in queued {
                stoppedEvents.append(
                    (
                        payload, "failed",
                        reason == "stopped_by_user" ? "stopped_by_user" : "local_audio_interrupted"
                    ))
            }
        }
        for index in queued.indices {
            queued[index]["text"] = .string("")
        }
        resumeRequestedEpoch = nil
        recognitionEpoch += 1
        var boundTurn: LocalTurn?
        if var current = turn {
            current.pendingFinal = nil
            if reportRecognition, !current.finalSent, !current.failureSent {
                if current.turnId != nil {
                    current.failureSent = true
                    boundTurn = current
                } else {
                    retainPendingFailure(
                        common: current.common, clientTurnId: current.clientTurnId,
                        chatId: current.chatId,
                        chatContextRevision: current.chatContextRevision,
                        recognitionSequence: current.recognitionSequence, reason: reason)
                }
            }
        }
        turn = nil
        engineStopAll()
        for event in stoppedEvents {
            reportStoppedPlayout(event.payload, phase: event.phase, reason: event.reason)
        }
        if let boundTurn {
            sendRecognitionFailure(
                common: boundTurn.common, clientTurnId: boundTurn.clientTurnId,
                turnId: boundTurn.turnId, submissionId: boundTurn.submissionId,
                requestGeneration: boundTurn.requestGeneration, chatId: boundTurn.chatId,
                chatContextRevision: boundTurn.chatContextRevision,
                recognitionSequence: boundTurn.recognitionSequence,
                bindingExpiresAt: boundTurn.bindingExpiresAt, reason: reason)
        }
    }

    private func retainPendingFailure(
        common base: [String: JSONValue], clientTurnId: String, chatId: String,
        chatContextRevision: Int, recognitionSequence: Int, reason: String
    ) {
        prunePendingFailures()
        while pendingFailures.count >= Self.maximumPendingFailures {
            pendingFailures.removeFirst()
        }
        pendingFailures.append(
            LocalPendingFailure(
                common: base, clientTurnId: clientTurnId, chatId: chatId,
                chatContextRevision: chatContextRevision,
                recognitionSequence: recognitionSequence,
                reason: Self.failureReason(reason),
                expiresAt: wiring.now().addingTimeInterval(
                    Double(Self.bindingTimeoutMilliseconds) / 1_000)))
    }

    private func prunePendingFailures() {
        let now = wiring.now()
        pendingFailures.removeAll { $0.expiresAt <= now || !authorityMatches($0.common) }
    }

    private func requestReady() {
        guard isActive, !stopInFlight, foregroundActive, microphoneEnabled, !speechMuted else {
            readyPending = false
            readyAuthorized = false
            return
        }
        if readyPending { return }
        let capability: [String: JSONValue]?
        if let initialCapability {
            capability = initialCapability
            initialCapability = nil
        } else {
            capability = nil
        }
        if let capability {
            dispatchReady(capability)
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.isActive, !self.readyPending, !self.readyAuthorized else {
                return
            }
            let observation = await self.engine.observation()
            guard self.isActive, !self.readyPending, !self.readyAuthorized else { return }
            guard observation.ready, let ready = observation.readyCapability() else {
                self.feedback(
                    "unavailable", observation.refusalReason() ?? "local_engine_lost")
                self.readyAuthorized = false
                return
            }
            self.dispatchReady(ready)
        }
    }

    private func dispatchReady(_ capability: [String: JSONValue]) {
        guard var fields = common("voice_local_ready") else { return }
        for (key, value) in capability { fields[key] = value }
        clientSequence += 1
        fields["client_sequence"] = .number(Double(clientSequence))
        readyPending = true
        if !sendFrame(fields) {
            readyPending = false
            readyAuthorized = false
        }
    }

    private func authorityMatches(_ fields: [String: JSONValue]) -> Bool {
        guard !closed, let current = fence, wiring.bindingFresh() else { return false }
        return fields["device_id"]?.stringValue == current.deviceId
            && fields["connection_generation"]?.stringValue == current.connectionGeneration
            && fields["session_id"]?.stringValue == current.sessionId
            && fields["generation"]?.numberValue == Double(current.generation)
            && fields["speech_revision"]?.numberValue == Double(current.speechRevision)
    }

    private func frozenAuthorityMatches(
        _ frozen: [String: JSONValue], _ payload: [String: JSONValue]
    ) -> Bool {
        for name in [
            "device_id", "connection_generation", "session_id", "generation", "speech_revision",
        ] where frozen[name] != payload[name] {
            return false
        }
        return true
    }

    private func common(_ type: String) -> [String: JSONValue]? {
        guard let current = fence else { return nil }
        return [
            "type": .string(type),
            "schema_version": .string("2"),
            "speech_backend": .string("client_local"),
            "device_id": .string(current.deviceId),
            "connection_generation": .string(current.connectionGeneration),
            "session_id": .string(current.sessionId),
            "generation": .number(Double(current.generation)),
            "speech_revision": .number(Double(current.speechRevision)),
        ]
    }

    private func sendFrame(_ fields: [String: JSONValue]) -> Bool {
        guard let encoded = try? JSONValue.object(fields).encoded() else { return false }
        let text = String(decoding: encoded, as: UTF8.self)
        guard VoiceCurrentConnectionFrame(frameText: text) != nil else { return false }
        return wiring.send(text)
    }

    private func feedback(_ phase: String, _ reason: String, _ message: String? = nil) {
        wiring.feedback(phase, reason, message)
    }

    private func engineStopCapture() {
        Task { await engine.stopRecognition() }
    }

    private func engineStopAll() {
        Task { await engine.stopAll() }
    }

    private func scrubEphemeralText() {
        clearPendingFinal()
        playout?.payload["text"] = .string("")
        for index in announcementQueue.indices {
            announcementQueue[index]["text"] = .string("")
        }
        turn?.pendingFinal = nil
    }

    private func scheduleMilliseconds(
        _ milliseconds: UInt64, _ work: @escaping @MainActor () -> Void
    ) {
        if let schedule = wiring.schedule {
            schedule(milliseconds, work)
            return
        }
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            } catch {
                return
            }
            guard let self else { return }
            await MainActor.run {
                guard !self.closed else { return }
                work()
            }
        }
    }

    private func localTimestamp(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    private func localPositive(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.isFinite, number.rounded() == number,
            number >= 1
        else { return nil }
        return Int(number)
    }

    static func wireTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
