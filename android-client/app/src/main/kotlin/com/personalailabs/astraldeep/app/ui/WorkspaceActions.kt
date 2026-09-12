package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.auth.ConversationResumeStore.AccountIdentity
import com.personalailabs.astraldeep.core.chrome.TopBarControl

internal fun workspaceControls(state: UiState): List<TopBarControl> {
    if (state.screen != Screen.Chat || state.mandatorySurface || state.isViewingHistory || state.timelineReadOnly ||
        state.showsStart || state.visibleCanvas.none { welcomePlacementRole(it) == null }
    ) {
        return emptyList()
    }
    return state.chromeMenu?.topbar.orEmpty().filter {
        it.kind == "workspace_action" && it.context == "live_canvas" && it.action == null &&
            it.operation in setOf("export_canvas", "share_canvas")
    }
}

internal data class WorkspaceContext(
    val owner: AccountIdentity,
    val epoch: Long,
    val chatId: String,
    val revision: ULong,
    val operations: Set<String>,
)

internal fun workspaceContext(
    state: UiState,
    owner: AccountIdentity?,
    epoch: Long,
): WorkspaceContext? {
    if (owner == null) return null
    val chat = state.activeChatId?.takeIf { it.isNotBlank() } ?: return null
    val operations = workspaceControls(state).mapNotNull { it.operation }.toSet()
    if (operations.isEmpty()) return null
    return WorkspaceContext(
        owner,
        epoch,
        chat,
        state.lastCommittedRenderRevision,
        operations,
    )
}

/** Identity tickets keep a late completion from releasing a newer in-flight action. */
internal class WorkspaceActionLeases {
    class Ticket internal constructor(val operation: String, val context: WorkspaceContext)

    private val active = mutableMapOf<String, Ticket>()

    @Synchronized
    fun begin(
        operation: String,
        context: WorkspaceContext?,
    ): Ticket? {
        if (context == null || operation !in context.operations || operation in active) return null
        return Ticket(operation, context).also { active[operation] = it }
    }

    @Synchronized
    fun isCurrent(
        ticket: Ticket,
        current: WorkspaceContext?,
    ): Boolean =
        active[ticket.operation] === ticket && current != null && ticket.operation in current.operations &&
            ticket.context.owner == current.owner && ticket.context.epoch == current.epoch &&
            ticket.context.chatId == current.chatId &&
            (ticket.operation != "export_canvas" || ticket.context.revision == current.revision)

    @Synchronized
    fun finish(ticket: Ticket) {
        if (active[ticket.operation] === ticket) active.remove(ticket.operation)
    }
}
