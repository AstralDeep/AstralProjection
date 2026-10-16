// Controller-level client-local voice tests: server-selected activation through the v2 capability
// route, typed fallback refusals before any local session request, the shared-socket local frame
// path, session-ready recognition start, and stop/background teardown without a separate dispatch.

package com.personalailabs.astraldeep.app.voice

import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.LocalVoiceFrame
import com.personalailabs.astraldeep.core.protocol.VoiceControlBinding
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class VoiceSessionController075LocalTest {
    private class RecordingSocket : (String) -> Boolean {
        val frames = mutableListOf<JsonObject>()
        var accept = true

        override fun invoke(frame: String): Boolean {
            if (!accept) return false
            frames += Json.parseToJsonElement(frame).jsonObject
            return true
        }

        fun typed(type: String): List<JsonObject> = frames.filter { it.string("type") == type }
    }

    private class ScriptedEngine(private var facts: LocalSpeechFacts) : LocalSpeechEngine {
        var started = 0
        var stopAllCalls = 0
        var onFinal: ((String) -> Unit)? = null
        var onError: ((String) -> Unit)? = null
        var probeCalls = 0
        var releaseProbe: CompletableDeferred<Unit>? = null

        override suspend fun probe(): LocalSpeechFacts {
            probeCalls += 1
            releaseProbe?.await()
            return facts
        }

        override fun startRecognition(
            onPartial: (String) -> Unit,
            onFinal: (String) -> Unit,
            onError: (String) -> Unit,
        ): Boolean {
            started += 1
            this.onFinal = onFinal
            this.onError = onError
            return true
        }

        override fun stopRecognition() = Unit

        override fun stopAll() {
            stopAllCalls += 1
        }

        override fun speak(
            text: String,
            locale: String,
            onStarted: () -> Unit,
            onDone: (Boolean) -> Unit,
        ): Boolean = false
    }

    private class LocalFakeApi : VoiceControlApi {
        var backendSelection: VoiceBackendSelection = VoiceBackendSelection.Legacy
        var localStartOutcome: VoiceStartOutcome = VoiceStartOutcome.LocalStarted(localSession())
        var localStartCalls = 0
        var startCalls = 0
        var stopCalls = 0
        var endCalls = 0
        var beforeUpdate: (suspend () -> Unit)? = null
        val updateFields = mutableListOf<JsonObject>()

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
        ): VoiceStartOutcome = VoiceStartOutcome.Failed("stale_generation")

        override suspend fun selectBackend(binding: VoiceUiBinding): VoiceBackendSelection = backendSelection

        override suspend fun startLocalSession(
            binding: VoiceUiBinding,
            activationId: String,
            chatId: String,
            capability: LocalSpeechCapability,
            takeover: VoiceTakeoverTarget?,
        ): VoiceStartOutcome {
            localStartCalls += 1
            return localStartOutcome
        }

        override suspend fun update(
            binding: VoiceUiBinding,
            session: VoiceRestSession,
            fields: JsonObject,
        ): Result<VoiceRestSession> {
            updateFields += fields
            beforeUpdate?.invoke()
            return Result.success(
                session.copy(
                    foregroundActive = fields["foreground_active"]?.jsonPrimitive?.booleanOrNull ?: session.foregroundActive,
                    microphoneEnabled = fields["microphone_enabled"]?.jsonPrimitive?.booleanOrNull ?: session.microphoneEnabled,
                ),
            )
        }

        override suspend fun stopSpeech(
            binding: VoiceUiBinding,
            session: VoiceRestSession,
        ): Boolean {
            stopCalls += 1
            return true
        }

        override suspend fun end(
            binding: VoiceUiBinding,
            session: VoiceRestSession,
        ): Boolean {
            endCalls += 1
            return true
        }
    }

    private class LocalFakeMedia : VoiceMediaClient {
        private val flow = MutableSharedFlow<VoiceMediaEvent>(replay = 8, extraBufferCapacity = 8)

        override val events: Flow<VoiceMediaEvent> = flow
        var connectCalls = 0
        var disconnectCalls = 0
        val microphoneCalls = mutableListOf<Boolean>()

        override suspend fun connect(grant: LiveKitVoiceGrant) {
            connectCalls += 1
        }

        override suspend fun setMicrophoneEnabled(enabled: Boolean) {
            microphoneCalls += enabled
        }

        override suspend fun queueAnnouncement(value: com.personalailabs.astraldeep.core.protocol.VoiceAnnouncementMedia): Boolean = true

        override fun interruptPlayout() = Unit

        override fun disconnect() {
            disconnectCalls += 1
        }
    }

    private data class LocalFixture(
        val controller: VoiceSessionController,
        val api: LocalFakeApi,
        val media: LocalFakeMedia,
        val engine: ScriptedEngine,
        val socket: RecordingSocket,
    )

    private fun fixture(
        scope: TestScope,
        facts: LocalSpeechFacts = readyFacts(),
    ): LocalFixture {
        val api = LocalFakeApi()
        val media = LocalFakeMedia()
        val engine = ScriptedEngine(facts)
        val socket = RecordingSocket()
        val controller =
            VoiceSessionController(
                api = api,
                media = media,
                scope = scope.backgroundScope,
                uuidFactory = { ACTIVATION_ID },
                clock = { Instant.parse(NOW).plusMillis(scope.testScheduler.currentTime) },
                localEngine = engine,
            )
        controller.setLocalFrameSender(socket)
        controller.installUiConnection("user-token", DEVICE_ID, CONNECTION_ID, CHAT_ID)
        controller.consumeBinding(
            VoiceControlBinding(DEVICE_ID, CONNECTION_ID, BINDING_ID, BINDING_VALUE, "2026-07-31T12:10:00Z"),
        )
        return LocalFixture(controller, api, media, engine, socket)
    }

    @Test
    fun serverSelectedLocalActivationSendsReadyOnTheSharedSocketAndStartsRecognition() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()

            assertEquals(1, fixture.api.localStartCalls)
            assertEquals(0, fixture.api.startCalls)
            assertEquals(0, fixture.media.connectCalls)
            val ready = fixture.socket.typed("voice_local_ready").single()
            assertEquals("client_local", ready.string("speech_backend"))
            assertEquals(SESSION_ID, ready.string("session_id"))
            assertEquals("authorized", ready.string("recognition_permission"))
            assertEquals("guaranteed_local", ready.string("recognition_processing"))

            fixture.controller.handleInbound(sessionReady())
            runCurrent()
            assertEquals("voice_local_recognition_started", fixture.socket.frames.last().string("type"))
            assertEquals("listening", fixture.controller.state.value.phase)
        }

    @Test
    fun audioFocusLossStopsLocalOwnersBeforeTheServerReply() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()
            val reply = CompletableDeferred<Unit>()
            fixture.api.beforeUpdate = { reply.await() }

            fixture.controller.audioFocusChanged(true)

            assertEquals(1, fixture.engine.stopAllCalls)
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()
            assertEquals(1, fixture.engine.started)
            assertTrue(fixture.media.microphoneCalls.isEmpty())
            reply.complete(Unit)
        }

    @Test
    fun outputRouteLossStopsLocalOwnersBeforeTheServerReply() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()
            val reply = CompletableDeferred<Unit>()
            fixture.api.beforeUpdate = { reply.await() }

            fixture.controller.audioRouteChanged(false)

            assertEquals(1, fixture.engine.stopAllCalls)
            runCurrent()
            assertTrue(fixture.media.microphoneCalls.isEmpty())
            reply.complete(Unit)
        }

    @Test
    fun localAudioRecoveryRequiresBothSignalsAndANewReadyAcknowledgement() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()
            fixture.controller.audioFocusChanged(true)
            fixture.controller.audioRouteChanged(false)
            runCurrent()

            fixture.controller.audioFocusChanged(false)
            runCurrent()
            assertEquals(1, fixture.socket.typed("voice_local_ready").size)
            fixture.controller.audioRouteChanged(true)
            runCurrent()
            assertEquals(2, fixture.socket.typed("voice_local_ready").size)
            assertEquals(1, fixture.engine.started)
            fixture.controller.handleInbound(sessionReady())
            runCurrent()
            assertEquals(1, fixture.engine.started)
            advanceTimeBy(500)
            runCurrent()
            assertEquals(2, fixture.engine.started)
            assertTrue(fixture.media.microphoneCalls.isEmpty())
        }

    @Test
    fun renewedAudioLossFencesAProbeAlreadyAwaitingRecovery() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()
            fixture.controller.audioFocusChanged(true)
            runCurrent()
            val probe = CompletableDeferred<Unit>()
            fixture.engine.releaseProbe = probe
            fixture.controller.audioFocusChanged(false)
            runCurrent()
            assertEquals(2, fixture.engine.probeCalls)

            fixture.controller.audioFocusChanged(true)
            probe.complete(Unit)
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()

            assertEquals(1, fixture.socket.typed("voice_local_ready").size)
            assertEquals(1, fixture.engine.started)
            assertTrue(fixture.media.microphoneCalls.isEmpty())
        }

    @Test
    fun localAudioRecoveryPreservesAnExplicitMicrophoneOffIntent() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()
            fixture.controller.audioFocusChanged(true)
            runCurrent()
            fixture.controller.setMicrophoneEnabled(false)
            fixture.controller.audioFocusChanged(false)
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()

            assertEquals(1, fixture.socket.typed("voice_local_ready").size)
            assertEquals(1, fixture.engine.started)
            assertEquals(false, fixture.api.updateFields.last()["microphone_enabled"]?.jsonPrimitive?.booleanOrNull)
            assertTrue(fixture.media.microphoneCalls.isEmpty())
        }

    @Test
    fun localFinalFlowsThroughTheSharedSocketAndExactAckProjectsProcessing() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()
            val clientTurnId = fixture.socket.typed("voice_local_recognition_started").single().string("client_turn_id")!!

            fixture.engine.onFinal?.invoke("check my schedule")
            fixture.controller.handleInbound(turnBound(clientTurnId = clientTurnId))
            val final = fixture.socket.typed("voice_local_final").single()
            assertEquals("check my schedule", final.string("text"))
            assertEquals(sha256Hex("check my schedule"), final.string("text_digest_sha256"))

            fixture.controller.handleInbound(ack())
            assertEquals("processing", fixture.controller.state.value.phase)
            assertEquals("On it!", fixture.controller.state.value.message)
            runCurrent()
            assertEquals(2, fixture.socket.typed("voice_local_recognition_started").size)
        }

    @Test
    fun permissionDenialRefusesLocalActivationBeforeAnyLocalSessionRequest() =
        runTest {
            val fixture = fixture(this, facts = readyFacts(microphonePermission = "denied"))
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()

            assertEquals(0, fixture.api.localStartCalls)
            assertEquals(0, fixture.api.startCalls)
            assertEquals("unavailable", fixture.controller.state.value.phase)
            assertEquals("microphone_permission_denied", fixture.controller.state.value.reason)
            assertTrue(fixture.socket.frames.isEmpty())
        }

    @Test
    fun missingRecognitionLanguageKeepsTypedFallbackWithoutASessionRequest() =
        runTest {
            val fixture = fixture(this, facts = readyFacts(recognitionInstallation = "downloadable"))
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()

            assertEquals(0, fixture.api.localStartCalls)
            assertEquals("unavailable", fixture.controller.state.value.phase)
            assertEquals("local_language_download_required", fixture.controller.state.value.reason)
        }

    @Test
    fun serverUnavailableSelectionShowsTypedFallbackAndSkipsActivation() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection =
                VoiceBackendSelection.Local("unavailable", "local_synthesis_unavailable", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()

            assertEquals(0, fixture.api.localStartCalls)
            assertEquals(0, fixture.api.startCalls)
            assertEquals("unavailable", fixture.controller.state.value.phase)
            assertEquals("local_synthesis_unavailable", fixture.controller.state.value.reason)
        }

    @Test
    fun stopSpeechRoutesThroughTheRuntimeAndReauthorizesWithANewHandshake() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()

            fixture.controller.stopSpeech()
            runCurrent()

            assertEquals(1, fixture.api.stopCalls)
            assertEquals(1, fixture.engine.stopAllCalls)
            assertEquals(2, fixture.socket.typed("voice_local_ready").size)
        }

    @Test
    fun remoteSelectionKeepsTheLiveKitActivationPath() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Remote("ready", "ready")
            fixture.controller.activate(voiceCapability())
            runCurrent()

            assertEquals(0, fixture.api.localStartCalls)
            assertEquals(1, fixture.api.startCalls)
            assertEquals(1, fixture.media.connectCalls)
            assertTrue(fixture.socket.frames.isEmpty())
        }

    @Test
    fun connectionLostTearsDownTheLocalSessionAndRefusesLaterLocalFrames() =
        runTest {
            val fixture = fixture(this)
            fixture.api.backendSelection = VoiceBackendSelection.Local("ready", "ready", EXPIRES_AT, requirements())
            fixture.controller.activate(voiceCapability())
            runCurrent()
            fixture.controller.handleInbound(sessionReady())
            runCurrent()

            fixture.controller.connectionLost()
            assertEquals(1, fixture.engine.stopAllCalls)
            fixture.controller.handleInbound(sessionReady())
            assertEquals(1, fixture.socket.typed("voice_local_ready").size)
            assertEquals(1, fixture.socket.typed("voice_local_recognition_started").size)
        }

    companion object {
        private const val DEVICE_ID = "00000000-0000-4000-8000-000000000001"
        private const val CONNECTION_ID = "00000000-0000-4000-8000-000000000002"
        private const val SESSION_ID = "00000000-0000-4000-8000-000000000003"
        private const val CHAT_ID = "00000000-0000-4000-8000-000000000004"
        private const val TURN_ID = "00000000-0000-4000-8000-000000000006"
        private const val SUBMISSION_ID = "00000000-0000-4000-8000-000000000007"
        private const val REQUEST_ID = "00000000-0000-4000-8000-000000000008"
        private const val BINDING_ID = "00000000-0000-4000-8000-00000000000a"
        private const val BINDING_VALUE = "synthetic-binding-value-000000000000"
        private const val ACTIVATION_ID = "00000000-0000-4000-8000-00000000000b"
        private const val NOW = "2026-07-31T12:00:00Z"
        private const val EXPIRES_AT = "2026-07-31T12:10:00Z"

        private fun voiceCapability() = VoiceMediaCapability(hasMicrophone = true, hasAudioOutput = true, microphonePermission = "authorized", fullDuplex = false)

        private fun readyFacts(
            microphonePermission: String = "authorized",
            recognitionInstallation: String = "ready",
        ) = LocalSpeechFacts(
            hasMicrophone = true,
            hasAudioOutput = true,
            microphonePermission = microphonePermission,
            recognitionServiceAvailable = true,
            recognitionOnDevice = true,
            recognitionLocaleState = "ready",
            recognitionInstallation = recognitionInstallation,
            synthesisEngineReady = true,
            synthesisLocaleState = "ready",
        )

        private fun localSession() =
            LocalVoiceSession(
                deviceId = DEVICE_ID,
                connectionGeneration = CONNECTION_ID,
                sessionId = SESSION_ID,
                generation = 1,
                speechRevision = 1,
                chatId = CHAT_ID,
                chatContextRevision = 1,
                foregroundActive = true,
                microphoneEnabled = true,
                speechMuted = false,
            )

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
                workerIdentity = "voice-worker-a",
            )

        private fun requirements() =
            LocalVoiceRequirements(
                configuredLocale = "en-US",
                maxFinalUnicodeScalars = 8000,
                maxAnnouncementUtf8Bytes = 600,
                announcementTtlSeconds = 10,
                echoSuppressionMilliseconds = 500,
            )

        private fun common(type: String): Map<String, JsonPrimitive> =
            mapOf(
                "type" to JsonPrimitive(type),
                "schema_version" to JsonPrimitive("2"),
                "speech_backend" to JsonPrimitive("client_local"),
                "device_id" to JsonPrimitive(DEVICE_ID),
                "connection_generation" to JsonPrimitive(CONNECTION_ID),
                "session_id" to JsonPrimitive(SESSION_ID),
                "generation" to JsonPrimitive(1),
                "speech_revision" to JsonPrimitive(1),
            )

        private fun sessionReady(): Inbound.LocalVoiceFrame =
            Inbound.LocalVoiceFrame(
                requireNotNull(
                    LocalVoiceFrame.fromJson(
                        JsonObject(
                            common("voice_local_session_ready") +
                                mapOf(
                                    "contract" to JsonPrimitive("client_local/v1"),
                                    "transport" to JsonPrimitive("client_local"),
                                    "configured_locale" to JsonPrimitive("en-US"),
                                    "chat_id" to JsonPrimitive(CHAT_ID),
                                    "chat_context_revision" to JsonPrimitive(1),
                                    "applied_chat_context_revision" to JsonPrimitive(1),
                                    "foreground_active" to JsonPrimitive(true),
                                    "microphone_enabled" to JsonPrimitive(true),
                                    "speech_muted" to JsonPrimitive(false),
                                    "lease_expires_at" to JsonPrimitive("2026-07-31T12:05:00Z"),
                                ),
                        ),
                    ),
                ),
            )

        private fun turnBound(clientTurnId: String): Inbound.LocalVoiceFrame =
            Inbound.LocalVoiceFrame(
                requireNotNull(
                    LocalVoiceFrame.fromJson(
                        JsonObject(
                            common("voice_local_turn_bound") +
                                mapOf(
                                    "client_turn_id" to JsonPrimitive(clientTurnId),
                                    "turn_id" to JsonPrimitive(TURN_ID),
                                    "submission_id" to JsonPrimitive(SUBMISSION_ID),
                                    "request_generation" to JsonPrimitive(REQUEST_ID),
                                    "chat_id" to JsonPrimitive(CHAT_ID),
                                    "chat_context_revision" to JsonPrimitive(1),
                                    "recognition_sequence" to JsonPrimitive(1),
                                    "binding_expires_at" to JsonPrimitive("2026-07-31T12:01:00Z"),
                                ),
                        ),
                    ),
                ),
            )

        private fun ack() =
            Inbound.UserMessageAcked(
                chatId = CHAT_ID,
                messageId = "1",
                submissionId = SUBMISSION_ID,
                requestGeneration = REQUEST_ID,
                connectionGeneration = CONNECTION_ID,
                voiceTurnId = TURN_ID,
            )
    }
}
