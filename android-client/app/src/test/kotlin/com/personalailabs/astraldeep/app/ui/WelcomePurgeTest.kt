// Tests for AppViewModel's welcome-component purge rule: wel_-prefixed components are turn-scoped, purged the
// moment a turn arms, and never archived into the canvas timeline.

package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConversationRequestPurpose
import com.personalailabs.astraldeep.app.transport.LocalSubmission
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.sdui.CanvasOp
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WelcomePurgeTest {
    private val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))

    private fun comp(
        id: String?,
        type: String = "card",
    ) = Component(type, id, JsonObject(emptyMap()), emptyList())

    private val welcome = listOf(comp("wel_hero", "hero"), comp("wel_examples"), comp("wel_enable"))

    private val placedWelcome =
        listOf(
            Component(
                "text",
                "wel_intro",
                buildJsonObject {
                    put("data-welcome", "intro")
                    put("text", "Ready to help.")
                },
                emptyList(),
            ),
            Component("container", "wel_examples", buildJsonObject { put("data-welcome", "examples") }, emptyList()),
        )

    @Test
    fun new_chat_pending_ack_does_not_discard_its_unscoped_welcome() {
        val pending =
            vm.projectLocalSubmission(
                UiState(connectionGeneration = "connection"),
                LocalSubmission("new_chat", null, "submission", "navigation"),
            )
        assertTrue(pending.hasActiveWork)
        val after = vm.reduce(pending, Inbound.UiRender(target = "canvas", components = placedWelcome))
        assertEquals(placedWelcome, after.canvas)
        assertEquals(pending.pendingSubmissions, after.pendingSubmissions)
        assertTrue(!after.workspaceStarted)
        val settled = after.copy(pendingSubmissions = emptyMap())
        assertTrue(settled.showsStart)
    }

    @Test
    fun actual_work_or_hydration_still_rejects_late_welcome() {
        for (state in listOf(
            UiState(workspaceStarted = true, canvas = listOf(comp("work"))),
            UiState(connectionGeneration = "connection", activeChatId = "chat", requestGeneration = "load", requestPurpose = ConversationRequestPurpose.HYDRATION),
            UiState(connectionGeneration = "connection", activeChatId = "chat", requestGeneration = "commit", requestPurpose = ConversationRequestPurpose.COMMIT),
        )) {
            assertEquals(state, vm.reduce(state, Inbound.UiRender(target = "canvas", components = placedWelcome)))
        }
    }

    @Test
    fun turn_start_arming_purges_welcome_from_the_canvas() {
        val s = vm.armTurn(UiState(canvas = welcome + comp("A")))
        assertEquals(listOf("A"), s.canvas.map { it.id })
        assertEquals(listOf("A"), s.preTurnCanvas.map { it.id })
        assertTrue(s.turnActive)
        assertTrue(s.pendingReplace)
    }

    @Test
    fun commit_never_archives_a_welcome_only_canvas() {
        var s = UiState(canvas = welcome, preTurnCanvas = welcome, turnActive = true, pendingReplace = true)
        s = vm.reduce(s, Inbound.UiUpsert(chatId = null, ops = listOf(CanvasOp("upsert", "A", comp("A")))))
        s = vm.reduce(s, Inbound.ChatStatus(status = "done", message = null))
        assertEquals(listOf("A"), s.canvas.map { it.id })
        assertTrue(s.canvasHistory.isEmpty())
    }

    @Test
    fun commit_archives_only_the_non_welcome_components() {
        var s =
            UiState(
                canvas = welcome + comp("old"),
                preTurnCanvas = welcome + comp("old"),
                canvasLabel = "old turn",
                turnActive = true,
                pendingReplace = true,
            )
        s = vm.reduce(s, Inbound.UiUpsert(chatId = null, ops = listOf(CanvasOp("upsert", "A", comp("A")))))
        s = vm.reduce(s, Inbound.ChatStatus(status = "done", message = null))
        assertEquals(listOf(listOf("old")), s.canvasHistory.map { snap -> snap.components.map { it.id } })
        assertEquals("old turn", s.canvasHistory.single().label)
        assertEquals(listOf("old", "A"), s.canvas.map { it.id })
    }

    @Test
    fun a_text_only_turn_does_not_resurrect_welcome() {
        var s = UiState(canvas = welcome + comp("A"), turnActive = true, pendingReplace = true)
        s = vm.reduce(s, Inbound.ChatStatus(status = "done", message = null))
        assertEquals(listOf("A"), s.canvas.map { it.id })
        assertTrue(s.canvasHistory.isEmpty())
    }

    @Test
    fun non_welcome_ids_are_never_dropped() {
        val keep = listOf(comp("welcome"), comp("wc_abc123"), comp(null, "text"))
        val s = vm.armTurn(UiState(canvas = keep))
        assertEquals(listOf("welcome", "wc_abc123", null), s.canvas.map { it.id })
    }
}
