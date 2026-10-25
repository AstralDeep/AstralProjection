// Exercises registered code rendering through SurfaceScreen, including literal text precedence and
// native selection copying to the platform clipboard without emitting a server action.

package com.personalailabs.astraldeep.app

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.RootMatchers.isPlatformPopup
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.SurfaceScreen
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class CodeSurfaceUiTest {
    @get:Rule val rule = createComposeRule()

    private val emitted = mutableListOf<Pair<String, JsonObject>>()
    private val clipboard: ClipboardManager
        get() = InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(ClipboardManager::class.java)

    private fun render(
        content: String? = null,
        legacy: String? = null,
    ) {
        val component =
            Component(
                "code",
                "source-code",
                buildJsonObject {
                    put("type", "code")
                    if (content != null) put("content", content)
                    if (legacy != null) put("code", legacy)
                },
                emptyList(),
            )
        rule.setContent {
            AstralTheme {
                val renderer = Renderer(Emit { action, payload -> emitted += action to payload }).registerAllRenderers()
                SurfaceScreen(Inbound.ChromeSurface("terminal", "Terminal", listOf(component)), "terminal", renderer, {})
            }
        }
    }

    private fun assertLiteral(content: String) {
        val node = rule.onNodeWithText(content, useUnmergedTree = true).assertIsDisplayed().fetchSemanticsNode()
        val rendered = node.config[SemanticsProperties.Text].single()
        assertEquals(content, rendered.text)
        assertTrue(rendered.getLinkAnnotations(0, rendered.length).isEmpty())
        rule.runOnIdle { assertTrue(emitted.isEmpty()) }
    }

    @Test
    fun multiline_content_is_literal_and_takes_precedence_over_legacy_code() {
        val content = "first = 1\n**literal** <b>tag</b>\n[reference](https://example.org)"
        render(content = content, legacy = "obsolete fallback")
        assertLiteral(content)
        rule.onNodeWithText("obsolete fallback").assertDoesNotExist()
    }

    @Test
    fun legacy_code_is_rendered_when_content_is_absent() {
        val legacy = "legacy = 2\n`literal` <script>text</script>"
        render(legacy = legacy)
        assertLiteral(legacy)
    }

    @Test
    fun empty_content_remains_authoritative_over_legacy_code() {
        render(content = "", legacy = "obsolete fallback")
        rule.onNodeWithText("obsolete fallback").assertDoesNotExist()
        rule.runOnIdle { assertTrue(emitted.isEmpty()) }
    }

    @Test
    fun selecting_all_multiline_code_copies_exact_text_without_a_server_action() {
        val content = "first = 1\nsecond = **literal**\nthird = <tag>"
        render(content = content)
        assertLiteral(content)
        rule.runOnIdle { clipboard.setPrimaryClip(ClipData.newPlainText("sentinel", "unchanged")) }
        rule.onNodeWithText(content, useUnmergedTree = true).performTouchInput { longClick() }
        onView(withText(android.R.string.selectAll)).inRoot(isPlatformPopup()).perform(click())
        onView(withText(android.R.string.copy)).inRoot(isPlatformPopup()).perform(click())
        rule.runOnIdle {
            assertEquals(content, clipboard.primaryClip?.getItemAt(0)?.text?.toString())
            assertTrue(emitted.isEmpty())
        }
    }
}
