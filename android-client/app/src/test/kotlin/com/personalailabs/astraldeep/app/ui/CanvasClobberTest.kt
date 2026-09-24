// Tests for AppViewModel's canvas convergence contract: in-turn ui_upsert ops apply to the live canvas
// immediately, while a full ui_render replaces it wholesale and commits atomically at turn done.

package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.sdui.CanvasOp
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CanvasClobberTest {
    private val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))

    private fun comp(
        id: String,
        type: String = "card",
    ) = Component(type, id, JsonObject(emptyMap()), emptyList())

    @Test
    fun out_of_turn_full_render_is_authoritative_replace() {
        var s = vm.reduce(UiState(), Inbound.UiUpsert(chatId = null, ops = listOf(CanvasOp("upsert", "A", comp("A")))))
        assertEquals(listOf("A"), s.canvas.map { it.id })
        s = vm.reduce(s, Inbound.UiRender(target = "canvas", components = listOf(comp("B"))))
        assertEquals(listOf("B"), s.canvas.map { it.id })
    }

    @Test
    fun out_of_turn_render_updates_a_matching_id_in_place() {
        var s = vm.reduce(UiState(), Inbound.UiUpsert(chatId = null, ops = listOf(CanvasOp("upsert", "A", comp("A", "card")))))
        s = vm.reduce(s, Inbound.UiRender(target = "canvas", components = listOf(comp("A", "alert"))))
        assertEquals(listOf("A"), s.canvas.map { it.id })
        assertEquals("alert", s.canvas.single().type)
    }

    @Test
    fun out_of_turn_empty_render_clears_the_canvas() {
        var s = vm.reduce(UiState(), Inbound.UiUpsert(chatId = null, ops = listOf(CanvasOp("upsert", "A", comp("A")))))
        assertEquals(listOf("A"), s.canvas.map { it.id })
        s = vm.reduce(s, Inbound.UiRender(target = "canvas", components = emptyList()))
        assertEquals(emptyList(), s.canvas.map { it.id })
    }

    @Test
    fun in_turn_upsert_applies_live_and_clears_the_skeleton() {
        var s = vm.armTurn(UiState())
        assertTrue(s.showSkeleton)
        s = vm.reduce(s, Inbound.UiUpsert(chatId = null, ops = listOf(CanvasOp("upsert", "A", comp("A")))))
        assertEquals(listOf("A"), s.visibleCanvas.map { it.id })
        assertTrue(s.pendingCanvas.isEmpty())
        assertFalse(s.showSkeleton)
    }

    @Test
    fun in_turn_full_render_stays_buffered_and_wins_at_done() {
        var s = vm.armTurn(UiState())
        s = vm.reduce(s, Inbound.UiUpsert(chatId = null, ops = listOf(CanvasOp("upsert", "A", comp("A", "card")))))
        s = vm.reduce(s, Inbound.UiRender(target = "canvas", components = listOf(comp("A", "alert"), comp("B"))))
        assertEquals(listOf("A"), s.canvas.map { it.id })
        assertEquals("card", s.canvas.single().type)
        assertEquals(listOf("A", "B"), s.pendingCanvas.map { it.id })
        s = vm.reduce(s, Inbound.ChatStatus(status = "done", message = null))
        assertEquals(listOf("A", "B"), s.canvas.map { it.id })
        assertEquals("alert", s.canvas.first().type)
        assertFalse(s.pendingReplace)
    }

    @Test
    fun ops_only_turn_commits_the_live_canvas_no_double_apply() {
        var s = vm.armTurn(UiState(canvas = listOf(comp("old")), canvasLabel = "before"))
        s = vm.reduce(s, Inbound.UiUpsert(chatId = null, ops = listOf(CanvasOp("upsert", "A", comp("A")))))
        assertEquals(listOf("old", "A"), s.visibleCanvas.map { it.id })
        s = vm.reduce(s, Inbound.ChatStatus(status = "done", message = null))
        assertEquals(listOf("old", "A"), s.canvas.map { it.id })
        assertEquals(listOf(listOf("old")), s.canvasHistory.map { snap -> snap.components.map { it.id } })
        assertEquals("before", s.canvasHistory.single().label)
        assertFalse(s.pendingReplace)
    }

    @Test
    fun mid_turn_stream_ops_go_live_and_the_join_guard_reads_the_live_canvas() {
        var s = vm.armTurn(UiState())
        s = vm.reduce(s, Inbound.UiUpsert(chatId = null, ops = listOf(CanvasOp("upsert", "wc_abc", comp("wc_abc", "card")))))
        assertFalse(s.showSkeleton)
        s = vm.reduce(s, Inbound.StreamSubscribed("s1", "ticker", "wc_abc"))
        assertEquals(listOf("wc_abc"), s.canvas.map { it.id })
        assertEquals("card", s.canvas.single().type)
    }
}
