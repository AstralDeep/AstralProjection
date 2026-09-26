// Normalizes composite primitives into the bounded values shared by native drawing and accessibility.
// These presentations mirror the server vocabulary without executing payload text.

package com.personalailabs.astraldeep.core.sdui

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.round
import kotlin.math.sin

object CompositeValue {
    fun text(value: JsonElement?): String =
        when (value) {
            null, JsonNull -> ""
            is JsonPrimitive -> value.content
            else -> value.toString()
        }

    fun number(
        value: JsonElement?,
        fallback: Double = 0.0,
    ): Double = (value as? JsonPrimitive)?.doubleOrNull?.takeIf { it.isFinite() } ?: fallback

    fun fraction(value: JsonElement?): Double = number(value).coerceIn(0.0, 1.0)

    fun objects(value: JsonElement?): List<JsonObject> = (value as? JsonArray).orEmpty().filterIsInstance<JsonObject>()

    fun variant(
        value: JsonElement?,
        fallback: String = "default",
    ): String = text(value).trim().lowercase().takeIf { it in setOf("default", "success", "warning", "error", "info") } ?: fallback
}

class ActionGroupPresentation(raw: JsonObject) {
    val label = CompositeValue.text(raw["label"])
    val alignment =
        CompositeValue.text(raw["align"]).trim().lowercase()
            .takeIf { it in setOf("start", "center", "end", "between") } ?: "start"
    val buttons =
        CompositeValue.objects(raw["buttons"]).map {
            Component.fromJson(JsonObject(it + ("type" to JsonPrimitive("button"))))
        }
}

class StatGroupPresentation(raw: JsonObject) {
    data class Item(val label: String, val value: String, val delta: String, val hint: String, val trend: String, val variant: String) {
        val trendSymbol: String get() =
            when (trend) {
                "up" -> "▲"
                "down" -> "▼"
                "flat" -> "–"
                else -> ""
            }
    }

    val title = CompositeValue.text(raw["title"])
    val columns = CompositeValue.number(raw["columns"], 4.0).coerceIn(1.0, 6.0).toInt()
    val items =
        CompositeValue.objects(raw["items"]).map {
            Item(
                CompositeValue.text(it["label"]),
                CompositeValue.text(it["value"]),
                CompositeValue.text(it["delta"]),
                CompositeValue.text(it["hint"]),
                CompositeValue.text(it["trend"]).trim().lowercase(),
                CompositeValue.variant(it["variant"]),
            )
        }
}

class GaugePresentation(raw: JsonObject) {
    val label = CompositeValue.text(raw["label"])
    val value = CompositeValue.fraction(raw["value"])
    val displayValue = CompositeValue.text(raw["display_value"]).ifEmpty { "${round(value * 100).toInt()}%" }
    val subtitle = CompositeValue.text(raw["subtitle"])
    val variant =
        CompositeValue.objects(raw["thresholds"]).fold("default") { previous, threshold ->
            if (value >= CompositeValue.fraction(threshold["at"])) CompositeValue.variant(threshold["variant"], previous) else previous
        }
    val accessibilityLabel: String get() = if (label.isEmpty()) displayValue else "$label: $displayValue"
}

class PipelinePresentation(raw: JsonObject) {
    data class Step(val label: String, val detail: String, val status: String, val isCurrent: Boolean) {
        val variant: String get() =
            when (status) {
                "done" -> "success"
                "active" -> "info"
                "error" -> "error"
                else -> "default"
            }
    }

    val title = CompositeValue.text(raw["title"])
    val vertical = CompositeValue.text(raw["orientation"]).lowercase() == "vertical"
    val steps: List<Step>

    init {
        var markedCurrent = false
        steps =
            CompositeValue.objects(raw["steps"]).map {
                val status =
                    CompositeValue.text(it["status"]).trim().lowercase()
                        .takeIf { candidate -> candidate in setOf("done", "active", "pending", "error") } ?: "pending"
                val current = status == "active" && !markedCurrent
                if (current) markedCurrent = true
                Step(CompositeValue.text(it["label"]), CompositeValue.text(it["detail"]), status, current)
            }
    }
}

class DonutPresentation(raw: JsonObject) {
    data class Segment(val label: String, val value: Double, val start: Double, val end: Double, val series: Int)

    val title = CompositeValue.text(raw["title"])
    val centerLabel = CompositeValue.text(raw["center_label"])
    val centerValue = CompositeValue.text(raw["center_value"])
    val segments: List<Segment>

    init {
        val labels = (raw["labels"] as? JsonArray).orEmpty()
        val values = (raw["data"] as? JsonArray).orEmpty().map { CompositeValue.number(it).coerceAtLeast(0.0) }
        val maximum = values.maxOrNull() ?: 0.0
        val scaled = values.map { if (maximum > 0) it / maximum else 0.0 }
        val total = scaled.sum().coerceAtLeast(1.0)
        var offset = 0.0
        segments =
            values.indices.map { index ->
                val start = offset
                offset = (offset + scaled[index] / total).coerceAtMost(1.0)
                Segment(
                    if (index < labels.size) CompositeValue.text(labels[index]) else "series ${index + 1}",
                    values[index], start, offset, index % 6,
                )
            }
    }
}

class RadarPresentation(raw: JsonObject) {
    data class Point(val x: Double, val y: Double)

    data class Dataset(val label: String, val values: List<Double>, val points: List<Point>, val series: Int)

    val title = CompositeValue.text(raw["title"])
    val axes = (raw["axes"] as? JsonArray).orEmpty().map(CompositeValue::text)
    val datasets: List<Dataset>
    val canRender: Boolean get() = axes.size >= 3 && datasets.isNotEmpty()

    init {
        val records = CompositeValue.objects(raw["datasets"])
        val values =
            records.map { row ->
                (row["data"] as? JsonArray).orEmpty().map { CompositeValue.number(it).coerceAtLeast(0.0) }
            }
        val observed = values.flatten().maxOrNull() ?: 0.0
        val declared = CompositeValue.number(raw["max_value"], observed)
        val scale =
            if (declared > 0) {
                declared
            } else if (observed > 0) {
                observed
            } else {
                1.0
            }
        datasets =
            records.indices.map { index ->
                val row = values[index]
                val points =
                    axes.indices.map { axis ->
                        val magnitude = ((row.getOrNull(axis) ?: 0.0) / scale).coerceAtMost(1.0)
                        val angle = 2 * PI * axis / axes.size - PI / 2
                        Point(0.5 + 0.45 * magnitude * cos(angle), 0.5 + 0.45 * magnitude * sin(angle))
                    }
                Dataset(CompositeValue.text(records[index]["label"]), row, points, index % 6)
            }
    }
}
