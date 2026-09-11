package com.personalailabs.astraldeep.app

import android.graphics.Bitmap
import android.view.View
import android.webkit.WebView
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.espresso.Espresso
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.render.CanvasHost
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.app.ui.AdaptiveShellContent
import com.personalailabs.astraldeep.app.ui.AppViewModel
import com.personalailabs.astraldeep.app.ui.ChatTurn
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.voice.VoiceUiState
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

class Workspace088InstrumentedTest {
    @get:Rule val rule = createComposeRule()

    private val fixture =
        Json.parseToJsonElement(
            InstrumentationRegistry.getInstrumentation().context.assets.open("welcome.json").bufferedReader().use { it.readText() },
        ).jsonObject
    private val welcome = Component.listFromJson(fixture.getValue("components").jsonArray)

    @Composable
    private fun FixtureTheme(content: @Composable () -> Unit) {
        AstralTheme { Surface(color = MaterialTheme.colorScheme.background, content = content) }
    }

    private fun capture(name: String) {
        // Semantics may be ready before the display compositor has presented them.
        val painted = java.util.concurrent.CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            android.view.Choreographer.getInstance().postFrameCallback {
                android.view.Choreographer.getInstance().postFrameCallback { painted.countDown() }
            }
        }
        assertTrue(painted.await(5, java.util.concurrent.TimeUnit.SECONDS))
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.filesDir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun inspectChart(script: String): String? {
        var result: String? = null
        val completion = java.util.concurrent.CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            fun findChart(view: View): WebView? {
                if (view is WebView) return view
                if (view is android.view.ViewGroup) {
                    for (index in 0 until view.childCount) findChart(view.getChildAt(index))?.let { return it }
                }
                return null
            }
            val activity =
                androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).firstOrNull()
            val chart = activity?.window?.decorView?.let(::findChart)
            if (chart != null) {
                assertTrue(chart.settings.blockNetworkLoads)
                assertFalse(chart.settings.allowFileAccess)
                assertFalse(chart.settings.allowContentAccess)
                assertFalse(chart.settings.domStorageEnabled)
                assertTrue(chart.width > 0 && chart.height > 0)
                chart.evaluateJavascript(script) {
                    result = it
                    chart.postVisualStateCallback(
                        0,
                        object : WebView.VisualStateCallback() {
                            override fun onComplete(requestId: Long) {
                                chart.postOnAnimation { chart.postOnAnimation { completion.countDown() } }
                            }
                        },
                    )
                }
            } else {
                completion.countDown()
            }
        }
        completion.await(5, java.util.concurrent.TimeUnit.SECONDS)
        return result
    }

    @Test
    fun exact_offline_plotly_preserves_multiple_bar_traces_and_interactions() {
        val chart =
            Component.fromJson(
                Json.parseToJsonElement(
                    """{"type":"plotly_chart","component_id":"chart_088","title":"Synthetic comparison",
            "data":[{"type":"bar","name":"First","x":["A","B","C"],"y":[-4,6,8]},
            {"type":"bar","name":"Second","x":["A","B","C"],"y":[3,4,7]}],"layout":{"barmode":"group"}}""",
                ).jsonObject,
            )
        rule.setContent { FixtureTheme { CanvasHost(listOf(chart), Renderer(Emit { _, _ -> }).registerAllRenderers()) } }
        rule.waitUntil(15000) { inspectChart("document.documentElement.dataset.chartState") == "\"ready\"" }
        assertEquals("\"bar,bar\"", inspectChart("document.getElementById('chart').data.map(function(trace){return trace.type}).join(',')"))
        assertEquals("\"-4,6,8\"", inspectChart("document.getElementById('chart').data[0].y.join(',')"))
        assertEquals("false", inspectChart("!!document.querySelector('.modebar')"))
        assertEquals("true", inspectChart("!!document.querySelector('.legendtoggle')"))
        inspectChart("Plotly.relayout(document.getElementById('chart'), {'xaxis.range':[0,1]})")
        rule.waitUntil(5000) { inspectChart("document.getElementById('chart').layout.xaxis.range.join(',')") == "\"0,1\"" }
        inspectChart("Plotly.relayout(document.getElementById('chart'), {'xaxis.autorange':true})")
        inspectChart("document.documentElement.dataset.chartState")
        capture("088-android-chart.png")
    }

    @Test
    fun server_welcome_keeps_one_composer_and_exact_actions_then_preserves_draft_across_layouts() {
        val model = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))
        val work = mutableStateOf(false)
        val width = mutableStateOf(400)
        val result = Component.fromJson(fixture.getValue("result").jsonObject)
        val events = mutableListOf<Pair<String, JsonObject>>()
        val renderer = Renderer(Emit { action, payload -> events.add(action to payload) }).registerAllRenderers()
        rule.setContent {
            val state by model.state.collectAsState()
            FixtureTheme {
                AdaptiveShellContent(
                    state.copy(
                        canvas = if (work.value) listOf(result) else welcome.filterNot { it.type == "card" },
                        activeChatId = if (work.value) "chat" else null,
                        turns = if (work.value) listOf(ChatTurn("user", "Existing message")) else emptyList(),
                    ),
                    VoiceUiState(),
                    renderer,
                    model,
                    width.value,
                )
            }
        }
        rule.onNodeWithText("How can I help?").assertIsDisplayed()
        capture("088-android-start.png")
        rule.onAllNodesWithTag("chat-input").assertCountEquals(1)
        rule.onNodeWithTag("chat-input").performTextInput("keep this\nmultiline draft")
        Espresso.closeSoftKeyboard()
        rule.runOnIdle {
            assertEquals("keep this\nmultiline draft", model.state.value.composerDraft)
            work.value = true
        }
        rule.onNodeWithTag("workspace-stacked").assertIsDisplayed()
        capture("088-android-work-stacked.png")
        rule.onNodeWithTag("chat-input").assertTextEquals("keep this\nmultiline draft")
        rule.runOnIdle { width.value = 1280 }
        rule.onNodeWithTag("workspace-split").assertIsDisplayed()
        capture("088-android-work-split.png")
        rule.onNodeWithText("Collapse").performClick()
        rule.onNodeWithTag("workspace-collapsed").assertIsDisplayed()
        rule.onNodeWithTag("chat-input").assertTextEquals("keep this\nmultiline draft")
        rule.onNodeWithText("Move conversation to the right sidebar").performClick()
        rule.onNodeWithTag("workspace-split").assertIsDisplayed()
        rule.onAllNodesWithTag("chat-input").assertCountEquals(1)
    }

    @Test
    fun wide_tables_scroll_inside_the_canvas_and_keep_literal_values() {
        val table =
            Component.fromJson(
                Json.parseToJsonElement(
                    """{"type":"table","component_id":"table_088","headers":["Date","Observation","Amount","Reference"],
            "rows":[["2026-09-11","A complete synthetic observation","123456.78","REFERENCE-088-2026"]]}""",
                ).jsonObject,
            )
        rule.setContent {
            FixtureTheme { CanvasHost(listOf(table), Renderer(Emit { _, _ -> }).registerAllRenderers()) }
        }
        rule.onNodeWithText("2026-09-11").assertIsDisplayed()
        rule.onNodeWithTag("table-scroll").assertIsDisplayed()
        capture("088-android-narrow-table.png")
    }

    @Test
    fun native_examples_emit_exact_server_actions_and_permission_content_remains_available() {
        val events = mutableListOf<Pair<String, JsonObject>>()
        val renderer = Renderer(Emit { action, payload -> events.add(action to payload) }).registerAllRenderers()
        val model = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))
        rule.setContent {
            FixtureTheme {
                AdaptiveShellContent(model.state.value.copy(canvas = welcome), VoiceUiState(), renderer, model, 400)
            }
        }
        rule.onNodeWithText("Enable recommended agents").performScrollTo().performClick()
        rule.runOnIdle { assertEquals("enable_recommended_agents", events.single().first) }
        val example = welcome.first { it.type == "grid" }.children.first()
        val label = example.attributes.getValue("label").toString().trim('"')
        rule.onNodeWithText(label).performScrollTo().performClick()
        rule.runOnIdle {
            assertEquals("chat_message", events.last().first)
            assertEquals(example.attributes.getValue("payload").jsonObject, events.last().second)
        }
        rule.onNodeWithText("› More examples").performScrollTo().performClick()
        rule.onNodeWithText("System status").performScrollTo().assertIsDisplayed()
    }
}
