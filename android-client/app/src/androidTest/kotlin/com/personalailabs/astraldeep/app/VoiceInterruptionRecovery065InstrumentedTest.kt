// Bounded deterministic voice conversation scenario for the real Android session controller: media
// interruption through server-owned reconnecting state, recovery, exactly one accepted transcript turn
// with fenced stale replays, resumed post-recovery playout, and rendered composer/feedback assertions.

package com.personalailabs.astraldeep.app

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.personalailabs.astraldeep.app.ui.ConsoleComposer
import com.personalailabs.astraldeep.app.ui.VoiceFeedback
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.voice.LiveKitVoiceGrant
import com.personalailabs.astraldeep.app.voice.VOICE_ANNOUNCEMENT_TOPIC
import com.personalailabs.astraldeep.app.voice.VOICE_TRANSCRIPT_TOPIC
import com.personalailabs.astraldeep.app.voice.VoiceControlApi
import com.personalailabs.astraldeep.app.voice.VoiceMediaCapability
import com.personalailabs.astraldeep.app.voice.VoiceMediaClient
import com.personalailabs.astraldeep.app.voice.VoiceMediaEvent
import com.personalailabs.astraldeep.app.voice.VoicePlayoutEvent
import com.personalailabs.astraldeep.app.voice.VoiceRestSession
import com.personalailabs.astraldeep.app.voice.VoiceSessionController
import com.personalailabs.astraldeep.app.voice.VoiceStartOutcome
import com.personalailabs.astraldeep.app.voice.VoiceTakeoverTarget
import com.personalailabs.astraldeep.app.voice.VoiceUiBinding
import com.personalailabs.astraldeep.core.chrome.ChromeMenuModel
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.VoiceAnnouncementMedia
import com.personalailabs.astraldeep.core.protocol.VoiceComposerModel
import com.personalailabs.astraldeep.core.protocol.VoiceControl
import com.personalailabs.astraldeep.core.protocol.VoiceControlBinding
import com.personalailabs.astraldeep.core.protocol.VoiceOwnerDevice
import com.personalailabs.astraldeep.core.protocol.VoiceSessionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Instant

@RunWith(AndroidJUnit4::class)
class VoiceInterruptionRecovery065InstrumentedTest {
    @get:Rule val rule = createComposeRule()

    private val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
    private val console = requireNotNull(
        ChromeMenuModel.fromJson(
            Json.parseToJsonElement(
                instrumentation.context.assets.open("console/chrome-console.json").bufferedReader().use { it.readText() },
            ).jsonObject,
        ),
    )

    @Test
    fun interruptionRecoversIntoExactlyOneAcceptedTurnWithFencedStaleReplaysAndResumedPlayout() {
        val api = RecordingVoiceApi()
        val media = RecordingVoiceMedia()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val controller = VoiceSessionController(
            api = api,
            media = media,
            scope = scope,
            uuidFactory = { ACTIVATION_ID },
            clock = { FIXED_NOW },
            retryDelayMillis = 3_600_000L,
        )
        val submissions = mutableListOf<Pair<String, String>>()
        controller.setTranscriptSubmitter { transcript, connection ->
            submissions += transcript.submissionId to connection
            true
        }
        val playoutEvents = mutableListOf<Pair<String, String>>()
        controller.setPlayoutReporter { event: VoicePlayoutEvent ->
            playoutEvents += event.kind to event.phase
            true
        }
        controller.installUiConnection("user-token", DEVICE_ID, CONNECTION_ID, CHAT_ID)
        controller.consumeBinding(
            VoiceControlBinding(DEVICE_ID, CONNECTION_ID, BINDING_ID, BINDING_VALUE, "2099-07-31T12:10:00Z"),
        )

        var draft by mutableStateOf("")
        rule.setContent {
            AstralTheme {
                val voice by controller.state.collectAsState()
                Column {
                    VoiceFeedback(voice)
                    ConsoleComposer(
                        draft, { draft = it }, false, voice,
                        { }, { }, { }, draft.isNotBlank(), console, false, { },
                    )
                }
            }
        }
        rule.waitForIdle()

        rule.runOnIdle {
            controller.consumeComposer(Inbound.ComposerState(1, CONNECTION_ID, activeComposer()))
            scope.launch { controller.activate(VoiceMediaCapability(true, true, "authorized", true)) }
        }
        rule.waitForIdle()
        assertEquals("greeting", controller.state.value.phase)
        assertTrue(controller.state.value.mediaConnected)
        rule.onNodeWithTag("voice-control-voice_session_end").assertIsDisplayed().assertIsEnabled()
        rule.onNodeWithTag("chat-input").assertIsEnabled()

        rule.runOnIdle { media.emit(greetingData()) }
        rule.waitForIdle()
        rule.runOnIdle { media.emit(VoiceMediaEvent.Playout(ANNOUNCEMENT_ID, 1, "started")) }
        rule.waitForIdle()
        assertEquals("speaking_progress", controller.state.value.phase)
        rule.onNodeWithText("Speaking a progress update…").assertIsDisplayed()

        rule.runOnIdle {
            controller.handleInbound(
                Inbound.VoiceSessionStateFrame(sessionState(state = "reconnecting", reason = "network_interrupted")),
            )
        }
        rule.waitForIdle()
        assertEquals("reconnecting", controller.state.value.phase)
        assertEquals("network_interrupted", controller.state.value.reason)
        assertFalse(controller.state.value.mediaConnected)
        rule.onNodeWithTag("voice-feedback")
            .assertIsDisplayed()
            .assertTextContains("Voice connection was interrupted. Typed chat is still available.")
        rule.onNodeWithTag("chat-input").assertIsEnabled()
        rule.onNodeWithTag("chat-input").performTextInput("typed fallback during interruption")
        rule.onNodeWithTag("voice-control-voice_session_end").assertIsEnabled()

        rule.runOnIdle {
            controller.handleInbound(
                Inbound.VoiceSessionStateFrame(sessionState(state = "listening", reason = "ready")),
            )
        }
        rule.waitForIdle()
        assertEquals("greeting", controller.state.value.phase)
        assertTrue(controller.state.value.mediaConnected)

        rule.runOnIdle { media.emit(transcriptData(final = true, sequence = 1)) }
        rule.waitForIdle()
        assertEquals("acknowledging", controller.state.value.phase)
        assertEquals(1, controller.state.value.awaitingAcceptance)
        rule.onNodeWithTag("voice-feedback").assertTextContains("Heard: check my schedule")
        assertEquals(listOf(SUBMISSION_ID to CONNECTION_ID), submissions)

        rule.runOnIdle {
            controller.handleInbound(acked(connectionGeneration = OTHER_CONNECTION_ID))
        }
        rule.waitForIdle()
        assertEquals(1, controller.state.value.awaitingAcceptance)
        rule.runOnIdle { media.emit(transcriptData(final = true, sequence = 1)) }
        rule.waitForIdle()
        assertEquals(1, submissions.size)

        rule.runOnIdle { controller.handleInbound(acked(connectionGeneration = CONNECTION_ID)) }
        rule.waitForIdle()
        assertEquals("processing", controller.state.value.phase)
        assertEquals(0, controller.state.value.awaitingAcceptance)
        assertEquals("On it!", controller.state.value.message)
        rule.onNodeWithTag("voice-feedback").assertTextContains("Heard: check my schedule")
        rule.onNodeWithTag("chat-input").assertIsEnabled()

        rule.runOnIdle { media.emit(resultData()) }
        rule.waitForIdle()
        rule.runOnIdle { media.emit(VoiceMediaEvent.Playout(RESULT_ANNOUNCEMENT_ID, 2, "started")) }
        rule.waitForIdle()
        assertEquals("speaking_result", controller.state.value.phase)
        assertEquals("Speaking the completed result…", controller.state.value.message)
        rule.onNodeWithTag("voice-feedback").assertTextContains("Heard: check my schedule")

        rule.runOnIdle {
            media.emit(greetingData())
            media.emit(transcriptData(final = true, sequence = 1))
        }
        rule.waitForIdle()
        assertEquals(1, submissions.size)
        assertEquals(1, controller.state.value.awaitingAcceptance)
        assertEquals(2, media.announcements.size)
        assertEquals(listOf("greeting" to "started", "result" to "started"), playoutEvents)
        controller.close()
    }

    private fun greetingData(): VoiceMediaEvent.Data =
        VoiceMediaEvent.Data(
            VOICE_ANNOUNCEMENT_TOPIC,
            WORKER,
            announcement(
                announcementId = ANNOUNCEMENT_ID,
                announcementSequence = 1,
                kind = "greeting",
                turnId = null,
                quantumRole = "single",
                durationSamples = 12_000,
            ).toByteArray(),
        )

    private fun resultData(): VoiceMediaEvent.Data =
        VoiceMediaEvent.Data(
            VOICE_ANNOUNCEMENT_TOPIC,
            WORKER,
            announcement(
                announcementId = RESULT_ANNOUNCEMENT_ID,
                announcementSequence = 2,
                kind = "result",
                turnId = TURN_ID,
                quantumRole = "result_opening",
                durationSamples = 12_000,
                reservedSamples = 36_000,
            ).toByteArray(),
        )

    private fun transcriptData(final: Boolean, sequence: Int): VoiceMediaEvent.Data =
        VoiceMediaEvent.Data(
            VOICE_TRANSCRIPT_TOPIC,
            WORKER,
            transcript(final, sequence).toByteArray(),
        )

    private fun acked(connectionGeneration: String) =
        Inbound.UserMessageAcked(
            chatId = CHAT_ID,
            messageId = "42",
            submissionId = SUBMISSION_ID,
            requestGeneration = REQUEST_ID,
            connectionGeneration = connectionGeneration,
            voiceTurnId = TURN_ID,
        )

    private fun activeComposer() =
        VoiceComposerModel(
            available = true,
            state = "listening",
            speechMuted = false,
            microphoneEnabled = true,
            foregroundActive = true,
            reason = "ready",
            outputLocale = "en-US",
            message = null,
            chatContextRevision = 1,
            appliedChatContextRevision = 1,
            chatContextSynced = true,
            sessionId = SESSION_ID,
            generation = 1,
            mediaGrantRevision = 1,
            visibleChatId = CHAT_ID,
            foregroundTurnId = null,
            ownerDevice = VoiceOwnerDevice(DEVICE_ID, "android", null, 1),
            idleExpiresAt = null,
            controls =
                listOf(
                    VoiceControl(
                        "voice-end", "voice_session_end", "End voice conversation", "stop",
                        true, true, false, false,
                    ),
                ),
        )

    private fun sessionState(state: String, reason: String) =
        VoiceSessionState(
            sessionId = SESSION_ID,
            connectionGeneration = CONNECTION_ID,
            generation = 1,
            mediaGrantRevision = 1,
            visibleChatId = CHAT_ID,
            chatContextRevision = 1,
            appliedChatContextRevision = 1,
            chatContextSynced = true,
            state = state,
            speechMuted = false,
            microphoneEnabled = true,
            foregroundActive = true,
            reason = reason,
            message = null,
            occurredAt = "2099-07-31T12:00:00Z",
        )

    private class RecordingVoiceApi : VoiceControlApi {
        var startCalls = 0

        override suspend fun start(
            binding: VoiceUiBinding,
            activationId: String,
            capability: VoiceMediaCapability,
        ): VoiceStartOutcome {
            startCalls += 1
            return VoiceStartOutcome.Started(session(), grant())
        }

        override suspend fun takeover(
            binding: VoiceUiBinding,
            activationId: String,
            target: VoiceTakeoverTarget,
            capability: VoiceMediaCapability,
        ): VoiceStartOutcome = VoiceStartOutcome.Failed("takeover_required", null)

        override suspend fun update(
            binding: VoiceUiBinding,
            session: VoiceRestSession,
            fields: JsonObject,
        ): Result<VoiceRestSession> =
            Result.success(
                session.copy(
                    microphoneEnabled = fields["microphone_enabled"]?.jsonPrimitive?.booleanOrNull ?: session.microphoneEnabled,
                    speechMuted = fields["speech_muted"]?.jsonPrimitive?.booleanOrNull ?: session.speechMuted,
                    visibleChatId = fields["visible_chat_id"]?.jsonPrimitive?.contentOrNull ?: session.visibleChatId,
                    foregroundActive = fields["foreground_active"]?.jsonPrimitive?.booleanOrNull ?: session.foregroundActive,
                ),
            )

        override suspend fun stopSpeech(
            binding: VoiceUiBinding,
            session: VoiceRestSession,
        ): Boolean = true

        override suspend fun end(
            binding: VoiceUiBinding,
            session: VoiceRestSession,
        ): Boolean = true

        private fun session() =
            VoiceRestSession(
                sessionId = SESSION_ID,
                deviceId = DEVICE_ID,
                ownerConnectionGeneration = CONNECTION_ID,
                visibleChatId = CHAT_ID,
                appliedVisibleChatId = CHAT_ID,
                generation = 1,
                mediaGrantRevision = 1,
                chatContextRevision = 1,
                appliedChatContextRevision = 1,
                chatContextSynced = true,
                state = "active",
                foregroundActive = true,
                speechMuted = false,
                microphoneEnabled = true,
            )

        private fun grant() =
            LiveKitVoiceGrant(
                grantId = "grant-a",
                sessionId = SESSION_ID,
                generation = 1,
                mediaGrantRevision = 1,
                expiresAt = "2099-07-31T12:10:00Z",
                url = "wss://voice.example.test",
                joinToken = "synthetic-client-token-000000000000000000000000",
                roomName = "voice-room-a",
                participantIdentity = "voice-client-a",
                workerIdentity = WORKER,
            )
    }

    private class RecordingVoiceMedia : VoiceMediaClient {
        private val flow = MutableSharedFlow<VoiceMediaEvent>(replay = 16, extraBufferCapacity = 16)
        override val events: Flow<VoiceMediaEvent> = flow
        val announcements = mutableListOf<VoiceAnnouncementMedia>()
        var acceptAnnouncements = true

        override suspend fun connect(grant: LiveKitVoiceGrant) = Unit

        override suspend fun setMicrophoneEnabled(enabled: Boolean) = Unit

        override suspend fun queueAnnouncement(value: VoiceAnnouncementMedia): Boolean {
            if (acceptAnnouncements) announcements += value
            return acceptAnnouncements
        }

        override fun interruptPlayout() = Unit

        override fun disconnect() = Unit

        fun emit(event: VoiceMediaEvent) {
            check(flow.tryEmit(event))
        }
    }

    private companion object {
        const val DEVICE_ID = "00000000-0000-4000-8000-000000000001"
        const val CONNECTION_ID = "00000000-0000-4000-8000-000000000002"
        const val OTHER_CONNECTION_ID = "00000000-0000-4000-8000-000000000012"
        const val SESSION_ID = "00000000-0000-4000-8000-000000000003"
        const val CHAT_ID = "00000000-0000-4000-8000-000000000004"
        const val TURN_ID = "00000000-0000-4000-8000-000000000005"
        const val SUBMISSION_ID = "00000000-0000-4000-8000-000000000007"
        const val REQUEST_ID = "00000000-0000-4000-8000-000000000008"
        const val ANNOUNCEMENT_ID = "00000000-0000-4000-8000-000000000009"
        const val RESULT_ANNOUNCEMENT_ID = "00000000-0000-4000-8000-000000000019"
        const val BINDING_ID = "00000000-0000-4000-8000-00000000000a"
        const val BINDING_VALUE = "synthetic-binding-value-000000000000"
        const val ACTIVATION_ID = "00000000-0000-4000-8000-00000000000b"
        const val WORKER = "voice-worker-a"
        val FIXED_NOW: Instant = Instant.parse("2026-07-31T12:00:00Z")

        private fun announcement(
            announcementId: String,
            announcementSequence: Int,
            kind: String,
            turnId: String?,
            quantumRole: String,
            durationSamples: Int,
            reservedSamples: Int = 36_000,
        ): String =
            """
            {
              "type":"voice_announcement_media",
              "schema_version":"1",
              "session_id":"$SESSION_ID",
              "generation":1,
              "media_grant_revision":1,
              "announcement_id":"$announcementId",
              "announcement_sequence":$announcementSequence,
              "turn_id":${turnId?.let { "\"$it\"" } ?: "null"},
              "kind":"$kind",
              "quantum_role":"$quantumRole",
              "quantum_index":0,
              "transport":"livekit",
              "worker_identity":"$WORKER",
              "sample_rate_hz":24000,
              "duration_samples":$durationSamples,
              ${if (kind == "result") "\"result_reserved_samples_after\":$reservedSamples," else ""}
              "track_sid":"TR_audio_1",
              "track_name":"announcement-1"
            }
            """.trimIndent()

        private fun transcript(final: Boolean, sequence: Int): String =
            """
            {
              "type":"voice_transcript",
              "schema_version":"1",
              "session_id":"$SESSION_ID",
              "generation":1,
              "turn_id":"$TURN_ID",
              "client_turn_id":"00000000-0000-4000-8000-000000000006",
              "submission_id":"$SUBMISSION_ID",
              "request_generation":"$REQUEST_ID",
              "chat_id":"$CHAT_ID",
              "chat_context_revision":1,
              "media_grant_revision":1,
              "sequence":$sequence,
              "final":$final,
              "text":"check my schedule",
              "detected_language":${if (final) "\"en\"" else "null"},
              ${if (final) "\"text_digest_sha256\":\"${"a".repeat(64)}\",\"transcript_proof\":\"${"b".repeat(64)}\",\"proof_expires_at\":\"2099-07-31T12:10:00Z\"," else ""}
              "source_participant_identity":"$WORKER"
            }
            """.trimIndent()
    }
}
