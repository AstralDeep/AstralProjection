package com.personalailabs.astraldeep.app

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.ui.theme.THEME_PRESETS
import com.personalailabs.astraldeep.app.ui.theme.ThemePalette
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

class HistoryPrimitive088InstrumentedTest {
    @get:Rule val rule = createComposeRule()

    @Test
    fun canonical_history_rows_render_plain_text_and_dispatch_exact_chat() {
        val emitted = mutableListOf<Pair<String, JsonObject>>()
        val component =
            Component.fromJson(
                Json.parseToJsonElement(
                    """{"type":"chat_history","title":"Recent chats","items":[
            {"chat_id":"first","title":"New Chat","preview":"Earlier result","time":"2m","icon":"📝"},
            {"chat_id":"second","title":"New Chat","preview":"\nAlpha = 2\tBeta = 5","time":"1h","icon":"🎲","saved":true},
            {"chat_id":{},"title":"Invalid row","preview":"Must be skipped"}
        ]}""",
                ).jsonObject,
            )
        rule.setContent {
            AstralTheme {
                Column { Renderer(Emit { action, payload -> emitted += action to payload }).registerAllRenderers().render(component) }
            }
        }
        rule.onNodeWithText("RECENT CHATS").assertIsDisplayed()
        rule.onNodeWithText("2").assertIsDisplayed()
        rule.onNodeWithText("2m").assertIsDisplayed()
        rule.onNodeWithText("1h").assertIsDisplayed()
        rule.onNodeWithText("Must be skipped").assertDoesNotExist()
        val layouts = mutableListOf<TextLayoutResult>()
        rule.onNodeWithText("Alpha = 2 Beta = 5", useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertEquals(12.sp, layouts.single().layoutInput.style.fontSize)
        rule.onNodeWithText("Alpha = 2 Beta = 5").assertIsDisplayed().performClick()
        rule.runOnIdle {
            assertEquals(listOf("load_chat" to Json.parseToJsonElement("""{"chat_id":"second"}""").jsonObject), emitted)
        }
    }

    @Test
    fun history_has_web_type_scale_count_alignment_and_accessible_rows_in_both_themes() {
        var palette by mutableStateOf<ThemePalette?>(null)
        val component =
            Component.fromJson(
                Json.parseToJsonElement(
                    """{"type":"chat_history","items":[
            {"chat_id":"one","title":"Alpha vs Beta","preview":"Two saved categories","time":"2m","icon":"🎲","saved":true},
            {"chat_id":"two","title":"Research notes","preview":"<a href='file:///tmp'>plain text</a>","time":"1h","icon":"📝"}
        ]}""",
                ).jsonObject,
            )
        rule.setContent {
            AstralTheme(palette) {
                Column(Modifier.width(360.dp).background(MaterialTheme.colorScheme.background).padding(16.dp).testTag("history-fixture")) {
                    Renderer(Emit { _, _ -> }).registerAllRenderers().render(component)
                }
            }
        }
        for ((name, selected) in listOf("midnight" to null, "daylight" to THEME_PRESETS.getValue("daylight"))) {
            rule.runOnIdle { palette = selected }
            val layouts = mutableListOf<TextLayoutResult>()
            rule.onNodeWithText("Alpha vs Beta", useUnmergedTree = true)
                .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            assertEquals(13.sp, layouts.single().layoutInput.style.fontSize)
            assertEquals(Role.Button, rule.onNodeWithText("Alpha vs Beta").fetchSemanticsNode().config[SemanticsProperties.Role])
            val heading = rule.onNodeWithText("RECENT CHATS").fetchSemanticsNode().boundsInRoot
            val count = rule.onNodeWithText("2").fetchSemanticsNode().boundsInRoot
            assertTrue(count.left > heading.right)
            rule.onNodeWithText("<a href='file:///tmp'>plain text</a>").assertIsDisplayed()
            val bitmap = rule.onNodeWithTag("history-fixture").captureToImage().asAndroidBitmap()
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            File(context.filesDir, "088-history-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }
}
