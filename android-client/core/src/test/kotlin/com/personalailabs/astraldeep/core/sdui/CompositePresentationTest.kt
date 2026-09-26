// Verifies shared composite semantics, finite chart geometry, and malformed input handling.
// Native renderers consume these exact values for drawing and accessibility.

package com.personalailabs.astraldeep.core.sdui

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CompositePresentationTest {
    private fun raw(text: String) = Json.parseToJsonElement(text) as JsonObject

    private val empty = raw("{}")

    @Test fun actionsPreserveIdentityPayloadAndDisabledState() {
        val group = ActionGroupPresentation(raw("""{"label":"Review","align":" END ","buttons":[null,7,{"id":"approve","label":"Approve","action":"confirm","payload":{"nonce":"bound"},"disabled":true},{"type":"text","label":"Cancel","action":"cancel"}]}"""))
        assertEquals("Review", group.label)
        assertEquals("end", group.alignment)
        assertEquals(2, group.buttons.size)
        assertEquals("approve", group.buttons[0].id)
        assertEquals(raw("""{"nonce":"bound"}"""), group.buttons[0].attributes["payload"])
        assertEquals(JsonPrimitive(true), group.buttons[0].attributes["disabled"])
        assertEquals("button", group.buttons[1].type)
        assertEquals(JsonPrimitive("cancel"), group.buttons[1].attributes["action"])
        assertTrue(ActionGroupPresentation(empty).buttons.isEmpty())
        for (align in listOf("start", "center", "between", "INVALID")) {
            assertEquals(if (align == "INVALID") "start" else align, ActionGroupPresentation(raw("""{"align":"$align"}""")).alignment)
        }
    }

    @Test fun statsRetainZerosAndAllTrendStates() {
        val stats = StatGroupPresentation(raw("""{"title":"Counts","columns":99,"items":[false,{"label":"None","value":0,"delta":"0%","hint":"No change","trend":" FLAT ","variant":"invalid"},{"trend":"up","variant":"success"},{"trend":"down","variant":"warning"},{}]}"""))
        assertEquals("Counts", stats.title)
        assertEquals(6, stats.columns)
        assertEquals("None", stats.items[0].label)
        assertEquals("0", stats.items[0].value)
        assertEquals("0%", stats.items[0].delta)
        assertEquals("No change", stats.items[0].hint)
        assertEquals(listOf("–", "▲", "▼", ""), stats.items.map { it.trendSymbol })
        assertEquals(listOf("default", "success", "warning", "default"), stats.items.map { it.variant })
        assertEquals(4, StatGroupPresentation(empty).columns)
        assertEquals(1, StatGroupPresentation(raw("""{"columns":-10}""")).columns)
        assertEquals(4, StatGroupPresentation(raw("""{"columns":"Infinity"}""")).columns)
    }

    @Test fun gaugeUsesAuthoredThresholdOrderAndClampsInvalidValues() {
        val gauge = GaugePresentation(raw("""{"label":"Capacity","value":0.75,"display_value":"3 of 4","subtitle":"Ready","thresholds":[false,{"at":0.5,"variant":"warning"},{"at":0.9,"variant":"error"},{"at":0.7,"variant":"invalid"}]}"""))
        assertEquals(0.75, gauge.value)
        assertEquals("warning", gauge.variant)
        assertEquals("Capacity: 3 of 4", gauge.accessibilityLabel)
        assertEquals("Ready", gauge.subtitle)
        for ((value, expected) in listOf("-2" to "0%", "2" to "100%", "\"0.425\"" to "42%", "\"bad\"" to "0%", "\"NaN\"" to "0%", "\"Infinity\"" to "0%")) {
            assertEquals(expected, GaugePresentation(raw("""{"value":$value}""")).accessibilityLabel)
        }
        assertEquals("default", GaugePresentation(empty).variant)
        assertEquals(3.0, CompositeValue.number(JsonPrimitive("nan"), 3.0))
        assertEquals("", CompositeValue.text(JsonNull))
        assertEquals("", CompositeValue.text(null))
        assertEquals("{\"x\":1}", CompositeValue.text(raw("""{"x":1}""")))
        for (variant in listOf("default", "success", "warning", "error", "info")) {
            assertEquals(variant, CompositeValue.variant(JsonPrimitive(" ${variant.uppercase()} ")))
        }
    }

    @Test fun pipelineAnnouncesOnlyFirstActiveStep() {
        val pipeline = PipelinePresentation(raw("""{"title":"Pipeline","orientation":"VERTICAL","steps":[0,{"label":"Load","status":"done","detail":"12 rows"},{"status":"active"},{"status":"active"},{"status":"error"},{"status":"injected"}]}"""))
        assertEquals("Pipeline", pipeline.title)
        assertTrue(pipeline.vertical)
        assertEquals(listOf(false, true, false, false, false), pipeline.steps.map { it.isCurrent })
        assertEquals(listOf("success", "info", "info", "error", "default"), pipeline.steps.map { it.variant })
        assertEquals("Load", pipeline.steps[0].label)
        assertEquals("12 rows", pipeline.steps[0].detail)
        assertEquals("pending", pipeline.steps.last().status)
        assertFalse(PipelinePresentation(empty).vertical)
        assertTrue(PipelinePresentation(empty).steps.isEmpty())
    }

    @Test fun donutKeepsFiniteProportionsAndEverySeries() {
        val donut = DonutPresentation(raw("""{"title":"Shares","center_label":"Total","center_value":"100","labels":["A","B"],"data":[60,40,-1,"bad",0,0,0]}"""))
        assertEquals("Shares", donut.title)
        assertEquals("Total", donut.centerLabel)
        assertEquals("100", donut.centerValue)
        assertEquals(7, donut.segments.size)
        assertEquals(0.0, donut.segments[0].start)
        assertEquals(0.6, donut.segments[0].end, 0.00001)
        assertEquals(0.6, donut.segments[1].start, 0.00001)
        assertEquals(1.0, donut.segments[1].end)
        assertEquals(0.0, donut.segments[2].value)
        assertEquals("series 3", donut.segments[2].label)
        assertEquals(0, donut.segments[6].series)
        val overflow = DonutPresentation(raw("""{"data":[1e308,1e308]}"""))
        assertEquals(0.5, overflow.segments[0].end)
        assertEquals(1.0, overflow.segments[1].end)
        assertEquals(0.0, DonutPresentation(raw("""{"data":[0]}""")).segments[0].end)
        assertTrue(DonutPresentation(empty).segments.isEmpty())
    }

    @Test fun radarBoundsGeometryWithoutLosingSourceValues() {
        val radar = RadarPresentation(raw("""{"title":"Quality","axes":["A","B","C"],"max_value":10,"datasets":[false,{"label":"Run","data":[20,5,-2]},{"label":"Partial","data":["2"]}]}"""))
        assertEquals("Quality", radar.title)
        assertTrue(radar.canRender)
        assertEquals(listOf("A", "B", "C"), radar.axes)
        assertEquals(listOf(20.0, 5.0, 0.0), radar.datasets[0].values)
        assertEquals("Run", radar.datasets[0].label)
        assertEquals(0.5, radar.datasets[0].points[0].x, 0.00001)
        assertEquals(0.05, radar.datasets[0].points[0].y, 0.00001)
        assertEquals(RadarPresentation.Point(0.5, 0.5), radar.datasets[1].points[1])
        assertEquals(1, radar.datasets[1].series)
        for (maximum in listOf("null", "0", "-5", "\"bad\"", "\"Infinity\"")) {
            val model = RadarPresentation(raw("""{"axes":["A","B","C"],"max_value":$maximum,"datasets":[{"data":[2]}]}"""))
            assertEquals(0.05, model.datasets[0].points[0].y, 0.00001)
        }
        val zero = RadarPresentation(raw("""{"axes":["A","B","C"],"datasets":[{"data":[0,0,0]}]}"""))
        assertEquals(listOf(0.5, 0.5, 0.5), zero.datasets[0].points.map { it.y })
        assertFalse(RadarPresentation(empty).canRender)
        assertFalse(RadarPresentation(raw("""{"axes":["A","B"],"datasets":[{}]}""")).canRender)
        assertFalse(RadarPresentation(raw("""{"axes":["A","B","C"]}""")).canRender)
    }
}
