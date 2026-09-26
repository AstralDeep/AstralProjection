// Exercises native composite drawing, action delivery, and captured pixels on Android.
// Synthetic fixtures cover compact layouts and owner-scoped exports without a network session.

package com.personalailabs.astraldeep.app

import android.graphics.BitmapFactory
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.render.CanvasCapture
import com.personalailabs.astraldeep.app.render.CanvasCaptureRegistry
import com.personalailabs.astraldeep.app.render.CompositePixels
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.WorkspaceContext
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.ui.theme.THEME_PRESETS
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.Base64

class CompositeRenderersTest {
    @get:Rule val rule = createComposeRule()
    private val context = WorkspaceContext(ConversationResumeStore.AccountIdentity("synthetic", "owner"), 1, "chat", 1u, setOf("export_canvas"))
    private val theme = listOf("bg", "surface", "surface2", "primary", "secondary", "accent", "text", "muted", "border").associateWith { "#112233" }

    private fun component(raw: String) = Component.fromJson(Json.parseToJsonElement(raw).jsonObject)

    private val fixtures =
        listOf(
            """{"type":"stat_group","title":"Counts","columns":3,"items":[{"label":"Ready","value":23,"delta":"3%","trend":"up","variant":"success"},{"label":"Waiting","value":0,"hint":"Awaiting review","trend":"down","variant":"warning"},{"label":"Stable","value":4,"trend":"flat"}]}""",
            """{"type":"gauge","label":"Capacity","value":0.75,"subtitle":"Ready","thresholds":[{"at":0.5,"variant":"warning"}]}""",
            """{"type":"pipeline_stepper","title":"Pipeline","steps":[{"label":"Load","status":"done","detail":"12 rows"},{"label":"Review","status":"active"},{"label":"Retry","status":"error"},{"label":"Finish"}]}""",
            """{"type":"donut_chart","title":"Shares","center_value":"100","center_label":"Total","labels":["A","B"],"data":[60,40]}""",
            """{"type":"radar_chart","title":"Quality","axes":["A","B","C"],"datasets":[{"label":"Run","data":[5,2,3]}]}""",
        ).map(::component)

    private suspend fun freeze(registry: CanvasCaptureRegistry): CanvasCapture =
        withTimeout(10000) {
            var value: CanvasCapture? = null
            while (value == null) {
                value = withContext(Dispatchers.Main) { runCatching { registry.freeze(context) }.getOrNull() }
                if (value == null) delay(50)
            }
            value
        }

    private fun png(capture: CanvasCapture): String =
        (capture.presentation["images"] as JsonArray).single().jsonObject.getValue("data_url").jsonPrimitive.content

    @Test fun badgeVariantsUseTheWebSemanticForegroundInBothThemes() {
        var variant by mutableStateOf("success")
        var light by mutableStateOf(false)
        rule.setContent {
            AstralTheme(THEME_PRESETS.getValue(if (light) "daylight" else "midnight")) {
                val renderer = remember { Renderer(Emit { _, _ -> }).registerAllRenderers() }
                renderer.render(component("""{"type":"badge","label":"Available","variant":"$variant","icon":"✓"}"""))
            }
        }
        for (daylight in listOf(false, true)) {
            for ((name, expected) in mapOf(
                "success" to 0xFF4ADE80,
                "warning" to 0xFFFACC15,
                "error" to 0xFFF87171,
                "info" to 0xFF60A5FA,
                "accent" to if (daylight) 0xFF4F46E5 else 0xFF6366F1,
                "unknown" to if (daylight) 0xFF1E293B else 0xFFF3F4F6,
            )) {
                rule.runOnIdle {
                    light = daylight
                    variant = name
                }
                val layouts = mutableListOf<TextLayoutResult>()
                rule.onNodeWithText("Available").assertIsDisplayed().performSemanticsAction(SemanticsActions.GetTextLayoutResult) {
                    it(layouts)
                }
                assertEquals(Color(expected), layouts.single().layoutInput.style.color)
                rule.onNodeWithText("✓").assertIsDisplayed()
            }
        }
    }

    @Test fun actionGroupPreservesEventsAndDisabledButtons() {
        val events = mutableListOf<Pair<String, JsonObject>>()
        rule.setContent {
            AstralTheme {
                val renderer = remember { Renderer(Emit { action, payload -> events += action to payload }).registerAllRenderers() }
                Box(Modifier.width(230.dp)) { renderer.render(component("""{"type":"action_group","label":"Actions","align":"end","buttons":[{"label":"Run","action":"confirm","payload":{"nonce":"bound"}},{"label":"Unavailable","action":"unsafe","disabled":true}]}""")) }
            }
        }
        rule.onNodeWithText("Actions").assertIsDisplayed()
        rule.onNodeWithText("Unavailable").assertIsNotEnabled().performClick()
        assertTrue(events.isEmpty())
        rule.onNodeWithText("Run").performClick()
        assertEquals(listOf("confirm" to Json.parseToJsonElement("""{"nonce":"bound"}""").jsonObject), events)
    }

    @Test fun everyCompositeProducesRealPixelsAtCompactAndLargeTextSizes() =
        runBlocking {
            var current by mutableStateOf(fixtures.first())
            var width by mutableStateOf(300)
            var scale by mutableStateOf(1f)
            val capture = CanvasCaptureRegistry()
            rule.setContent {
                val density = LocalDensity.current
                CompositionLocalProvider(LocalDensity provides Density(density.density, scale)) {
                    AstralTheme {
                        val renderer = remember { Renderer(Emit { _, _ -> }).registerAllRenderers().also { it.capture = capture } }
                        capture.bind(context, listOf(current), width, 800, theme)
                        Box(Modifier.width(width.dp)) { renderer.render(current, "/components/0") }
                    }
                }
            }
            for (fixture in fixtures) {
                for (fontScale in listOf(1f, 1.6f)) {
                    rule.runOnIdle {
                        current = fixture
                        scale = fontScale
                        width = if (fontScale == 1f) 300 else 210
                    }
                    rule.waitForIdle()
                    val export = freeze(capture)
                    val bytes = Base64.getDecoder().decode(png(export).substringAfter(','))
                    File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "composite-${fixture.type}-$fontScale.png").writeBytes(bytes)
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    assertTrue(bitmap.width > 10 && bitmap.height > 10)
                    val pixels = IntArray(bitmap.width * bitmap.height)
                    bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                    assertTrue("${fixture.type} at $fontScale has ${pixels.toSet().size} colors", pixels.toSet().size > 8)
                    assertTrue(
                        "${fixture.type} must use the visible foreground palette",
                        pixels.any { color ->
                            android.graphics.Color.alpha(color) > 240 && android.graphics.Color.red(color) > 225 &&
                                android.graphics.Color.green(color) > 225 && android.graphics.Color.blue(color) > 225
                        },
                    )
                    assertEquals("image", (export.presentation["components"] as JsonArray).single().jsonObject.getValue("type").jsonPrimitive.content)
                    assertFalse(export.presentation.toString().contains("datasets"))
                    bitmap.recycle()
                }
            }
        }

    @Test fun cachedPixelsSurviveScrollingButNotOwnerReset() =
        runBlocking {
            val capture = CanvasCaptureRegistry()
            var visible by mutableStateOf(true)
            var preset by mutableStateOf("midnight")
            val c = fixtures[3]
            rule.setContent {
                AstralTheme(THEME_PRESETS.getValue(preset)) {
                    val renderer = remember { Renderer(Emit { _, _ -> }).registerAllRenderers().also { it.capture = capture } }
                    capture.bind(context, listOf(c), 300, 800, theme)
                    if (visible) renderer.render(c, "/components/0")
                }
            }
            val dark = freeze(capture)
            rule.runOnIdle { preset = "daylight" }
            rule.waitForIdle()
            val light = freeze(capture)
            assertNotEquals(png(dark), png(light))
            delay(200)
            rule.runOnIdle { visible = false }
            rule.waitForIdle()
            assertEquals(png(light), png(freeze(capture)))
            withContext(Dispatchers.Main) { capture.clear() }
            assertFalse(capture.isCurrent(light, context))
            assertTrue(runCatching { withContext(Dispatchers.Main) { capture.freeze(context) } }.isFailure)
        }

    @Test fun unrecordedDetachedAndRevokedLayersRefuseExport() =
        runBlocking {
            lateinit var source: CompositePixels
            rule.setContent { source = remember { CompositePixels(null) } }
            rule.waitForIdle()
            assertEquals(0L, source.retainedBytes())
            assertTrue(runCatching { source.png() }.isFailure)
            source.ready = true
            assertTrue(runCatching { source.png() }.isFailure)
            source.close()
            assertTrue(source.closed)
            assertTrue(runCatching { source.png() }.isFailure)
        }
}
