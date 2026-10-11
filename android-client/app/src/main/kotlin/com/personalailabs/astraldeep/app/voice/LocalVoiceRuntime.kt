// Pure client-local voice runtime: owns the server-authorized ready handshake, recognition turn
// binding, immutable final submission with exact-ack retries, the bounded pending-failure ledger
// and bounded announcement playout with playout-event accounting. VoiceSessionController starts,
// controls and tears it down; LocalSpeechEngine supplies recognition and synthesis.

package com.personalailabs.astraldeep.app.voice

import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.LocalVoiceDisposition
import com.personalailabs.astraldeep.core.protocol.LocalVoiceFrame
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.security.MessageDigest
import java.text.Normalizer
import java.time.Instant
import java.util.UUID

data class LocalVoiceSession(
    val deviceId: String,
    val connectionGeneration: String,
    val sessionId: String,
    val generation: Int,
    val speechRevision: Int,
    val chatId: String,
    val chatContextRevision: Int,
    val foregroundActive: Boolean,
    val microphoneEnabled: Boolean,
    val speechMuted: Boolean,
)

internal data class LocalVoiceUiEvent(
    val phase: String? = null,
    val reason: String? = null,
    val message: String? = null,
    val unavailable: Boolean = false,
    val transcriptPreview: String? = null,
    val transcriptFinal: Boolean? = null,
    val accepted: Boolean = false,
    val unrecoverable: Boolean = false,
)

internal data class CanonicalLocalFinal(val text: String?, val reason: String?)

internal fun canonicalizeLocalFinal(
    value: String,
    maxScalars: Int,
): CanonicalLocalFinal {
    val canonical = value.replace("\r\n", "\n").replace("\r", "\n").normalizeNfc().trim()
    if (canonical.isEmpty()) return CanonicalLocalFinal(null, "local_final_empty")
    if (canonical.codePointCount(0, canonical.length) > maxScalars) {
        return CanonicalLocalFinal(null, "local_final_malformed")
    }
    if (canonical.any { it != '\t' && it != '\n' && it.hasOtherUnicodeCategory() }) {
        return CanonicalLocalFinal(null, "local_final_malformed")
    }
    return CanonicalLocalFinal(canonical, null)
}

internal fun validLocalAnnouncementText(value: String): Boolean {
    if (value.isEmpty() || value.normalizeNfc() != value) return false
    return value.none { it == '\u0000' || Character.getType(it).toInt() == Character.CONTROL.toInt() }
}

internal fun sha256Hex(value: String): String =
    MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

private fun String.normalizeNfc(): String = Normalizer.normalize(this, Normalizer.Form.NFC)

private val OTHER_UNICODE_CATEGORIES =
    setOf(
        Character.CONTROL.toInt(),
        Character.FORMAT.toInt(),
        Character.PRIVATE_USE.toInt(),
        Character.SURROGATE.toInt(),
        Character.UNASSIGNED.toInt(),
    )

private fun Char.hasOtherUnicodeCategory(): Boolean = Character.getType(this) in OTHER_UNICODE_CATEGORIES

internal class LocalVoiceRuntime(
    private val scope: CoroutineScope,
    private val engine: LocalSpeechEngine,
    private val send: (String) -> Boolean,
    private val clock: () -> Instant,
    private val uuidFactory: () -> String = { UUID.randomUUID().toString() },
    private val onEvent: (LocalVoiceUiEvent) -> Unit,
) {
    private class Turn(
        val clientTurnId: String,
        val chatId: String,
        val chatContextRevision: Int,
        var recognitionSequence: Int? = null,
        var startedSent: Boolean = false,
        var bound: Boolean = false,
        var bindingExpiry: Instant? = null,
        var bindingTurnId: String? = null,
        var bindingSubmissionId: String? = null,
        var bindingRequestGeneration: String? = null,
        var finalValue: String? = null,
        var finalSent: Boolean = false,
        var failureReason: String? = null,
        var failureSent: Boolean = false,
        var cancelled: Boolean = false,
    )

    private class PendingFinal(
        val frameJson: String,
        val identifiers: JsonObject,
        var expiresAt: Instant,
    )

    private class PendingFailure(
        val clientTurnId: String,
        val chatId: String,
        val chatContextRevision: Int,
        val recognitionSequence: Int,
        val reason: String,
        var binding: JsonObject? = null,
        val expiresAt: Instant,
        var expiryJob: Job? = null,
    )

    private class ActiveAnnouncement(
        val payload: JsonObject,
        var started: Boolean = false,
        var terminal: Boolean = false,
        var expiryJob: Job? = null,
    )

    private var session: LocalVoiceSession? = null
    private var requirements: LocalVoiceRequirements? = null
    private var capability: LocalSpeechCapability? = null
    private var ending = false

    private var readyPending = false
    private var readyAuthorized = false
    private var stopResetPending = false
    private var stopInFlight = false

    private var clientSequence = 0
    private var recognitionSequence = 0
    private var recognitionEpoch = 0
    private var turn: Turn? = null
    private var pendingFinal: PendingFinal? = null
    private val pendingFailures = mutableListOf<PendingFailure>()
    private var announcementSequence = 0
    private var lastMuteRevision = 0
    private var lastConsentRevision = 0
    private var activeAnnouncement: ActiveAnnouncement? = null
    private val announcementQueue = ArrayDeque<JsonObject>()
    private var echoUntilMillis = 0L

    private var bindingJob: Job? = null
    private var echoJob: Job? = null
    private var finalRetryJob: Job? = null

    fun start(
        value: LocalVoiceSession,
        voiceRequirements: LocalVoiceRequirements,
        speechCapability: LocalSpeechCapability,
    ) {
        session = value
        requirements = voiceRequirements
        capability = speechCapability
        ending = false
        readyPending = false
        readyAuthorized = false
        stopResetPending = false
        stopInFlight = false
        clientSequence = 0
        recognitionSequence = 0
        recognitionEpoch++
        turn = null
        pendingFailures.clear()
        announcementSequence = 0
        lastMuteRevision = 0
        lastConsentRevision = 0
        activeAnnouncement = null
        announcementQueue.clear()
        echoUntilMillis = 0
        onEvent(
            LocalVoiceUiEvent(
                phase = "connecting",
                reason = "client_readiness_required",
                message = "Local speech is ready. Securing this conversation…",
            ),
        )
        sendReady()
    }

    fun acceptFrame(frame: LocalVoiceFrame): Boolean {
        if (session == null || ending) return false
        if (!authorityMatches(frame.payload)) return false
        return when (frame.disposition) {
            LocalVoiceDisposition.READY ->
                when (frame.type) {
                    "voice_local_session_ready" -> acceptSessionReady(frame.payload)
                    "voice_local_turn_bound" -> acceptTurnBound(frame.payload)
                    else -> false
                }
            LocalVoiceDisposition.REJECTED ->
                if (frame.type == "voice_local_final_rejected") acceptFinalRejected(frame.payload) else false
            LocalVoiceDisposition.SPEAKING ->
                if (frame.type == "voice_local_announcement") acceptAnnouncement(frame.payload) else false
            else -> false
        }
    }

    fun acceptMessageAck(value: Inbound.UserMessageAcked): Boolean {
        val current = session ?: return false
        val pending = pendingFinal ?: return false
        if (
            value.submissionId != pending.identifiers.string("submission_id") ||
            value.chatId != pending.identifiers.string("chat_id") ||
            value.requestGeneration != pending.identifiers.string("request_generation") ||
            value.connectionGeneration != current.connectionGeneration ||
            value.voiceTurnId != pending.identifiers.string("turn_id")
        ) {
            return false
        }
        clearPendingFinal()
        onEvent(LocalVoiceUiEvent(accepted = true))
        scheduleRecognition()
        return true
    }

    fun suspendForBackground() {
        stopOwners("local_recognition_cancelled")
    }

    suspend fun resumeForeground(): Boolean {
        val current = session ?: return false
        if (ending || !current.foregroundActive) return false
        val verdict = LocalSpeechReadiness.evaluate(engine.probe())
        val next = verdict.capability
        if (!verdict.eligible || next == null) {
            onEvent(LocalVoiceUiEvent(unavailable = true, reason = verdict.reason))
            return false
        }
        capability = next
        return sendReady()
    }

    fun reconcileAfterControlChange() {
        val current = session ?: return
        if (ending) return
        if (!current.foregroundActive || !current.microphoneEnabled || current.speechMuted) {
            stopOwners(
                when {
                    current.speechMuted -> "stopped_by_user"
                    else -> "local_audio_interrupted"
                },
            )
            return
        }
        if (readyAuthorized) {
            scheduleRecognition()
        } else {
            sendReady()
        }
    }

    fun stopSpeech() {
        stopOwners("stopped_by_user")
        stopResetPending = true
        stopInFlight = true
    }

    fun speechStopped() {
        stopInFlight = false
    }

    fun chatTransition() {
        stopOwners("local_recognition_cancelled")
    }

    fun updateAuthority(value: LocalVoiceSession) {
        session = value
    }

    fun teardown(clearSession: Boolean) {
        ending = clearSession
        stopOwners("local_recognition_cancelled")
        if (clearSession) {
            clearPendingFinal()
            pendingFailures.clear()
            session = null
            requirements = null
            capability = null
            clientSequence = 0
            announcementSequence = 0
            lastMuteRevision = 0
            lastConsentRevision = 0
            stopResetPending = false
            stopInFlight = false
        }
    }

    fun close() {
        teardown(true)
        bindingJob?.cancel()
        echoJob?.cancel()
        finalRetryJob?.cancel()
    }

    private fun authorityMatches(payload: JsonObject): Boolean {
        val current = session ?: return false
        return payload.string("device_id") == current.deviceId &&
            payload.string("connection_generation") == current.connectionGeneration &&
            payload.string("session_id") == current.sessionId &&
            payload.int("generation") == current.generation &&
            payload.int("speech_revision") == current.speechRevision
    }

    private fun acceptSessionReady(payload: JsonObject): Boolean {
        val current = session ?: return false
        val lease = payload.string("lease_expires_at")?.let(::parseInstant) ?: return false
        if (
            !readyPending ||
            stopInFlight ||
            payload.string("contract") != "client_local/v1" ||
            payload.string("transport") != "client_local" ||
            payload.string("configured_locale") != "en-US" ||
            payload.string("chat_id") != current.chatId ||
            payload.int("chat_context_revision") != current.chatContextRevision ||
            payload.int("applied_chat_context_revision") != payload.int("chat_context_revision") ||
            payload.bool("foreground_active") != true ||
            payload.bool("microphone_enabled") != true ||
            payload.bool("speech_muted") != false ||
            !current.foregroundActive ||
            !current.microphoneEnabled ||
            current.speechMuted ||
            !lease.isAfter(clock())
        ) {
            return false
        }
        readyPending = false
        readyAuthorized = true
        if (stopResetPending) {
            announcementSequence = 0
            lastMuteRevision = 0
            lastConsentRevision = 0
            stopResetPending = false
        }
        onEvent(LocalVoiceUiEvent(phase = "listening", reason = "ready"))
        scheduleRecognition()
        return true
    }

    private fun acceptTurnBound(payload: JsonObject): Boolean {
        val current = session ?: return false
        val expiry = payload.string("binding_expires_at")?.let(::parseInstant) ?: return false
        val now = clock()
        if (
            !expiry.isAfter(now) ||
            expiry.toEpochMilli() - now.toEpochMilli() > TURN_BINDING_TIMEOUT_MILLIS + 1_000
        ) {
            return false
        }
        val active = turn
        if (
            active != null &&
            !active.bound &&
            payload.string("client_turn_id") == active.clientTurnId &&
            payload.int("recognition_sequence") == active.recognitionSequence &&
            payload.string("chat_id") == active.chatId &&
            payload.int("chat_context_revision") == active.chatContextRevision
        ) {
            active.bound = true
            active.bindingExpiry = expiry
            active.bindingTurnId = payload.string("turn_id")
            active.bindingSubmissionId = payload.string("submission_id")
            active.bindingRequestGeneration = payload.string("request_generation")
            bindingJob?.cancel()
            bindingJob = null
            val failure = active.failureReason
            if (failure != null) {
                sendRecognitionFailure(active, failure)
                finishTurnWithoutReport(active)
                scheduleRecognition()
            } else if (active.finalValue != null) {
                sendFinal(active)
            }
            return true
        }
        prunePendingFailures()
        val retained = pendingFailures.firstOrNull { candidate ->
            candidate.binding == null &&
                payload.string("client_turn_id") == candidate.clientTurnId &&
                payload.int("recognition_sequence") == candidate.recognitionSequence &&
                payload.string("chat_id") == candidate.chatId &&
                payload.int("chat_context_revision") == candidate.chatContextRevision &&
                candidate.expiresAt.isAfter(now)
        }
        if (retained == null) return false
        retained.binding = payload
        retained.expiryJob?.cancel()
        sendRetainedFailure(retained)
        return true
    }

    private fun acceptFinalRejected(payload: JsonObject): Boolean {
        val pending = pendingFinal ?: return false
        if (pending.identifiers.any { (key, value) -> payload[key] != value }) return false
        clearPendingFinal()
        onEvent(
            LocalVoiceUiEvent(
                phase = "error",
                reason = payload.string("reason"),
                message = "That spoken request was not accepted. You can try again or keep typing.",
            ),
        )
        scheduleRecognition()
        return true
    }

    private fun acceptAnnouncement(payload: JsonObject): Boolean {
        val current = session ?: return false
        val voiceRequirements = requirements ?: return false
        if (!readyAuthorized || stopInFlight || current.speechMuted || !current.foregroundActive || !current.microphoneEnabled) {
            return false
        }
        val text = payload.string("text") ?: return false
        if (!validLocalAnnouncementText(text) || sha256Hex(text) != payload.string("text_digest_sha256")) return false
        val expiresAt = payload.string("expires_at")?.let(::parseInstant) ?: return false
        val now = clock()
        if (!expiresAt.isAfter(now)) return false
        if (expiresAt.toEpochMilli() - now.toEpochMilli() > voiceRequirements.announcementTtlSeconds * 1_000L + 1_000) {
            return false
        }
        val sequence = payload.int("announcement_sequence") ?: return false
        if (sequence != announcementSequence + 1) return false
        if (payload.string("locale") != voiceRequirements.configuredLocale) return false
        if (payload.bool("foreground_required") != true) return false
        val muteRevision = payload.int("mute_revision") ?: return false
        val consentRevision = payload.int("consent_revision") ?: return false
        if (muteRevision < 1 || muteRevision < lastMuteRevision) return false
        if (consentRevision < 1 || consentRevision < lastConsentRevision) return false
        val kind = payload.string("kind") ?: return false
        val turnId = payload["turn_id"]
        if (if (kind == "greeting") turnId != JsonNull else !isUuid4(payload.string("turn_id"))) return false
        if (announcementQueue.size + (if (activeAnnouncement != null) 1 else 0) >= MAX_ANNOUNCEMENTS) return false
        announcementSequence = sequence
        lastMuteRevision = muteRevision
        lastConsentRevision = consentRevision
        announcementQueue.addLast(payload)
        if (activeAnnouncement == null) startNextAnnouncement()
        return true
    }

    private fun startNextAnnouncement() {
        if (activeAnnouncement != null || announcementQueue.isEmpty()) return
        val payload = announcementQueue.removeFirst()
        if (!announcementAuthorityCurrent(payload)) {
            val expiresAt = payload.string("expires_at")?.let(::parseInstant)
            if (expiresAt != null && !expiresAt.isAfter(clock())) {
                sendPlayoutEvent(payload, "failed", "local_announcement_expired")
            }
            if (announcementQueue.isNotEmpty()) {
                startNextAnnouncement()
            } else {
                settleAnnouncementQueue()
            }
            return
        }
        cancelRecognition("local_audio_interrupted")
        val active = ActiveAnnouncement(payload)
        activeAnnouncement = active
        val started =
            runCatching {
                engine.speak(
                    payload.string("text") ?: "",
                    payload.string("locale") ?: "en-US",
                    onStarted = {
                        if (active === activeAnnouncement && announcementAuthorityCurrent(payload)) {
                            if (!active.started) {
                                active.started = true
                                sendPlayoutEvent(payload, "started", null)
                                onEvent(
                                    LocalVoiceUiEvent(
                                        phase = if (payload.string("kind") == "greeting") "greeting" else "speaking_progress",
                                        reason = "ready",
                                    ),
                                )
                            }
                        } else if (active === activeAnnouncement) {
                            engine.stopAll()
                            finishAnnouncement(active, "failed", "local_audio_interrupted")
                        }
                    },
                    onDone = { success ->
                        if (active === activeAnnouncement) {
                            finishAnnouncement(
                                active,
                                if (success && active.started) "finished" else "failed",
                                if (success && active.started) null else "local_synthesis_failed",
                            )
                        }
                    },
                )
            }.getOrDefault(false)
        if (!started && !active.terminal) {
            finishAnnouncement(active, "failed", "local_synthesis_failed")
            return
        }
        val expiresAt = payload.string("expires_at")?.let(::parseInstant) ?: return
        val remaining = expiresAt.toEpochMilli() - clock().toEpochMilli()
        active.expiryJob =
            scope.launch {
                delay(remaining.coerceAtLeast(1))
                if (active === activeAnnouncement) {
                    engine.stopAll()
                    finishAnnouncement(active, "failed", "local_announcement_expired")
                }
            }
    }

    private fun finishAnnouncement(
        active: ActiveAnnouncement,
        phase: String,
        reason: String?,
    ) {
        if (active.terminal || activeAnnouncement !== active) return
        active.terminal = true
        active.expiryJob?.cancel()
        activeAnnouncement = null
        sendPlayoutEvent(active.payload, phase, reason)
        if (announcementQueue.isNotEmpty()) {
            startNextAnnouncement()
        } else {
            settleAnnouncementQueue()
        }
    }

    private fun settleAnnouncementQueue() {
        echoUntilMillis = clock().toEpochMilli() + (requirements?.echoSuppressionMilliseconds ?: DEFAULT_ECHO_SUPPRESSION_MILLIS)
        scheduleRecognition()
    }

    private fun announcementAuthorityCurrent(payload: JsonObject): Boolean {
        val current = session ?: return false
        val expiresAt = payload.string("expires_at")?.let(::parseInstant) ?: return false
        return authorityMatches(payload) &&
            readyAuthorized &&
            !stopInFlight &&
            current.foregroundActive &&
            current.microphoneEnabled &&
            !current.speechMuted &&
            payload.bool("foreground_required") == true &&
            payload.string("locale") == requirements?.configuredLocale &&
            expiresAt.isAfter(clock())
    }

    private fun sendPlayoutEvent(
        payload: JsonObject,
        phase: String,
        reason: String?,
    ) {
        val current = session ?: return
        val frame =
            buildJsonObject {
                common("voice_local_playout_event", current).forEach { (key, value) -> put(key, value) }
                put("announcement_id", payload.string("announcement_id"))
                put("announcement_sequence", payload.int("announcement_sequence"))
                put("turn_id", payload["turn_id"] ?: JsonNull)
                put("kind", payload.string("kind"))
                put("phase", phase)
                put("client_sequence", ++clientSequence)
                put("observed_at", clock().toString())
                if (reason != null) put("reason", reason)
            }
        send(frame.toString())
    }

    private fun scheduleRecognition() {
        if (!canRecognize()) return
        val remaining = echoUntilMillis - clock().toEpochMilli()
        if (remaining > 0) {
            val epoch = recognitionEpoch
            echoJob?.cancel()
            echoJob =
                scope.launch {
                    delay(remaining)
                    if (recognitionEpoch == epoch) scheduleRecognition()
                }
            return
        }
        startRecognitionCycle()
    }

    private fun canRecognize(): Boolean {
        val current = session ?: return false
        return !ending &&
            readyAuthorized &&
            !stopInFlight &&
            pendingFinal == null &&
            activeAnnouncement == null &&
            announcementQueue.isEmpty() &&
            turn == null &&
            current.foregroundActive &&
            current.microphoneEnabled &&
            !current.speechMuted
    }

    private fun startRecognitionCycle() {
        val current = session ?: return
        val epoch = recognitionEpoch
        val next =
            Turn(
                clientTurnId = uuidFactory().takeIf(::isUuid4) ?: return,
                chatId = current.chatId,
                chatContextRevision = current.chatContextRevision,
            )
        next.recognitionSequence = ++recognitionSequence
        turn = next
        val started =
            send(
                buildJsonObject {
                    common("voice_local_recognition_started", current).forEach { (key, value) -> put(key, value) }
                    put("client_turn_id", next.clientTurnId)
                    put("chat_id", next.chatId)
                    put("chat_context_revision", next.chatContextRevision)
                    put("recognition_sequence", next.recognitionSequence)
                }.toString(),
            )
        if (!started) {
            turn = null
            recognitionEpoch++
            readyAuthorized = false
            readyPending = false
            onEvent(LocalVoiceUiEvent(unavailable = true, reason = "local_recognition_unavailable"))
            return
        }
        next.startedSent = true
        bindingJob?.cancel()
        bindingJob =
            scope.launch {
                delay(TURN_BINDING_TIMEOUT_MILLIS)
                expireTurnBinding(epoch, next.clientTurnId)
            }
        val engineStarted =
            runCatching {
                engine.startRecognition(
                    onPartial = { partial ->
                        if (turn === next && !next.cancelled && !next.finalSent) {
                            onEvent(LocalVoiceUiEvent(transcriptPreview = "Hearing: $partial", transcriptFinal = false))
                        }
                    },
                    onFinal = { text -> onRecognizedFinal(next, text) },
                    onError = { reason -> onRecognitionError(next, reason) },
                )
            }.getOrDefault(false)
        if (!engineStarted) onRecognitionError(next, "local_recognition_unavailable")
    }

    private fun expireTurnBinding(
        epoch: Int,
        clientTurnId: String,
    ) {
        val active = turn ?: return
        if (recognitionEpoch != epoch || active.clientTurnId != clientTurnId || active.bound) return
        nextRecognitionEpoch()
        turn = null
        engine.stopRecognition()
        scheduleRecognition()
    }

    private fun onRecognizedFinal(
        active: Turn,
        text: String,
    ) {
        if (turn !== active || active.cancelled || active.finalSent || active.failureSent) return
        val voiceRequirements = requirements ?: return
        val canonical = canonicalizeLocalFinal(text, voiceRequirements.maxFinalUnicodeScalars)
        val reason = canonical.reason
        if (reason != null || canonical.text == null) {
            onRecognitionError(active, reason ?: "local_final_malformed")
            return
        }
        active.finalValue = canonical.text
        onEvent(LocalVoiceUiEvent(transcriptPreview = "Heard: ${canonical.text}", transcriptFinal = true))
        if (active.bound) sendFinal(active)
    }

    private fun onRecognitionError(
        active: Turn,
        reason: String,
    ) {
        if (turn !== active || active.cancelled || active.finalSent || active.failureSent) return
        val canonicalReason =
            if (reason in RECOGNITION_FAILURE_REASONS) reason else "local_recognition_failed"
        nextRecognitionEpoch()
        active.failureReason = canonicalReason
        turn = null
        if (active.bound) {
            sendRecognitionFailure(active, canonicalReason)
        } else {
            retainFailure(active, canonicalReason)
        }
        engine.stopRecognition()
        onEvent(LocalVoiceUiEvent(phase = "error", reason = canonicalReason))
        scheduleRecognition()
    }

    private fun sendFinal(active: Turn) {
        val current = session ?: return
        val text = active.finalValue ?: return
        val expiry = active.bindingExpiry ?: return
        if (!expiry.isAfter(clock())) return
        val frame =
            buildJsonObject {
                common("voice_local_final", current).forEach { (key, value) -> put(key, value) }
                put("client_turn_id", active.clientTurnId)
                put("turn_id", active.bindingTurnId)
                put("submission_id", active.bindingSubmissionId)
                put("request_generation", active.bindingRequestGeneration)
                put("chat_id", active.chatId)
                put("chat_context_revision", active.chatContextRevision)
                put("recognition_sequence", active.recognitionSequence)
                put("final", true)
                put("recognized_locale", requirements?.configuredLocale ?: "en-US")
                put("text", text)
                put("text_digest_sha256", sha256Hex(text))
            }
        val pending =
            PendingFinal(
                frameJson = frame.toString(),
                identifiers =
                    buildJsonObject {
                        put("device_id", current.deviceId)
                        put("connection_generation", current.connectionGeneration)
                        put("session_id", current.sessionId)
                        put("generation", current.generation)
                        put("speech_revision", current.speechRevision)
                        put("client_turn_id", active.clientTurnId)
                        put("turn_id", active.bindingTurnId)
                        put("submission_id", active.bindingSubmissionId)
                        put("request_generation", active.bindingRequestGeneration)
                        put("chat_id", active.chatId)
                        put("chat_context_revision", active.chatContextRevision)
                        put("recognition_sequence", active.recognitionSequence)
                    },
                expiresAt = minOf(expiry, clock().plusMillis(FINAL_ACK_TIMEOUT_MILLIS)),
            )
        active.finalSent = true
        turn = null
        engine.stopRecognition()
        pendingFinal = pending
        send(pending.frameJson)
        armFinalRetry(pending)
    }

    private fun armFinalRetry(pending: PendingFinal) {
        finalRetryJob?.cancel()
        finalRetryJob =
            scope.launch {
                while (pendingFinal === pending) {
                    delay(FINAL_RETRY_MILLIS)
                    if (pendingFinal !== pending) return@launch
                    if (pending.expiresAt <= clock()) {
                        failPendingFinal(pending)
                        return@launch
                    }
                    send(pending.frameJson)
                }
            }
    }

    private fun failPendingFinal(pending: PendingFinal) {
        if (pendingFinal !== pending) return
        clearPendingFinal()
        onEvent(
            LocalVoiceUiEvent(
                unavailable = true,
                reason = "stale_local_turn",
                message = "Voice stopped because request acceptance could not be confirmed. Typed chat remains available.",
                unrecoverable = true,
            ),
        )
    }

    private fun clearPendingFinal() {
        finalRetryJob?.cancel()
        finalRetryJob = null
        pendingFinal = null
    }

    private fun sendRecognitionFailure(
        active: Turn,
        reason: String,
    ): Boolean {
        val expiry = active.bindingExpiry ?: return false
        if (active.finalSent || active.failureSent || !expiry.isAfter(clock())) return false
        active.failureSent = true
        return send(
            buildJsonObject {
                common("voice_local_recognition_failed", session ?: return false).forEach { (key, value) -> put(key, value) }
                put("client_turn_id", active.clientTurnId)
                put("turn_id", active.bindingTurnId)
                put("submission_id", active.bindingSubmissionId)
                put("request_generation", active.bindingRequestGeneration)
                put("chat_id", active.chatId)
                put("chat_context_revision", active.chatContextRevision)
                put("recognition_sequence", active.recognitionSequence)
                put("reason", canonicalFailureReason(reason))
            }.toString(),
        )
    }

    private fun sendRetainedFailure(entry: PendingFailure): Boolean {
        val binding = entry.binding ?: return false
        val expiry = binding.string("binding_expires_at")?.let(::parseInstant) ?: return false
        if (!expiry.isAfter(clock())) return false
        val sent =
            send(
                buildJsonObject {
                    common("voice_local_recognition_failed", session ?: return false).forEach { (key, value) -> put(key, value) }
                    put("client_turn_id", entry.clientTurnId)
                    put("turn_id", binding.string("turn_id"))
                    put("submission_id", binding.string("submission_id"))
                    put("request_generation", binding.string("request_generation"))
                    put("chat_id", entry.chatId)
                    put("chat_context_revision", entry.chatContextRevision)
                    put("recognition_sequence", entry.recognitionSequence)
                    put("reason", canonicalFailureReason(entry.reason))
                }.toString(),
            )
        if (sent) {
            pendingFailures.remove(entry)
            scheduleRecognition()
        }
        return sent
    }

    private fun retainFailure(
        active: Turn,
        reason: String,
    ) {
        if (!active.startedSent || active.recognitionSequence == null) return
        prunePendingFailures()
        while (pendingFailures.size >= MAX_PENDING_FAILURES) pendingFailures.removeAt(0)
        val entry =
            PendingFailure(
                clientTurnId = active.clientTurnId,
                chatId = active.chatId,
                chatContextRevision = active.chatContextRevision,
                recognitionSequence = requireNotNull(active.recognitionSequence),
                reason = canonicalFailureReason(reason),
                expiresAt = clock().plusMillis(TURN_BINDING_TIMEOUT_MILLIS),
            )
        entry.expiryJob =
            scope.launch {
                delay(TURN_BINDING_TIMEOUT_MILLIS)
                if (pendingFailures.remove(entry) && turn == null) scheduleRecognition()
            }
        pendingFailures.add(entry)
    }

    private fun prunePendingFailures() {
        val now = clock()
        pendingFailures.removeAll { entry ->
            val stale = !entry.expiresAt.isAfter(now) || !authorityStillCurrent()
            if (stale) entry.expiryJob?.cancel()
            stale
        }
    }

    private fun authorityStillCurrent(): Boolean = session != null && !ending

    private fun cancelRecognition(reason: String) {
        val active = turn ?: return
        active.cancelled = true
        if (active.startedSent && !active.finalSent && !active.failureSent) {
            if (active.bound) {
                sendRecognitionFailure(active, reason)
                finishTurnWithoutReport(active)
            } else {
                retainFailure(active, reason)
            }
        }
        turn = null
        engine.stopRecognition()
    }

    private fun finishTurnWithoutReport(active: Turn) {
        turn = null
        engine.stopRecognition()
    }

    fun stopOwners(reason: String) {
        readyAuthorized = false
        readyPending = false
        cancelPlayout(reason)
        nextRecognitionEpoch()
        cancelRecognition(reason)
        engine.stopAll()
    }

    private fun cancelPlayout(reason: String) {
        val playoutReason = if (reason == "stopped_by_user") "stopped_by_user" else "local_audio_interrupted"
        activeAnnouncement?.let { active ->
            if (!active.terminal) {
                active.terminal = true
                active.expiryJob?.cancel()
                sendPlayoutEvent(active.payload, if (active.started) "interrupted" else "failed", playoutReason)
            }
        }
        activeAnnouncement = null
        val queued = announcementQueue.toList()
        announcementQueue.clear()
        queued.forEach { payload -> sendPlayoutEvent(payload, "failed", playoutReason) }
        echoUntilMillis = clock().toEpochMilli() + (requirements?.echoSuppressionMilliseconds ?: DEFAULT_ECHO_SUPPRESSION_MILLIS)
    }

    private fun nextRecognitionEpoch() {
        recognitionEpoch++
        bindingJob?.cancel()
        bindingJob = null
    }

    private fun sendReady(): Boolean {
        val current = session ?: return false
        val speechCapability = capability
        if (
            ending ||
            !current.foregroundActive ||
            !current.microphoneEnabled ||
            current.speechMuted ||
            speechCapability == null
        ) {
            readyPending = false
            readyAuthorized = false
            return false
        }
        if (readyPending) return true
        val frame =
            buildJsonObject {
                common("voice_local_ready", current).forEach { (key, value) -> put(key, value) }
                speechCapability.toJson().forEach { (key, value) -> put(key, value) }
                put("client_sequence", ++clientSequence)
            }
        readyPending = true
        if (!send(frame.toString())) {
            readyPending = false
            readyAuthorized = false
            onEvent(LocalVoiceUiEvent(phase = "error", reason = "local_session_not_ready"))
            return false
        }
        return true
    }

    private fun common(
        type: String,
        current: LocalVoiceSession,
    ): JsonObject {
        return buildJsonObject {
            put("type", type)
            put("schema_version", "2")
            put("speech_backend", "client_local")
            put("device_id", current.deviceId)
            put("connection_generation", current.connectionGeneration)
            put("session_id", current.sessionId)
            put("generation", current.generation)
            put("speech_revision", current.speechRevision)
        }
    }

    private fun canonicalFailureReason(reason: String): String =
        if (reason in RECOGNITION_FAILURE_REASONS) reason else "local_recognition_failed"

    private fun parseInstant(value: String): Instant? = runCatching { Instant.parse(value) }.getOrNull()

    private fun isUuid4(value: String?): Boolean {
        val parsed = value?.let { runCatching { UUID.fromString(it) }.getOrNull() } ?: return false
        return parsed.version() == 4 && parsed.toString() == value
    }

    companion object {
        private const val TURN_BINDING_TIMEOUT_MILLIS = 120_000L
        private const val FINAL_RETRY_MILLIS = 2_500L
        private const val FINAL_ACK_TIMEOUT_MILLIS = 120_000L
        private const val MAX_PENDING_FAILURES = 4
        private const val MAX_ANNOUNCEMENTS = 8
        private const val DEFAULT_ECHO_SUPPRESSION_MILLIS = 500L
        private val RECOGNITION_FAILURE_REASONS =
            setOf(
                "local_recognition_unavailable",
                "local_recognition_failed",
                "local_recognition_cancelled",
                "local_audio_interrupted",
                "local_engine_lost",
                "local_final_empty",
                "local_final_oversized",
                "local_final_malformed",
                "stopped_by_user",
            )
    }
}
