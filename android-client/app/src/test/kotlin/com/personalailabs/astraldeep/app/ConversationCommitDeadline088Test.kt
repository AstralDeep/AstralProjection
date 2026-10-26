// Tests for AppViewModel: the conversation commit-ready deadline — snapshot arrival before and after the
// fence expires, and retry targeting once it does.

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

    @Test
    fun offered_search_conversation_selects_and_hydrates_before_the_next_explicit_send() =
        withFixture {
            val payload = buildJsonObject { put("chat_id", OTHER_ID) }
            offerSearch(payload)
            model.sendEvent("load_chat", payload)
            assertEquals(OTHER_ID, model.state.value.activeChatId)
            assertEquals(com.personalailabs.astraldeep.app.ui.Screen.Chat, model.state.value.screen)
            val load = nextLoad()
            assertEquals(OTHER_ID, load["session_id"]?.jsonPrimitive?.content)
            assertEquals(OTHER_ID, load.getValue("payload").jsonObject["chat_id"]?.jsonPrimitive?.content)
            assertEquals(ConversationRequestPurpose.HYDRATION, model.state.value.requestPurpose)
            assertEquals(1, loads().size)
            assertTrue(messages().isEmpty())
            val connection = assertNotNull(model.state.value.connectionGeneration)
            val request = load.getValue("request_generation").jsonPrimitive.content
            deliver(
                Json.parseToJsonElement(
                    """{
                "type":"conversation_snapshot","schema_version":1,
                "snapshot_id":"44444444-4444-4444-8444-444444444444",
                "chat_id":"$OTHER_ID","connection_generation":"$connection",
                "request_generation":"$request","snapshot_purpose":"hydration","render_revision":0,
                "committed_at":"2026-09-11T00:00:00Z","transcript":[],
                "canvas":{"target":"canvas","components":[{"type":"text","content":"Hydrated target"}]}
            }""",
                ).jsonObject,
                "hydrated-target",
            )
            assertTrue(model.state.value.hydrationApplied)
            assertEquals("Hydrated target", model.state.value.canvas.single().attributes["content"]?.jsonPrimitive?.content)
            model.sendChat("Explicit next message")
            awaitMessages()
            assertEquals(OTHER_ID, messages().single()["session_id"]?.jsonPrimitive?.content)
        }

    @Test
    fun offered_work_conversation_uses_the_existing_chat_hydration_path() =
        withFixture {
            val payload = buildJsonObject { put("chat_id", OTHER_ID) }
            offerSearch(payload, surfaceName = "work")
            model.sendEvent("load_chat", payload)
            val load = nextLoad()
            assertEquals(OTHER_ID, model.state.value.activeChatId)
            assertEquals(OTHER_ID, load["session_id"]?.jsonPrimitive?.content)
            assertEquals(ConversationRequestPurpose.HYDRATION, model.state.value.requestPurpose)
            assertTrue(messages().isEmpty())
        }

    @Test
    fun existing_history_selection_still_submits_one_hydration_for_the_selected_chat() =
        withFixture {
            model.openChat(OTHER_ID)
            val load = nextLoad()
            assertEquals(OTHER_ID, model.state.value.activeChatId)
            assertEquals(OTHER_ID, load["session_id"]?.jsonPrimitive?.content)
            assertEquals(ConversationRequestPurpose.HYDRATION, model.state.value.requestPurpose)
            assertEquals(1, loads().size)
        }

    @Test
    fun malformed_and_retired_search_conversation_offers_cannot_select_or_forward() {
        for (change in listOf("malformed", "wrong-target", "closed", "pending", "timeout", "disabled", "owner", "disconnect")) {
            withFixture {
                val payload = buildJsonObject { put("chat_id", if (change == "malformed") "invalid" else OTHER_ID) }
                offerSearch(payload, disabled = change == "disabled")
                when (change) {
                    "closed" -> model.goTo(com.personalailabs.astraldeep.app.ui.Screen.Chat)
                    "pending" -> model.openSurface("search")
                    "timeout" -> {
                        model.openSurface("search")
                        model.timeoutPrivateSurface(model.state.value.privateSurfaceRequest!!.requestGeneration)
                    }
                    "owner" -> model.signOut {}
                    "disconnect" -> disconnect()
                }
                val before = model.state.value
                val request = if (change == "wrong-target") buildJsonObject { put("chat_id", CHAT_ID) } else payload
                model.sendEvent("load_chat", request)
                assertEquals(before.activeChatId, model.state.value.activeChatId, change)
                assertEquals(before.privateSurfaceRequest, model.state.value.privateSurfaceRequest, change)
                assertTrue(loads().isEmpty(), change)
            }
        }
    }

    @Test
    fun accepted_history_primitive_uses_normal_hydration() {
        for (origin in listOf("canvas", "transcript", "surface")) {
            for (committed in if (origin == "surface") listOf(false) else listOf(false, true)) {
                withFixture {
                    val row = offerHistory(origin, committed)
                    model.navigationEmitter(row).event("load_chat", buildJsonObject { put("chat_id", OTHER_ID) })
                    assertEquals(OTHER_ID, model.state.value.activeChatId, "$origin/$committed")
                    assertEquals(OTHER_ID, nextLoad()["session_id"]?.jsonPrimitive?.content)
                    assertTrue(messages().isEmpty())
                }
            }
        }
    }

    @Test
    fun captured_history_rows_reject_retired_sources_and_changed_payloads() {
        for (origin in listOf("canvas", "transcript", "surface")) {
            for (change in listOf("replacement", "request", "owner", "disconnect", "pending", "wrong-target", "malformed", "extra")) {
                withFixture {
                    val row = offerHistory(origin)
                    val callback = model.navigationEmitter(row)
                    when (change) {
                        "replacement" -> {
                            model.openChat(CHAT_ID)
                            offerHistory(origin)
                        }
                        "request" -> model.openChat(CHAT_ID)
                        "owner" -> model.signOut {}
                        "disconnect" -> disconnect()
                        "pending" -> model.openSurface("search")
                    }
                    if (change == "replacement" || change == "request") nextLoad()
                    val before = model.state.value.activeChatId
                    val count = loads().size
                    val payload =
                        buildJsonObject {
                            if (change != "malformed") put("chat_id", if (change == "wrong-target") CHAT_ID else OTHER_ID)
                            if (change == "extra") put("other", true)
                        }
                    callback.event("load_chat", payload)
                    assertEquals(before, model.state.value.activeChatId, "$origin/$change")
                    assertEquals(count, loads().size, "$origin/$change")
                }
            }
        }
    }

    @Test
    fun new_transcript_preview_cannot_rebind_retained_canvas_history() =
        withFixture {
            val row = offerHistory("canvas")
            model.openChat(CHAT_ID)
            nextLoad()
            val connection = assertNotNull(model.state.value.connectionGeneration)
            val request = assertNotNull(model.state.value.requestGeneration)
            deliver(
                Json.parseToJsonElement(
                    """{"type":"ui_render","target":"chat","chat_id":"$CHAT_ID",
                "connection_generation":"$connection","request_generation":"$request",
                "base_render_revision":0,"frame_sequence":1,"components":[{"type":"text","content":"Current preview"}]}""",
                ).jsonObject,
                "current-preview",
            )
            assertTrue(model.state.value.pendingTurns.isNotEmpty())
            val payload = buildJsonObject { put("chat_id", OTHER_ID) }
            model.navigationEmitter(row).event("load_chat", payload)
            assertEquals(CHAT_ID, model.state.value.activeChatId)
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

        fun offerHistory(
            origin: String,
            committed: Boolean = false,
        ): com.personalailabs.astraldeep.core.sdui.Component {
            val history = """{"type":"chat_history","items":[{"chat_id":"$OTHER_ID","title":"Owned history"}]}"""
            if (origin == "surface") {
                model.openSurface("search")
                val request = model.state.value.privateSurfaceRequest!!.requestGeneration
                deliver(
                    Json.parseToJsonElement(
                        """{"type":"chrome_surface","surface_key":"search","title":"Sources","region":"modal",
                    "admin_only":false,"request_generation":"$request","mode":"replace","components":[$history]}""",
                    ).jsonObject,
                    "history-surface",
                )
                return model.state.value.pendingSurface!!.components.single()
            }
            if (committed) deliver(ready(), "history-commit-ready")
            val connection = assertNotNull(model.state.value.connectionGeneration)
            val request = assertNotNull(model.state.value.requestGeneration)
            val purpose = if (committed) "commit" else "hydration"
            val revision = if (committed) 1 else 0
            val transcript =
                if (origin == "transcript") {
                    """[{"message_id":"a1","role":"assistant","created_at":"2026-09-11T00:00:00Z",
                "parts":[{"type":"components","components":[$history]}],"attachments":[]}]"""
                } else {
                    "[]"
                }
            val canvas = if (origin == "canvas") history else """{"type":"text","content":"Current canvas"}"""
            deliver(
                Json.parseToJsonElement(
                    """{"type":"conversation_snapshot","schema_version":1,
                "snapshot_id":"44444444-4444-4444-8444-444444444444","chat_id":"$CHAT_ID",
                "connection_generation":"$connection","request_generation":"$request",
                "snapshot_purpose":"$purpose","render_revision":$revision,"committed_at":"2026-09-11T00:00:00Z",
                "transcript":$transcript,"canvas":{"target":"canvas","components":[$canvas]}}""",
                ).jsonObject,
                "history-accepted",
            )
            return if (origin == "canvas") {
                model.state.value.canvas.single()
            } else {
                model.state.value.turns.single().segments.single().components.single()
            }
        }

        fun offerSearch(
            payload: JsonObject,
            disabled: Boolean = false,
            surfaceName: String = "search",
        ) {
            model.openSurface(surfaceName)
            val request = model.state.value.privateSurfaceRequest!!.requestGeneration
            val component =
                buildJsonObject {
                    put("type", "button")
                    put("label", "Open conversation")
                    put("action", "load_chat")
                    put("payload", payload)
                    put("disabled", disabled)
                }
            deliver(
                buildJsonObject {
                    put("type", "chrome_surface")
                    put("surface_key", surfaceName)
                    put("title", "Sources")
                    put("region", "modal")
                    put("admin_only", false)
                    put("request_generation", request)
                    put("mode", "replace")
                    put("components", kotlinx.serialization.json.JsonArray(listOf(component)))
                },
                "search-offered",
            )
            assertNotNull(model.state.value.pendingSurface)
        }

        fun nextLoad(): JsonObject {
            awaitTransport { loads().isNotEmpty() }
            return loads().last()
        }

        fun messages(): List<JsonObject> = sent.filter { it["action"]?.jsonPrimitive?.content == "chat_message" }

        fun awaitMessages() = awaitTransport { messages().isNotEmpty() }

        fun disconnect() {
            socket.get().close(1000, "fixture retired")
            awaitTransport { model.state.value.connection != ConnectionState.Connected }
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
