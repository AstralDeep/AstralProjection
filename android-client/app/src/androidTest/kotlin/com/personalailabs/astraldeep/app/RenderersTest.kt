// Instrumented test for the primitive renderer registry: registered types render, an unknown type degrades to
// a labeled placeholder, and a select submits its option key rather than its label.

package com.personalailabs.astraldeep.app

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextInput
import com.personalailabs.astraldeep.app.render.CanvasHost
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.LocalViewportInteraction
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class RenderersTest {
    @get:Rule val rule = createComposeRule()

    private fun render(components: List<Component>) {
        rule.setContent {
            val r = Renderer(Emit { _, _ -> }).registerAllRenderers()
            CanvasHost(components = components, renderer = r)
        }
    }

    @Test fun focusedAndDirtyInputDefersViewportChangesUntilSubmitted() {
        val interactions = mutableSetOf<Any>()
        val component = Component("input", "input", attrs("""{"label":"Draft value","value":"","action":"input_done"}"""), emptyList())
        rule.setContent {
            val focus = LocalFocusManager.current
            CompositionLocalProvider(
                LocalViewportInteraction provides { key, active ->
                    if (active) interactions.add(key) else interactions.remove(key)
                },
            ) {
                Column {
                    Renderer(Emit { _, _ -> }).registerAllRenderers().render(component)
                    TextButton(onClick = { focus.clearFocus() }) { Text("Leave field") }
                }
            }
        }
        rule.runOnIdle { assertTrue(interactions.isEmpty()) }
        rule.onNodeWithText("Draft value").performClick().performTextInput("Unsent value")
        rule.runOnIdle { assertFalse(interactions.isEmpty()) }
        rule.onNodeWithText("Leave field").performClick()
        rule.runOnIdle { assertFalse(interactions.isEmpty()) }
        rule.onNodeWithText("Draft value").assertTextContains("Unsent value").performClick().performImeAction()
        rule.onNodeWithText("Leave field").performClick()
        rule.runOnIdle { assertTrue(interactions.isEmpty()) }
    }

    @Test
    fun card_with_child_text_renders() {
        val card =
            Component("card", "card1", attrs("""{"type":"card","title":"My Card"}"""), listOf(textComponent("inside card")))
        render(listOf(card))
        rule.onNodeWithText("My Card").assertIsDisplayed()
        rule.onNodeWithText("inside card").assertIsDisplayed()
    }

    @Test
    fun unknown_type_shows_labeled_placeholder() {
        val unknown = Component("frobnicator", "u1", attrs("""{"type":"frobnicator"}"""), emptyList())
        render(listOf(unknown))
        rule.onNodeWithText("[frobnicator]").assertIsDisplayed()
    }

    @Test
    fun a_select_field_opens_a_dropdown_and_submits_the_picked_key() {
        val emitted = mutableListOf<Pair<String, JsonObject>>()
        val picker =
            Component(
                "param_picker",
                "pp1",
                attrs(
                    """{"type":"param_picker","title":"LLM","submit_action":"chrome_llm_save","fields":[
                       {"name":"provider","label":"Provider","kind":"select","default":"openai",
                        "options":["openai","anthropic","xai"]}]}""",
                ),
                emptyList(),
            )
        rule.setContent {
            val r = Renderer(Emit { action, payload -> emitted += action to payload }).registerAllRenderers()
            CanvasHost(components = listOf(picker), renderer = r)
        }
        rule.onNodeWithText("openai").assertIsDisplayed()
        rule.onNodeWithText("openai").performClick()
        rule.onNodeWithText("xai").performClick()
        rule.onNodeWithText("Save").performClick()

        assertEquals(1, emitted.size)
        assertEquals("chrome_llm_save", emitted[0].first)
        val fields = emitted[0].second["fields"] as JsonObject
        assertEquals("xai", (fields["provider"] as JsonPrimitive).content)
    }
}
