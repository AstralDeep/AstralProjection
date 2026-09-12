package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.auth.ConversationResumeStore.AccountIdentity
import com.personalailabs.astraldeep.core.chrome.ChromeMenuModel
import com.personalailabs.astraldeep.core.chrome.SignOutItem
import com.personalailabs.astraldeep.core.chrome.TopBarControl
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WorkspaceActions088Test {
    private val owner = AccountIdentity("https://iam.example", "owner")
    private val controls =
        listOf("export_canvas", "share_canvas").map {
            TopBarControl(it, "workspace_action", it, "download", operation = it, context = "live_canvas")
        }
    private val live =
        UiState(
            activeChatId = "chat-1",
            workspaceStarted = true,
            canvas = listOf(Component("text", "result", JsonObject(emptyMap()), emptyList())),
            chromeMenu = ChromeMenuModel(2, controls, emptyList(), SignOutItem()),
        )

    @Test
    fun visibility_follows_server_capability_and_live_canvas_without_busy_or_revision_predicate() {
        assertTrue(workspaceControls(live).size == 2)
        assertTrue(workspaceControls(live.copy(turnActive = true, pendingReplace = true)).size == 2)
        assertTrue(workspaceControls(live.copy(workspaceStarted = false, hydrationApplied = true)).size == 2)
        for (state in listOf(
            live.copy(screen = Screen.History),
            live.copy(viewingIndex = 0),
            live.copy(timelineReadOnly = true),
            live.copy(mandatorySurface = true),
            live.copy(canvas = emptyList()),
            live.copy(workspaceStarted = false, canvas = emptyList()),
            live.copy(chromeMenu = null),
        )) assertTrue(workspaceControls(state).isEmpty())
    }

    @Test
    fun lease_rejects_duplicates_and_late_owner_chat_session_revision_or_capability_completion() {
        val state = workspaceContext(live, owner, 1)!!
        val gate = WorkspaceActionLeases()
        val export = gate.begin("export_canvas", state)!!
        assertNull(gate.begin("export_canvas", state))
        assertNotNull(gate.begin("share_canvas", state))
        assertTrue(gate.isCurrent(export, state))
        for (other in listOf(
            null,
            state.copy(owner = owner.copy(subject = "other")),
            state.copy(epoch = 2),
            state.copy(chatId = "other"),
            state.copy(revision = 1UL),
            state.copy(operations = emptySet()),
        )) assertFalse(gate.isCurrent(export, other))
        gate.finish(export)
        val newer = gate.begin("export_canvas", state)!!
        gate.finish(export)
        assertTrue(gate.isCurrent(newer, state))
        assertFalse(gate.isCurrent(export, state))
        assertNull(gate.begin("arbitrary", state))
    }

    @Test
    fun share_is_chat_bound_while_export_is_also_revision_bound() {
        val context = workspaceContext(live, owner, 3)!!
        val gate = WorkspaceActionLeases()
        val share = gate.begin("share_canvas", context)!!
        assertTrue(gate.isCurrent(share, context.copy(revision = 20UL)))
        val reconnected = workspaceContext(live.copy(connectionGeneration = "new-connection", requestGeneration = "new-turn"), owner, 3)!!
        assertTrue(gate.isCurrent(share, reconnected))
        val export = gate.begin("export_canvas", context)!!
        assertTrue(gate.isCurrent(export, reconnected))
        assertNull(workspaceContext(live, null, 3))
    }
}
