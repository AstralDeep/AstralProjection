// Exercises current-generation safety responses and read-only retry after an uncertain control.
package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.ConversationGenerationBinding
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.Wire
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SafetySurfaceReducerTest {
    private val connection = "22222222-2222-4222-8222-222222222222"
    private val generation = "33333333-3333-4333-8333-333333333333"
    private val model = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))

    private fun engaged(): Inbound.ChromeSurface {
        var directory: File? = File(".").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/safety/owner_stop.json")
            if (candidate.isFile) {
                val fixture = Json.parseToJsonElement(candidate.readText()).jsonObject
                val frame =
                    buildJsonObject {
                        put("type", "chrome_surface")
                        put("surface_key", "safety")
                        put("title", "Emergency stop")
                        put("mode", "replace")
                        put("request_generation", generation)
                        put("components", fixture.getValue("engaged"))
                    }
                return assertIs<Inbound.ChromeSurface>(Wire.decode(frame))
            }
            directory = directory.parentFile
        }
        error("shared safety fixture missing")
    }

    private fun pending(): UiState =
        UiState(
            connection = ConnectionState.Connected,
            connectionGeneration = connection,
            screen = Screen.Surface,
            pendingSurfaceKey = "safety",
            pendingSurface = engaged(),
            privateSurfaceRequest = PrivateSurfaceRequest(generation, connection, "safety", "chrome_safety_resume"),
        )

    @Test
    fun only_current_correlated_response_can_release_safety_controls() {
        val start = pending()
        val response = engaged()
        for (invalid in listOf(
            response.copy(requestGeneration = null),
            response.copy(requestGeneration = "44444444-4444-4444-8444-444444444444"),
            response.copy(requestGeneration = "malformed"),
            response.copy(mode = "mandatory"),
            response.copy(surfaceKey = "other"),
        )) assertEquals(start, model.reduce(start, invalid))
        for (retired in listOf(
            start.copy(connection = ConnectionState.Disconnected),
            start.copy(connectionGeneration = "44444444-4444-4444-8444-444444444444"),
            start.copy(screen = Screen.Chat),
            start.copy(pendingSurfaceKey = "theme"),
            start.copy(privateSurfaceRequest = null),
            UiState(),
        )) assertEquals(retired, model.reduce(retired, response))
        val settled = model.reduce(start, response)
        assertNull(settled.privateSurfaceRequest)
        assertEquals(response, settled.pendingSurface)
        assertFalse(settled.surfaceReloadRequired)
        assertEquals(settled, model.reduce(settled, response.copy(title = "Late duplicate")))
        val rebound = model.bindConversationGeneration(start, ConversationGenerationBinding("44444444-4444-4444-8444-444444444444", null, null, null))
        assertEquals(rebound, model.reduce(rebound, response))
    }

    @Test
    fun failed_resume_requires_reload_before_any_new_write() {
        val start = pending()
        val response = engaged().copy(surfaceKey = "error", title = "Revision changed", components = emptyList())
        val failed = model.reduce(start, response)
        assertNull(failed.privateSurfaceRequest)
        assertEquals(start.pendingSurface, failed.pendingSurface)
        assertTrue(failed.privateSurfaceFailed)
        assertTrue(failed.surfaceReloadRequired)
        assertEquals("Revision changed", failed.surfaceErrorMessage)
        assertEquals(failed, model.reduce(failed, engaged()))
        val disconnected = model.reduceConnectionState(start, ConnectionState.Disconnected)
        assertTrue(disconnected.surfaceReloadRequired)
        assertNull(disconnected.privateSurfaceRequest)
        assertEquals(disconnected, model.reduce(disconnected, engaged()))
    }

    @Test
    fun actual_navigation_timeout_retry_and_owner_change_never_queue_or_replay_a_write() =
        runTest {
            Dispatchers.setMain(StandardTestDispatcher(testScheduler))
            val client = OrchestratorClient("ws://localhost:9/ws")
            val live = AppViewModel(client, AstralRest("http://localhost:9"))
            val socket = SafetySocket()

            fun token(owner: String): String =
                "header." +
                    Base64.getUrlEncoder().withoutPadding().encodeToString(
                        """{"iss":"https://example.invalid/realm","sub":"$owner"}""".toByteArray(),
                    ) + ".signature"
            try {
                live.start(token("owner-a"), DeviceCapabilities(800, 600))
                client.installOpenSocketForTest(socket)
                client.replayPendingForTest(connection, {}, {}, { true })
                live.openSurface("safety")
                val first = live.state.value.privateSurfaceRequest!!
                live.timeoutPrivateSurface(first.requestGeneration)
                assertTrue(live.state.value.surfaceReloadRequired)
                assertNull(live.state.value.privateSurfaceRequest)
                live.sendEvent(
                    "chrome_safety_resume",
                    buildJsonObject {
                        put("surface", "safety")
                        put("expected_revision", 7)
                    },
                )
                assertEquals(1, socket.frames.size)
                live.retryPendingSurface()
                val retry = live.state.value.privateSurfaceRequest!!
                assertFalse(first.requestGeneration == retry.requestGeneration)
                for (raw in socket.frames) {
                    val frame = Json.parseToJsonElement(raw).jsonObject
                    assertEquals("chrome_open", frame.getValue("action").jsonPrimitive.content)
                    assertEquals(setOf("surface", "params"), frame.getValue("payload").jsonObject.keys)
                    assertEquals(connection, frame.getValue("connection_generation").jsonPrimitive.content)
                }
                live.start(token("owner-b"), DeviceCapabilities(800, 600))
                assertNull(live.state.value.privateSurfaceRequest)
                assertEquals(2, socket.frames.size)
                assertTrue(client.pendingActions().isEmpty())
                client.installOpenSocketForTest(socket)
                client.replayPendingForTest(connection, {}, {}, { true })
                socket.accept = false
                live.openSurface("safety")
                assertNull(live.state.value.privateSurfaceRequest)
                assertTrue(live.state.value.surfaceReloadRequired)
            } finally {
                live.clearConversationForSignOut()
                Dispatchers.resetMain()
            }
        }

    private class SafetySocket : okhttp3.WebSocket {
        val frames = mutableListOf<String>()
        var accept = true

        override fun request(): okhttp3.Request = okhttp3.Request.Builder().url("ws://localhost:9/ws").build()

        override fun queueSize(): Long = 0

        override fun send(text: String): Boolean {
            if (accept) frames.add(text)
            return accept
        }

        override fun send(bytes: okio.ByteString): Boolean = false

        override fun close(
            code: Int,
            reason: String?,
        ): Boolean = true

        override fun cancel() = Unit
    }
}
