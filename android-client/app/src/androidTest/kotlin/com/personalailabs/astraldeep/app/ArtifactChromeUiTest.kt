package com.personalailabs.astraldeep.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.dp
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore.AccountIdentity
import com.personalailabs.astraldeep.app.render.CanvasChrome
import com.personalailabs.astraldeep.app.render.CanvasHost
import com.personalailabs.astraldeep.app.render.Download
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.ComponentActionContext
import com.personalailabs.astraldeep.app.ui.ComponentActionHandler
import com.personalailabs.astraldeep.app.ui.UiState
import com.personalailabs.astraldeep.app.ui.componentActionContext
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/**
 * Feature 055 US4/US5 (T036/T040/T045) — the per-component chrome end to end:
 * ordinary grounded badges stay hidden while estimated/generated warnings
 * render from the stamped field, the inline Refine
 * action sends `component_refine`, and an export entry hits the download path.
 */
class ArtifactChromeUiTest {
    @get:Rule val rule = createComposeRule()

    private val emitted = mutableListOf<Pair<String, JsonObject>>()
    private val downloads = mutableListOf<String>()

    private fun host(vararg components: Component) {
        rule.setContent {
            val r =
                Renderer(
                    Emit { a, p -> emitted.add(a to p) },
                    Download { url, _ -> downloads.add(url) },
                ).registerAllRenderers().also { renderer ->
                    renderer.componentActions =
                        object : ComponentActionHandler {
                            override fun context(component: Component): ComponentActionContext? =
                                componentActionContext(
                                    UiState(activeChatId = "chat-1", canvas = components.toList()), AccountIdentity("fixture", "owner"), 1, component,
                                )

                            override fun perform(
                                context: ComponentActionContext,
                                kind: String,
                                payload: JsonObject,
                            ) {
                                emitted.add(kind to payload)
                            }
                        }
                }
            CanvasHost(
                components = components.toList(),
                renderer = r,
                chrome = CanvasChrome(chatId = "chat-1", mutationsLocked = false),
            )
        }
    }

    private fun table(provenance: String = "grounded") =
        Component.fromJson(
            attrs("""{"type":"table","component_id":"wc_abc","title":"Sales","headers":["a"],"rows":[["1"]],"provenance":"$provenance","component_chrome":{"version":1,"actions":[{"kind":"refine","label":"refine","icon":"✎","title":"Refine this component","context":"live_canvas"},{"kind":"history","label":"history","icon":"⟲","title":"Version history","context":"live_canvas"},{"kind":"csv","label":"csv","icon":"⬇","title":"Download CSV","context":"owned_chat"}]}}"""),
        )

    @Test
    fun grounded_provenance_keeps_actions_without_a_badge() {
        val component = table()
        host(component)
        assertEquals(JsonPrimitive("grounded"), component.attributes["provenance"])
        rule.onNodeWithText("tool data").assertDoesNotExist()
        rule.onNodeWithText("refine").assertIsDisplayed()
        rule.onNodeWithText("history").assertIsDisplayed()
        rule.onNodeWithText("csv").assertIsDisplayed()
    }

    @Test
    fun estimated_provenance_keeps_its_warning_and_actions() {
        host(table("estimated"))
        rule.onNodeWithText("estimated").assertIsDisplayed()
        rule.onNodeWithText("tool data").assertDoesNotExist()
        rule.onNodeWithText("refine").assertIsDisplayed()
        rule.onNodeWithText("history").assertIsDisplayed()
        rule.onNodeWithText("csv").assertIsDisplayed()
    }

    @Test
    fun generated_provenance_keeps_its_warning_and_actions() {
        host(table("generated"))
        rule.onNodeWithText("AI-generated").assertIsDisplayed()
        rule.onNodeWithText("tool data").assertDoesNotExist()
        rule.onNodeWithText("refine").assertIsDisplayed()
        rule.onNodeWithText("history").assertIsDisplayed()
        rule.onNodeWithText("csv").assertIsDisplayed()
    }

    @Test
    fun unstamped_component_shows_no_badge() {
        host(Component.fromJson(attrs("""{"type":"card","component_id":"wc_c","title":"Plain"}""")))
        rule.onNodeWithText("tool data").assertDoesNotExist()
        rule.onNodeWithText("AI-generated").assertDoesNotExist()
    }

    @Test
    fun refine_dialog_sends_component_refine_with_the_instruction() {
        host(table())
        rule.onNodeWithText("refine").performClick()
        rule.onNode(hasSetTextAction()).performTextInput("make it a bar chart")
        rule.onNodeWithText("Refine").performClick()
        assertEquals(1, emitted.size)
        val (action, payload) = emitted.single()
        assertEquals("refine", action)
        assertEquals("make it a bar chart", (payload["instruction"] as JsonPrimitive).content)
    }

    @Test
    fun export_entry_routes_through_the_download_path() {
        host(table())
        rule.onNodeWithText("csv").performClick()
        assertEquals(listOf("csv"), emitted.map { it.first })
    }

    @Test fun history_has_honest_empty_state_and_missing_metadata_never_invents_actions() {
        host(table())
        rule.onNodeWithText("history").performClick()
        rule.onNodeWithText("No earlier versions yet — refine the component to create one.").assertIsDisplayed()
        assertEquals(0, emitted.size)
    }

    @Test fun older_server_without_metadata_shows_no_inferred_exports_or_refine() {
        host(Component.fromJson(attrs("""{"type":"table","id":"old","headers":[],"rows":[]}""")))
        rule.onNodeWithText("refine").assertDoesNotExist()
        rule.onNodeWithText("history").assertDoesNotExist()
        rule.onNodeWithText("csv").assertDoesNotExist()
    }

    @Test fun server_version_dialog_restores_only_listed_metadata_and_closes_on_replacement() {
        val original =
            table().let { value ->
                value.copy(
                    attributes =
                        JsonObject(
                            value.attributes + (
                                "versions" to
                                    kotlinx.serialization.json.Json.parseToJsonElement(
                                        """[{"version_no":2,"reason":"refine","created_at":"2026-09-12T12:34:00Z","title":"Earlier"}]""",
                                    )
                            ),
                        ),
                )
            }
        val current = mutableStateOf(original)
        rule.setContent {
            val component = current.value
            com.personalailabs.astraldeep.app.render.renderers.ArtifactFooter(
                component,
                object : ComponentActionHandler {
                    override fun context(component: Component): ComponentActionContext? =
                        componentActionContext(
                            UiState(activeChatId = "chat-1", canvas = listOf(current.value)),
                            AccountIdentity("fixture", "owner"),
                            1,
                            component,
                        )

                    override fun perform(
                        context: ComponentActionContext,
                        kind: String,
                        payload: JsonObject,
                    ) {
                        emitted.add(kind to payload)
                    }
                },
            )
        }
        rule.onNodeWithText("history").performClick()
        rule.onNodeWithText("v2 · Earlier · 2026-09-12 12:34").assertIsDisplayed().performClick()
        assertEquals("history", emitted.single().first)
        assertEquals(JsonPrimitive(2), emitted.single().second["version_no"])
        rule.onNodeWithText("history").performClick()
        rule.runOnIdle { current.value = original.copy(attributes = JsonObject(original.attributes - "component_chrome")) }
        rule.onNodeWithText("Version history").assertDoesNotExist()
        rule.onNodeWithText("refine").assertDoesNotExist()
        rule.onNodeWithText("history").assertDoesNotExist()
        rule.onNodeWithText("csv").assertDoesNotExist()
    }

    @Test fun inline_actions_wrap_in_server_order_with_accessible_targets() {
        val component = com.personalailabs.astraldeep.app.workspace.ComponentControllerFixture.component()
        rule.setContent {
            Box(Modifier.width(132.dp).testTag("footer")) {
                com.personalailabs.astraldeep.app.render.renderers.ArtifactFooter(
                    component,
                    object : ComponentActionHandler {
                        override fun context(component: Component) =
                            componentActionContext(
                                UiState(activeChatId = "chat-1", canvas = listOf(component)),
                                AccountIdentity("fixture", "owner"),
                                1,
                                component,
                            )

                        override fun perform(
                            context: ComponentActionContext,
                            kind: String,
                            payload: JsonObject,
                        ) {
                            emitted.add(kind to payload)
                        }
                    },
                )
            }
        }
        val parent = rule.onNodeWithTag("footer").getUnclippedBoundsInRoot()
        val bounds =
            listOf("refine", "history", "csv", "share").map { label ->
                rule.onNodeWithText(label).assertIsDisplayed().getUnclippedBoundsInRoot().also {
                    assertTrue(it.right - it.left >= 48.dp && it.bottom - it.top >= 48.dp)
                    assertTrue(it.left >= parent.left && it.right <= parent.right)
                }
            }
        assertTrue(bounds.last().top > bounds.first().top)
        bounds.zipWithNext().forEach { (left, right) ->
            assertTrue(right.top > left.top || right.left > left.left)
        }
        rule.onNodeWithText("share").performClick()
        assertEquals("share", emitted.single().first)
    }
}
