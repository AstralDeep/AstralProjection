// Tests that AppViewModel's reducer folds boot-time and live theme_apply updates into UiState.themePalette.

package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.app.ui.theme.THEME_PRESETS
import com.personalailabs.astraldeep.core.protocol.Inbound
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ThemeReducerTest {
    private val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))

    @Test
    fun user_preferences_theme_at_boot_sets_the_palette() {
        val s = vm.reduce(UiState(), Inbound.UserPreferences(theme = buildJsonObject { put("preset", "sunset") }))
        assertEquals(THEME_PRESETS["sunset"], s.themePalette)
    }

    @Test
    fun user_preferences_without_a_theme_leaves_the_palette_null() {
        val s = vm.reduce(UiState(), Inbound.UserPreferences(theme = null))
        assertNull(s.themePalette)
    }

    @Test
    fun apply_theme_updates_the_palette_live() {
        vm.applyTheme(buildJsonObject { put("preset", "forest") })
        assertEquals(THEME_PRESETS["forest"], vm.state.value.themePalette)
    }
}
