package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.ChatSummary
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.TransientFrameScope
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals

class HistorySurface088Test {
    private val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))

    private fun component(json: String) = Component.fromJson(Json.parseToJsonElement(json).jsonObject)

    private val history = component("""{"type":"chat_history","items":[{"chat_id":"other-chat","title":"New Chat","preview":"Alpha = 2","time":"2m","icon":"📝","saved":true}]}""")
    private val active =
        UiState(
            activeChatId = "active", connectionGeneration = "connection", requestGeneration = "request",
            lastCommittedRenderRevision = 7UL, lastTransientFrameSequence = 3UL,
            canvas = listOf(component("""{"type":"text","content":"Committed"}""")),
            transientCanvas = listOf(component("""{"type":"text","content":"Working"}""")),
            turns = listOf(ChatTurn("user", "Question")), pendingTurns = listOf(ChatTurn("assistant", "Draft")),
            turnActive = true, pendingReplace = true, workspaceStarted = true, historyLoading = true,
        )

    @Test
    fun unscoped_history_updates_only_history_during_an_active_turn() {
        val after = vm.reduce(active, Inbound.UiRender("history", listOf(history)))
        assertEquals("other-chat", after.history.single().id)
        assertEquals("Alpha = 2", after.history.single().preview)
        assertEquals(active.copy(history = after.history, historyLoading = false), after)
    }

    @Test
    fun scoped_history_is_refused_even_when_its_conversation_scope_matches() {
        for (chat in listOf("active", "wrong-chat")) {
            val scope = TransientFrameScope(chat, "connection", "request", 7UL, 4UL)
            assertEquals(active, vm.reduce(active, Inbound.UiRender("history", listOf(history), scope)))
        }
    }

    @Test
    fun start_history_and_skeleton_never_replace_the_welcome_canvas() {
        val start = UiState(canvas = listOf(component("""{"type":"text","component_id":"wel_intro","content":"Welcome"}""")))
        val loaded = vm.reduce(start, Inbound.UiRender("history", listOf(history)))
        assertEquals(start.copy(history = loaded.history), loaded)
        assertEquals("other-chat", loaded.history.single().id)
        val skeleton = component("""{"type":"skeleton","variant":"chat-history"}""")
        assertEquals(loaded.copy(historyLoading = true), vm.reduce(loaded, Inbound.UiRender("history", listOf(skeleton))))
        assertEquals(loaded, vm.reduce(loaded, Inbound.UiRender("history", listOf(component("""{"type":"text","content":"Unexpected"}""")))))
    }

    @Test
    fun raw_history_list_fallback_keeps_its_existing_state_contract() {
        val chats = listOf(ChatSummary("old", "Fallback"))
        assertEquals(active.copy(history = chats, historyLoading = false), vm.reduce(active.copy(historyTitle = "Server heading"), Inbound.HistoryList(chats)))
    }

    @Test
    fun canonical_title_is_preserved_while_empty_or_wrong_type_defaults() {
        for ((value, title) in listOf("\"  Saved\\tconversations  \"" to "Saved conversations", "\"\"" to "Recent chats", "{}" to "Recent chats")) {
            val frame = component("""{"type":"chat_history","title":$value,"items":[]}""")
            val after = vm.reduce(active, Inbound.UiRender("history", listOf(frame)))
            assertEquals(active.copy(history = emptyList(), historyTitle = title, historyLoading = false), after)
        }
        assertEquals("Recent chats", UiState().historyTitle)
    }

    @Test
    fun malformed_canonical_items_do_not_erase_existing_history() {
        val current = active.copy(history = listOf(ChatSummary("retained", "Previous")))
        for (fields in listOf("", ",\"items\":null", ",\"items\":{}", ",\"items\":\"invalid\"")) {
            val malformed = component("""{"type":"chat_history"$fields}""")
            assertEquals(current, vm.reduce(current, Inbound.UiRender("history", listOf(malformed))))
        }
    }
}
