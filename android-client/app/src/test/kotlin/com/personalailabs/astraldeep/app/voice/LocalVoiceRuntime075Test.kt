// Deterministic client-local voice runtime tests: the ready handshake, turn binding, immutable
// final retries with exact acknowledgements, the bounded failure ledger, bounded announcement
// playout with echo suppression, and background/mute suspension over fake speech and transport.

package com.personalailabs.astraldeep.app.voice

import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.LocalVoiceFrame
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class LocalVoiceRuntime075Test {
    private class RecordingSender : (String) -> Boolean {
        val frames = mutableListOf<JsonObject>()
        var accept = true

        override fun invoke(frame: String): Boolean {
            if (!accept) return false
            frames += Json.parseToJsonElement(frame).jsonObject
            return true
        }

        fun typed(type: String): List<JsonObject> = frames.filter { it.string("type") == type }
    }

    private class FakeEngine(private var facts: LocalSpeechFacts) : LocalSpeechEngine {
        var started = 0
        var stopRecognitionCalls = 0
        var stopAllCalls = 0
        var speakText: String? = null
        var speakLocale: String? = null
        var onFinal: ((String) -> Unit)? = null
        var onError: ((String) -> Unit)? = null
        var speakStarted: (() -> Unit)? = null
        var speakDone: ((Boolean) -> Unit)? = null

        override suspend fun probe(): LocalSpeechFacts = facts

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

        override fun stopRecognition() {
            stopRecognitionCalls += 1
        }

        override fun stopAll() {
            stopAllCalls += 1
        }

        override fun speak(
            text: String,
            locale: String,
            onStarted: () -> Unit,
            onDone: (Boolean) -> Unit,
        ): Boolean {
            speakText = text
            speakLocale = locale
            speakStarted = onStarted
            speakDone = onDone
            return true
        }
    }

    private class Harness(scope: TestScope) {
        var now = Instant.parse(NOW)
        val sender = RecordingSender()
        val engine = FakeEngine(readyFacts())
        val events = mutableListOf<LocalVoiceUiEvent>()
        private var uuidCounter = 0
        val runtime =
            LocalVoiceRuntime(
                scope = scope.backgroundScope,
                engine = engine,
                send = { frame -> sender.invoke(frame) },
                clock = { now },
                uuidFactory = { nextUuid() },
                onEvent = { event -> events += event },
            )

        private fun nextUuid(): String {
            uuidCounter += 1
            return "00000000-0000-4000-8000-0000000000${uuidCounter + 10}"
        }

        fun start() {
            runtime.start(localSession(), requirements(), capability())
        }
    }

    @Test
    fun readyHandshakeConsumesExactlyOneFreshSessionReadyAndStartsOneCycle() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertEquals(listOf("voice_local_ready"), harness.sender.frames.map { it.string("type") })
            assertEquals(1, harness.sender.typed("voice_local_ready").single().int("client_sequence"))
            assertEquals("client_local/v1", harness.sender.typed("voice_local_ready").single().string("contract"))

            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            assertEquals("voice_local_recognition_started", harness.sender.frames.last().string("type"))
            val started = harness.sender.typed("voice_local_recognition_started").single()
            assertEquals(1, started.int("recognition_sequence"))
            assertEquals(1, harness.engine.started)
            assertFalse(started.keys.contains("turn_id"))

            assertFalse(harness.runtime.acceptFrame(sessionReady()))
            assertEquals(1, harness.engine.started)
            assertEquals(1, harness.sender.typed("voice_local_recognition_started").size)
        }

    @Test
    fun staleConnectionSessionGenerationAndRevisionFramesAreRefused() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()

            assertFalse(harness.runtime.acceptFrame(sessionReady(deviceId = OTHER_DEVICE)))
            assertFalse(harness.runtime.acceptFrame(sessionReady(connection = OTHER_CONNECTION)))
            assertFalse(harness.runtime.acceptFrame(sessionReady(sessionId = OTHER_SESSION)))
            assertFalse(harness.runtime.acceptFrame(sessionReady(generation = 2)))
            assertFalse(harness.runtime.acceptFrame(sessionReady(speechRevision = 2)))
            assertEquals(1, harness.sender.typed("voice_local_recognition_started").size)
        }

    @Test
    fun finalWaitsForTurnBindingThenSendsOneImmutableFrameAndRetriesExactBytesUntilExactAck() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            val clientTurnId = harness.sender.typed("voice_local_recognition_started").single().string("client_turn_id")!!

            harness.engine.onFinal?.invoke("check my schedule")
            assertTrue(harness.sender.typed("voice_local_final").isEmpty())

            assertTrue(harness.runtime.acceptFrame(turnBound(clientTurnId = clientTurnId)))
            val finals = harness.sender.typed("voice_local_final")
            assertEquals(1, finals.size)
            val final = finals.single()
            assertEquals("check my schedule", final.string("text"))
            assertEquals(sha256Hex("check my schedule"), final.string("text_digest_sha256"))
            assertEquals(true, final.bool("final"))
            assertEquals("en-US", final.string("recognized_locale"))
            assertEquals(clientTurnId, final.string("client_turn_id"))
            val immutableBytes = final.toString()

            advanceTimeBy(2_500)
            assertEquals(2, harness.sender.typed("voice_local_final").size)
            assertEquals(immutableBytes, harness.sender.typed("voice_local_final").last().toString())

            assertFalse(harness.runtime.acceptMessageAck(ack(submissionId = OTHER_SUBMISSION)))
            assertTrue(harness.runtime.acceptMessageAck(ack()))
            assertEquals(2, harness.sender.typed("voice_local_final").size)

            advanceTimeBy(30_000)
            assertEquals(2, harness.sender.typed("voice_local_final").size)
            assertEquals("voice_local_recognition_started", harness.sender.frames.last().string("type"))
            assertEquals(2, harness.engine.started)
        }

    @Test
    fun boundTurnsRejectDuplicateAndUnknownBindingsWithoutResendingTheFinal() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            val clientTurnId = harness.sender.typed("voice_local_recognition_started").single().string("client_turn_id")!!
            harness.engine.onFinal?.invoke("first request")
            assertTrue(harness.runtime.acceptFrame(turnBound(clientTurnId = clientTurnId)))
            assertEquals(1, harness.sender.typed("voice_local_final").size)

            assertFalse(harness.runtime.acceptFrame(turnBound(clientTurnId = clientTurnId)))
            assertFalse(harness.runtime.acceptFrame(turnBound(clientTurnId = clientTurnId, turnId = OTHER_TURN)))
            assertFalse(harness.runtime.acceptFrame(turnBound(clientTurnId = OTHER_TURN)))
            assertEquals(1, harness.sender.typed("voice_local_final").size)
        }

    @Test
    fun finalAckTimeoutFailsClosedAndRefusesLaterTrafficForTheTurn() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            val clientTurnId = harness.sender.typed("voice_local_recognition_started").single().string("client_turn_id")!!
            harness.engine.onFinal?.invoke("secret acceptance text")
            assertTrue(harness.runtime.acceptFrame(turnBound(clientTurnId = clientTurnId)))
            assertEquals(1, harness.sender.typed("voice_local_final").size)

            harness.now = harness.now.plusSeconds(121)
            advanceTimeBy(121_000)
            runCurrent()

            assertEquals(1, harness.sender.typed("voice_local_final").size)
            assertFalse(harness.runtime.acceptFrame(sessionReady()))
            assertFalse(harness.runtime.acceptMessageAck(ack()))
            assertEquals("stale_local_turn", harness.events.lastOrNull()?.reason)
            assertTrue(harness.events.lastOrNull()?.unrecoverable == true)
        }

    @Test
    fun finalRejectedClearsPendingRestartsAndIgnoresStaleRejections() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            val clientTurnId = harness.sender.typed("voice_local_recognition_started").single().string("client_turn_id")!!
            harness.engine.onFinal?.invoke("rejected text")
            assertTrue(harness.runtime.acceptFrame(turnBound(clientTurnId = clientTurnId)))
            assertEquals(1, harness.sender.typed("voice_local_final").size)

            assertTrue(harness.runtime.acceptFrame(finalRejected(clientTurnId = clientTurnId)))
            assertEquals("stale_speech_revision", harness.events.lastOrNull()?.reason)
            assertEquals("error", harness.events.lastOrNull()?.phase)
            runCurrent()
            assertEquals(2, harness.sender.typed("voice_local_recognition_started").size)

            assertFalse(harness.runtime.acceptFrame(finalRejected(clientTurnId = OTHER_TURN)))
            assertEquals(2, harness.sender.typed("voice_local_recognition_started").size)
        }

    @Test
    fun turnBindingTimeoutScrubsThePendingFinalAndRestartsWithoutReportingAFailure() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            val firstTurn = harness.sender.typed("voice_local_recognition_started").single().string("client_turn_id")!!
            harness.engine.onFinal?.invoke("text that must be scrubbed")

            harness.now = harness.now.plusSeconds(121)
            advanceTimeBy(121_000)
            runCurrent()

            assertEquals(2, harness.sender.typed("voice_local_recognition_started").size)
            assertTrue(harness.sender.typed("voice_local_final").isEmpty())
            assertTrue(harness.sender.typed("voice_local_recognition_failed").isEmpty())
            assertFalse(harness.runtime.acceptFrame(turnBound(clientTurnId = firstTurn)))
            assertTrue(harness.sender.typed("voice_local_recognition_failed").isEmpty())
            harness.engine.onFinal?.invoke("sensitive timeout text")
            assertTrue(harness.sender.typed("voice_local_final").isEmpty())
        }

    @Test
    fun backgroundSuspendsEverythingAndResumeRequiresANewHandshake() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            val clientTurnId = harness.sender.typed("voice_local_recognition_started").single().string("client_turn_id")!!

            harness.runtime.suspendForBackground()
            assertEquals(1, harness.engine.stopAllCalls)
            assertFalse(harness.runtime.acceptFrame(sessionReady()))
            assertEquals(1, harness.sender.typed("voice_local_recognition_started").size)

            assertTrue(harness.runtime.resumeForeground())
            assertEquals(2, harness.sender.typed("voice_local_ready").size)
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            advanceTimeBy(500)
            runCurrent()
            assertEquals(2, harness.sender.typed("voice_local_recognition_started").size)

            assertTrue(harness.runtime.acceptFrame(turnBound(clientTurnId = clientTurnId)))
            val failure = harness.sender.typed("voice_local_recognition_failed").single()
            assertEquals(clientTurnId, failure.string("client_turn_id"))
            assertEquals("local_recognition_cancelled", failure.string("reason"))
        }

    @Test
    fun muteStopsSpeechAndPlayoutAndUnmuteReauthorizesBeforeRecognition() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            assertTrue(harness.runtime.acceptFrame(announcement(text = "I am listening.", sequence = 1)))
            harness.engine.speakStarted?.invoke()
            assertEquals("started", harness.sender.typed("voice_local_playout_event").single().string("phase"))

            harness.runtime.stopOwners("stopped_by_user")
            assertEquals(1, harness.engine.stopAllCalls)
            val playout = harness.sender.typed("voice_local_playout_event")
            assertEquals("interrupted", playout.last().string("phase"))
            assertEquals("stopped_by_user", playout.last().string("reason"))

            harness.runtime.reconcileAfterControlChange()
            assertEquals(2, harness.sender.typed("voice_local_ready").size)
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            advanceTimeBy(500)
            runCurrent()
            assertEquals(2, harness.sender.typed("voice_local_recognition_started").size)
        }

    @Test
    fun announcementsValidateSequenceDigestTtlLocaleAndRevisions() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()

            assertFalse(harness.runtime.acceptFrame(announcement(text = "I\u2019m listening.", sequence = 2)))
            assertTrue(harness.runtime.acceptFrame(announcement(text = "I\u2019m listening.", sequence = 1)))
            assertEquals(0, harness.sender.typed("voice_local_playout_event").size)
            harness.engine.speakStarted?.invoke()
            assertEquals("started", harness.sender.typed("voice_local_playout_event").single().string("phase"))

            assertFalse(harness.runtime.acceptFrame(announcement(text = "tampered text", sequence = 2)))
            assertFalse(harness.runtime.acceptFrame(announcement(text = "I\u2019m listening.", sequence = 2, locale = "fr-FR")))
            assertFalse(harness.runtime.acceptFrame(announcement(text = "I\u2019m listening.", sequence = 2, expired = true)))
            assertFalse(harness.runtime.acceptFrame(announcement(text = "I\u2019m listening.", sequence = 2, muteRevision = 0)))
            assertEquals(1, harness.sender.typed("voice_local_playout_event").size)

            harness.engine.speakDone?.invoke(true)
            runCurrent()
            assertEquals(
                listOf("started", "finished"),
                harness.sender.typed("voice_local_playout_event").map { it.string("phase") },
            )
            assertNull(harness.sender.typed("voice_local_playout_event").last().string("reason"))
        }

    @Test
    fun announcementExpiryInterruptsPlayoutAndReportsExpired() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            assertTrue(harness.runtime.acceptFrame(announcement(text = "Long progress note.", sequence = 1)))
            harness.engine.speakStarted?.invoke()
            assertEquals("started", harness.sender.typed("voice_local_playout_event").single().string("phase"))

            harness.now = harness.now.plusSeconds(11)
            advanceTimeBy(11_000)
            runCurrent()

            assertEquals(1, harness.engine.stopAllCalls)
            val event = harness.sender.typed("voice_local_playout_event").last()
            assertEquals("failed", event.string("phase"))
            assertEquals("local_announcement_expired", event.string("reason"))
        }

    @Test
    fun interruptedSynthesisReportsFailedAndEchoSuppressesTheNextCycle() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            assertTrue(harness.runtime.acceptFrame(announcement(text = "Progress update.", sequence = 1)))
            harness.engine.speakStarted?.invoke()

            harness.engine.speakDone?.invoke(false)
            runCurrent()
            val event = harness.sender.typed("voice_local_playout_event").last()
            assertEquals("failed", event.string("phase"))
            assertEquals("local_synthesis_failed", event.string("reason"))

            advanceTimeBy(499)
            runCurrent()
            assertEquals(1, harness.sender.typed("voice_local_recognition_started").size)

            advanceTimeBy(1)
            runCurrent()
            assertEquals(2, harness.sender.typed("voice_local_recognition_started").size)
        }

    @Test
    fun echoSuppressionDelaysRecognitionRestartAfterFinishedPlayout() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            assertEquals(1, harness.sender.typed("voice_local_recognition_started").size)
            assertTrue(harness.runtime.acceptFrame(announcement(text = "Greeting first.", sequence = 1)))
            harness.engine.speakStarted?.invoke()
            harness.engine.speakDone?.invoke(true)
            runCurrent()
            assertEquals(1, harness.sender.typed("voice_local_recognition_started").size)

            advanceTimeBy(500)
            runCurrent()
            assertEquals(2, harness.sender.typed("voice_local_recognition_started").size)
        }

    @Test
    fun recognitionFailureBeforeBindingIsRetainedAndFlushedOnLateBinding() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            val firstTurn = harness.sender.typed("voice_local_recognition_started").single().string("client_turn_id")!!
            harness.engine.onError?.invoke("local_recognition_failed")
            runCurrent()
            assertTrue(harness.sender.typed("voice_local_recognition_failed").isEmpty())
            assertEquals(2, harness.sender.typed("voice_local_recognition_started").size)

            assertTrue(harness.runtime.acceptFrame(turnBound(clientTurnId = firstTurn)))
            assertEquals(1, harness.sender.typed("voice_local_recognition_failed").size)
            assertEquals(firstTurn, harness.sender.typed("voice_local_recognition_failed").single().string("client_turn_id"))
            runCurrent()
            assertEquals(2, harness.sender.typed("voice_local_recognition_started").size)
        }

    @Test
    fun oversizedEmptyAndControlCharacterFinalsFailClosed() =
        runTest {
            assertEquals("local_final_empty", canonicalizeLocalFinal("   ", 8000).reason)
            assertNull(canonicalizeLocalFinal("   ", 8000).text)
            assertEquals("local_final_malformed", canonicalizeLocalFinal("x".repeat(8001), 8000).reason)
            assertEquals("local_final_malformed", canonicalizeLocalFinal("bad\u0007text", 8000).reason)
            assertNull(canonicalizeLocalFinal("bad\u0000text", 8000).text)
            assertEquals("cleaned text", canonicalizeLocalFinal("cleaned text\r\n", 8000).text)
        }

    @Test
    fun messageAckRequiresExactSubmissionTurnChatRequestAndConnection() =
        runTest {
            val harness = Harness(this)
            harness.start()
            assertTrue(harness.runtime.acceptFrame(sessionReady()))
            runCurrent()
            val clientTurnId = harness.sender.typed("voice_local_recognition_started").single().string("client_turn_id")!!
            harness.engine.onFinal?.invoke("acked text")
            assertTrue(harness.runtime.acceptFrame(turnBound(clientTurnId = clientTurnId)))
            assertFalse(harness.runtime.acceptMessageAck(ack(connection = OTHER_CONNECTION)))
            assertFalse(harness.runtime.acceptMessageAck(ack(voiceTurnId = OTHER_TURN)))
            assertTrue(harness.runtime.acceptMessageAck(ack()))
            assertTrue(harness.events.lastOrNull()?.accepted == true)
        }

    companion object {
        private const val DEVICE_ID = "00000000-0000-4000-8000-000000000001"
        private const val CONNECTION_ID = "00000000-0000-4000-8000-000000000002"
        private const val SESSION_ID = "00000000-0000-4000-8000-000000000003"
        private const val CHAT_ID = "00000000-0000-4000-8000-000000000004"
        private const val TURN_ID = "00000000-0000-4000-8000-000000000006"
        private const val SUBMISSION_ID = "00000000-0000-4000-8000-000000000007"
        private const val REQUEST_ID = "00000000-0000-4000-8000-000000000008"
        private const val ANNOUNCEMENT_ID = "00000000-0000-4000-8000-000000000009"
        private const val OTHER_DEVICE = "00000000-0000-4000-8000-0000000000a1"
        private const val OTHER_CONNECTION = "00000000-0000-4000-8000-0000000000a2"
        private const val OTHER_SESSION = "00000000-0000-4000-8000-0000000000a3"
        private const val OTHER_SUBMISSION = "00000000-0000-4000-8000-0000000000a7"
        private const val OTHER_TURN = "00000000-0000-4000-8000-0000000000a6"
        private const val NOW = "2026-08-28T12:00:00Z"

        private fun readyFacts() =
            LocalSpeechFacts(
                hasMicrophone = true,
                hasAudioOutput = true,
                microphonePermission = "authorized",
                recognitionServiceAvailable = true,
                recognitionOnDevice = true,
                recognitionLocaleState = "ready",
                recognitionInstallation = "ready",
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

        private fun requirements() =
            LocalVoiceRequirements(
                configuredLocale = "en-US",
                maxFinalUnicodeScalars = 8000,
                maxAnnouncementUtf8Bytes = 600,
                announcementTtlSeconds = 10,
                echoSuppressionMilliseconds = 500,
            )

        private fun capability() =
            LocalSpeechCapability(
                hasMicrophone = true,
                hasAudioOutput = true,
                microphonePermission = "authorized",
                recognitionPermission = "authorized",
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

        private fun parse(map: Map<String, JsonPrimitive>): LocalVoiceFrame = requireNotNull(LocalVoiceFrame.fromJson(JsonObject(map)))

        private fun sessionReady(
            deviceId: String = DEVICE_ID,
            connection: String = CONNECTION_ID,
            sessionId: String = SESSION_ID,
            generation: Int = 1,
            speechRevision: Int = 1,
        ): LocalVoiceFrame =
            parse(
                common("voice_local_session_ready") +
                    mapOf(
                        "device_id" to JsonPrimitive(deviceId),
                        "connection_generation" to JsonPrimitive(connection),
                        "session_id" to JsonPrimitive(sessionId),
                        "generation" to JsonPrimitive(generation),
                        "speech_revision" to JsonPrimitive(speechRevision),
                        "contract" to JsonPrimitive("client_local/v1"),
                        "transport" to JsonPrimitive("client_local"),
                        "configured_locale" to JsonPrimitive("en-US"),
                        "chat_id" to JsonPrimitive(CHAT_ID),
                        "chat_context_revision" to JsonPrimitive(1),
                        "applied_chat_context_revision" to JsonPrimitive(1),
                        "foreground_active" to JsonPrimitive(true),
                        "microphone_enabled" to JsonPrimitive(true),
                        "speech_muted" to JsonPrimitive(false),
                        "lease_expires_at" to JsonPrimitive("2026-08-28T12:02:00Z"),
                    ),
            )

        private fun turnBound(
            clientTurnId: String,
            turnId: String = TURN_ID,
        ): LocalVoiceFrame =
            parse(
                common("voice_local_turn_bound") +
                    mapOf(
                        "client_turn_id" to JsonPrimitive(clientTurnId),
                        "turn_id" to JsonPrimitive(turnId),
                        "submission_id" to JsonPrimitive(SUBMISSION_ID),
                        "request_generation" to JsonPrimitive(REQUEST_ID),
                        "chat_id" to JsonPrimitive(CHAT_ID),
                        "chat_context_revision" to JsonPrimitive(1),
                        "recognition_sequence" to JsonPrimitive(1),
                        "binding_expires_at" to JsonPrimitive("2026-08-28T12:01:00Z"),
                    ),
            )

        private fun finalRejected(clientTurnId: String): LocalVoiceFrame =
            parse(
                common("voice_local_final_rejected") +
                    mapOf(
                        "client_turn_id" to JsonPrimitive(clientTurnId),
                        "turn_id" to JsonPrimitive(TURN_ID),
                        "submission_id" to JsonPrimitive(SUBMISSION_ID),
                        "request_generation" to JsonPrimitive(REQUEST_ID),
                        "chat_id" to JsonPrimitive(CHAT_ID),
                        "chat_context_revision" to JsonPrimitive(1),
                        "recognition_sequence" to JsonPrimitive(1),
                        "reason" to JsonPrimitive("stale_speech_revision"),
                        "retry_policy" to JsonPrimitive("none"),
                        "occurred_at" to JsonPrimitive(NOW),
                    ),
            )

        private fun announcement(
            text: String,
            sequence: Int,
            locale: String = "en-US",
            expired: Boolean = false,
            muteRevision: Int = 1,
        ): LocalVoiceFrame =
            parse(
                common("voice_local_announcement") +
                    mapOf(
                        "announcement_id" to JsonPrimitive(ANNOUNCEMENT_ID),
                        "announcement_sequence" to JsonPrimitive(sequence),
                        "turn_id" to JsonPrimitive("00000000-0000-4000-8000-0000000000be"),
                        "kind" to JsonPrimitive("progress"),
                        "output_policy" to JsonPrimitive("lifecycle"),
                        "locale" to JsonPrimitive(locale),
                        "text" to JsonPrimitive(text),
                        "text_digest_sha256" to JsonPrimitive(sha256Hex(text)),
                        "expires_at" to JsonPrimitive(if (expired) "2026-08-28T11:59:59Z" else "2026-08-28T12:00:09Z"),
                        "foreground_required" to JsonPrimitive(true),
                        "mute_revision" to JsonPrimitive(muteRevision),
                        "consent_revision" to JsonPrimitive(1),
                    ),
            )

        private fun ack(
            submissionId: String = SUBMISSION_ID,
            connection: String = CONNECTION_ID,
            voiceTurnId: String = TURN_ID,
        ): Inbound.UserMessageAcked =
            Inbound.UserMessageAcked(
                chatId = CHAT_ID,
                messageId = "1",
                submissionId = submissionId,
                requestGeneration = REQUEST_ID,
                connectionGeneration = connection,
                voiceTurnId = voiceTurnId,
            )
    }
}
