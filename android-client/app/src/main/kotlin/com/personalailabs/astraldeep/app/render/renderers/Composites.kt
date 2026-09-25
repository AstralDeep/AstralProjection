// Draws the shared composite vocabulary with native Compose geometry and server palette roles.
// Normalized presentations supply both visible values and accessibility descriptions.

package com.personalailabs.astraldeep.app.render.renderers

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.personalailabs.astraldeep.app.render.CompositeCapture
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.ui.theme.AstralWebStyle
import com.personalailabs.astraldeep.app.ui.theme.astralCardSurface
import com.personalailabs.astraldeep.core.sdui.ActionGroupPresentation
import com.personalailabs.astraldeep.core.sdui.Component
import com.personalailabs.astraldeep.core.sdui.DonutPresentation
import com.personalailabs.astraldeep.core.sdui.GaugePresentation
import com.personalailabs.astraldeep.core.sdui.PipelinePresentation
import com.personalailabs.astraldeep.core.sdui.RadarPresentation
import com.personalailabs.astraldeep.core.sdui.StatGroupPresentation

fun Renderer.registerCompositeRenderers(): Renderer =
    apply {
        register("action_group") { c -> ActionGroup(c) { render(it) } }
        register("stat_group") { c -> CompositeCapture(c) { StatGroup(StatGroupPresentation(c.attributes)) } }
        register("gauge") { c -> CompositeCapture(c) { Gauge(GaugePresentation(c.attributes)) } }
        register("pipeline_stepper") { c -> CompositeCapture(c) { Pipeline(PipelinePresentation(c.attributes)) } }
        register("donut_chart") { c -> CompositeCapture(c) { Donut(DonutPresentation(c.attributes)) } }
        register("radar_chart") { c -> CompositeCapture(c) { Radar(RadarPresentation(c.attributes)) } }
    }

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ActionGroup(
    c: Component,
    render: @Composable (Component) -> Unit,
) {
    val group = ActionGroupPresentation(c.attributes)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CompositeTitle(group.label)
        FlowRow(
            Modifier.fillMaxWidth(),
            horizontalArrangement =
                when (group.alignment) {
                    "center" -> Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)
                    "end" -> Arrangement.spacedBy(8.dp, Alignment.End)
                    "between" -> Arrangement.SpaceBetween
                    else -> Arrangement.spacedBy(8.dp)
                },
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) { group.buttons.forEach { render(it) } }
    }
}

@Composable
private fun StatGroup(group: StatGroupPresentation) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CompositeTitle(group.title)
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val columns = minOf(group.columns, ((maxWidth.value + 12) / 162).toInt().coerceAtLeast(1))
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                group.items.chunked(columns).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        row.forEach { item ->
                            Column(
                                Modifier.weight(1f).astralCardSurface().padding(12.dp),
                                verticalArrangement = Arrangement.spacedBy(4.dp),
                            ) {
                                Text(item.label, style = AstralWebStyle.MetricTitle, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(item.value, style = AstralWebStyle.MetricValue, color = MaterialTheme.colorScheme.onSurface)
                                if (item.delta.isNotEmpty() || item.trendSymbol.isNotEmpty()) {
                                    Text(
                                        listOf(item.trendSymbol, item.delta).filter(String::isNotEmpty).joinToString(" "),
                                        style = AstralWebStyle.MetricSubtitle,
                                        color = variantColor(item.variant),
                                    )
                                }
                                if (item.hint.isNotEmpty()) {
                                    Text(
                                        item.hint,
                                        style = AstralWebStyle.MetricSubtitle,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                        repeat(columns - row.size) { Box(Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Gauge(gauge: GaugePresentation) {
    val color = variantColor(gauge.variant)
    val track = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(140.dp, 82.dp).clearAndSetSemantics { contentDescription = gauge.accessibilityLabel }) {
            Canvas(Modifier.size(140.dp, 82.dp)) {
                val stroke = Stroke(10.dp.toPx(), cap = StrokeCap.Round)
                val origin = Offset(6.dp.toPx(), 6.dp.toPx())
                val diameter = size.width - 12.dp.toPx()
                drawArc(track, 180f, 180f, false, origin, Size(diameter, diameter), style = stroke)
                if (gauge.value > 0) {
                    drawArc(
                        color,
                        180f,
                        (180 * gauge.value).toFloat(),
                        false,
                        origin,
                        Size(diameter, diameter),
                        style = stroke,
                    )
                }
            }
            Text(
                gauge.displayValue,
                Modifier.align(Alignment.BottomCenter),
                style = AstralWebStyle.MetricValue,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
        if (gauge.label.isNotEmpty()) Text(gauge.label, style = AstralWebStyle.MetricTitle, color = MaterialTheme.colorScheme.onSurface)
        if (gauge.subtitle.isNotEmpty()) {
            Text(
                gauge.subtitle,
                style = AstralWebStyle.MetricSubtitle,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Pipeline(pipeline: PipelinePresentation) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CompositeTitle(pipeline.title)
        if (pipeline.vertical) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { pipeline.steps.forEach { PipelineStep(it) } }
        } else {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                pipeline.steps.forEach { PipelineStep(it) }
            }
        }
    }
}

@Composable
private fun PipelineStep(step: PipelinePresentation.Step) {
    val color = if (step.status == "pending") MaterialTheme.colorScheme.onSurface.copy(alpha = 0.25f) else variantColor(step.variant)
    Row(
        Modifier.semantics(
            mergeDescendants = true,
        ) { stateDescription = if (step.isCurrent) "Current step, ${step.status}" else step.status },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Canvas(Modifier.padding(top = 4.dp).size(14.dp)) {
            if (step.isCurrent) drawCircle(color.copy(alpha = 0.25f), 7.dp.toPx())
            drawCircle(color, 4.dp.toPx())
        }
        Column(Modifier.widthIn(max = 240.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(step.label, style = AstralWebStyle.MetricSubtitle, color = MaterialTheme.colorScheme.onSurface)
            if (step.detail.isNotEmpty()) {
                Text(
                    step.detail,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Donut(donut: DonutPresentation) {
    if (donut.segments.isEmpty()) return
    val colors = seriesColors()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CompositeTitle(donut.title)
        Box(
            Modifier.size(160.dp).clearAndSetSemantics {
                contentDescription = if (donut.title.isEmpty()) "Donut chart" else "Donut chart: ${donut.title}"
                stateDescription = listOf(donut.centerValue, donut.centerLabel).filter(String::isNotEmpty).joinToString(", ")
            },
            contentAlignment = Alignment.Center,
        ) {
            Canvas(Modifier.size(160.dp)) {
                donut.segments.forEach { segment ->
                    if (segment.end > segment.start) {
                        drawArc(
                            colors[segment.series],
                            (segment.start * 360 - 90).toFloat(),
                            ((segment.end - segment.start) * 360).toFloat(),
                            false,
                            Offset(16.dp.toPx(), 16.dp.toPx()),
                            Size(size.width - 32.dp.toPx(), size.height - 32.dp.toPx()),
                            style = Stroke(22.4.dp.toPx()),
                        )
                    }
                }
            }
            Column(Modifier.padding(30.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    donut.centerValue,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(donut.centerLabel, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            donut.segments.forEach { segment -> Legend(segment.label, colors[segment.series], segment.value.toString()) }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Radar(radar: RadarPresentation) {
    if (!radar.canRender) return
    val colors = seriesColors()
    val grid = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.15f)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CompositeTitle(radar.title)
        Canvas(
            Modifier.size(192.dp).clearAndSetSemantics {
                contentDescription = if (radar.title.isEmpty()) "Radar chart" else "Radar chart: ${radar.title}"
            },
        ) {
            for (diameter in listOf(
                0.24f,
                0.48f,
                0.72f,
                0.9f,
            )) drawCircle(grid, size.minDimension * diameter / 2, style = Stroke(1.dp.toPx()))
            radar.datasets.forEach { dataset ->
                val polygon =
                    Path().apply {
                        dataset.points.forEachIndexed { index, point ->
                            if (index == 0) {
                                moveTo((point.x * size.width).toFloat(), (point.y * size.height).toFloat())
                            } else {
                                lineTo((point.x * size.width).toFloat(), (point.y * size.height).toFloat())
                            }
                        }
                        close()
                    }
                drawPath(polygon, colors[dataset.series].copy(alpha = 0.28f))
                drawPath(polygon, colors[dataset.series], style = Stroke(2.88.dp.toPx()))
            }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            radar.datasets.forEach { dataset ->
                Legend(
                    dataset.label,
                    colors[dataset.series],
                    radar.axes.mapIndexed { index, axis ->
                        "$axis: ${dataset.values.getOrNull(index)?.toString() ?: "No value"}"
                    }.joinToString(", "),
                )
            }
        }
    }
}

@Composable
private fun CompositeTitle(title: String) {
    if (title.isNotEmpty()) {
        Text(
            title,
            Modifier.semantics {
                heading()
            },
            style = AstralWebStyle.ChartTitle,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun Legend(
    label: String,
    color: Color,
    value: String,
) {
    Row(
        Modifier.semantics(mergeDescendants = true) { stateDescription = value },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(Modifier.size(10.dp).background(color, CircleShape))
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun variantColor(variant: String): Color =
    when (variant) {
        "success" -> AstralWebStyle.Success
        "warning" -> AstralWebStyle.Warning
        "error" -> AstralWebStyle.Error
        "info" -> MaterialTheme.colorScheme.tertiary
        else -> MaterialTheme.colorScheme.primary
    }

@Composable
private fun seriesColors(): List<Color> {
    val base = listOf(MaterialTheme.colorScheme.primary, MaterialTheme.colorScheme.secondary, MaterialTheme.colorScheme.tertiary)
    return base + base.map { Color(it.red * 0.55f + 0.45f, it.green * 0.55f + 0.45f, it.blue * 0.55f + 0.45f) }
}
