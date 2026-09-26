// Tracks a negotiated viewport hydration without discarding the settled conversation or local interaction state.
// AppViewModel applies these exact request and revision fences before accepting or restoring a layout refresh.

package com.personalailabs.astraldeep.app.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.ConversationRequestPurpose
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities

data class ViewportRefresh(
    val requestGeneration: String,
    val submissionId: String,
    val device: DeviceCapabilities,
    val settled: UiState,
) {
    fun owns(state: UiState): Boolean =
        state.viewportRefresh === this &&
            state.activeChatId == settled.activeChatId &&
            state.connectionGeneration == settled.connectionGeneration &&
            state.requestGeneration == requestGeneration &&
            state.requestPurpose == ConversationRequestPurpose.HYDRATION &&
            state.lastCommittedRenderRevision == settled.lastCommittedRenderRevision && !state.hydrationApplied
}

internal fun viewportRefreshReady(
    state: UiState,
    voiceActive: Boolean,
    interactions: Boolean,
): Boolean =
    state.viewportSnapshotSupported && state.connection == ConnectionState.Connected &&
        state.activeChatId != null && state.connectionGeneration != null &&
        state.viewportRefresh == null && !state.hasActiveWork &&
        (state.requestPurpose == null || state.requestPurpose == ConversationRequestPurpose.HYDRATION && state.hydrationApplied) &&
        state.screen == Screen.Chat && !state.timelineReadOnly && !state.mandatorySurface &&
        state.viewingIndex == null && !state.consoleDrawerOpen &&
        state.staged.none { it.state != "ready" } && !voiceActive && !interactions

internal fun restoreViewportRefresh(
    state: UiState,
    pending: ViewportRefresh,
): UiState {
    if (!pending.owns(state)) return state
    val settled = pending.settled
    return state.copy(
        requestGeneration = settled.requestGeneration,
        requestChatId = settled.requestChatId,
        requestPurpose = settled.requestPurpose,
        expectedCommitRenderRevision = settled.expectedCommitRenderRevision,
        hydrationApplied = settled.hydrationApplied,
        acceptedSnapshotId = settled.acceptedSnapshotId,
        acceptedSnapshot = settled.acceptedSnapshot,
        viewportRefresh = null,
        pendingViewportConfig = null,
        viewportRefreshFailed = true,
        banner = "Layout refresh failed. Retry when connected.",
        bannerKind = "error",
    )
}

internal val LocalViewportInteraction = staticCompositionLocalOf<(Any, Boolean) -> Unit> { { _, _ -> } }

@Composable
internal fun ViewportInteraction(active: Boolean) {
    val update = LocalViewportInteraction.current
    val key = remember { Any() }
    DisposableEffect(active, update) {
        update(key, active)
        onDispose { update(key, false) }
    }
}
