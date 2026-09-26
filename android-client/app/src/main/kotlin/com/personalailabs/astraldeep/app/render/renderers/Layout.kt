// Registers layout/content primitives (grid, hero, badge, metric, key-value, timeline, rating, progress,
// collapsible), matching the web renderer's presentation.

package com.personalailabs.astraldeep.app.render.renderers

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.toUpperCase
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.personalailabs.astraldeep.app.render.LocalCanvasCapture
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.inlineMarkdown
import com.personalailabs.astraldeep.app.ui.theme.AstralColors
import com.personalailabs.astraldeep.app.ui.theme.AstralWebStyle
import com.personalailabs.astraldeep.app.ui.theme.astralSoftShadow
import com.personalailabs.astraldeep.app.ui.welcomePlacementRole
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull

fun Renderer.registerLayoutRenderers(): Renderer =
    apply {
        register("grid") { c -> GridPrimitive(c) { render(it) } }
        register("hero") { c -> HeroPrimitive(c) }
        register("badge") { c -> BadgePrimitive(c) }
        register("metric") { c -> MetricPrimitive(c) }
        register("keyvalue") { c -> KeyValuePrimitive(c) }
        register("timeline") { c -> TimelinePrimitive(c) }
        register("rating") { c -> RatingPrimitive(c) }
        register("divider") { HorizontalDivider() }
        register("progress") { c -> ProgressPrimitive(c) }
        register("collapsible") { c -> CollapsiblePrimitive(c) { render(it) } }
    }

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun GridPrimitive(
    c: Component,
    renderChild: @Composable (Component) -> Unit,
) {
    if (welcomePlacementRole(c) == "examples") {
        FlowRow(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) { c.children.forEach { renderChild(it) } }
        return
    }
    val capture = LocalCanvasCapture.current
    val cols = (c.int("columns") ?: 2).coerceAtLeast(1)
    BoxWithConstraints {
        val fit = (maxWidth / 150.dp).toInt().coerceAtLeast(1)
        val effective = cols.coerceAtMost(fit)
        capture?.registry?.columns(capture.path, effective)
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            c.children.chunked(effective).forEach { rowItems ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    rowItems.forEach { Box(Modifier.weight(1f)) { renderChild(it) } }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HeroPrimitive(c: Component) {
    if (welcomePlacementRole(c) == "intro") {
        val titleSize = (LocalConfiguration.current.screenWidthDp * 0.032f).coerceIn(30f, 40f)
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            c.str("eyebrow")?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            c.str("title")?.let {
                Text(
                    it,
                    fontSize = titleSize.sp,
                    lineHeight = (titleSize * 1.2f).sp,
                    letterSpacing = (-titleSize * 0.045f).sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            c.str("subtitle")?.let { Text(it, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        return
    }
    val gradient = c.str("variant") == "gradient"
    val primary = MaterialTheme.colorScheme.primary
    Card(modifier = Modifier.fillMaxWidth()) {
        Column {
            if (gradient) {
                Box(Modifier.fillMaxWidth().height(3.dp).background(AstralColors.AccentBrush))
            }
            Column(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .then(
                            if (gradient) {
                                Modifier.background(
                                    Brush.linearGradient(
                                        listOf(
                                            primary.copy(alpha = 0.18f),
                                            MaterialTheme.colorScheme.secondary.copy(alpha = 0.08f),
                                        ),
                                        start = Offset.Zero,
                                        end = Offset.Infinite,
                                    ),
                                )
                            } else {
                                Modifier
                            },
                        )
                        .padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                c.str("eyebrow")?.let {
                    Text(
                        it.uppercase(),
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = primary,
                    )
                }
                c.str("title")?.let { Text(it, style = MaterialTheme.typography.headlineSmall) }
                c.str(
                    "subtitle",
                )?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                val badges = c.arr("badges")?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank) }.orEmpty()
                if (badges.isNotEmpty()) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        badges.forEach { badge ->
                            Text(
                                badge,
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                                modifier =
                                    Modifier
                                        .clip(RoundedCornerShape(50))
                                        .background(primary.copy(alpha = 0.18f))
                                        .padding(horizontal = 8.dp, vertical = 3.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun BadgePrimitive(c: Component) {
    val scheme = MaterialTheme.colorScheme
    val colors =
        when (c.str("variant")) {
            "success" -> AstralWebStyle.Success to Color(0xFF4ADE80)
            "warning" -> AstralWebStyle.Warning to Color(0xFFFACC15)
            "error" -> AstralWebStyle.Error to Color(0xFFF87171)
            "info" -> Color(0xFF3B82F6) to Color(0xFF60A5FA)
            "accent" -> scheme.primary to scheme.primary
            else -> scheme.onSurface to scheme.onSurface
        }
    val alpha = if (c.str("variant") in setOf("success", "warning", "error", "info", "accent")) 0.15f else 0.1f
    Surface(
        shape = RoundedCornerShape(50),
        color = colors.first.copy(alpha = alpha),
        contentColor = colors.second,
        border = BorderStroke(1.dp, colors.first.copy(alpha = if (alpha == 0.15f) 0.25f else 0.15f)),
    ) {
        Row(
            Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            c.str("icon")?.let { Text(it, fontSize = 12.sp) }
            Text(c.str("label") ?: c.str("text").orEmpty(), fontSize = 12.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
private fun MetricPrimitive(c: Component) {
    val title = c.str("title").orEmpty()
    val value = c.str("value").orEmpty()
    val accent =
        when (c.str("variant")) {
            "success" -> AstralWebStyle.Success
            "warning" -> AstralWebStyle.Warning
            "error" -> AstralWebStyle.Error
            else -> MaterialTheme.colorScheme.primary
        }
    val progress = (c.attributes["progress"] as? JsonPrimitive)?.doubleOrNull?.takeIf { it.isFinite() }
    val name = c.str("aria-label") ?: if (title.isNotBlank()) "$title: $value" else value
    Column(
        Modifier.fillMaxWidth()
            .astralSoftShadow(12f)
            .clip(AstralWebStyle.MetricShape)
            .background(Brush.linearGradient(listOf(accent.copy(alpha = 0.2f), accent.copy(alpha = 0.05f))))
            .border(1.dp, AstralWebStyle.MetricBorder, AstralWebStyle.MetricShape)
            .drawBehind { drawRect(accent.copy(alpha = 0.85f), size = Size(3.dp.toPx(), size.height)) }
            .semantics(mergeDescendants = true) { contentDescription = name }
            .padding(17.dp),
    ) {
        Text(
            inlineMarkdown(title).toUpperCase(LocaleList("en")),
            style = AstralWebStyle.MetricTitle,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(4.dp))
        Text(value, style = AstralWebStyle.MetricValue, color = MaterialTheme.colorScheme.onSurface)
        c.str("subtitle")?.takeIf { it.isNotEmpty() }?.let {
            Spacer(Modifier.height(4.dp))
            Text(inlineMarkdown(it), style = AstralWebStyle.MetricSubtitle, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (progress != null) {
            Spacer(Modifier.height(12.dp))
            val progressColor =
                when {
                    progress > 0.9 -> AstralWebStyle.Error
                    progress > 0.7 -> AstralWebStyle.Warning
                    else -> MaterialTheme.colorScheme.primary
                }
            Box(
                Modifier.fillMaxWidth().height(
                    6.dp,
                ).clip(
                    RoundedCornerShape(50),
                ).background(androidx.compose.ui.graphics.Color.White.copy(alpha = 0.1f)).testTag("metric-progress"),
            ) {
                Box(
                    Modifier.fillMaxWidth(
                        progress.coerceIn(0.0, 1.0).toFloat(),
                    ).height(6.dp).clip(RoundedCornerShape(50)).background(progressColor),
                )
            }
        }
    }
}

private fun pairLabel(o: JsonObject): String = (o["key"] ?: o["label"]).let { (it as? JsonPrimitive)?.contentOrNull } ?: ""

private fun pairValue(o: JsonObject): String = (o["value"] as? JsonPrimitive)?.contentOrNull ?: ""

@Composable
private fun KeyValuePrimitive(c: Component) {
    val items = c.arr("items") ?: c.arr("pairs")
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        items?.forEach { el ->
            (el as? JsonObject)?.let { o ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(pairLabel(o), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(pairValue(o), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

@Composable
private fun TimelinePrimitive(c: Component) {
    val items = c.arr("items")
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        items?.forEach { el ->
            (el as? JsonObject)?.let { o ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("•", color = MaterialTheme.colorScheme.primary)
                    Text(
                        ((o["title"] ?: o["label"] ?: o["text"]) as? JsonPrimitive)?.contentOrNull ?: "",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
    }
}

@Composable
private fun RatingPrimitive(c: Component) {
    val max = c.int("max") ?: 5
    val value = (c.dbl("value") ?: 0.0).toInt().coerceIn(0, max)
    Text(text = "★".repeat(value) + "☆".repeat(max - value), color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun ProgressPrimitive(c: Component) {
    val raw = c.dbl("value") ?: c.dbl("progress") ?: 0.0
    val fraction = (if (raw > 1.0) raw / 100.0 else raw).toFloat().coerceIn(0f, 1f)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        c.str("label")?.let { Text(it, style = MaterialTheme.typography.labelMedium) }
        LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CollapsiblePrimitive(
    c: Component,
    renderChild: @Composable (Component) -> Unit,
) {
    val capture = LocalCanvasCapture.current
    var expanded by remember(c.attributes) { mutableStateOf(capture?.registry?.node(capture.path)?.expanded ?: false) }
    if (welcomePlacementRole(c) == "more") {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            TextButton(onClick = {
                expanded = !expanded
                capture?.registry?.expand(capture.path, expanded)
            }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text((if (expanded) "⌄ " else "› ") + (c.str("title") ?: "Details"), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (expanded) {
                FlowRow(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    c.children.forEach { renderChild(it) }
                }
            }
        }
        return
    }
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = (if (expanded) "▼ " else "▶ ") + (c.str("title") ?: "Details"),
                style = MaterialTheme.typography.titleSmall,
                modifier =
                    Modifier.fillMaxWidth().clickable {
                        expanded = !expanded
                        capture?.registry?.expand(capture.path, expanded)
                    },
            )
            if (expanded) c.children.forEach { renderChild(it) }
        }
    }
}
