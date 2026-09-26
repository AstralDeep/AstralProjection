// Exercises viewport coalescing and deadlines through the live WebSocket transport against a loopback server.
// A refresh uses only its current owner connection and never falls back to navigation or offline replay.

package com.personalailabs.astraldeep.app.ui

import androidx.lifecycle.viewModelScope
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.SnapshotCanvas
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import java.time.Instant
import java.util.Base64
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class ViewportRefreshTransportTest {
    @Test fun changesCoalesceAndWaitForInteractionThenRefreshSameRevision() =
        withFixture {
            val lease = Any()
            model.viewportInteraction(lease, true)
            model.updateComposerDraft("Keep this draft")
            model.updateDeviceCapabilities(device.copy(viewportWidth = 600))
            model.updateDeviceCapabilities(device.copy(viewportWidth = 900))
            advance(800)
            assertNull(model.state.value.viewportRefresh)
            assertTrue(refreshes().isEmpty())
            model.viewportInteraction(lease, false)
            advance(200)
            awaitTransport { refreshes().size == 1 }
            val first = refreshes().single().getValue("payload").jsonObject
            assertEquals("900", first.getValue("device").jsonObject.getValue("viewport_width").jsonPrimitive.content)
            assertEquals("7", first.getValue("base_render_revision").jsonPrimitive.content)
            val request = assertNotNull(model.state.value.requestGeneration)
            model.updateDeviceCapabilities(device.copy(viewportWidth = 1200))
            advance(500)
            assertEquals(1, refreshes().size)
            hydrate()
            advance(200)
            awaitTransport { refreshes().size == 2 }
            assertNotEquals(request, model.state.value.requestGeneration)
            hydrate()
            assertEquals(7UL, model.state.value.lastCommittedRenderRevision)
            assertEquals("Keep this draft", model.state.value.composerDraft)
            assertNull(model.state.value.viewportRefresh)
            assertTrue(loads().isEmpty())
        }

    @Test fun timeoutRetainsDraftAndOffersExplicitRetryWithoutNavigation() =
        withFixture {
            model.updateComposerDraft("New unsent draft")
            model.updateDeviceCapabilities(device.copy(viewportWidth = 1000))
            advance(200)
            awaitTransport { refreshes().size == 1 }
            val expired = model.state.value.requestGeneration
            advance(5_001)
            assertNull(model.state.value.viewportRefresh)
            assertTrue(model.state.value.viewportRefreshFailed)
            assertEquals("New unsent draft", model.state.value.composerDraft)
            assertTrue(loads().isEmpty())
            model.retryViewportRefresh()
            advance(200)
            awaitTransport { refreshes().size == 2 }
            assertNotEquals(expired, model.state.value.requestGeneration)
            hydrate()
            assertFalse(model.state.value.viewportRefreshFailed)
        }

    @Test fun disconnectDropsDeferredRefreshAndCannotReplayOnAConnection() =
        withFixture {
            model.viewportInteraction(this, true)
            model.updateDeviceCapabilities(device.copy(viewportWidth = 1000))
            advance(200)
            socket.get().close(1000, "fixture disconnect")
            awaitTransport { model.state.value.connection == ConnectionState.Disconnected }
            advance(300)
            assertTrue(refreshes().isEmpty())
            assertNull(model.state.value.viewportRefresh)
            assertTrue(client.pendingFrames().isEmpty())
        }

    @Test fun editStartedDuringRefreshRetiresSnapshotAndWaitsBeforeRetry() =
        withFixture {
            model.updateDeviceCapabilities(device.copy(viewportWidth = 900))
            advance(200)
            awaitTransport { refreshes().size == 1 }
            val pending = model.state.value
            val request = assertNotNull(pending.requestGeneration)
            model.receiveInbound(Inbound.RoteConfig(null, true, CHAT, pending.connectionGeneration, request))
            assertNotNull(model.state.value.pendingViewportConfig)
            model.viewportInteraction(this, true)
            assertNull(model.state.value.viewportRefresh)
            assertNull(model.state.value.pendingViewportConfig)
            model.receiveInbound(
                Inbound.ConversationSnapshot(
                    1, "00000000-0000-4000-8000-000000000004", CHAT,
                    assertNotNull(pending.connectionGeneration), request, "hydration", 7UL,
                    "2026-09-26T00:00:00Z", emptyList(), SnapshotCanvas("canvas", emptyList()),
                ),
            )
            advance(600)
            assertEquals(1, refreshes().size)
            model.viewportInteraction(this, false)
            advance(200)
            awaitTransport { refreshes().size == 2 }
            assertNotEquals(request, model.state.value.requestGeneration)
            hydrate()
            assertTrue(loads().isEmpty())
        }

    @Test fun authenticationLossCannotTurnViewportDeadlineIntoQueuedNavigation() =
        withFixture {
            model.updateDeviceCapabilities(device.copy(viewportWidth = 900))
            advance(200)
            awaitTransport { refreshes().size == 1 }
            val expired = model.state.value.requestGeneration
            model.receiveInbound(Inbound.AuthRequired("session_required"))
            assertNull(model.state.value.viewportRefresh)
            assertNotEquals(expired, model.state.value.requestGeneration)
            assertEquals(ConnectionState.AuthRequired, model.state.value.connection)
            advance(10_000)
            assertTrue(loads().isEmpty())
            assertTrue(client.pendingFrames().isEmpty())
        }

    private fun withFixture(block: Fixture.() -> Unit) {
        val scheduler = TestCoroutineScheduler()
        Dispatchers.setMain(StandardTestDispatcher(scheduler))
        try {
            Fixture(scheduler).use(block)
        } finally {
            Dispatchers.resetMain()
        }
    }

    private class Fixture(private val scheduler: TestCoroutineScheduler) : AutoCloseable {
        private val server = MockWebServer()
        private val http = OkHttpClient()
        val socket = AtomicReference<WebSocket>()
        private val sent = ConcurrentLinkedQueue<JsonObject>()
        val device = DeviceCapabilities(400, 800, deviceId = CHAT)
        val client: OrchestratorClient
        val model: AppViewModel

        init {
            server.enqueue(
                MockResponse().withWebSocketUpgrade(
                    object : WebSocketListener() {
                        override fun onOpen(
                            webSocket: WebSocket,
                            response: Response,
                        ) {
                            socket.set(webSocket)
                        }

                        override fun onMessage(
                            webSocket: WebSocket,
                            text: String,
                        ) {
                            sent.add(Json.parseToJsonElement(text).jsonObject)
                        }
                    },
                ),
            )
            server.start()
            val values = mutableMapOf<String, String>()
            val store =
                ConversationResumeStore(
                    object : ConversationResumeStore.Storage {
                        override fun get(key: String) = values[key]

                        override fun put(
                            key: String,
                            value: String,
                        ): Boolean {
                            values[key] = value
                            return true
                        }

                        override fun remove(key: String): Boolean {
                            values.remove(key)
                            return true
                        }
                    },
                ) { Instant.parse("2026-09-26T00:00:00Z") }
            val owner = ConversationResumeStore.AccountIdentity("https://iam.example/realms/astral", "viewport-test")
            assertTrue(store.save(owner, CHAT))
            val body = """{"iss":"${owner.issuer}","sub":"${owner.subject}"}"""
            val token = "header.${Base64.getUrlEncoder().withoutPadding().encodeToString(body.toByteArray())}.signature"
            client = OrchestratorClient(server.url("/ws").toString(), http)
            model = AppViewModel(client, AstralRest(server.url("/").toString()), store)
            model.start(token, device)
            awaitTransport { socket.get() != null && model.state.value.connection == ConnectionState.Connected }
            model.receiveInbound(Inbound.RoteConfig(null, true))
            hydrate()
        }

        fun hydrate() {
            val state = model.state.value
            model.receiveInbound(
                Inbound.ConversationSnapshot(
                    1, "00000000-0000-4000-8000-000000000004", CHAT,
                    assertNotNull(state.connectionGeneration), assertNotNull(state.requestGeneration),
                    "hydration", 7UL, "2026-09-26T00:00:00Z", emptyList(), SnapshotCanvas("canvas", emptyList()),
                ),
            )
        }

        fun advance(milliseconds: Long) {
            scheduler.advanceTimeBy(milliseconds)
            scheduler.runCurrent()
        }

        fun refreshes() = sent.filter { it["payload"]?.jsonObject?.containsKey("snapshot_purpose") == true }

        fun loads() = sent.filter { it["action"]?.jsonPrimitive?.content == "load_chat" }

        fun awaitTransport(condition: () -> Boolean) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (true) {
                scheduler.runCurrent()
                if (condition()) return
                check(System.nanoTime() < deadline) { "local WebSocket event not observed" }
                Thread.sleep(1)
            }
        }

        override fun close() {
            model.viewModelScope.cancel()
            scheduler.runCurrent()
            http.dispatcher.executorService.shutdownNow()
            http.connectionPool.evictAll()
            server.close()
        }
    }

    companion object {
        private const val CHAT = "00000000-0000-4000-8000-000000000001"
    }
}
