// Resolves a server-owned top-bar control (pulse/timeline) into its drawable, label, and target surface for
// AstralTopBar in RootScaffold.kt; a control with no actionable surface resolves to null.

package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.core.chrome.TopBarControl
import kotlinx.serialization.json.JsonObject

/** Which glyph a server-owned top-bar action maps to (feature 044 T037). */
enum class TopBarIcon { SPARKLE, HISTORY, GENERIC }

data class TopBarActionView(
    val key: String,
    val label: String,
    val icon: TopBarIcon,
    val surface: String,
    val params: JsonObject,
)

fun topBarActionView(control: TopBarControl): TopBarActionView? {
    val action = control.action ?: return null
    val surface = action.surface.takeIf { it.isNotBlank() } ?: return null
    return TopBarActionView(
        key = control.key,
        label = control.label ?: surface,
        icon =
            when (control.icon) {
                "sparkle" -> TopBarIcon.SPARKLE
                "history" -> TopBarIcon.HISTORY
                else -> TopBarIcon.GENERIC
            },
        surface = surface,
        params = action.params,
    )
}
