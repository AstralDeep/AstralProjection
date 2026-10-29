// Exercises actual Work dispatch with displayed commands, owner retirement and read-only retries.
package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.WorkContinuity
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WorkContinuityDispatchTest {
    private val connection = "33333333-3333-4333-8333-333333333333"
    private val operation = "180cd30b-cc38-432d-8349-1851b0d3ad7e"
    private val submission = "fc5c2124-ce23-48d9-927b-9c004d950c10"

    private fun payload() =
        buildJsonObject {
            put("version", 1)
            put("operation_id", operation)
            put("expected_revision", 7)
            put("submission_id", submission)
        }

    private fun shown() =
        UiState(
            screen = Screen.Surface,
            connection = ConnectionState.Connected,
            connectionGeneration = connection,
            pendingSurfaceKey = "work",
            pendingSurfaceConnectionGeneration = connection,
            pendingSurface =
                Inbound.ChromeSurface(
                    "work",
                    "Waiting for an event",
                    listOf(
                        Component.fromJson(
                            buildJsonObject {
                                put("type", "button")
                                put("action", WorkContinuity.ACTION)
                                put("payload", payload())
                                put("disabled", false)
                                put("local", false)
                            },
                        ),
                    ),
                ),
        )

    @Suppress("UNCHECKED_CAST")
    private fun state(vm: AppViewModel) = AppViewModel::class.java.getDeclaredField("_state").apply { isAccessible = true }.get(vm) as MutableStateFlow<UiState>

    @Test fun displayed_command_keeps_binding_and_unknown_outcome_retries_only_a_read() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val vm = AppViewModel(client, AstralRest("http://localhost:9"))
        val socket = Socket()
        client.installOpenSocketForTest(socket)
        client.replayPendingForTest(connection, {}, {}, { true })
        state(vm).value = shown()
        vm.sendEvent(WorkContinuity.ACTION, payload())
        val pending = vm.state.value.privateSurfaceRequest!!
        val sent = Json.parseToJsonElement(socket.frames.single()).jsonObject
        assertEquals(payload(), sent["payload"])
        assertEquals(submission, sent.getValue("submission_id").jsonPrimitive.content)
        assertEquals(connection, sent.getValue("connection_generation").jsonPrimitive.content)
        assertEquals(WorkContinuity.ACTION, pending.action)
        vm.sendEvent(WorkContinuity.ACTION, payload())
        assertEquals(1, socket.frames.size)
        vm.timeoutPrivateSurface(pending.requestGeneration)
        vm.retryPendingSurface()
        val retry = Json.parseToJsonElement(socket.frames.last()).jsonObject
        assertEquals("chrome_open", retry.getValue("action").jsonPrimitive.content)
        assertEquals("detail", retry.getValue("payload").jsonObject.getValue("params").jsonObject.getValue("mode").jsonPrimitive.content)
        assertTrue(client.pendingActions().isEmpty())
        vm.clearConversationForSignOut()
    }

    @Test fun retired_unoffered_or_locked_commands_never_reach_transport_or_queue() {
        for (change in listOf("connection", "screen", "surface", "mandatory", "locked", "unoffered", "disconnected", "payload", "signout")) {
            val client = OrchestratorClient("ws://localhost:9/ws")
            val vm = AppViewModel(client, AstralRest("http://localhost:9"))
            val socket = Socket()
            client.installOpenSocketForTest(socket)
            client.replayPendingForTest(connection, {}, {}, { true })
            val value = shown()
            state(vm).value =
                when (change) {
                    "connection" -> value.copy(connectionGeneration = operation)
                    "screen" -> value.copy(screen = Screen.Chat)
                    "surface" -> value.copy(pendingSurfaceKey = "theme")
                    "mandatory" -> value.copy(mandatorySurface = true)
                    "locked" -> value.copy(timelineReadOnly = true)
                    "unoffered" -> value.copy(pendingSurface = value.pendingSurface!!.copy(components = emptyList()))
                    "disconnected" -> value.copy(connection = ConnectionState.Disconnected)
                    else -> value
                }
            if (change == "signout") vm.clearConversationForSignOut()
            val command = if (change == "payload") JsonObject(payload() + ("expected_revision" to kotlinx.serialization.json.JsonPrimitive(8))) else payload()
            vm.sendEvent(WorkContinuity.ACTION, command)
            assertTrue(socket.frames.isEmpty(), change)
            assertTrue(client.pendingActions().isEmpty(), change)
            assertNull(vm.state.value.privateSurfaceRequest, change)
            vm.clearConversationForSignOut()
        }
    }

    private class Socket : okhttp3.WebSocket {
        val frames = mutableListOf<String>()

        override fun request() = okhttp3.Request.Builder().url("ws://localhost:9/ws").build()

        override fun queueSize() = 0L

        override fun send(text: String): Boolean {
            frames.add(text)
            return true
        }

        override fun send(bytes: okio.ByteString) = false

        override fun close(
            code: Int,
            reason: String?,
        ) = true

        override fun cancel() = Unit
    }
}
