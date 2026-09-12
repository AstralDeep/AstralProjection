package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.auth.ConversationResumeStore.AccountIdentity
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ComponentActions088Test {
    private val owner = AccountIdentity("https://iam.example", "owner")
    private val component =
        Component.fromJson(
            Json.parseToJsonElement(
                """{
        "type":"table","component_id":"wc_a","id":"layout_alias","component_chrome":{"version":1,"actions":[
        {"kind":"refine","label":"refine","icon":"✎","title":"Refine","context":"live_canvas"},
        {"kind":"history","label":"history","icon":"⟲","title":"History","context":"live_canvas"},
        {"kind":"csv","label":"csv","icon":"⬇","title":"CSV","context":"owned_chat"},
        {"kind":"share","label":"share","icon":"↗","title":"Share","context":"owned_chat"}]}}
        """,
            ) as JsonObject,
        )
    private val live = UiState(activeChatId = "chat", canvas = listOf(component))

    @Test fun mounted_owned_context_is_required_and_timeline_only_hides_live_actions() {
        assertEquals(listOf("refine", "history", "csv", "share"), componentActionContext(live, owner, 1, component)!!.actions.map { it.kind })
        val snapshots = live.copy(canvasHistory = listOf(CanvasSnapshot("Earlier", listOf(component))), viewingIndex = 0)
        for (state in listOf(live.copy(timelineReadOnly = true), snapshots)) {
            assertEquals(listOf("csv", "share"), componentActionContext(state, owner, 1, component)!!.actions.map { it.kind })
        }
        for (state in listOf(live.copy(screen = Screen.History), live.copy(mandatorySurface = true), live.copy(activeChatId = null), live.copy(canvas = emptyList()), live.copy(canvas = listOf(component, component)))) {
            assertNull(componentActionContext(state, owner, 1, component))
        }
        assertNull(componentActionContext(live, null, 1, component))
        assertNull(componentActionContext(live, owner, 1, component.copy(attributes = JsonObject(emptyMap()))))
        val old = component.copy(attributes = JsonObject(component.attributes - "component_chrome"))
        assertNull(componentActionContext(live.copy(canvas = listOf(old)), owner, 1, old))
    }

    @Test fun late_sheet_or_response_cannot_cross_owner_epoch_chat_component_or_action_fences() {
        val context = componentActionContext(live, owner, 3, component)!!
        val leases = ComponentActionLeases()
        val ticket = leases.begin(context, "share")!!
        assertNull(leases.begin(context, "share"))
        assertNull(leases.begin(context, "injected"))
        assertNotNull(leases.begin(context, "csv"))
        assertTrue(leases.isCurrent(ticket, context))
        for (other in listOf(null, context.copy(owner = owner.copy(subject = "other")), context.copy(epoch = 4), context.copy(chatId = "other"), context.copy(component = component.copy(type = "text")), context.copy(actions = emptyList()))) {
            assertFalse(leases.isCurrent(ticket, other))
        }
        val ordinary = componentActionContext(live.copy(connectionGeneration = "new", requestGeneration = "other", lastCommittedRenderRevision = 50UL), owner, 3, component)
        assertTrue(leases.isCurrent(ticket, ordinary))
        leases.finish(ticket)
        val replacement = leases.begin(context, "share")!!
        leases.finish(ticket)
        assertTrue(leases.isCurrent(replacement, context))
        assertFalse(leases.isCurrent(ticket, context))
    }
}
