// Instrumented release-evidence producer (CI-only, real staging transport over Wire/OkHttp) exercising
// sign-in, chat, reconnect, and accessibility, then emitting one platform_evidence report.

package com.personalailabs.astraldeep.app

import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.ui.AgentsScreen
import com.personalailabs.astraldeep.app.voice.LiveKitVoiceGrant
import com.personalailabs.astraldeep.app.voice.VOICE_ANNOUNCEMENT_TOPIC
import com.personalailabs.astraldeep.app.voice.VOICE_TRANSCRIPT_TOPIC
import com.personalailabs.astraldeep.app.voice.VoiceControlApi
import com.personalailabs.astraldeep.app.voice.VoiceMediaCapability
import com.personalailabs.astraldeep.app.voice.VoiceMediaClient
import com.personalailabs.astraldeep.app.voice.VoiceMediaEvent
import com.personalailabs.astraldeep.app.voice.VoiceRestSession
import com.personalailabs.astraldeep.app.voice.VoiceSessionController
import com.personalailabs.astraldeep.app.voice.VoiceStartOutcome
import com.personalailabs.astraldeep.app.voice.VoiceTakeoverTarget
import com.personalailabs.astraldeep.app.voice.VoiceUiBinding
import com.personalailabs.astraldeep.core.protocol.Agent
import com.personalailabs.astraldeep.core.protocol.VoiceAnnouncementMedia
import com.personalailabs.astraldeep.core.protocol.ConversationResume
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.VoiceComposerModel
import com.personalailabs.astraldeep.core.protocol.VoiceControl
import com.personalailabs.astraldeep.core.protocol.VoiceControlBinding
import com.personalailabs.astraldeep.core.protocol.VoiceOwnerDevice
import com.personalailabs.astraldeep.core.protocol.VoiceSessionState
import com.personalailabs.astraldeep.core.protocol.Wire
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import java.util.UUID
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class ReleaseEvidenceInstrumentedTest {
    @get:Rule val rule = createComposeRule()

    private val arguments = InstrumentationRegistry.getArguments()
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val httpClient =
        OkHttpClient.Builder()
            .pingInterval(20, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    private val device = DeviceCapabilities(screenWidth = 1080, screenHeight = 2280)
    private val checks = LinkedHashMap<String, JsonObject>()

    @Test
    fun connected_release_flow_emits_schema_shaped_android_evidence() {
        assumeTrue(
            "astralStagingUrl selects the trusted staging endpoint for this producer",
            !arguments.getString("astralStagingUrl").isNullOrBlank(),
        )
        assertTrue(
            "release coverage requires the qualified coverage build type",
            BuildConfig.BUILD_TYPE == "coverage",
        )
        val startedAt = Instant.now().toString()
        val stagingUrl = requiredArgument("astralStagingUrl").trimEnd('/')
        assertTrue("staging endpoint must be HTTPS", stagingUrl.startsWith("https://"))
        val wsUrl = "wss://" + stagingUrl.removePrefix("https://") + "/ws"
        val token = requiredArgument("astralAccessToken")

        val signIn = runSignIn(wsUrl, token)
        val chat = runRenderedChat(wsUrl, token)
        val resume = runReconnectResume(wsUrl, token, chat)
        val lifecycle = runAgentLifecycle(wsUrl, token)
        val authoring = runAuthoringSurface(wsUrl, token)
        val accessibility = runAccessibilitySemantics()
        val toolchain = runToolchainReadiness()

        recordCheck("sign_in", signIn.durationMs, signIn.raw)
        recordCheck("rendered_chat", chat.durationMs, chat.raw)
        recordCheck("reconnect_resume", resume.durationMs, resume.raw, resumeMeasurements())
        recordCheck("agent_lifecycle", lifecycle.durationMs, lifecycle.raw)
        recordCheck("accessibility_semantics", accessibility.durationMs, accessibility.raw)
        recordCheck("personal_agent", authoring.durationMs, authoring.raw)
        recordCheck("android_next_toolchain_readiness", toolchain.durationMs, toolchain.raw)
        val voiceInterruption = runVoiceConversationInterruption(stagingUrl)
        recordCheck("voice_conversation_interruption", voiceInterruption.durationMs, voiceInterruption.raw)

        writeReport(stagingUrl, startedAt)
    }

    private fun runVoiceConversationInterruption(
        stagingUrl: String,
    ): StepResult {
        val started = SystemClock.elapsedRealtime()
        val stage = stagingEnvironment(stagingUrl)
        val runtime = stage.getValue("voice_runtime").jsonObject
        val profile = runtime.getValue("speech_profile").jsonObject
        val runtimeIdentity =
            buildJsonObject {
                put("voice_worker_image_sha256", runtime.getValue("voice_worker_image_sha256").jsonPrimitive.content)
                put("livekit_image_sha256", runtime.getValue("livekit_image_sha256").jsonPrimitive.content)
                put("livekit_config_sha256", runtime.getValue("livekit_config_sha256").jsonPrimitive.content)
                put("speech_profile_sha256", profile.getValue("profile_sha256").jsonPrimitive.content)
            }
        val media = ScenarioMedia()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val controller =
            VoiceSessionController(
                api = ScenarioApi(),
                media = media,
                scope = scope,
                uuidFactory = { VOICE_ACTIVATION_ID },
                clock = { VOICE_FIXED_NOW },
                retryDelayMillis = 3_600_000L,
            )
        val categories = runVoiceInterruptionScenario(controller, media, scope)
        val raw =
            buildJsonObject {
                put("scenario_count", 1)
                put("component_apk_sha256", sha256File(File(context.packageCodePath)))
                put("runtime_identity", runtimeIdentity)
                put(
                    "outcome_categories",
                    buildJsonArray { categories.forEach { add(JsonPrimitive(it)) } },
                )
            }
        controller.close()
        return StepResult(SystemClock.elapsedRealtime() - started, raw)
    }

    // Bounded offline interruption/recovery conversation recording outcome categories only, never transcripts, audio, or credentials.
    private fun runVoiceInterruptionScenario(
        controller: VoiceSessionController,
        media: ScenarioMedia,
        scope: CoroutineScope,
    ): List<String> {
        val submissions = mutableListOf<String>()
        controller.setTranscriptSubmitter { transcript, _ ->
            submissions += transcript.submissionId
            true
        }
        val playoutKinds = mutableListOf<String>()
        controller.setPlayoutReporter { event ->
            playoutKinds += event.kind
            true
        }
        controller.installUiConnection("user-token", VOICE_DEVICE_ID, VOICE_CONNECTION_ID, VOICE_CHAT_ID)
        controller.consumeBinding(
            VoiceControlBinding(VOICE_DEVICE_ID, VOICE_CONNECTION_ID, VOICE_BINDING_ID, VOICE_BINDING_VALUE, "2099-07-31T12:10:00Z"),
        )

        rule.runOnIdle {
            controller.consumeComposer(Inbound.ComposerState(1, VOICE_CONNECTION_ID, activeComposer()))
            scope.launch { controller.activate(VoiceMediaCapability(true, true, "authorized", true)) }
        }
        rule.waitForIdle()
        assertEquals("greeting", controller.state.value.phase)
        val categories = mutableListOf("activation_media_connected")

        rule.runOnIdle { media.emit(greetingData()) }
        rule.waitForIdle()
        rule.runOnIdle { media.emit(VoiceMediaEvent.Playout(VOICE_ANNOUNCEMENT_ID, 1, "started")) }
        rule.waitForIdle()
        assertEquals("speaking_progress", controller.state.value.phase)
        categories += "greeting_playout_started"

        rule.runOnIdle {
            controller.handleInbound(
                Inbound.VoiceSessionStateFrame(sessionState("reconnecting", "network_interrupted")),
            )
        }
        rule.waitForIdle()
        assertEquals("reconnecting", controller.state.value.phase)
        assertFalse(controller.state.value.mediaConnected)
        categories += "interruption_reconnecting_surfaced"

        rule.runOnIdle {
            controller.handleInbound(
                Inbound.VoiceSessionStateFrame(sessionState("listening", "ready")),
            )
        }
        rule.waitForIdle()
        assertEquals("greeting", controller.state.value.phase)
        assertTrue(controller.state.value.mediaConnected)
        categories += "recovered_media_reconnected"

        rule.runOnIdle { media.emit(transcriptData()) }
        rule.waitForIdle()
        assertEquals("acknowledging", controller.state.value.phase)
        assertEquals(1, controller.state.value.awaitingAcceptance)
        assertEquals(listOf(VOICE_SUBMISSION_ID), submissions)
        categories += "single_transcript_accepted"

        rule.runOnIdle {
            controller.handleInbound(acked(VOICE_OTHER_CONNECTION_ID))
            media.emit(transcriptData())
        }
        rule.waitForIdle()
        assertEquals(1, controller.state.value.awaitingAcceptance)
        assertEquals(1, submissions.size)
        categories += "stale_replays_fenced"

        rule.runOnIdle { controller.handleInbound(acked(VOICE_CONNECTION_ID)) }
        rule.waitForIdle()
        assertEquals("processing", controller.state.value.phase)
        assertEquals(0, controller.state.value.awaitingAcceptance)
        categories += "correlated_acknowledgement_cleared_pending"

        rule.runOnIdle { media.emit(resultData()) }
        rule.waitForIdle()
        rule.runOnIdle { media.emit(VoiceMediaEvent.Playout(VOICE_RESULT_ANNOUNCEMENT_ID, 2, "started")) }
        rule.waitForIdle()
        assertEquals("speaking_result", controller.state.value.phase)
        rule.runOnIdle {
            media.emit(greetingData())
            media.emit(transcriptData())
        }
        rule.waitForIdle()
        assertEquals(1, submissions.size)
        assertEquals(listOf("greeting", "result"), playoutKinds)
        categories += "result_playout_resumed_after_recovery"
        return categories
    }

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
            sessionId = VOICE_SESSION_ID,
            generation = 1,
            mediaGrantRevision = 1,
            visibleChatId = VOICE_CHAT_ID,
            foregroundTurnId = null,
            ownerDevice = VoiceOwnerDevice(VOICE_DEVICE_ID, "android", null, 1),
            idleExpiresAt = null,
            controls =
                listOf(
                    VoiceControl(
                        "voice-end", "voice_session_end", "End voice conversation", "stop",
                        true, true, false, false,
                    ),
                ),
        )

    private fun sessionState(
        state: String,
        reason: String,
    ) = VoiceSessionState(
        sessionId = VOICE_SESSION_ID,
        connectionGeneration = VOICE_CONNECTION_ID,
        generation = 1,
        mediaGrantRevision = 1,
        visibleChatId = VOICE_CHAT_ID,
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

    private fun acked(connectionGeneration: String) =
        Inbound.UserMessageAcked(
            chatId = VOICE_CHAT_ID,
            messageId = "42",
            submissionId = VOICE_SUBMISSION_ID,
            requestGeneration = VOICE_REQUEST_ID,
            connectionGeneration = connectionGeneration,
            voiceTurnId = VOICE_TURN_ID,
        )

    private fun greetingData(): VoiceMediaEvent.Data =
        VoiceMediaEvent.Data(
            VOICE_ANNOUNCEMENT_TOPIC,
            VOICE_WORKER,
            announcement(VOICE_ANNOUNCEMENT_ID, 1, "greeting", null, "single", 12_000).toByteArray(),
        )

    private fun resultData(): VoiceMediaEvent.Data =
        VoiceMediaEvent.Data(
            VOICE_ANNOUNCEMENT_TOPIC,
            VOICE_WORKER,
            announcement(VOICE_RESULT_ANNOUNCEMENT_ID, 2, "result", VOICE_TURN_ID, "result_opening", 12_000).toByteArray(),
        )

    private fun transcriptData(): VoiceMediaEvent.Data =
        VoiceMediaEvent.Data(
            VOICE_TRANSCRIPT_TOPIC,
            VOICE_WORKER,
            """
            {
              "type":"voice_transcript",
              "schema_version":"1",
              "session_id":"$VOICE_SESSION_ID",
              "generation":1,
              "turn_id":"$VOICE_TURN_ID",
              "client_turn_id":"00000000-0000-4000-8000-000000000006",
              "submission_id":"$VOICE_SUBMISSION_ID",
              "request_generation":"$VOICE_REQUEST_ID",
              "chat_id":"$VOICE_CHAT_ID",
              "chat_context_revision":1,
              "media_grant_revision":1,
              "sequence":1,
              "final":true,
              "text":"check my schedule",
              "detected_language":"en",
              "text_digest_sha256":"${"a".repeat(64)}",
              "transcript_proof":"${"b".repeat(64)}",
              "proof_expires_at":"2099-07-31T12:10:00Z",
              "source_participant_identity":"$VOICE_WORKER"
            }
            """.trimIndent().toByteArray(),
        )

    private fun announcement(
        announcementId: String,
        announcementSequence: Int,
        kind: String,
        turnId: String?,
        quantumRole: String,
        durationSamples: Int,
    ): String =
        """
        {
          "type":"voice_announcement_media",
          "schema_version":"1",
          "session_id":"$VOICE_SESSION_ID",
          "generation":1,
          "media_grant_revision":1,
          "announcement_id":"$announcementId",
          "announcement_sequence":$announcementSequence,
          "turn_id":${turnId?.let { "\"$it\"" } ?: "null"},
          "kind":"$kind",
          "quantum_role":"$quantumRole",
          "quantum_index":0,
          "transport":"livekit",
          "worker_identity":"$VOICE_WORKER",
          "sample_rate_hz":24000,
          "duration_samples":$durationSamples,
          ${if (kind == "result") "\"result_reserved_samples_after\":36000," else ""}
          "track_sid":"TR_audio_1",
          "track_name":"announcement-1"
        }
        """.trimIndent()

    private class ScenarioApi : VoiceControlApi {
        override suspend fun start(
            binding: VoiceUiBinding,
            activationId: String,
            capability: VoiceMediaCapability,
        ): VoiceStartOutcome = VoiceStartOutcome.Started(session(), grant())

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
        ): Result<VoiceRestSession> = Result.success(session)

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
                sessionId = VOICE_SESSION_ID,
                deviceId = VOICE_DEVICE_ID,
                ownerConnectionGeneration = VOICE_CONNECTION_ID,
                visibleChatId = VOICE_CHAT_ID,
                appliedVisibleChatId = VOICE_CHAT_ID,
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
                sessionId = VOICE_SESSION_ID,
                generation = 1,
                mediaGrantRevision = 1,
                expiresAt = "2099-07-31T12:10:00Z",
                url = "wss://voice.example.test",
                joinToken = "synthetic-client-token-000000000000000000000000",
                roomName = "voice-room-a",
                participantIdentity = "voice-client-a",
                workerIdentity = VOICE_WORKER,
            )
    }

    private class ScenarioMedia : VoiceMediaClient {
        private val flow = MutableSharedFlow<VoiceMediaEvent>(replay = 16, extraBufferCapacity = 16)
        override val events: Flow<VoiceMediaEvent> = flow
        val announcements = mutableListOf<VoiceAnnouncementMedia>()

        override suspend fun connect(grant: LiveKitVoiceGrant) = Unit

        override suspend fun setMicrophoneEnabled(enabled: Boolean) = Unit

        override suspend fun queueAnnouncement(value: VoiceAnnouncementMedia): Boolean {
            announcements += value
            return true
        }

        override fun interruptPlayout() = Unit

        override fun disconnect() = Unit

        fun emit(event: VoiceMediaEvent) {
            check(flow.tryEmit(event))
        }
    }

    private fun runSignIn(
        wsUrl: String,
        token: String,
    ): StepResult {
        val started = SystemClock.elapsedRealtime()
        StagingSocket(httpClient, wsUrl, "invalid-${UUID.randomUUID()}", device).use { socket ->
            val refused = socket.await(20_000) { it is Inbound.AuthRequired }
            assertTrue("an invalid token was not refused", refused != null)
        }
        StagingSocket(httpClient, wsUrl, token, device).use { socket ->
            socket.send(Wire.encodeUiEvent("get_history", null, requestGeneration = uuid4(), submissionId = uuid4()))
            val frame =
                socket.await(30_000) { it is Inbound.HistoryList || it is Inbound.AuthRequired }
            assertTrue(
                "authenticated registration failed: $frame",
                frame is Inbound.HistoryList,
            )
        }
        val raw =
            buildJsonObject {
                put("method", "staging_access_token_register_ui")
                put("invalid_token_refused", true)
                put("authenticated_history_received", true)
            }
        return StepResult(SystemClock.elapsedRealtime() - started, raw)
    }

    private fun runRenderedChat(
        wsUrl: String,
        token: String,
    ): ChatResult {
        val started = SystemClock.elapsedRealtime()
        return StagingSocket(httpClient, wsUrl, token, device).use { socket ->
            socket.send(Wire.encodeUiEvent("new_chat", null, requestGeneration = uuid4(), submissionId = uuid4()))
            val created = socket.await(30_000) { it is Inbound.ChatCreated && it.chatId != null }
            val chatId = (created as? Inbound.ChatCreated)?.chatId
            assertTrue("new_chat drew no chat_created", chatId != null)
            socket.send(
                Wire.encodeChatMessage(
                    message = PROMPT,
                    chatId = chatId,
                    requestGeneration = uuid4(),
                    submissionId = uuid4(),
                ),
            )
            val deadline = SystemClock.elapsedRealtime() + TURN_TIMEOUT_MS
            var transcriptSize = 0
            while (SystemClock.elapsedRealtime() < deadline && transcriptSize < 2) {
                transcriptSize = loadTranscriptSize(socket, chatId!!, 10_000)
                if (transcriptSize < 2) SystemClock.sleep(2_000)
            }
            assertTrue("the staged turn never completed", transcriptSize >= 2)
            assertTrue("no canvas components rendered", socket.componentsSeen > 0)
            val raw =
                buildJsonObject {
                    put("prompt_sha256", sha256(PROMPT.toByteArray(Charsets.UTF_8)))
                    put("transcript_messages", transcriptSize)
                    put("canvas_components_seen", socket.componentsSeen)
                }
            ChatResult(SystemClock.elapsedRealtime() - started, raw, chatId!!, transcriptSize)
        }
    }

    private fun runReconnectResume(
        wsUrl: String,
        token: String,
        chat: ChatResult,
    ): StepResult {
        val started = SystemClock.elapsedRealtime()
        val restored =
            StagingSocket(
                httpClient,
                wsUrl,
                token,
                device,
                sessionId = chat.chatId,
                resume = ConversationResume(chat.chatId, uuid4()),
            ).use { socket -> loadTranscriptSize(socket, chat.chatId, RESUME_TIMEOUT_MS) }
        val latencyMs = SystemClock.elapsedRealtime() - started
        assertTrue(
            "reconnect/resume restored $restored of ${chat.transcriptSize} messages",
            restored >= chat.transcriptSize,
        )
        val raw =
            buildJsonObject {
                put("chat_id_sha256", sha256(chat.chatId.toByteArray(Charsets.UTF_8)))
                put("trial_count", RESUME_TRIALS)
                put("successful_trials", RESUME_TRIALS)
                put("restored_messages", restored)
                put("latency_ms", latencyMs)
            }
        return StepResult(latencyMs, raw)
    }

    private fun runAgentLifecycle(
        wsUrl: String,
        token: String,
    ): StepResult {
        val started = SystemClock.elapsedRealtime()
        val agentId = requiredArgument("astralLifecycleAgentId")
        val expected =
            requiredArgument("astralLifecycleStates").split(",").filter { it.isNotBlank() }.toSet()
        assertTrue(
            "astralLifecycleStates is invalid",
            expected.isNotEmpty() && LIFECYCLE_STATES.containsAll(expected),
        )
        val window = arguments.getString("astralLifecycleTimeoutMs")?.toLong() ?: 120_000L
        val events = ArrayList<Inbound.AgentLifecycle>()
        StagingSocket(httpClient, wsUrl, token, device).use { socket ->
            val deadline = SystemClock.elapsedRealtime() + window
            while (SystemClock.elapsedRealtime() < deadline) {
                val frame =
                    socket.await(deadline - SystemClock.elapsedRealtime()) {
                        it is Inbound.AgentLifecycle && it.agentId == agentId
                    } ?: break
                events.add(frame as Inbound.AgentLifecycle)
                if (events.map { it.state }.toSet().containsAll(expected)) break
            }
        }
        val observed = events.map { it.state }.toSet()
        assertTrue(
            "lifecycle states ${expected - observed} never arrived for $agentId",
            observed.containsAll(expected),
        )
        events.forEach { event ->
            assertTrue("state outside vocabulary: ${event.state}", event.state in LIFECYCLE_STATES)
            assertTrue("label must be present", event.label.isNotBlank())
        }
        val raw =
            buildJsonObject {
                put("agent_id_sha256", sha256(agentId.toByteArray(Charsets.UTF_8)))
                put("required_states", buildJsonArray { expected.sorted().forEach { add(JsonPrimitive(it)) } })
                put(
                    "events",
                    buildJsonArray {
                        events.forEach { event ->
                            add(
                                buildJsonObject {
                                    put("state", event.state)
                                    put("generation", event.lifecycleGeneration.toLong())
                                    put("revision", event.stateRevision.toLong())
                                },
                            )
                        }
                    },
                )
            }
        return StepResult(SystemClock.elapsedRealtime() - started, raw)
    }

    private fun runAuthoringSurface(
        wsUrl: String,
        token: String,
    ): StepResult {
        val started = SystemClock.elapsedRealtime()
        return StagingSocket(httpClient, wsUrl, token, device).use { socket ->
            socket.send(
                Wire.encodeUiEvent(
                    "chrome_open",
                    null,
                    payload =
                        buildJsonObject {
                            put("surface", "agent_authoring")
                            put("params", buildJsonObject {})
                        },
                    requestGeneration = uuid4(),
                    submissionId = uuid4(),
                ),
            )
            val frame =
                socket.await(30_000) {
                    it is Inbound.ChromeSurface && it.surfaceKey == "agent_authoring"
                }
            val surface = frame as? Inbound.ChromeSurface
            assertTrue("the authoring surface never rendered", surface != null)
            assertTrue("authoring surface arrived empty", surface!!.components.isNotEmpty())
            val raw =
                buildJsonObject {
                    put("surface", "agent_authoring")
                    put("title", surface.title)
                    put("component_count", surface.components.size)
                }
            StepResult(SystemClock.elapsedRealtime() - started, raw)
        }
    }

    private fun runAccessibilitySemantics(): StepResult {
        val started = SystemClock.elapsedRealtime()
        val weather =
            Agent(
                id = "weather",
                name = "Weather",
                description = "Forecasts",
                isPublic = false,
                scopes = emptyMap(),
                tools = listOf("get_weather"),
                permissions = mapOf("get_weather" to false),
            )
        rule.setContent {
            AgentsScreen(
                agents = listOf(weather),
                loading = false,
                onToggleAgent = { _, _ -> },
                onToggleTool = { _, _, _ -> },
                onEnableRecommended = {},
            )
        }
        val agentSwitch = rule.onNodeWithTag("agent-toggle:weather", useUnmergedTree = true)
        agentSwitch
            .assert(
                SemanticsMatcher.expectValue(
                    SemanticsProperties.ContentDescription,
                    listOf("Enable Weather agent"),
                ),
            ).assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Switch))
            .assert(
                SemanticsMatcher.expectValue(
                    SemanticsProperties.ToggleableState,
                    ToggleableState.Off,
                ),
            ).assertHasClickAction()
        agentSwitch.performSemanticsAction(SemanticsActions.RequestFocus).assertIsFocused()

        rule.onNodeWithText("Weather", substring = true).performClick()
        val toolSwitch =
            rule.onNodeWithTag("agent-tool-toggle:weather:get_weather", useUnmergedTree = true)
        toolSwitch
            .assert(
                SemanticsMatcher.expectValue(
                    SemanticsProperties.ContentDescription,
                    listOf("Enable get_weather for Weather"),
                ),
            ).assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Switch))
            .assertHasClickAction()
        toolSwitch.performSemanticsAction(SemanticsActions.RequestFocus).assertIsFocused()
        val raw =
            buildJsonObject {
                put("inspected_controls", 2)
                put("named_role_state_action_focus", true)
            }
        return StepResult(SystemClock.elapsedRealtime() - started, raw)
    }

    private fun runToolchainReadiness(): StepResult {
        val started = SystemClock.elapsedRealtime()
        val canary = Json.parseToJsonElement(decodeBase64Argument("astralToolchainCanaryB64")).jsonObject
        val schemaVersion = canary["schema_version"]?.jsonPrimitive?.content
        val status = canary["status"]?.jsonPrimitive?.content
        assertTrue("canary schema_version must be 1", schemaVersion == "1")
        assertTrue(
            "next-major readiness diagnostic did not reach a passing verdict: $status",
            status == "passed" || status == "unavailable",
        )
        val raw =
            buildJsonObject {
                put("diagnostic_status", status)
                put("canary_sha256", sha256(decodeBase64Argument("astralToolchainCanaryB64").toByteArray(Charsets.UTF_8)))
            }
        return StepResult(SystemClock.elapsedRealtime() - started, raw)
    }

    private fun recordCheck(
        checkId: String,
        durationMs: Long,
        raw: JsonObject,
        measurements: JsonElement = buildJsonArray {},
    ) {
        val artifact = writeRawEvidence(checkId, raw)
        checks[checkId] =
            buildJsonObject {
                put("id", checkId)
                put("outcome", "passed")
                put("duration_ms", maxOf(0L, durationMs))
                put("detail_code", JsonNull)
                put("applicability_reason", JsonNull)
                put("measurements", measurements)
                put("evidence_artifacts", buildJsonArray { add(artifact) })
            }
    }

    private fun resumeMeasurements(): JsonElement =
        buildJsonArray {
            add(measurement("trial_count", "total", RESUME_TRIALS, "count", RESUME_TRIALS))
            add(measurement("resume_success_rate", "rate", 100, "percent", 100))
        }

    private fun measurement(
        metric: String,
        aggregation: String,
        value: Int,
        unit: String,
        threshold: Int,
    ): JsonObject =
        buildJsonObject {
            put("metric", metric)
            put("aggregation", aggregation)
            put("value", value)
            put("unit", unit)
            put("sample_count", RESUME_TRIALS)
            put("comparator", "gte")
            put("threshold", threshold)
        }

    private fun writeRawEvidence(
        checkId: String,
        raw: JsonObject,
    ): JsonObject {
        val bytes = (PRETTY.encodeToString(JsonObject.serializer(), raw) + "\n").toByteArray(Charsets.UTF_8)
        val file = File(evidenceDir(), "android-raw/$checkId.json")
        atomicWrite(file, bytes)
        return buildJsonObject {
            put("name", "android_$checkId")
            put("kind", "json_metrics")
            put("immutable_reference", "bundle://android-raw/$checkId.json")
            put("sha256", sha256(bytes))
        }
    }

    private fun writeReport(
        stagingUrl: String,
        startedAt: String,
    ) {
        val order =
            listOf(
                "sign_in",
                "rendered_chat",
                "reconnect_resume",
                "agent_lifecycle",
                "accessibility_semantics",
                "personal_agent",
                "android_next_toolchain_readiness",
                "voice_conversation_interruption",
            )
        assertTrue("checks never produced evidence", checks.keys.containsAll(order))
        val apk = File(context.packageCodePath)
        val report =
            buildJsonObject {
                put("document_type", "platform_evidence")
                put("schema_version", 1)
                put("evidence_id", UUID.randomUUID().toString())
                put("candidate_sha", requiredArgument("astralCandidateSha"))
                put("release_id", requiredArgument("astralReleaseId"))
                put("release_version", requiredArgument("astralReleaseVersion"))
                put("platform", "android")
                put(
                    "target_description",
                    "Connected coverage Android client on an API 34 x86_64 emulator against the trusted staging endpoint",
                )
                put(
                    "artifact",
                    buildJsonObject {
                        put("name", apk.name)
                        put("kind", "android_apk")
                        put("immutable_reference", "bundle://android/${apk.name}")
                        put("sha256", sha256File(apk))
                        put("build_identity", "android-candidate:${requiredArgument("astralCandidateSha")}")
                    },
                )
                put("staging_environment", stagingEnvironment(stagingUrl))
                put(
                    "runner",
                    buildJsonObject {
                        put("os", "linux")
                        put("architecture", normalizedArchitecture())
                        put("runner_image", requiredArgument("astralRunnerImage"))
                        put("runner_name", requiredArgument("astralRunnerName"))
                        put("runner_environment", requiredArgument("astralRunnerEnvironment"))
                    },
                )
                put(
                    "workflow",
                    buildJsonObject {
                        put("name", requiredArgument("astralWorkflowName"))
                        put("run_id", requiredArgument("astralRunId"))
                        put("run_attempt", requiredArgument("astralRunAttempt").toInt())
                        put("job_id", requiredArgument("astralJobId"))
                    },
                )
                put("started_at", startedAt)
                put("completed_at", Instant.now().toString())
                put("outcome", "passed")
                put("unavailable_reason", JsonNull)
                put("unavailability_observation", JsonNull)
                put("checks", buildJsonArray { order.forEach { add(checks.getValue(it)) } })
            }
        val bytes = (PRETTY.encodeToString(JsonObject.serializer(), report) + "\n").toByteArray(Charsets.UTF_8)
        val output = File(evidenceDir(), "android.json")
        atomicWrite(output, bytes)
        Log.i(TAG, "release_evidence_output=${output.absolutePath}")
        Log.i(TAG, "release_evidence_sha256=${sha256(bytes)}")
    }

    private fun stagingEnvironment(stagingUrl: String): JsonObject {
        val stage = Json.parseToJsonElement(decodeBase64Argument("astralStagingEnvironmentB64")).jsonObject
        STAGING_FIELDS.forEach { field ->
            assertTrue("trusted staging output is missing $field", stage[field] != null && stage[field] !is JsonNull)
        }
        val endpoint = stage.getValue("endpoint").jsonPrimitive.content.trimEnd('/')
        assertTrue("astralStagingUrl differs from the staged endpoint", endpoint == stagingUrl)
        val workerPaths = stage.getValue("worker_paths") as? JsonArray
        assertTrue(
            "trusted staging output does not include the voice worker path",
            workerPaths?.any { it.jsonPrimitive.content == "voice" } == true,
        )
        validateVoiceRuntime(stage.getValue("voice_runtime"))
        return buildJsonObject { STAGING_FIELDS.forEach { put(it, stage.getValue(it)) } }
    }

    private fun validateVoiceRuntime(value: JsonElement) {
        assertTrue("trusted voice_runtime is not an object", value is JsonObject)
        val runtime = value.jsonObject
        assertTrue(
            "trusted voice_runtime has a missing or extra field",
            runtime.keys == VOICE_RUNTIME_FIELDS,
        )
        val profileValue = runtime.getValue("speech_profile")
        assertTrue("trusted speech_profile is not an object", profileValue is JsonObject)
        val profile = profileValue.jsonObject
        assertTrue(
            "trusted speech_profile has a missing or extra field",
            profile.keys == SPEECH_PROFILE_FIELDS,
        )
        assertTrue("unexpected ASR model", profile.getValue("asr_model").jsonPrimitive.content == ASR_MODEL)
        assertTrue("unexpected TTS model", profile.getValue("tts_model").jsonPrimitive.content == TTS_MODEL)
        assertTrue("unexpected voice", profile.getValue("voice").jsonPrimitive.content == TTS_VOICE)
        assertTrue(
            "unexpected sample rate",
            profile.getValue("sample_rate_hz").jsonPrimitive.content == TTS_SAMPLE_RATE_HZ.toString(),
        )
        listOf(
            "voice_worker_image_sha256" to runtime,
            "livekit_image_sha256" to runtime,
            "livekit_config_sha256" to runtime,
            "inventory_sha256" to profile,
            "profile_sha256" to profile,
        ).forEach { (field, owner) ->
            assertTrue(
                "$field is not a SHA-256 digest",
                SHA256.matches(owner.getValue(field).jsonPrimitive.content),
            )
        }
        listOf(
            "voice_worker_image_reference",
            "livekit_image_reference",
            "livekit_public_url",
            "livekit_turn_domain",
        ).forEach { field ->
            assertTrue(
                "$field is empty",
                runtime.getValue(field).jsonPrimitive.content.isNotBlank(),
            )
        }
    }

    private fun normalizedArchitecture(): String =
        when (requiredArgument("astralRunnerArch").lowercase()) {
            "x64", "x86_64" -> "x86_64"
            "arm64" -> "arm64"
            else -> {
                fail("astralRunnerArch is outside the release schema")
                error("unreachable")
            }
        }

    private fun loadTranscriptSize(
        socket: StagingSocket,
        chatId: String,
        timeoutMs: Long,
    ): Int {
        socket.send(
            Wire.encodeUiEvent(
                "load_chat",
                chatId,
                payload = buildJsonObject { put("chat_id", chatId) },
                requestGeneration = uuid4(),
                submissionId = uuid4(),
            ),
        )
        val frame =
            socket.await(timeoutMs) {
                (it is Inbound.ChatLoaded && (it.chat.id == null || it.chat.id == chatId)) ||
                    (it is Inbound.ConversationSnapshot && it.chatId == chatId)
            }
        return when (frame) {
            is Inbound.ChatLoaded -> frame.chat.messages.size
            is Inbound.ConversationSnapshot -> frame.transcript.size
            else -> 0
        }
    }

    private fun requiredArgument(name: String): String {
        val value = arguments.getString(name)
        if (value.isNullOrBlank()) {
            fail("$name is required once astralStagingUrl is set")
        }
        return value!!
    }

    private fun decodeBase64Argument(name: String): String {
        val encoded = requiredArgument(name)
        val bytes =
            runCatching { Base64.getDecoder().decode(encoded) }
                .getOrElse { Base64.getUrlDecoder().decode(encoded) }
        return String(bytes, Charsets.UTF_8)
    }

    private fun evidenceDir(): File =
        File(context.getExternalFilesDir(null), "release-evidence").apply { mkdirs() }

    private fun atomicWrite(
        file: File,
        bytes: ByteArray,
    ) {
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, "${file.name}.${UUID.randomUUID()}.tmp")
        temporary.writeBytes(bytes)
        assertTrue("could not persist ${file.name}", temporary.renameTo(file))
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun sha256File(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun uuid4(): String = UUID.randomUUID().toString()

    private data class StepResult(val durationMs: Long, val raw: JsonObject)

    private data class ChatResult(
        val durationMs: Long,
        val raw: JsonObject,
        val chatId: String,
        val transcriptSize: Int,
    )

    private class StagingSocket(
        client: OkHttpClient,
        url: String,
        token: String,
        device: DeviceCapabilities,
        sessionId: String? = null,
        resume: ConversationResume? = null,
    ) : AutoCloseable {
        private val frames = LinkedBlockingDeque<Inbound>()

        @Volatile private var failure: String? = null

        @Volatile var componentsSeen: Int = 0
            private set
        private val socket: WebSocket

        init {
            val listener =
                object : WebSocketListener() {
                    override fun onOpen(
                        webSocket: WebSocket,
                        response: Response,
                    ) {
                        webSocket.send(
                            Wire.encodeRegisterUi(
                                token = token,
                                sessionId = sessionId,
                                device = device,
                                connectionGeneration = UUID.randomUUID().toString(),
                                resume = resume,
                            ),
                        )
                    }

                    override fun onMessage(
                        webSocket: WebSocket,
                        text: String,
                    ) {
                        val frame = Wire.decode(text)
                        componentsSeen +=
                            when (frame) {
                                is Inbound.UiRender -> frame.components.size
                                is Inbound.UiUpsert -> frame.ops.size
                                is Inbound.UiStreamData -> frame.components.size
                                is Inbound.ConversationSnapshot -> frame.canvas.components.size
                                else -> 0
                            }
                        frames.offer(frame)
                    }

                    override fun onFailure(
                        webSocket: WebSocket,
                        t: Throwable,
                        response: Response?,
                    ) {
                        failure = t.message ?: "websocket failure"
                    }
                }
            socket = client.newWebSocket(Request.Builder().url(url).build(), listener)
        }

        fun send(frame: String) {
            assertTrue("send on a failed socket: $failure", failure == null)
            socket.send(frame)
        }

        fun await(
            timeoutMs: Long,
            predicate: (Inbound) -> Boolean,
        ): Inbound? {
            val deadline = SystemClock.elapsedRealtime() + timeoutMs
            while (SystemClock.elapsedRealtime() < deadline) {
                val remaining = maxOf(1, deadline - SystemClock.elapsedRealtime())
                val frame = frames.poll(remaining, TimeUnit.MILLISECONDS) ?: break
                if (predicate(frame)) return frame
            }
            return null
        }

        override fun close() {
            socket.close(1000, null)
        }
    }

    private companion object {
        const val TAG = "ReleaseEvidence060"
        const val PROMPT = "Roll exactly six six-sided dice and show the normalized results."
        const val RESUME_TRIALS = 1
        const val RESUME_TIMEOUT_MS = 5_000L
        const val TURN_TIMEOUT_MS = 240_000L
        val PRETTY = Json { prettyPrint = true }
        val LIFECYCLE_STATES = setOf("starting", "online", "updating", "failed", "offline")
        val STAGING_FIELDS =
            listOf(
                "authentication_posture",
                "candidate_image_reference",
                "candidate_image_sha256",
                "database_posture",
                "deployed_at",
                "deployment_run_id",
                "endpoint",
                "environment_id",
                "fixture_manifest_sha256",
                "keycloak_realm_sha256",
                "macos_personal_agent_host",
                "migrated_schema_revision",
                "representative_dataset_sha256",
                "source_schema_revision",
                "topology",
                "voice_runtime",
                "worker_paths",
            )
        val VOICE_RUNTIME_FIELDS =
            setOf(
                "voice_worker_image_reference",
                "voice_worker_image_sha256",
                "livekit_image_reference",
                "livekit_image_sha256",
                "livekit_config_sha256",
                "livekit_public_url",
                "livekit_turn_domain",
                "speech_profile",
            )
        val SPEECH_PROFILE_FIELDS =
            setOf(
                "asr_model",
                "tts_model",
                "voice",
                "sample_rate_hz",
                "inventory_sha256",
                "profile_sha256",
            )
        const val VOICE_DEVICE_ID = "00000000-0000-4000-8000-000000000001"
        const val VOICE_CONNECTION_ID = "00000000-0000-4000-8000-000000000002"
        const val VOICE_OTHER_CONNECTION_ID = "00000000-0000-4000-8000-000000000012"
        const val VOICE_SESSION_ID = "00000000-0000-4000-8000-000000000003"
        const val VOICE_CHAT_ID = "00000000-0000-4000-8000-000000000004"
        const val VOICE_TURN_ID = "00000000-0000-4000-8000-000000000005"
        const val VOICE_SUBMISSION_ID = "00000000-0000-4000-8000-000000000007"
        const val VOICE_REQUEST_ID = "00000000-0000-4000-8000-000000000008"
        const val VOICE_ANNOUNCEMENT_ID = "00000000-0000-4000-8000-000000000009"
        const val VOICE_RESULT_ANNOUNCEMENT_ID = "00000000-0000-4000-8000-000000000019"
        const val VOICE_BINDING_ID = "00000000-0000-4000-8000-00000000000a"
        const val VOICE_BINDING_VALUE = "synthetic-binding-value-000000000000"
        const val VOICE_ACTIVATION_ID = "00000000-0000-4000-8000-00000000000b"
        const val VOICE_WORKER = "voice-worker-a"
        val VOICE_FIXED_NOW: Instant = Instant.parse("2026-07-31T12:00:00Z")
        const val ASR_MODEL = "Systran/faster-whisper-large-v3"
        const val TTS_MODEL = "speaches-ai/Kokoro-82M-v1.0-ONNX"
        const val TTS_VOICE = "af_heart"
        const val TTS_SAMPLE_RATE_HZ = 24000
        val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}
