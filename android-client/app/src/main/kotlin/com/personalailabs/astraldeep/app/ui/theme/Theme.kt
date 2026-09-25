// Kotlin twin of the web/Windows theme system: a seven-channel ThemePalette folds live theme specs into a
// Material ColorScheme; presets and channel math mirror backend theme.py and client.js.

package com.personalailabs.astraldeep.app.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.personalailabs.astraldeep.app.R
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

object AstralColors {
    val Indigo = Color(0xFF6366F1)
    val Purple = Color(0xFF8B5CF6)
    val Cyan = Color(0xFF06B6D4)
    val Bg = Color(0xFF0F1221)
    val BgElevated = Color(0xFF12162A)
    val Surface = Color(0xFF1A1E2E)
    val SurfaceVariant = Color(0xFF1E2338)
    val Border = Color(0xFF2A2F49)
    val Text = Color(0xFFF3F4F6)
    val Muted = Color(0xFF9CA3AF)

    val AccentBrush =
        Brush.linearGradient(listOf(Indigo, Purple), start = Offset.Zero, end = Offset.Infinite)

    val BackdropBrush =
        Brush.verticalGradient(listOf(Color(0xFF0F1221), Color(0xFF141A33), Color(0xFF0F1221)))
}

@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
val AstralSans =
    FontFamily(
        listOf(FontWeight.Normal, FontWeight.Medium, FontWeight.SemiBold, FontWeight.Bold, FontWeight.ExtraBold).map { weight ->
            Font(R.font.open_sans_latin, weight = weight, variationSettings = FontVariation.Settings(FontVariation.weight(weight.weight)))
        },
    )
val AstralMono = FontFamily(Font(R.font.jetbrains_mono_latin))
private val baseTypography = Typography()
private val astralTypography =
    Typography(
        displayLarge = baseTypography.displayLarge.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        displayMedium = baseTypography.displayMedium.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        displaySmall = baseTypography.displaySmall.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        headlineLarge = baseTypography.headlineLarge.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        headlineMedium = baseTypography.headlineMedium.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        headlineSmall = baseTypography.headlineSmall.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        titleLarge = baseTypography.titleLarge.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        titleMedium = baseTypography.titleMedium.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        titleSmall = baseTypography.titleSmall.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        bodyLarge = baseTypography.bodyLarge.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        bodyMedium = baseTypography.bodyMedium.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        bodySmall = baseTypography.bodySmall.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        labelLarge = baseTypography.labelLarge.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        labelMedium = baseTypography.labelMedium.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
        labelSmall = baseTypography.labelSmall.copy(fontFamily = AstralSans, letterSpacing = 0.sp),
    )

private val AstralDarkColors =
    darkColorScheme(
        primary = AstralColors.Indigo,
        onPrimary = Color.White,
        secondary = AstralColors.Purple,
        tertiary = AstralColors.Cyan,
        background = AstralColors.Bg,
        onBackground = AstralColors.Text,
        surface = AstralColors.Surface,
        onSurface = AstralColors.Text,
        surfaceVariant = AstralColors.SurfaceVariant,
        onSurfaceVariant = AstralColors.Muted,
        outline = AstralColors.Border,
        outlineVariant = AstralColors.Border,
    )

@Immutable
data class ThemePalette(
    val bg: String,
    val surface: String,
    val primary: String,
    val secondary: String,
    val text: String,
    val muted: String,
    val accent: String,
) {
    fun withChannel(
        key: String,
        hex: String,
    ): ThemePalette =
        when (key) {
            "bg" -> copy(bg = hex)
            "surface" -> copy(surface = hex)
            "primary" -> copy(primary = hex)
            "secondary" -> copy(secondary = hex)
            "text" -> copy(text = hex)
            "muted" -> copy(muted = hex)
            "accent" -> copy(accent = hex)
            else -> this
        }

    fun channel(key: String): String? =
        when (key) {
            "bg" -> bg
            "surface" -> surface
            "primary" -> primary
            "secondary" -> secondary
            "text" -> text
            "muted" -> muted
            "accent" -> accent
            else -> null
        }
}

val THEME_PRESETS: Map<String, ThemePalette> =
    mapOf(
        "midnight" to ThemePalette("#0F1221", "#1A1E2E", "#6366F1", "#8B5CF6", "#F3F4F6", "#9CA3AF", "#06B6D4"),
        "daylight" to ThemePalette("#F8FAFC", "#FFFFFF", "#4F46E5", "#7C3AED", "#1E293B", "#64748B", "#0891B2"),
        "ocean" to ThemePalette("#0C1222", "#132038", "#0EA5E9", "#06B6D4", "#E2E8F0", "#94A3B8", "#2DD4BF"),
        "sunset" to ThemePalette("#1C1017", "#2D1B24", "#F97316", "#EF4444", "#FEF2F2", "#A8A29E", "#FBBF24"),
        "forest" to ThemePalette("#0F1A14", "#1A2E22", "#22C55E", "#10B981", "#ECFDF5", "#86EFAC", "#A3E635"),
    )

private val DEFAULT_PALETTE = THEME_PRESETS.getValue("midnight")

fun channelSwatchOptions(
    key: String,
    current: String?,
): List<String> {
    val cur = current?.takeIf { hexToColor(it) != null }
    val fromPresets = THEME_PRESETS.values.mapNotNull { it.channel(key) }
    return (listOfNotNull(cur) + fromPresets).distinct()
}

fun hexToColor(hex: String?): Color? {
    val s = (hex ?: "").trim().removePrefix("#")
    if (s.length != 6 || s.any { it.digitToIntOrNull(16) == null }) return null
    return Color(0xFF000000L or s.toLong(16))
}

fun themePaletteForSpec(
    current: ThemePalette?,
    spec: JsonObject?,
): ThemePalette? {
    if (spec == null) return current
    val base = current ?: DEFAULT_PALETTE
    val colors = spec["colors"] as? JsonObject
    if (!colors.isNullOrEmpty()) {
        var next = base
        for ((k, v) in colors) {
            val hex = (v as? JsonPrimitive)?.contentOrNull ?: continue
            if (hexToColor(hex) != null) next = next.withChannel(k, hex)
        }
        return next
    }
    val preset = (spec["preset"] as? JsonPrimitive)?.contentOrNull
    if (preset != null && THEME_PRESETS.containsKey(preset)) return THEME_PRESETS[preset]
    val key = (spec["color_key"] as? JsonPrimitive)?.contentOrNull
    val value =
        (spec["color_value"] as? JsonPrimitive)?.contentOrNull
            ?: (spec["value"] as? JsonPrimitive)?.contentOrNull
    if (key != null && value != null && hexToColor(value) != null) return base.withChannel(key, value)
    return current
}

fun paletteToColorScheme(palette: ThemePalette): ColorScheme {
    val base = AstralDarkColors
    val surface = hexToColor(palette.surface) ?: base.surface
    val text = hexToColor(palette.text) ?: base.onSurface
    val secondary = hexToColor(palette.secondary) ?: base.secondary
    return darkColorScheme(
        primary = hexToColor(palette.primary) ?: base.primary,
        onPrimary = base.onPrimary,
        secondary = secondary,
        tertiary = hexToColor(palette.accent) ?: base.tertiary,
        background = hexToColor(palette.bg) ?: base.background,
        onBackground = hexToColor(palette.text) ?: base.onBackground,
        surface = surface,
        onSurface = text,
        surfaceVariant = surface,
        onSurfaceVariant = hexToColor(palette.muted) ?: base.onSurfaceVariant,
        outline = base.outline,
        outlineVariant = base.outlineVariant,
        // M3 components read these container roles, not background/surface
        surfaceContainerLowest = surface,
        surfaceContainerLow = surface,
        surfaceContainer = surface,
        surfaceContainerHigh = surface,
        surfaceContainerHighest = surface,
        secondaryContainer = tint(secondary, surface, 0.24f),
        onSecondaryContainer = text,
    )
}

private fun tint(
    fg: Color,
    bg: Color,
    alpha: Float,
): Color =
    Color(
        red = fg.red * alpha + bg.red * (1 - alpha),
        green = fg.green * alpha + bg.green * (1 - alpha),
        blue = fg.blue * alpha + bg.blue * (1 - alpha),
    )

@Composable
fun AstralTheme(
    palette: ThemePalette? = null,
    content: @Composable () -> Unit,
) {
    val scheme = palette?.let { paletteToColorScheme(it) } ?: AstralDarkColors
    MaterialTheme(colorScheme = scheme, typography = astralTypography, content = content)
}

internal fun exportPalette(scheme: ColorScheme): Map<String, String> {
    fun hex(color: Color): String =
        "#%02X%02X%02X".format((color.red * 255).toInt(), (color.green * 255).toInt(), (color.blue * 255).toInt())
    return mapOf(
        "bg" to hex(scheme.background), "surface" to hex(scheme.surface), "surface2" to hex(scheme.surfaceVariant),
        "primary" to hex(scheme.primary), "secondary" to hex(scheme.secondary), "accent" to hex(scheme.tertiary),
        "text" to hex(scheme.onSurface), "muted" to hex(scheme.onSurfaceVariant), "border" to "#FFFFFF12",
        "success" to hex(AstralWebStyle.Success),
        "warning" to hex(AstralWebStyle.Warning),
        "error" to hex(AstralWebStyle.Error),
        "info" to "#3B82F6",
    )
}
