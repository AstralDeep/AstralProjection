package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

enum class LayoutMode { Stacked, Collapsed, Split }

fun layoutModeFor(widthDp: Int): LayoutMode =
    when {
        widthDp < 700 -> LayoutMode.Stacked
        widthDp < 1024 -> LayoutMode.Collapsed
        else -> LayoutMode.Split
    }

/** Only a top-level welcome identity can move out of the canvas. */
internal fun welcomePlacementRole(component: Component): String? {
    if (component.id?.startsWith("wel_") == false) return null
    return (component.attributes["data-welcome"] as? JsonPrimitive)?.contentOrNull
        ?.takeIf { it in setOf("intro", "permission", "examples", "more") }
}

internal val UiState.showsStart: Boolean
    get() =
        !workspaceStarted && !hasActiveWork && !showSkeleton &&
            !isViewingHistory && !timelineReadOnly && requestPurpose == null &&
            visibleTurns.none { it.hasVisibleContent } && canvasHistory.isEmpty() &&
            visibleCanvas.all { welcomePlacementRole(it) != null }

/** A pending navigation acknowledgment does not retire server-owned welcome. */
internal val UiState.acceptsStartWelcome: Boolean
    get() = !workspaceStarted && requestGeneration == null && !turnActive && !pendingReplace
