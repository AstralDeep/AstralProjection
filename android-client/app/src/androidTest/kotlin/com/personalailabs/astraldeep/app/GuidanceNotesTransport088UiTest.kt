package com.personalailabs.astraldeep.app

import androidx.activity.compose.setContent
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.RootScaffold
import com.personalailabs.astraldeep.app.ui.Screen
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.workspace.WorkspaceControllerFixture
import com.personalailabs.astraldeep.app.workspace.WorkspaceControllerFixture.Companion.await
import com.personalailabs.astraldeep.app.workspace.WorkspaceControllerFixture.Companion.main
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Actual client socket, reducer, shared form and current-only sender; only server replies are synthetic. */
class GuidanceNotesTransport088UiTest {
    @get:Rule val rule = createEmptyComposeRule()

    @Test fun shared_save_traverses_current_socket_and_stale_reply_cannot_replace_new_read() {
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("guidance_notes_088.json").bufferedReader().use { it.readText() }
        val fixtures = Json.parseToJsonElement(bytes).jsonObject

        fun frame(
            mode: String,
            generation: String,
        ) = JsonObject(fixtures.getValue(mode).jsonObject + ("request_generation" to JsonPrimitive(generation)))
        WorkspaceControllerFixture().use { base ->
            main { base.model.openSurface("guidance", buildJsonObject { put("mode", "new") }) }
            base.scenario.onActivity { activity ->
                activity.setContent {
                    AstralTheme {
                        val renderer = Renderer(Emit { action, payload -> base.model.sendEvent(action, payload) }).registerAllRenderers()
                        RootScaffold(base.model, renderer, onSignOut = {}, onWorkspaceAction = {})
                    }
                }
            }
            await { base.outboundFrames.any { it["action"]?.jsonPrimitive?.content == "chrome_open" } }
            val first = base.model.state.value.privateSurfaceRequest!!.requestGeneration
            base.send(frame("new", first))
            await { base.model.state.value.pendingSurface != null }
            rule.onNodeWithText("Note").performScrollTo().performTextReplacement("Synthetic private note")
            rule.onNodeWithText("Save note").performScrollTo().performClick()
            await { base.outboundFrames.any { it["action"]?.jsonPrimitive?.content == "chrome_note_save" } }
            val save = base.outboundFrames.single { it["action"]?.jsonPrimitive?.content == "chrome_note_save" }
            val second = save.getValue("request_generation").jsonPrimitive.content
            assertNotEquals(first, second)
            assertNotEquals(save.getValue("submission_id"), save.getValue("request_generation"))
            assertEquals("Synthetic private note", save.getValue("payload").jsonObject.getValue("fields").jsonObject.getValue("value").jsonPrimitive.content)
            assertTrue(base.model.state.value.pendingSurfaceParams.isEmpty())
            base.send(frame("list", first))
            base.send(frame("list", second))
            await { base.model.state.value.pendingSurface?.requestGeneration == second }
            assertNull(base.model.state.value.privateSurfaceRequest)
            main { base.model.goTo(Screen.Chat) }
            assertNull(base.model.state.value.pendingSurface)
            base.send(frame("list", second))
            main { assertEquals(Screen.Chat, base.model.state.value.screen) }
        }
    }
}
