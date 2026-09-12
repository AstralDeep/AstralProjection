package com.personalailabs.astraldeep.app

import androidx.lifecycle.viewModelScope
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.ConversationRequestPurpose
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.app.ui.AppViewModel
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
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
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class ConversationCommitDeadline088Test {
    @Test
    fun duplicate_prelude_does_not_postpone_the_original_commit_deadline() = rejectedPreludeKeepsDeadline()

    @Test
    fun foreign_chat_prelude_does_not_replace_the_original_commit_deadline() = rejectedPreludeKeepsDeadline(chat = OTHER_ID)

    @Test
    fun foreign_connection_prelude_does_not_replace_the_original_commit_deadline() =
        rejectedPreludeKeepsDeadline(connection = OTHER_ID)

    @Test
    fun accepted_prelude_opens_a_new_five_second_deadline() =
        withFixture {
            advance(4_000)
            deliver(ready(), "accepted")
            assertEquals(ConversationRequestPurpose.COMMIT, model.state.value.requestPurpose)
            advance(4_999)
            assertTrue(loads().isEmpty(), "the superseded hydration deadline must not fire")
            advance(1)
            assertRefresh()
        }

    private fun rejectedPreludeKeepsDeadline(
        chat: String = CHAT_ID,
        connection: String? = null,
    ) = withFixture {
        deliver(ready(), "accepted")
        advance(4_000)
        deliver(ready(chat, connection), "rejected")
        assertEquals(REQUEST_ID, model.state.value.requestGeneration)
        assertEquals(1UL, model.state.value.expectedCommitRenderRevision)
        advance(999)
        assertTrue(loads().isEmpty())
        advance(1)
        assertRefresh()
    }

    private fun withFixture(block: Fixture.() -> Unit) {
        val scheduler = TestCoroutineScheduler()
        Dispatchers.setMain(StandardTestDispatcher(scheduler))
        try {
            Fixture(scheduler).use { fixture -> fixture.block() }
        } finally {
            Dispatchers.resetMain()
        }
    }

    private class Fixture(private val scheduler: TestCoroutineScheduler) : AutoCloseable {
        private val server = MockWebServer()
        private val http = OkHttpClient()
        private val socket = AtomicReference<WebSocket>()
        private val sent = ConcurrentLinkedQueue<JsonObject>()
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
            val store = ConversationResumeStore(MemoryStorage()) { Instant.parse("2026-09-11T00:00:00Z") }
            val account = ConversationResumeStore.AccountIdentity("https://iam.example/realms/astral", "test-owner")
            assertTrue(store.save(account, CHAT_ID))
            val body = """{"iss":"${account.issuer}","sub":"${account.subject}"}"""
            val token = "header.${Base64.getUrlEncoder().withoutPadding().encodeToString(body.toByteArray())}.signature"
            model = AppViewModel(OrchestratorClient(server.url("/ws").toString(), http), AstralRest(server.url("/").toString()), store)
            model.start(token, DeviceCapabilities(400, 800))
            awaitTransport { socket.get() != null && sent.isNotEmpty() && model.state.value.connection == ConnectionState.Connected }
            assertEquals(CHAT_ID, model.state.value.activeChatId)
            assertEquals(ConversationRequestPurpose.HYDRATION, model.state.value.requestPurpose)
        }

        fun ready(
            chat: String = CHAT_ID,
            connection: String? = null,
        ): JsonObject =
            buildJsonObject {
                put("type", "conversation_commit_ready")
                put("schema_version", 1)
                put("chat_id", chat)
                put("connection_generation", connection ?: assertNotNull(model.state.value.connectionGeneration))
                put("request_generation", REQUEST_ID)
                put("render_revision", 1)
            }

        fun deliver(
            frame: JsonObject,
            marker: String,
        ) {
            assertTrue(socket.get().send(frame.toString()))
            // The following unscoped notification is observed by the same real
            // collector, proving the preceding frame's side effects have run.
            val notification =
                buildJsonObject {
                    put("type", "notification")
                    put("title", marker)
                }
            assertTrue(socket.get().send(notification.toString()))
            awaitTransport { model.state.value.banner == marker }
        }

        fun advance(milliseconds: Long) {
            scheduler.advanceTimeBy(milliseconds)
            scheduler.runCurrent()
        }

        fun loads(): List<JsonObject> = sent.filter { it["action"]?.jsonPrimitive?.content == "load_chat" }

        fun assertRefresh() {
            awaitTransport { loads().isNotEmpty() }
            val load = loads().single()
            assertEquals(CHAT_ID, load.getValue("payload").jsonObject.getValue("chat_id").jsonPrimitive.content)
            assertNotEquals(REQUEST_ID, load.getValue("request_generation").jsonPrimitive.content)
            assertEquals(ConversationRequestPurpose.HYDRATION, model.state.value.requestPurpose)
        }

        private fun awaitTransport(condition: () -> Boolean) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (true) {
                scheduler.runCurrent()
                if (condition()) return
                check(System.nanoTime() < deadline) { "local WebSocket frame was not observed" }
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

    private class MemoryStorage : ConversationResumeStore.Storage {
        private val values = mutableMapOf<String, String>()

        override fun get(key: String): String? = values[key]

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
    }

    companion object {
        private const val CHAT_ID = "11111111-1111-4111-8111-111111111111"
        private const val REQUEST_ID = "22222222-2222-4222-8222-222222222222"
        private const val OTHER_ID = "33333333-3333-4333-8333-333333333333"
    }
}
