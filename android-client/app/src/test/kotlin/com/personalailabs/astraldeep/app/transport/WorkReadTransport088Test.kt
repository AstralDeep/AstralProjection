// Tests for the work-surface read-request transport: sending a request and timing out under a stale
// generation.

package com.personalailabs.astraldeep.app.transport

import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Request
import okhttp3.WebSocket
import okio.ByteString
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WorkReadTransport088Test {
    private val connection = "22222222-2222-4222-8222-222222222222"

    @Test fun disconnected_and_unregistered_work_reads_never_queue() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val params = buildJsonObject { put("mode", "list") }
        client.sendEvent("get_history", null)
        client.sendEvent("chrome_open", null, buildJsonObject { put("surface", "work") })
        assertFalse(client.sendCurrentSurfaceEvent("work", "chrome_open", workPayload(params), { true }, { _, _ -> error("no submission") }))
        client.installOpenSocketForTest(Socket())
        assertFalse(client.sendCurrentSurfaceEvent("work", "chrome_open", workPayload(params), { true }, { _, _ -> error("no submission") }))
        assertEquals(listOf("get_history"), client.pendingActions())
    }

    @Test fun registered_read_installs_identity_before_send_and_failure_never_replays() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val socket = Socket()
        client.installOpenSocketForTest(socket)
        client.replayPendingForTest(connection, {}, {}, { true })
        val issued = mutableListOf<LocalSubmission>()
        socket.beforeSend = { assertTrue(issued.isNotEmpty()) }
        val params = buildJsonObject { put("mode", "detail") }
        assertTrue(
            client.sendCurrentSurfaceEvent("work", "chrome_open", workPayload(params), { true }) { value, generation ->
                assertEquals(connection, generation)
                issued.add(value)
            },
        )
        val frame = Json.parseToJsonElement(socket.frames.single()).jsonObject
        assertEquals("chrome_open", frame.getValue("action").jsonPrimitive.content)
        assertTrue(client.validQueuedIdentity(socket.frames.single(), issued.single()))
        assertEquals(params, frame.getValue("payload").jsonObject["params"])
        socket.accept = false
        assertFalse(client.sendCurrentSurfaceEvent("work", "chrome_open", workPayload(params), { true }) { value, _ -> issued.add(value) })
        assertTrue(issued[0].requestGeneration != issued[1].requestGeneration)
        assertTrue(client.pendingActions().isEmpty())
    }

    @Test fun callback_retirement_and_generation_changes_prevent_physical_send() {
        for (change in listOf("owner", "socket", "generation", "navigation")) {
            val client = OrchestratorClient("ws://localhost:9/ws")
            val socket = Socket()
            client.installOpenSocketForTest(socket)
            client.replayPendingForTest(connection, {}, {}, { true })
            var current = true
            assertFalse(
                client.sendCurrentSurfaceEvent("work", "chrome_open", workPayload(JsonObject(emptyMap())), { current }) { _, _ ->
                    when (change) {
                        "owner" -> client.clearOwnerSession()
                        "socket" -> client.installOpenSocketForTest(Socket())
                        "generation" -> client.replayPendingForTest("33333333-3333-4333-8333-333333333333", {}, {}, { true })
                        else -> current = false
                    }
                },
            )
            assertTrue(socket.frames.isEmpty())
            assertTrue(client.pendingActions().isEmpty())
        }
    }

    @Test fun actual_client_registration_advertises_work_reads() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val attempt = client.createRegistrationAttempt("synthetic", DeviceCapabilities(800, 600), null)
        val frame = Json.parseToJsonElement(attempt.frame).jsonObject
        assertTrue(frame.getValue("capabilities").jsonArray.any { it.jsonPrimitive.content == "work_read_v1" })
    }

    @Test fun guidance_current_send_is_closed_and_rechecks_owner_after_submission() {
        for (action in listOf("chrome_open", "chrome_note_search", "chrome_note_save", "chrome_note_toggle", "chrome_note_forget")) {
            val client = OrchestratorClient("ws://localhost:9/ws")
            val socket = Socket()
            val payload =
                buildJsonObject {
                    put("surface", "guidance")
                    put("expected_revision", 7)
                }
            assertFalse(client.sendCurrentSurfaceEvent("guidance", action, payload, { true }) { _, _ -> error("offline") })
            client.installOpenSocketForTest(socket)
            assertFalse(client.sendCurrentSurfaceEvent("guidance", action, payload, { true }) { _, _ -> error("unregistered") })
            client.replayPendingForTest(connection, {}, {}, { true })
            var current = true
            assertFalse(client.sendCurrentSurfaceEvent("guidance", action, payload, { current }) { _, _ -> current = false })
            assertTrue(socket.frames.isEmpty())
            assertTrue(client.pendingActions().isEmpty())
            current = true
            assertTrue(client.sendCurrentSurfaceEvent("guidance", action, payload, { current }) { _, _ -> })
            assertEquals(action, Json.parseToJsonElement(socket.frames.single()).jsonObject.getValue("action").jsonPrimitive.content)
        }
        val client = OrchestratorClient("ws://localhost:9/ws")
        val socket = Socket()
        client.installOpenSocketForTest(socket)
        client.replayPendingForTest(connection, {}, {}, { true })
        for ((surface, action) in listOf("theme" to "chrome_open", "work" to "chrome_note_save", "guidance" to "chrome_save_other")) {
            assertFalse(client.sendCurrentSurfaceEvent(surface, action, buildJsonObject { put("surface", surface) }, { true }) { _, _ -> error("unsupported") })
        }
        assertFalse(client.sendCurrentSurfaceEvent("guidance", "chrome_open", buildJsonObject { put("surface", "work") }, { true }) { _, _ -> error("wrong surface") })
        assertTrue(socket.frames.isEmpty())
    }

    private fun workPayload(params: JsonObject) =
        buildJsonObject {
            put("surface", "work")
            put("params", params)
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
