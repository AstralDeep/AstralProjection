// Validates ROTE's server-selected geometry without inventing native breakpoints.
// The app replaces this value when a current device profile arrives.

package com.personalailabs.astraldeep.core.chrome

import kotlinx.serialization.json.JsonElement

data class ConsoleInsets(val top: Double, val right: Double, val bottom: Double, val left: Double) {
    companion object {
        internal fun decode(value: JsonElement?): ConsoleInsets {
            val root = ConsoleDecoding.obj(value)
            return ConsoleInsets(
                ConsoleDecoding.number(root["top"], 0.0, 16384.0),
                ConsoleDecoding.number(root["right"], 0.0, 16384.0),
                ConsoleDecoding.number(root["bottom"], 0.0, 16384.0),
                ConsoleDecoding.number(root["left"], 0.0, 16384.0),
            )
        }
    }
}

data class ConsolePresentation(
    val navigationMode: String,
    val sidebarWidth: Double,
    val contentPadding: ConsoleInsets,
    val composerPadding: ConsoleInsets,
    val scenarioColumns: Int,
    val settingsPresentation: String,
    val settingsNavigationAxis: String,
    val settingsWidth: Double,
    val dialogWidth: Double,
    val settingsMaxHeight: Double,
    val settingsNavigationWidth: Double,
    val resultPreviewMaxHeight: Double,
    val resultBodyMaxHeight: Double,
    val fullscreenInset: Double,
    val minimumControlHeight: Double,
) {
    companion object {
        fun fromJson(value: JsonElement?): ConsolePresentation? =
            ConsoleDecoding.decode {
                val root = ConsoleDecoding.obj(value)

                fun number(
                    key: String,
                    minimum: Double = 0.0,
                ) = ConsoleDecoding.number(root[key], minimum, 16384.0)
                require(ConsoleDecoding.number(root["version"], 2.0, 2.0) == 2.0)
                val navigation = ConsoleDecoding.text(root["navigation_mode"], 20)
                require(navigation in setOf("drawer", "sidebar", "stack"))
                val sidebar = number("sidebar_width")
                require(if (navigation == "stack") sidebar == 0.0 else sidebar > 0.0)
                val columns = ConsoleDecoding.number(root["scenario_columns"], 1.0, 64.0)
                require(columns.toInt().toDouble() == columns)
                val settings = ConsoleDecoding.text(root["settings_presentation"], 20)
                val axis = ConsoleDecoding.text(root["settings_navigation_axis"], 20)
                require(settings in setOf("sheet", "dialog", "push") && axis in setOf("horizontal", "vertical"))
                ConsolePresentation(
                    navigation, sidebar, ConsoleInsets.decode(root["content_padding"]), ConsoleInsets.decode(root["composer_padding"]),
                    columns.toInt(), settings, axis, number("settings_width", 1.0), number("dialog_width", 1.0),
                    number("settings_max_height", 0.1), number("settings_navigation_width"), number("result_preview_max_height", 1.0),
                    number("result_body_max_height", 1.0), number("fullscreen_inset"), number("minimum_control_height"),
                )
            }
    }
}
