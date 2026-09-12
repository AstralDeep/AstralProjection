package com.personalailabs.astraldeep.app

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.NewChatButton
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.ui.theme.THEME_PRESETS
import com.personalailabs.astraldeep.app.ui.theme.ThemePalette
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import kotlin.math.abs

class CanvasStyle088InstrumentedTest {
    @get:Rule val rule = createComposeRule()
    private val renderer = Renderer(Emit { _, _ -> }).registerAllRenderers()

    private fun component(json: String) = Component.fromJson(Json.parseToJsonElement(json).jsonObject)

    private fun styleOf(text: String): TextLayoutResult {
        val results = mutableListOf<TextLayoutResult>()
        rule.onNodeWithText(text, useUnmergedTree = true).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
        return results.single()
    }

    private fun save(name: String) {
        val bitmap = rule.onNodeWithTag("fixture").captureToImage().asAndroidBitmap()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.filesDir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test
    fun canonical_metric_title_value_subtitle_and_progress_are_visible_and_named() {
        val card =
            component(
                """{"type":"card","title":"Dice Roll Results (6d6)","content":[
            {"type":"metric","title":"Total","value":30,"subtitle":"Six dice","progress":0.6},
            {"type":"metric","title":"Number of dice","value":6,"variant":"success"}]}""",
            )
        rule.setContent {
            AstralTheme {
                Surface(color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.padding(12.dp).testTag("fixture")) { renderer.render(card) }
                }
            }
        }
        rule.onNodeWithText("TOTAL", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("NUMBER OF DICE", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("Six dice", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithContentDescription("Total: 30").assertIsDisplayed()
        rule.onNodeWithTag("metric-progress", useUnmergedTree = true).assertIsDisplayed()
        assertEquals(FontWeight.SemiBold, styleOf("Dice Roll Results (6d6)").layoutInput.style.fontWeight)
        assertEquals(16.sp, styleOf("Dice Roll Results (6d6)").layoutInput.style.fontSize)
        assertEquals(28.sp, styleOf("30").layoutInput.style.fontSize)
        assertEquals(FontWeight.Bold, styleOf("30").layoutInput.style.fontWeight)
        assertEquals(0.6.sp, styleOf("TOTAL").layoutInput.style.letterSpacing)
        val title = rule.onNodeWithText("Dice Roll Results (6d6)").fetchSemanticsNode()
        assertTrue(title.config.contains(SemanticsProperties.Heading))
        save("088-android-web-metric-style.png")
    }

    @Test
    fun card_surface_uses_live_theme_compositing_in_midnight_and_daylight() {
        var palette by mutableStateOf<ThemePalette?>(null)
        val card = component("""{"type":"card","title":"Alpha vs Beta","content":[{"type":"text","content":"Two categories"}]}""")
        var background = Color.Unspecified
        var surface = Color.Unspecified
        rule.setContent {
            AstralTheme(palette) {
                background = MaterialTheme.colorScheme.background
                surface = MaterialTheme.colorScheme.surface
                Column(Modifier.background(background).padding(12.dp)) {
                    Box(Modifier.fillMaxWidth().testTag("fixture")) { renderer.render(card) }
                }
            }
        }
        for (preset in listOf(null, THEME_PRESETS.getValue("daylight"))) {
            rule.runOnIdle { palette = preset }
            val image = rule.onNodeWithTag("fixture").captureToImage().toPixelMap()
            val actual = image[image.width / 2, image.height - 6]
            val expected = surface.copy(alpha = 0.45f).compositeOver(background)
            save(if (preset == null) "088-android-web-card-midnight.png" else "088-android-web-card-daylight.png")
            for ((got, wanted) in listOf(actual.red to expected.red, actual.green to expected.green, actual.blue to expected.blue)) {
                assertTrue("Card must use the web's translucent theme surface: actual=$actual expected=$expected", abs(got - wanted) < 0.012f)
            }
        }
    }

    @Test
    fun new_chat_keeps_full_accessible_hit_target_and_respects_compact_and_locked_states() {
        var showLabel by mutableStateOf(false)
        var enabled by mutableStateOf(true)
        var calls = 0
        rule.setContent {
            AstralTheme {
                Surface(color = MaterialTheme.colorScheme.surface) {
                    Box(Modifier.testTag("fixture")) { NewChatButton(enabled, { calls++ }, showLabel) }
                }
            }
        }
        val button = rule.onNodeWithContentDescription("New chat")
        button.assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp)
        rule.onNodeWithText("New chat").assertDoesNotExist()
        button.performClick()
        assertEquals(1, calls)
        save("088-android-web-new-chat-compact.png")
        rule.runOnIdle { showLabel = true }
        rule.onNodeWithText("New chat").assertIsDisplayed()
        rule.runOnIdle { enabled = false }
        button.assertIsNotEnabled()
        button.performClick()
        assertEquals(1, calls)
    }
}
