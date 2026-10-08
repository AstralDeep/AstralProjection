// Verifies ordinary settings requests use the current socket and retain their action correlation without replay.
package com.personalailabs.astraldeep.app.transport

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.Request
import okhttp3.WebSocket
import okio.ByteString
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SettingsTransportTest {
    private val connection = "22222222-2222-4222-8222-222222222222"

    @Test
    fun settings_install_identity_before_physical_send_and_never_queue() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val payload = buildJsonObject { put("preset", "nord") }
        assertFalse(client.sendCurrentSettingsEvent("theme", "chrome_theme_preset", payload, { true }) { _, _ -> error("offline") })
        val socket = Socket()
        client.installOpenSocketForTest(socket)
        assertFalse(client.sendCurrentSettingsEvent("theme", "chrome_theme_preset", payload, { true }) { _, _ -> error("unregistered") })
        client.replayPendingForTest(connection, {}, {}, { true })
        var issued: LocalSubmission? = null
        socket.beforeSend = { assertTrue(issued != null) }
        assertTrue(
            client.sendCurrentSettingsEvent("theme", "chrome_theme_preset", payload, { true }) { submission, generation ->
                issued = submission
                assertEquals(connection, generation)
            },
        )
        val frame = Json.parseToJsonElement(socket.frames.single()).jsonObject
        assertEquals(issued!!.requestGeneration, frame["request_generation"]!!.jsonPrimitive.content)
        assertEquals("theme", frame["payload"]!!.jsonObject["surface"]!!.jsonPrimitive.content)
        assertEquals("nord", frame["payload"]!!.jsonObject["preset"]!!.jsonPrimitive.content)
        assertTrue(client.pendingActions().isEmpty())
    }

    @Test
    fun retired_owner_socket_generation_navigation_and_send_failure_never_replay() {
        for (change in listOf("owner", "socket", "generation", "navigation", "failure")) {
            val client = OrchestratorClient("ws://localhost:9/ws")
            val socket = Socket()
            client.installOpenSocketForTest(socket)
            client.replayPendingForTest(connection, {}, {}, { true })
            var current = true
            assertFalse(
                client.sendCurrentSettingsEvent("llm", "chrome_llm_models", buildJsonObject { put("provider", "custom") }, { current }) { _, _ ->
                    when (change) {
                        "owner" -> client.clearOwnerSession()
                        "socket" -> client.installOpenSocketForTest(Socket())
                        "generation" -> client.replayPendingForTest("33333333-3333-4333-8333-333333333333", {}, {}, { true })
                        "failure" -> socket.accept = false
                        else -> current = false
                    }
                },
            )
            assertTrue(socket.frames.isEmpty())
            assertTrue(client.pendingActions().isEmpty())
        }
    }

    @Test
    fun private_surfaces_use_their_existing_strict_sender() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val socket = Socket()
        client.installOpenSocketForTest(socket)
        client.replayPendingForTest(connection, {}, {}, { true })
        for (surface in listOf("", "work", "guidance", "agent_intro")) {
            assertFalse(client.sendCurrentSettingsEvent(surface, "chrome_open", buildJsonObject { put("surface", surface) }, { true }) { _, _ -> error("private") })
        }
        assertTrue(socket.frames.isEmpty())
    }

    @Test
    fun evidence_payload_is_unscoped_fresh_current_connection_and_never_replayed() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val payload =
            buildJsonObject {
                put("surface", "evidence")
                putJsonObject("params") { put("kind", "usage") }
            }
        for (action in listOf("chrome_open", "chrome_close")) {
            client.sendEvent(action, "44444444-4444-4444-8444-444444444444", payload)
            assertTrue(client.pendingActions().isEmpty())
        }
        val socket = Socket()
        client.installOpenSocketForTest(socket)
        client.replayPendingForTest(connection, {}, {}, { true })
        var previous: String? = null
        repeat(2) {
            assertTrue(
                client.sendCurrentSettingsEvent("evidence", "chrome_open", payload, { true }) { submission, _ ->
                    assertFalse(submission.requestGeneration == previous)
                    previous = submission.requestGeneration
                },
            )
        }
        for (raw in socket.frames) {
            val frame = Json.parseToJsonElement(raw).jsonObject
            assertEquals("null", frame.getValue("session_id").toString())
            val fields = frame.getValue("payload").jsonObject
            assertEquals(setOf("surface", "params", "request_generation", "submission_id"), fields.keys)
            assertEquals(payload["params"], fields["params"])
        }
        assertTrue(client.pendingActions().isEmpty())
    }

    private class Socket : WebSocket {
        val frames = mutableListOf<String>()
        var accept = true
        var beforeSend: () -> Unit = {}

        override fun request(): Request = Request.Builder().url("ws://localhost:9/ws").build()

        override fun queueSize(): Long = 0

        override fun send(text: String): Boolean {
            beforeSend()
            if (accept) frames.add(text)
            return accept
        }

        override fun send(bytes: ByteString): Boolean = false

        override fun close(
            code: Int,
            reason: String?,
        ): Boolean = true

        override fun cancel() = Unit
    }
}
