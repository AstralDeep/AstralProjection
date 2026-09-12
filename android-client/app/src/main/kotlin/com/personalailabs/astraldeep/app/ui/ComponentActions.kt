package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.auth.ConversationResumeStore.AccountIdentity
import com.personalailabs.astraldeep.core.chrome.ComponentAction
import com.personalailabs.astraldeep.core.chrome.ComponentChrome
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.JsonObject

internal data class ComponentActionContext(
    val owner: AccountIdentity,
    val epoch: Long,
    val chatId: String,
    val componentId: String,
    val component: Component,
    val actions: List<ComponentAction>,
)

internal fun componentActionContext(
    state: UiState,
    owner: AccountIdentity?,
    epoch: Long,
    component: Component,
): ComponentActionContext? {
    if (owner == null || state.screen != Screen.Chat || state.mandatorySurface) return null
    val chat = state.activeChatId?.takeIf { it.isNotBlank() } ?: return null
    val id = ComponentChrome.identity(component) ?: return null
    // A stale footer or duplicate ID is never a current action target.
    val matches = state.visibleCanvas.filter { ComponentChrome.identity(it) == id }
    if (matches.size != 1 || matches.single() != component) return null
    val actions =
        ComponentChrome.actions(component).filter {
            it.context == "owned_chat" || (!state.timelineReadOnly && !state.isViewingHistory)
        }
    if (actions.isEmpty()) return null
    return ComponentActionContext(owner, epoch, chat, id, component, actions)
}

private val idleComponentActions: StateFlow<Set<Pair<String, String>>> = MutableStateFlow(emptySet())

internal interface ComponentActionHandler {
    val pending: StateFlow<Set<Pair<String, String>>> get() = idleComponentActions

    fun context(component: Component): ComponentActionContext?

    fun perform(
        context: ComponentActionContext,
        kind: String,
        payload: JsonObject = JsonObject(emptyMap()),
    )
}

internal class ComponentActionLeases {
    class Ticket internal constructor(val context: ComponentActionContext, val kind: String)

    private val active = mutableMapOf<Pair<String, String>, Ticket>()

    @Synchronized
    fun begin(
        context: ComponentActionContext,
        kind: String,
    ): Ticket? {
        val key = context.componentId to kind
        if (context.actions.none { it.kind == kind } || key in active) return null
        return Ticket(context, kind).also { active[key] = it }
    }

    @Synchronized
    fun isCurrent(
        ticket: Ticket,
        current: ComponentActionContext?,
    ): Boolean =
        active[ticket.context.componentId to ticket.kind] === ticket && current != null &&
            current.owner == ticket.context.owner && current.epoch == ticket.context.epoch &&
            current.chatId == ticket.context.chatId && current.component == ticket.context.component &&
            current.actions.any { it.kind == ticket.kind }

    @Synchronized
    fun finish(ticket: Ticket) {
        val key = ticket.context.componentId to ticket.kind
        if (active[key] === ticket) active.remove(key)
    }
}
