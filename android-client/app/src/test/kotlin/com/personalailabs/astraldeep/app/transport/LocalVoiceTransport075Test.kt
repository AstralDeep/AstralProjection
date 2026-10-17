// Tests for the transport that sends client-local voice frames over the authenticated UI socket:
// exact byte pass-through on the live connection only, with no separate dispatch and no offline
// queueing because the local voice runtime owns exact immutable retries.

package com.personalailabs.astraldeep.app.transport

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

class LocalVoiceTransport075Test {
    @Test
    fun localVoiceFramesPassThroughVerbatimOnTheExactLiveSocketAndNeverQueue() {
        val socket = RecordingWebSocket()
        val client = OrchestratorClient("ws://localhost:9/ws")
        client.replayPendingForTest(CONNECTION_ID, {}, {}, { true })
        client.installOpenSocketForTest(socket)

        assertTrue(client.sendVoiceLocalFrame(READY_FRAME))
        assertEquals(READY_FRAME, socket.frames.single())
        val frame = Json.parseToJsonElement(socket.frames.single()).jsonObject
        assertEquals("voice_local_ready", frame.getValue("type").jsonPrimitive.content)
        assertEquals(CONNECTION_ID, frame.getValue("connection_generation").jsonPrimitive.content)
        assertTrue(client.pendingActions().isEmpty())
        assertTrue(client.pendingFrames().isEmpty())

        assertTrue(client.sendVoiceLocalFrame(FINAL_FRAME))
        assertEquals(listOf(READY_FRAME, FINAL_FRAME), socket.frames)
        assertTrue(client.pendingActions().isEmpty())
    }

    @Test
    fun localVoiceFramesAreRefusedWithoutSocketOrAfterSendFailureAndNeverQueueOffline() {
        val closed = OrchestratorClient("ws://localhost:9/ws")
        assertFalse(closed.sendVoiceLocalFrame(READY_FRAME))
        assertTrue(closed.pendingActions().isEmpty())
        assertTrue(closed.pendingFrames().isEmpty())

        val failing = OrchestratorClient("ws://localhost:9/ws")
        val socket = RecordingWebSocket().apply { accepted = false }
        failing.replayPendingForTest(CONNECTION_ID, {}, {}, { true })
        failing.installOpenSocketForTest(socket)
        assertFalse(failing.sendVoiceLocalFrame(READY_FRAME))
        assertEquals(1, socket.frames.size)
        assertTrue(failing.pendingActions().isEmpty())
        assertTrue(failing.pendingFrames().isEmpty())

        val accepted = OrchestratorClient("ws://localhost:9/ws")
        val live = RecordingWebSocket()
        accepted.replayPendingForTest(CONNECTION_ID, {}, {}, { true })
        accepted.installOpenSocketForTest(live)
        assertTrue(accepted.sendVoiceLocalFrame(READY_FRAME))
        assertEquals(READY_FRAME, live.frames.single())
    }

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
        private const val CONNECTION_ID = "00000000-0000-4000-8000-000000000002"

        private val READY_FRAME =
            """
            {
              "type": "voice_local_ready",
              "schema_version": "2",
              "speech_backend": "client_local",
              "device_id": "00000000-0000-4000-8000-000000000001",
              "connection_generation": "$CONNECTION_ID",
              "session_id": "00000000-0000-4000-8000-000000000003",
              "generation": 1,
              "speech_revision": 1,
              "contract": "client_local/v1",
              "transport": "client_local",
              "configured_locale": "en-US",
              "full_duplex": false,
              "has_microphone": true,
              "has_audio_output": true,
              "microphone_permission": "authorized",
              "recognition_permission": "authorized",
              "recognition_processing": "guaranteed_local",
              "recognition_locale": "ready",
              "recognition_installation": "ready",
              "synthesis_processing": "guaranteed_local",
              "synthesis_locale": "ready",
              "client_sequence": 1
            }
            """.trimIndent()

        private val FINAL_FRAME =
            """
            {
              "type": "voice_local_final",
              "schema_version": "2",
              "speech_backend": "client_local",
              "device_id": "00000000-0000-4000-8000-000000000001",
              "connection_generation": "$CONNECTION_ID",
              "session_id": "00000000-0000-4000-8000-000000000003",
              "generation": 1,
              "speech_revision": 1,
              "client_turn_id": "00000000-0000-4000-8000-000000000005",
              "turn_id": "00000000-0000-4000-8000-000000000006",
              "submission_id": "00000000-0000-4000-8000-000000000007",
              "request_generation": "00000000-0000-4000-8000-000000000008",
              "chat_id": "00000000-0000-4000-8000-000000000004",
              "chat_context_revision": 1,
              "recognition_sequence": 1,
              "final": true,
              "recognized_locale": "en-US",
              "text": "check my schedule",
              "text_digest_sha256": "bf2a146c64ad6c2e07d2ffa471bb5339e88fc61eca42badd273b8a5a2362be4c"
            }
            """.trimIndent()
    }
}
