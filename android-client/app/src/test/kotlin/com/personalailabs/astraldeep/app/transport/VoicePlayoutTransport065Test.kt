// Tests for the transport that sends local voice-playout observation events over the authenticated UI socket.

package com.personalailabs.astraldeep.app.transport

import com.personalailabs.astraldeep.core.protocol.VoicePlayoutEvent
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Request
import okhttp3.WebSocket
import okio.ByteString
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VoicePlayoutTransport065Test {
    @Test
    fun playoutEvidenceUsesOnlyTheExactLiveConnectionAndIsNeverOfflineQueued() {
        val socket = RecordingWebSocket()
        val client = OrchestratorClient("ws://localhost:9/ws")
        client.replayPendingForTest(CONNECTION_ID, {}, {}, { true })
        client.installOpenSocketForTest(socket)

        assertTrue(client.sendVoicePlayoutEvent(event()))
        val sent = Json.parseToJsonElement(socket.frames.single()).jsonObject
        assertEquals("voice_playout_event", sent["type"]?.jsonPrimitive?.content)
        assertEquals(CONNECTION_ID, sent["connection_generation"]?.jsonPrimitive?.content)
        assertFalse("text" in sent)
        assertFalse("track_sid" in sent)
        assertTrue(client.pendingActions().isEmpty())

        assertFalse(client.sendVoicePlayoutEvent(event().copy(connectionGeneration = OTHER_CONNECTION_ID)))
        assertEquals(1, socket.frames.size)
        assertTrue(client.pendingActions().isEmpty())
    }

    @Test fun voiceHydrationUsesOrdinaryCorrelatedLoadAndNeverQueuesOffline() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val socket = RecordingWebSocket()
        assertEquals(null, client.loadChatForVoice(SESSION_ID, CONNECTION_ID) {})
        client.replayPendingForTest(CONNECTION_ID, {}, {}, { true })
        client.installOpenSocketForTest(socket)
        val bindings = mutableListOf<ConversationGenerationBinding>()
        client.observeConversationGenerations { bindings += it }
        var projected: LocalSubmission? = null
        assertEquals(null, client.loadChatForVoice(SESSION_ID, OTHER_CONNECTION_ID) {})
        val sent = client.loadChatForVoice(SESSION_ID, CONNECTION_ID) { projected = it }
        assertEquals(sent, projected)
        assertTrue(sent != null)
        val frame = Json.parseToJsonElement(socket.frames.single()).jsonObject
        assertEquals("ui_event", frame.getValue("type").jsonPrimitive.content)
        assertEquals("load_chat", frame.getValue("action").jsonPrimitive.content)
        assertEquals(sent?.requestGeneration, frame.getValue("request_generation").jsonPrimitive.content)
        assertEquals(sent?.submissionId, frame.getValue("submission_id").jsonPrimitive.content)
        assertEquals(ConversationRequestPurpose.HYDRATION, bindings.single().purpose)
        assertEquals(SESSION_ID, bindings.single().chatId)
        assertTrue(client.pendingActions().isEmpty())
        client.clearOwnerSession()
        assertEquals(null, client.loadChatForVoice(SESSION_ID, CONNECTION_ID) {})
        assertTrue(client.pendingActions().isEmpty())
    }

    @Test fun voiceHydrationRefusesOwnerRetirementAndSocketSendFailureWithoutReplay() {
        for (retire in listOf(false, true)) {
            val client = OrchestratorClient("ws://localhost:9/ws")
            val socket = RecordingWebSocket().apply { accepted = false }
            client.replayPendingForTest(CONNECTION_ID, {}, {}, { true })
            client.installOpenSocketForTest(socket)
            val result = client.loadChatForVoice(SESSION_ID, CONNECTION_ID) { if (retire) client.clearOwnerSession() }
            assertEquals(null, result)
            assertEquals(if (retire) 0 else 1, socket.frames.size)
            assertTrue(client.pendingActions().isEmpty())
        }
    }

    private fun event() =
        VoicePlayoutEvent(
            deviceId = DEVICE_ID,
            connectionGeneration = CONNECTION_ID,
            sessionId = SESSION_ID,
            generation = 1,
            mediaGrantRevision = 1,
            announcementId = ANNOUNCEMENT_ID,
            announcementSequence = 1,
            turnId = TURN_ID,
            kind = "acknowledgement",
            quantumRole = "single",
            quantumIndex = 0,
            resultReservedSamplesAfter = null,
            phase = "started",
            clientSequence = 0,
            observedAt = "2026-07-31T12:00:00Z",
        )

    private class RecordingWebSocket : WebSocket {
        val frames = mutableListOf<String>()
        var accepted = true

        override fun request(): Request = Request.Builder().url("ws://localhost:9/ws").build()

        override fun queueSize(): Long = 0L

        override fun send(text: String): Boolean {
            frames += text
            return accepted
        }

        override fun send(bytes: ByteString): Boolean = false

        override fun close(
            code: Int,
            reason: String?,
        ): Boolean = true

        override fun cancel() = Unit
    }

    companion object {
        private const val DEVICE_ID = "00000000-0000-4000-8000-000000000001"
        private const val CONNECTION_ID = "00000000-0000-4000-8000-000000000002"
        private const val OTHER_CONNECTION_ID = "00000000-0000-4000-8000-000000000003"
        private const val SESSION_ID = "00000000-0000-4000-8000-000000000004"
        private const val TURN_ID = "00000000-0000-4000-8000-000000000005"
        private const val ANNOUNCEMENT_ID = "00000000-0000-4000-8000-000000000006"
    }
}
