package com.personalailabs.astraldeep.app

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.SurfaceScreen
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.Wire
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Exact shared builder fixture, shipping Compose renderer, synthetic note values only. */
class GuidanceNotes088UiTest {
    @get:Rule val rule = createComposeRule()
    private val events = mutableListOf<Pair<String, JsonObject>>()

    private fun render(mode: String) {
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("guidance_notes_088.json").bufferedReader().use { it.readText() }
        val frame = Json.parseToJsonElement(bytes).jsonObject.getValue(mode)
        val surface = Wire.decode(frame.toString()) as Inbound.ChromeSurface
        rule.setContent {
            AstralTheme {
                val renderer = Renderer(Emit { action, payload -> events.add(action to payload) }).registerAllRenderers()
                SurfaceScreen(surface, "guidance", renderer, {})
            }
        }
    }

    @Test fun list_note_text_is_literal_and_toggle_keeps_exact_revision() {
        render("list")
        val value = "**Literal** [notes](https://example.invalid/note) <b>text</b>"
        val node = rule.onNodeWithText(value, useUnmergedTree = true).performScrollTo().fetchSemanticsNode()
        val rendered = node.config[SemanticsProperties.Text].single()
        assertEquals(value, rendered.text)
        assertTrue(rendered.getLinkAnnotations(0, rendered.length).isEmpty())
        rule.onNodeWithText("Disable").performScrollTo().performClick()
        val (action, payload) = events.single()
        assertEquals("chrome_note_toggle", action)
        assertEquals(setOf("note_id", "expected_revision", "enabled"), payload.keys)
        assertEquals("7", payload.getValue("expected_revision").jsonPrimitive.content)
        assertEquals("false", payload.getValue("enabled").jsonPrimitive.content)
    }

    @Test fun new_note_hides_date_and_preserves_supplied_defaults_in_save() {
        render("new")
        rule.onNodeWithText("Expiry date (UTC)").assertDoesNotExist()
        rule.onNodeWithText("Note").performScrollTo().performTextReplacement("**Private** <b>literal</b>")
        rule.onNodeWithText("Save note").performScrollTo().performClick()
        val (action, payload) = events.single()
        assertEquals("chrome_note_save", action)
        assertEquals("0", payload.getValue("expected_revision").jsonPrimitive.content)
        val fields = payload.getValue("fields").jsonObject
        assertEquals("Context", fields.getValue("category").jsonPrimitive.content)
        assertEquals("true", fields.getValue("enabled").jsonPrimitive.content)
        assertEquals("No expiry", fields.getValue("expiry").jsonPrimitive.content)
        assertEquals("**Private** <b>literal</b>", fields.getValue("value").jsonPrimitive.content)
    }

    @Test fun edit_preserves_exact_revision_and_shows_date_only_when_selected() {
        render("edit")
        rule.onNodeWithText("Expiry date (UTC)").assertDoesNotExist()
        rule.onNodeWithText("Keep current expiry").performScrollTo().performClick()
        rule.onNodeWithText("Set a date").performClick()
        rule.onNodeWithText("Expiry date (UTC)").performScrollTo().performTextReplacement("2028-12-31T23:59:00Z")
        rule.onNodeWithText("Save note").performScrollTo().performClick()
        val (action, payload) = events.single()
        assertEquals("chrome_note_save", action)
        assertEquals("7", payload.getValue("expected_revision").jsonPrimitive.content)
        assertEquals("11111111-1111-4111-8111-111111111111", payload.getValue("note_id").jsonPrimitive.content)
        val fields = payload.getValue("fields").jsonObject
        assertEquals("Preference", fields.getValue("category").jsonPrimitive.content)
        assertEquals("Set a date", fields.getValue("expiry").jsonPrimitive.content)
        assertEquals("2028-12-31T23:59:00Z", fields.getValue("expiry_date").jsonPrimitive.content)
    }

    @Test fun forget_requires_explicit_button_and_sends_only_exact_identity() {
        render("forget")
        rule.onNodeWithText("Keep note").assertIsDisplayed()
        assertTrue(events.isEmpty())
        rule.onNodeWithText("Forget note").performScrollTo().performClick()
        val (action, payload) = events.single()
        assertEquals("chrome_note_forget", action)
        assertEquals(setOf("note_id", "expected_revision"), payload.keys)
        assertEquals("7", payload.getValue("expected_revision").jsonPrimitive.content)
    }
}
