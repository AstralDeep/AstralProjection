package com.personalailabs.astraldeep.app.render.renderers

import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class OfflineChartTest {
    @Test
    fun height_matches_shared_web_narrow_override_and_bounded_authored_layout() {
        fun chart(height: Int) = Component.fromJson(Json.parseToJsonElement("""{"type":"plotly_chart","layout":{"height":$height}}""").jsonObject)
        assertEquals(260, offlineChartHeight(chart(600), 499))
        assertEquals(600, offlineChartHeight(chart(600), 500))
        assertEquals(320, offlineChartHeight(chart(0), 568, 600))
        assertEquals(240, offlineChartHeight(Component.fromJson(Json.parseToJsonElement("""{"type":"bar_chart"}""").jsonObject), 568, 600))
        assertEquals(260, offlineChartHeight(chart(600), 320, 1280))
        assertEquals(320, offlineChartHeight(chart(0), 1200))
        assertEquals(160, offlineChartHeight(chart(-1), 1200))
        assertEquals(1200, offlineChartHeight(chart(2000), 1200))
    }

    @Test
    fun all_chart_data_is_encoded_without_html_or_executable_interpolation() {
        val source = Json.parseToJsonElement("""{"type":"plotly_chart","data":[{"type":"bar","x":["</script><img src=https://attacker.example>"],"y":[-4,null,9]},{"type":"bar","y":[2,5,8]}],"layout":{"barmode":"stack"}}""").jsonObject
        val encoded = offlineChartPayload(Component.fromJson(source), 1280)
        assertFalse('<' in encoded)
        val payload = Json.parseToJsonElement(String(Base64.getDecoder().decode(encoded))).jsonObject
        assertEquals(source, payload.getValue("component"))
        assertEquals("1280", payload.getValue("viewport_width").jsonPrimitive.content)
    }

    @Test
    fun simple_dataset_shape_is_preserved_for_exact_shared_web_renderer() {
        val source = Json.parseToJsonElement("""{"type":"line_chart","datasets":[{"data":[-1,3,4]}],"labels":["a","b","c"]}""").jsonObject
        val payload = Json.parseToJsonElement(String(Base64.getDecoder().decode(offlineChartPayload(Component.fromJson(source), 400)))).jsonObject
        assertEquals(source, payload.getValue("component"))
    }
}
