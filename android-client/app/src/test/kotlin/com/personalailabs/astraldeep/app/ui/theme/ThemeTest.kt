// Tests for the theme model: hex parsing, folding a theme_apply spec onto the current palette, and building a
// Material ColorScheme from it.

package com.personalailabs.astraldeep.app.ui.theme

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ThemeTest {
    @Test
    fun hex_parses_valid_and_rejects_malformed() {
        assertNotNull(hexToColor("#0F1221"))
        assertNotNull(hexToColor("0F1221"))
        assertNull(hexToColor("#12"))
        assertNull(hexToColor("nothex"))
        assertNull(hexToColor(null))
    }

    @Test
    fun graphite_leads_the_presets_and_midnight_keeps_its_values() {
        assertEquals("graphite", THEME_PRESETS.keys.first())
        assertEquals(
            ThemePalette("#121214", "#1B1B1F", "#7C3AED", "#6E6E78", "#ECECEF", "#93939B", "#A78BFA", "#5EC28F", "#D4A94A", "#E17272", "#9A8CF2", "#121214", "#6E6E75"),
            THEME_PRESETS["graphite"],
        )
        assertEquals(
            ThemePalette("#0F1221", "#1A1E2E", "#6366F1", "#8B5CF6", "#F3F4F6", "#9CA3AF", "#06B6D4", "#5EC28F", "#D4A94A", "#E27777", "#9A8CF2", "#0F1221", "#686F7E"),
            THEME_PRESETS["midnight"],
        )
        assertEquals(listOf("graphite", "midnight", "daylight", "ocean", "sunset", "forest"), THEME_PRESETS.keys.toList())
    }

    @Test
    fun a_colors_spec_with_no_current_palette_overlays_graphite() {
        val p = themePaletteForSpec(null, buildJsonObject { putJsonObject("colors") { put("primary", "#123456") } })
        assertEquals(THEME_PRESETS.getValue("graphite").copy(primary = "#123456"), p)
        val single =
            themePaletteForSpec(
                null,
                buildJsonObject {
                    put("color_key", "bg")
                    put("color_value", "#010203")
                },
            )
        assertEquals(THEME_PRESETS.getValue("graphite").copy(bg = "#010203"), single)
    }

    @Test
    fun the_default_color_constants_match_the_graphite_preset() {
        val graphite = THEME_PRESETS.getValue("graphite")
        assertEquals(hexToColor(graphite.bg), AstralColors.Bg)
        assertEquals(hexToColor(graphite.surface), AstralColors.Surface)
        assertEquals(hexToColor(graphite.primary), AstralColors.Primary)
        assertEquals(hexToColor(graphite.secondary), AstralColors.Secondary)
        assertEquals(hexToColor(graphite.text), AstralColors.Text)
        assertEquals(hexToColor(graphite.muted), AstralColors.Muted)
        assertEquals(hexToColor(graphite.accent), AstralColors.Accent)
        assertEquals(hexToColor(graphite.error), AstralColors.Error)
        assertEquals(hexToColor(graphite.onError), AstralColors.OnError)
        assertEquals(hexToColor(graphite.fieldBorder), AstralColors.FieldBorder)
    }

    @Test
    fun a_preset_spec_replaces_the_whole_palette() {
        assertEquals(THEME_PRESETS["ocean"], themePaletteForSpec(null, buildJsonObject { put("preset", "ocean") }))
    }

    @Test
    fun a_colors_spec_overlays_named_channels_onto_current() {
        val start = THEME_PRESETS.getValue("midnight")
        val p = themePaletteForSpec(start, buildJsonObject { putJsonObject("colors") { put("primary", "#123456") } })
        assertEquals("#123456", p?.primary)
        assertEquals(start.bg, p?.bg)
    }

    @Test
    fun a_single_key_spec_overlays_one_channel() {
        val p =
            themePaletteForSpec(
                THEME_PRESETS.getValue("midnight"),
                buildJsonObject {
                    put("color_key", "accent")
                    put("color_value", "#ABCDEF")
                },
            )
        assertEquals("#ABCDEF", p?.accent)
    }

    @Test
    fun explicit_colors_win_over_an_unknown_preset_name() {
        val p =
            themePaletteForSpec(
                null,
                buildJsonObject {
                    put("preset", "solarpunk")
                    putJsonObject("colors") {
                        put("bg", "#101010")
                        put("surface", "#202020")
                        put("primary", "#303030")
                        put("secondary", "#404040")
                        put("text", "#505050")
                        put("muted", "#606060")
                        put("accent", "#707070")
                    }
                },
            )
        assertEquals(
            THEME_PRESETS.getValue("graphite").copy(
                bg = "#101010",
                surface = "#202020",
                primary = "#303030",
                secondary = "#404040",
                text = "#505050",
                muted = "#606060",
                accent = "#707070",
            ),
            p,
        )
    }

    @Test
    fun explicit_colors_win_over_a_known_preset_name() {
        val p =
            themePaletteForSpec(
                THEME_PRESETS.getValue("midnight"),
                buildJsonObject {
                    put("preset", "ocean")
                    putJsonObject("colors") { put("primary", "#123456") }
                },
            )
        assertEquals("#123456", p?.primary)
    }

    @Test
    fun an_unknown_preset_or_empty_spec_leaves_current_unchanged() {
        val start = THEME_PRESETS.getValue("forest")
        assertEquals(start, themePaletteForSpec(start, buildJsonObject { put("preset", "chartreuse") }))
        assertEquals(start, themePaletteForSpec(start, JsonObject(emptyMap())))
        assertEquals(start, themePaletteForSpec(start, null))
    }

    @Test
    fun palette_maps_to_the_expected_color_scheme_channels() {
        val scheme = paletteToColorScheme(THEME_PRESETS.getValue("ocean"))
        assertEquals(hexToColor("#0EA5E9"), scheme.primary)
        assertEquals(hexToColor("#0C1222"), scheme.background)
        assertEquals(hexToColor("#2DD4BF"), scheme.tertiary)
    }

    @Test
    fun the_graphite_preset_maps_to_the_default_color_scheme() {
        val scheme = paletteToColorScheme(THEME_PRESETS.getValue("graphite"))
        assertEquals(hexToColor("#7C3AED"), scheme.primary)
        assertEquals(hexToColor("#6E6E78"), scheme.secondary)
        assertEquals(hexToColor("#A78BFA"), scheme.tertiary)
        assertEquals(hexToColor("#121214"), scheme.background)
        assertEquals(hexToColor("#1B1B1F"), scheme.surface)
        assertEquals(hexToColor("#ECECEF"), scheme.onSurface)
        assertEquals(hexToColor("#93939B"), scheme.onSurfaceVariant)
        assertEquals(hexToColor("#E17272"), scheme.error)
        assertEquals(hexToColor("#121214"), scheme.onError)
    }

    @Test
    fun daylight_maps_its_own_error_pair_and_every_status_channel_round_trips() {
        val daylight = THEME_PRESETS.getValue("daylight")
        val scheme = paletteToColorScheme(daylight)
        assertEquals(hexToColor("#B91C1C"), scheme.error)
        assertEquals(hexToColor("#FFFFFF"), scheme.onError)
        for (key in listOf("success", "warning", "error", "info", "on_error", "field_border")) {
            val probe = daylight.withChannel(key, "#010203")
            assertEquals("#010203", probe.channel(key), key)
            assertEquals(daylight.withChannel(key, "#010203"), probe, key)
        }
        assertNull(daylight.channel("unknown"))
        assertEquals(daylight, daylight.withChannel("unknown", "#010203"))
    }

    @Test
    fun a_preset_spec_carries_its_status_and_border_channels() {
        val applied = themePaletteForSpec(null, buildJsonObject { put("preset", "daylight") })
        assertEquals("#147739", applied?.success)
        assertEquals("#955B06", applied?.warning)
        assertEquals("#7F8A9B", applied?.fieldBorder)
        val single =
            themePaletteForSpec(
                THEME_PRESETS.getValue("midnight"),
                buildJsonObject {
                    put("color_key", "field_border")
                    put("color_value", "#ABCDEF")
                },
            )
        assertEquals("#ABCDEF", single?.fieldBorder)
    }

    @Test
    fun channel_swatch_options_lead_with_current_and_include_presets() {
        val opts = channelSwatchOptions("bg", "#000000")
        assertEquals("#000000", opts.first())
        assertTrue(opts.contains(THEME_PRESETS.getValue("ocean").bg))
    }
}
