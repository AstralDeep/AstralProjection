// Exercises native settings controls with synthetic server descriptors and current operation outcomes.
package com.personalailabs.astraldeep.app

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.FormSubmissionState
import com.personalailabs.astraldeep.app.render.LocalFormSubmissionState
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.ThemeSink
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class SettingsControlsTest {
    @get:Rule val rule = createComposeRule()

    private fun form() =
        Component(
            "param_picker",
            "provider",
            attrs(
                """{
        "fields":[{"name":"provider","label":"Provider","kind":"select","default":"custom",
        "options":[{"value":"openai","label":"OpenAI"},{"value":"custom","label":"Custom endpoint"}]},
        {"name":"base_url","label":"Endpoint","default":"https://example.test/v1",
        "visible_when":{"field":"provider","equals":"custom"}},
        {"name":"tools","label":"Tools","kind":"checklist","default":["saved"],
        "options":[{"value":"read","label":"Read files"}]}],
        "actions":[{"action":"chrome_llm_models","label":"Load models"}]}
        """,
            ),
            emptyList(),
        )

    @Test
    fun labeled_options_keep_saved_keys_and_control_visibility() {
        val sent = mutableListOf<Pair<String, JsonObject>>()
        rule.setContent { Renderer(Emit { a, p -> sent += a to p }).registerAllRenderers().render(form()) }
        rule.onNodeWithText("Custom endpoint").assertIsDisplayed()
        rule.onNodeWithText("Endpoint").assertIsDisplayed()
        rule.onNodeWithText("saved").assertIsSelected()
        rule.onNodeWithText("Custom endpoint").performClick()
        rule.onNodeWithText("OpenAI").performClick()
        rule.onNodeWithText("Endpoint").assertDoesNotExist()
        rule.onNodeWithText("Load models").performClick()
        rule.runOnIdle {
            val payload = sent.single().second["fields"]!!.jsonObject
            assertEquals("openai", payload["provider"]!!.jsonPrimitive.content)
            assertEquals("saved", payload["tools"]!!.jsonArray.single().jsonPrimitive.content)
        }
    }

    @Test
    fun pending_action_blocks_duplicates_and_failed_result_keeps_edits() {
        var status by mutableStateOf(FormSubmissionState())
        val sent = mutableListOf<Pair<String, JsonObject>>()
        val component = form()
        rule.setContent {
            CompositionLocalProvider(LocalFormSubmissionState provides status) {
                Renderer(
                    Emit { a, p ->
                        sent += a to p
                        status = status.copy(pending = true)
                    },
                )
                    .registerAllRenderers().render(component)
            }
        }
        rule.onNodeWithText("Endpoint").performTextReplacement("https://edited.test/v1")
        rule.onNodeWithText("Load models").performClick()
        rule.onNodeWithText("Load models…").assertIsDisplayed()
        rule.onNodeWithText("Load models").assertDoesNotExist()
        rule.runOnIdle { status = status.copy(pending = false, outcomeRevision = 1, error = "Service unavailable") }
        rule.onNodeWithText("Endpoint").assertTextContains("https://edited.test/v1")
        rule.onNodeWithText("Load models").performClick()
        rule.runOnIdle { assertEquals(2, sent.size) }
    }

    @Test
    fun custom_color_cancel_invalid_value_and_save_preserve_server_authority() {
        val sent = mutableListOf<Pair<String, JsonObject>>()
        val applied = mutableListOf<JsonObject>()
        val component = Component("color_picker", "accent", attrs("""{"label":"Accent","color_key":"accent","value":"#06B6D4"}"""), emptyList())
        rule.setContent {
            Renderer(Emit { a, p -> sent += a to p }, theme = ThemeSink(applied::add))
                .registerAllRenderers().render(component)
        }
        rule.onNodeWithText("Accent").performClick()
        rule.onNodeWithText("Hex color").performTextReplacement("invalid")
        rule.onNodeWithText("Save").assertIsNotEnabled()
        rule.onNodeWithText("Cancel").performClick()
        rule.runOnIdle { assertTrue(sent.isEmpty() && applied.isEmpty()) }
        rule.onNodeWithText("Accent").performClick()
        rule.onNodeWithText("Hex color").performTextReplacement("123abc")
        rule.onNodeWithText("Save").performClick()
        rule.onNodeWithText("#06B6D4").assertIsDisplayed()
        rule.runOnIdle {
            assertEquals("#123ABC", sent.single().second["theme"]!!.jsonObject["color_value"]!!.jsonPrimitive.content)
            assertTrue(applied.isEmpty())
        }
    }

    @Test
    fun missing_action_and_missing_label_are_explicitly_unavailable() {
        val sent = mutableListOf<Pair<String, JsonObject>>()
        rule.setContent {
            val renderer = Renderer(Emit { a, p -> sent += a to p }).registerAllRenderers()
            Column {
                renderer.render(Component("param_picker", "missing-action", attrs("""{"fields":[],"actions":[{"label":"Save"}]}"""), emptyList()))
                renderer.render(Component("button", "missing-label", attrs("""{"action":"chrome_llm_save","label":""}"""), emptyList()))
            }
        }
        rule.onNodeWithText("This action is unavailable. Reload this screen to retry.").assertIsDisplayed()
        rule.onNodeWithText("Action unavailable").assertIsNotEnabled()
        rule.runOnIdle { assertTrue(sent.isEmpty()) }
    }
}
