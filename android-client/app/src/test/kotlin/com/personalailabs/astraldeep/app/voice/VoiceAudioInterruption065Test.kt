// Tests for the project-owned voice audio-focus/route lifecycle: immediate capture/playout suspension,
// bounded generation-fenced recovery, and stale-callback rejection in VoiceSessionController.

package com.personalailabs.astraldeep.app.voice

import android.media.AudioManager
import com.personalailabs.astraldeep.core.protocol.VoiceAnnouncementMedia
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VoiceAudioInterruption065Test {
    @Test
    fun focusLossStopsCaptureAndPlayoutBeforeTheServerUpdateCompletes() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.api.releaseUpdate = CompletableDeferred()

            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()

            assertEquals(1, fixture.media.interruptCalls)
            assertEquals(listOf(true, false), fixture.media.microphoneChanges)
            assertEquals("suspended", fixture.controller.state.value.phase)
            assertEquals("audio_interrupted", fixture.controller.state.value.reason)
            assertFalse(fixture.controller.state.value.mediaConnected)
            assertNull(fixture.api.updatedSession)
            val suspension = fixture.api.updateCalls.single()
            assertEquals(false, suspension.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull)
            assertEquals("audio_interrupted", suspension.fields["foreground_reason"]?.jsonPrimitive?.contentOrNull)
            assertEquals(false, suspension.fields["microphone_enabled"]?.jsonPrimitive?.booleanOrNull)

            fixture.api.releaseUpdate!!.complete(Unit)
            runCurrent()
            assertEquals(false, fixture.api.updatedSession?.foregroundActive)
        }

    @Test
    fun focusGainResumesWithServerAuthorizationAndUserMicrophoneIntent() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()
            assertEquals(
                0,
                fixture.api.updateCalls.count {
                    it.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull == true
                },
            )

            fixture.controller.audioFocusChanged(interrupted = false)
            runCurrent()
            val resume = fixture.api.updateCalls.last()
            assertEquals(true, resume.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull)
            assertEquals("foreground", resume.fields["foreground_reason"]?.jsonPrimitive?.contentOrNull)
            assertEquals(true, resume.fields["microphone_enabled"]?.jsonPrimitive?.booleanOrNull)
            assertEquals(true, fixture.media.microphoneChanges.last())
            assertEquals(true, fixture.api.updatedSession?.foregroundActive)

            advanceTimeBy(20_000)
            runCurrent()
            val foregroundActiveUpdates =
                fixture.api.updateCalls.count {
                    it.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull == true
                }
            assertTrue(foregroundActiveUpdates >= 2, "lease renewal must restart after audio recovery")
            assertTrue(
                fixture.api.updateCalls.last().fields["foreground_active"]?.jsonPrimitive?.booleanOrNull == true,
            )
        }

    @Test
    fun userMuteIntentSurvivesSuspensionAndKeepsCaptureOffOnRecovery() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.controller.setMicrophoneEnabled(false)
            runCurrent()
            val microphoneGrantsAfterMute = fixture.media.microphoneChanges.count { it }

            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()
            fixture.controller.audioFocusChanged(interrupted = false)
            runCurrent()

            val resume = fixture.api.updateCalls.last()
            assertEquals("foreground", resume.fields["foreground_reason"]?.jsonPrimitive?.contentOrNull)
            assertEquals(false, resume.fields["microphone_enabled"]?.jsonPrimitive?.booleanOrNull)
            assertEquals(false, fixture.media.microphoneChanges.last())
            assertEquals(
                microphoneGrantsAfterMute,
                fixture.media.microphoneChanges.count { it },
                "recovery must not re-enable capture the user muted",
            )
        }

    @Test
    fun staleFocusGainAfterSessionEndDoesNotResumeCapture() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()
            val updateCount = fixture.api.updateCalls.size

            fixture.controller.end()
            runCurrent()
            fixture.controller.audioFocusChanged(interrupted = false)
            runCurrent()

            assertEquals(updateCount, fixture.api.updateCalls.size)
            assertEquals(false, fixture.media.microphoneChanges.last())
        }

    @Test
    fun suspensionAndRecoveryFromPreviousConnectionGenerationAreDroppedAfterRebind() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.api.releaseUpdate = CompletableDeferred()

            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()
            fixture.controller.installUiConnection("user-token", DEVICE_ID, OTHER_CONNECTION_ID, CHAT_ID)
            runCurrent()
            assertEquals("reconnecting", fixture.controller.state.value.phase)

            fixture.api.releaseUpdate!!.complete(Unit)
            runCurrent()
            assertEquals("reconnecting", fixture.controller.state.value.phase)
            assertEquals("network_interrupted", fixture.controller.state.value.reason)

            fixture.controller.audioFocusChanged(interrupted = false)
            runCurrent()
            assertTrue(
                fixture.api.updateCalls.none {
                    it.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull == true
                },
            )
            assertEquals(false, fixture.media.microphoneChanges.last())
        }

    @Test
    fun headsetRouteLossSuspendsImmediatelyAndRouteRestoreRecovers() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.controller.audioRouteChanged(available = false)
            runCurrent()

            assertEquals(1, fixture.media.interruptCalls)
            val suspension = fixture.api.updateCalls.single()
            assertEquals(false, suspension.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull)
            assertEquals("route_unavailable", suspension.fields["foreground_reason"]?.jsonPrimitive?.contentOrNull)
            assertEquals("suspended", fixture.controller.state.value.phase)

            fixture.controller.audioRouteChanged(available = true)
            runCurrent()
            val resume = fixture.api.updateCalls.last()
            assertEquals(true, resume.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull)
            assertEquals("foreground", resume.fields["foreground_reason"]?.jsonPrimitive?.contentOrNull)
            assertEquals(true, fixture.media.microphoneChanges.last())
        }

    @Test
    fun foregroundReturnDuringActiveInterruptionReassertsTheAudioSuspension() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()
            fixture.controller.appForegroundChanged(active = false, reason = "backgrounded")
            runCurrent()
            assertEquals(
                "backgrounded",
                fixture.api.updateCalls.last().fields["foreground_reason"]?.jsonPrimitive?.contentOrNull,
            )

            fixture.controller.appForegroundChanged(active = true)
            runCurrent()
            val reassertion = fixture.api.updateCalls.last()
            assertEquals(false, reassertion.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull)
            assertEquals("audio_interrupted", reassertion.fields["foreground_reason"]?.jsonPrimitive?.contentOrNull)
            assertEquals(false, reassertion.fields["microphone_enabled"]?.jsonPrimitive?.booleanOrNull)

            advanceTimeBy(20_000)
            runCurrent()
            assertTrue(
                fixture.api.updateCalls.none {
                    it.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull == true
                },
            )

            fixture.controller.audioFocusChanged(interrupted = false)
            runCurrent()
            assertEquals(
                "foreground",
                fixture.api.updateCalls.last().fields["foreground_reason"]?.jsonPrimitive?.contentOrNull,
            )
        }

    @Test
    fun focusGainWhileBackgroundedDefersRecoveryToTheForegroundReturn() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()
            fixture.controller.appForegroundChanged(active = false, reason = "backgrounded")
            runCurrent()

            fixture.controller.audioFocusChanged(interrupted = false)
            runCurrent()
            assertTrue(
                fixture.api.updateCalls.none {
                    it.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull == true
                },
            )

            fixture.controller.appForegroundChanged(active = true)
            runCurrent()
            val resume = fixture.api.updateCalls.last()
            assertEquals(true, resume.fields["foreground_active"]?.jsonPrimitive?.booleanOrNull)
            assertEquals("foreground", resume.fields["foreground_reason"]?.jsonPrimitive?.contentOrNull)
        }

    @Test
    fun interruptionFlapSerializesOnTheUpdateMutexAndConverges() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.api.releaseUpdate = CompletableDeferred()

            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()
            fixture.controller.audioFocusChanged(interrupted = false)
            fixture.controller.audioFocusChanged(interrupted = true)
            fixture.api.releaseUpdate!!.complete(Unit)
            runCurrent()

            val reasons =
                fixture.api.updateCalls.mapNotNull {
                    it.fields["foreground_reason"]?.jsonPrimitive?.contentOrNull
                }
            assertEquals(listOf("audio_interrupted", "audio_interrupted"), reasons)
            assertEquals("suspended", fixture.controller.state.value.phase)
            assertEquals(false, fixture.media.microphoneChanges.last())

            fixture.controller.audioFocusChanged(interrupted = false)
            runCurrent()
            assertEquals(
                "foreground",
                fixture.api.updateCalls.last().fields["foreground_reason"]?.jsonPrimitive?.contentOrNull,
            )
            assertEquals(true, fixture.media.microphoneChanges.last())
        }

    @Test
    fun activationDuringAudioInterruptionStartsSuspendedWithoutConnectingMedia() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()

            fixture.controller.activate(capability())
            runCurrent()

            assertEquals(1, fixture.api.startCalls)
            assertEquals(0, fixture.media.connectCalls)
            assertEquals(listOf(false), fixture.media.microphoneChanges)
            val suspension = fixture.api.updateCalls.single()
            assertEquals("audio_interrupted", suspension.fields["foreground_reason"]?.jsonPrimitive?.contentOrNull)
            assertEquals("suspended", fixture.controller.state.value.phase)
        }

    @Test
    fun announcementsAreNotQueuedWhileTheAudioEnvironmentIsIneligible() =
        runTest {
            val fixture = fixture(this)
            fixture.controller.activate(capability())
            runCurrent()
            fixture.controller.audioFocusChanged(interrupted = true)
            runCurrent()

            fixture.media.emit(
                VoiceMediaEvent.Data(
                    VOICE_ANNOUNCEMENT_TOPIC,
                    WORKER,
                    announcement(kind = "acknowledgement").encodeToByteArray(),
                ),
            )
            runCurrent()
            assertTrue(fixture.media.announcements.isEmpty())

            fixture.controller.audioFocusChanged(interrupted = false)
            runCurrent()
            fixture.media.emit(
                VoiceMediaEvent.Data(
                    VOICE_ANNOUNCEMENT_TOPIC,
                    WORKER,
                    announcement(kind = "acknowledgement").encodeToByteArray(),
                ),
            )
            runCurrent()
            assertEquals(1, fixture.media.announcements.size)
        }

    @Test
    fun audioFocusObservationsMapToVoiceInterruptionState() {
        assertEquals(false, voiceAudioFocusInterrupted(AudioManager.AUDIOFOCUS_GAIN))
        assertEquals(true, voiceAudioFocusInterrupted(AudioManager.AUDIOFOCUS_LOSS))
        assertEquals(true, voiceAudioFocusInterrupted(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT))
        assertEquals(true, voiceAudioFocusInterrupted(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK))
        assertNull(voiceAudioFocusInterrupted(0))
        assertFalse(voiceAudioFocusRequestInterrupted(AudioManager.AUDIOFOCUS_REQUEST_GRANTED))
        assertTrue(voiceAudioFocusRequestInterrupted(AudioManager.AUDIOFOCUS_REQUEST_FAILED))
        assertTrue(voiceAudioFocusRequestInterrupted(AudioManager.AUDIOFOCUS_REQUEST_DELAYED))
    }

    private fun fixture(scope: TestScope): Fixture {
        val api = FakeApi()
        val media = FakeMedia()
        val controller =
            VoiceSessionController(
                api = api,
                media = media,
                scope = scope.backgroundScope,
                uuidFactory = { ACTIVATION_ID },
                clock = { java.time.Instant.parse("2026-07-31T12:00:00Z") },
            )
        controller.installUiConnection("user-token", DEVICE_ID, CONNECTION_ID, CHAT_ID)
        controller.consumeBinding(
            VoiceControlBinding(
                DEVICE_ID,
                CONNECTION_ID,
                BINDING_ID,
                BINDING_VALUE,
                "2026-07-31T12:10:00Z",
            ),
        )
        return Fixture(controller, api, media)
    }

    private data class Fixture(
        val controller: VoiceSessionController,
        val api: FakeApi,
        val media: FakeMedia,
    )

    private class FakeApi : VoiceControlApi {
        data class UpdateCall(
            val binding: VoiceUiBinding,
            val session: VoiceRestSession,
            val fields: JsonObject,
        )

        var startOutcome: VoiceStartOutcome = VoiceStartOutcome.Started(session(), grant())
        var startCalls = 0
        var endCalls = 0
        var updatedSession: VoiceRestSession? = null
        val updateCalls = mutableListOf<UpdateCall>()
        var releaseUpdate: CompletableDeferred<Unit>? = null

        override suspend fun start(
            binding: VoiceUiBinding,
            activationId: String,
            capability: VoiceMediaCapability,
        ): VoiceStartOutcome {
            startCalls += 1
            return startOutcome
        }

        override suspend fun takeover(
            binding: VoiceUiBinding,
            activationId: String,
            target: VoiceTakeoverTarget,
            capability: VoiceMediaCapability,
        ): VoiceStartOutcome = startOutcome

        override suspend fun update(
            binding: VoiceUiBinding,
            session: VoiceRestSession,
            fields: JsonObject,
        ): Result<VoiceRestSession> {
            updateCalls += UpdateCall(binding, session, fields)
            releaseUpdate?.await()
            val updated =
                session.copy(
                    microphoneEnabled =
                        fields["microphone_enabled"]?.jsonPrimitive?.booleanOrNull ?: session.microphoneEnabled,
                    foregroundActive =
                        fields["foreground_active"]?.jsonPrimitive?.booleanOrNull ?: session.foregroundActive,
                )
            updatedSession = updated
            return Result.success(updated)
        }

        override suspend fun stopSpeech(
            binding: VoiceUiBinding,
            session: VoiceRestSession,
        ): Boolean = true

        override suspend fun end(
            binding: VoiceUiBinding,
            session: VoiceRestSession,
        ): Boolean {
            endCalls += 1
            return true
        }
    }

    private class FakeMedia : VoiceMediaClient {
        private val flow = MutableSharedFlow<VoiceMediaEvent>(replay = 16, extraBufferCapacity = 16)
        override val events: Flow<VoiceMediaEvent> = flow
        var connectCalls = 0
        var disconnectCalls = 0
        val microphoneChanges = mutableListOf<Boolean>()
        val announcements = mutableListOf<VoiceAnnouncementMedia>()
        var interruptCalls = 0

        override suspend fun connect(grant: LiveKitVoiceGrant) {
            connectCalls += 1
        }

        override suspend fun setMicrophoneEnabled(enabled: Boolean) {
            microphoneChanges += enabled
        }

        override suspend fun queueAnnouncement(value: VoiceAnnouncementMedia): Boolean {
            announcements += value
            return true
        }

        override fun interruptPlayout() {
            interruptCalls += 1
        }

        override fun disconnect() {
            disconnectCalls += 1
        }

        fun emit(event: VoiceMediaEvent) {
            assertTrue(flow.tryEmit(event))
        }
    }

    companion object {
        private const val DEVICE_ID = "00000000-0000-4000-8000-000000000001"
        private const val CONNECTION_ID = "00000000-0000-4000-8000-000000000002"
        private const val OTHER_CONNECTION_ID = "00000000-0000-4000-8000-000000000012"
        private const val SESSION_ID = "00000000-0000-4000-8000-000000000003"
        private const val CHAT_ID = "00000000-0000-4000-8000-000000000004"
        private const val ANNOUNCEMENT_ID = "00000000-0000-4000-8000-000000000009"
        private const val BINDING_ID = "00000000-0000-4000-8000-00000000000a"
        private const val BINDING_VALUE = "synthetic-binding-value-000000000000"
        private const val ACTIVATION_ID = "00000000-0000-4000-8000-00000000000b"
        private const val WORKER = "voice-worker-a"

        private fun capability() = VoiceMediaCapability(true, true, "authorized", true)

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
                expiresAt = "2026-07-31T12:10:00Z",
                url = "wss://voice.example.test",
                joinToken = "synthetic-client-token-000000000000000000000000",
                roomName = "voice-room-a",
                participantIdentity = "voice-client-a",
                workerIdentity = WORKER,
            )

        private fun announcement(kind: String): String =
            """
            {
              "type":"voice_announcement_media",
              "schema_version":"1",
              "session_id":"$SESSION_ID",
              "generation":1,
              "media_grant_revision":1,
              "announcement_id":"$ANNOUNCEMENT_ID",
              "announcement_sequence":1,
              "turn_id":null,
              "kind":"$kind",
              "quantum_role":"single",
              "quantum_index":0,
              "transport":"livekit",
              "worker_identity":"$WORKER",
              "sample_rate_hz":24000,
              "duration_samples":12000,
              "track_sid":"TR_audio_1",
              "track_name":"announcement-1"
            }
            """.trimIndent()
    }
}
