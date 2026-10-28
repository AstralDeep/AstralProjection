// Kotlin twin of the web/Windows theme system: a thirteen-channel ThemePalette folds live theme specs into a
// Material ColorScheme; presets and channel math mirror backend theme.py and client.js.

package com.personalailabs.astraldeep.app.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
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
    val Primary = Color(0xFF7C3AED)
    val Secondary = Color(0xFF6E6E78)
    val Accent = Color(0xFFA78BFA)
    val Cyan = Color(0xFF06B6D4)
    val Bg = Color(0xFF121214)
    val BgElevated = Color(0xFF18181C)
    val Surface = Color(0xFF1B1B1F)
    val SurfaceVariant = Color(0xFF232328)
    val Border = Color(0xFF2D2D31)
    val Text = Color(0xFFECECEF)
    val Muted = Color(0xFF93939B)
    val Error = Color(0xFFE17272)
    val OnError = Color(0xFF121214)
    val FieldBorder = Color(0xFF6E6E75)

    val AccentBrush =
        Brush.linearGradient(listOf(Primary, Secondary), start = Offset.Zero, end = Offset.Infinite)

    val BackdropBrush =
        Brush.verticalGradient(listOf(Bg, BgElevated, Bg))
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
        primary = AstralColors.Primary,
        onPrimary = Color.White,
        secondary = AstralColors.Secondary,
        tertiary = AstralColors.Accent,
        background = AstralColors.Bg,
        onBackground = AstralColors.Text,
        surface = AstralColors.Surface,
        onSurface = AstralColors.Text,
        surfaceVariant = AstralColors.SurfaceVariant,
        onSurfaceVariant = AstralColors.Muted,
        error = AstralColors.Error,
        onError = AstralColors.OnError,
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
    val success: String,
    val warning: String,
    val error: String,
    val info: String,
    val onError: String,
    val fieldBorder: String,
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
            "success" -> copy(success = hex)
            "warning" -> copy(warning = hex)
            "error" -> copy(error = hex)
            "info" -> copy(info = hex)
            "on_error" -> copy(onError = hex)
            "field_border" -> copy(fieldBorder = hex)
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
            "success" -> success
            "warning" -> warning
            "error" -> error
            "info" -> info
            "on_error" -> onError
            "field_border" -> fieldBorder
            else -> null
        }
}

val THEME_PRESETS: Map<String, ThemePalette> =
    mapOf(
        "graphite" to
            ThemePalette(
                "#121214",
                "#1B1B1F",
                "#7C3AED",
                "#6E6E78",
                "#ECECEF",
                "#93939B",
                "#A78BFA",
                "#5EC28F",
                "#D4A94A",
                "#E17272",
                "#9A8CF2",
                "#121214",
                "#6E6E75",
            ),
        "midnight" to
            ThemePalette(
                "#0F1221",
                "#1A1E2E",
                "#6366F1",
                "#8B5CF6",
                "#F3F4F6",
                "#9CA3AF",
                "#06B6D4",
                "#5EC28F",
                "#D4A94A",
                "#E27777",
                "#9A8CF2",
                "#0F1221",
                "#686F7E",
            ),
        "daylight" to
            ThemePalette(
                "#F8FAFC",
                "#FFFFFF",
                "#4F46E5",
                "#7C3AED",
                "#1E293B",
                "#58667B",
                "#067590",
                "#147739",
                "#955B06",
                "#B91C1C",
                "#4338CA",
                "#FFFFFF",
                "#7F8A9B",
            ),
        "ocean" to
            ThemePalette(
                "#0C1222",
                "#132038",
                "#0EA5E9",
                "#06B6D4",
                "#E2E8F0",
                "#94A3B8",
                "#2DD4BF",
                "#5EC28F",
                "#D4A94A",
                "#E27777",
                "#9A8CF2",
                "#0C1222",
                "#66758A",
            ),
        "sunset" to
            ThemePalette(
                "#1C1017",
                "#2D1B24",
                "#F97316",
                "#EF4444",
                "#FEF2F2",
                "#A8A29E",
                "#FBBF24",
                "#5EC28F",
                "#D4A94A",
                "#E37B7B",
                "#9A8CF2",
                "#1C1017",
                "#7B7172",
            ),
        "forest" to
            ThemePalette(
                "#0F1A14",
                "#1A2E22",
                "#22C55E",
                "#10B981",
                "#ECFDF5",
                "#86EFAC",
                "#A3E635",
                "#5EC28F",
                "#D4A94A",
                "#E78C8C",
                "#A69AF4",
                "#0F1A14",
                "#508965",
            ),
    )

private val DEFAULT_PALETTE = THEME_PRESETS.getValue("graphite")

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
        error = hexToColor(palette.error) ?: base.error,
        onError = hexToColor(palette.onError) ?: base.onError,
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

val LocalAstralFieldBorder = staticCompositionLocalOf { AstralColors.FieldBorder }

@Composable
internal fun astralOutlinedFieldColors() = OutlinedTextFieldDefaults.colors(unfocusedBorderColor = LocalAstralFieldBorder.current)

@Composable
fun AstralTheme(
    palette: ThemePalette? = null,
    content: @Composable () -> Unit,
) {
    val scheme = palette?.let { paletteToColorScheme(it) } ?: AstralDarkColors
    val fieldBorder = palette?.let { hexToColor(it.fieldBorder) } ?: AstralColors.FieldBorder
    CompositionLocalProvider(LocalAstralFieldBorder provides fieldBorder) {
        MaterialTheme(colorScheme = scheme, typography = astralTypography, content = content)
    }
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
