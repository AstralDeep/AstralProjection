// Exercises the real console shell against canonical server fixtures and a synthetic WebSocket peer.
// Captures contain only synthetic catalog content; result transitions verify retained native chart identity.

package com.personalailabs.astraldeep.app

import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.exportScript
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.app.transport.deviceCapabilities
import com.personalailabs.astraldeep.app.ui.AppViewModel
import com.personalailabs.astraldeep.app.ui.RootScaffold
import com.personalailabs.astraldeep.app.ui.Screen
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.core.chrome.ChromeMenuModel
import com.personalailabs.astraldeep.core.chrome.ConsolePresentation
import com.personalailabs.astraldeep.core.protocol.ChatSummary
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.Wire
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.floor

class ConsoleShellTest {
    @get:Rule val rule = createComposeRule()
    private var width by mutableStateOf(390)
    private var height by mutableStateOf(844)
    private var fontScale by mutableStateOf(1f)
    private var fittedDensity = 1f

    private fun fixture(name: String): JsonObject = Json.parseToJsonElement(InstrumentationRegistry.getInstrumentation().context.assets.open("console/$name.json").bufferedReader().use { it.readText() }).jsonObject

    private fun geometry(width: Int): ConsolePresentation = requireNotNull(ConsolePresentation.fromJson(fixture("rote-console").getValue("cases").jsonArray.first { it.jsonObject.getValue("viewport").jsonArray.first().jsonPrimitive.content == width.toString() }.jsonObject["presentation"]))

    private fun withShell(block: (AppViewModel, CopyOnWriteArrayList<JsonObject>, MockWebServer) -> Unit) {
        val frames = CopyOnWriteArrayList<JsonObject>()
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onMessage(
                        webSocket: WebSocket,
                        text: String,
                    ) {
                        frames += Json.parseToJsonElement(text).jsonObject
                    }
                },
            ),
        )
        server.start()
        val client = OrchestratorClient(server.url("/ws").toString().replace("http:", "ws:"))
        val vm = AppViewModel(client, AstralRest(server.url("/").toString()))
        val renderer = Renderer(Emit(vm::sendEvent)).registerAllRenderers()
        rule.setContent {
            BoxWithConstraints {
                val density = minOf(constraints.maxWidth / width.toFloat(), constraints.maxHeight / height.toFloat())
                fittedDensity = if (density >= 1f) floor(density) else density
                CompositionLocalProvider(LocalDensity provides Density(fittedDensity, fontScale)) {
                    AstralTheme {
                        Box(Modifier.size(width.dp, height.dp).testTag("console-root")) { RootScaffold(vm, renderer, {}, {}) }
                    }
                }
            }
        }
        try {
            rule.runOnIdle { vm.start("synthetic", deviceCapabilities(width, height, 1.0, renderer.supportedTypes.toList())) }
            rule.waitUntil(10000) { vm.state.value.connection == ConnectionState.Connected }
            rule.runOnIdle {
                vm.receiveInbound(Inbound.ChromeMenu(requireNotNull(ChromeMenuModel.fromJson(fixture("chrome-console")))))
                vm.receiveInbound(Inbound.RoteConfig(geometry(width)))
            }
            rule.waitForIdle()
            block(vm, frames, server)
        } finally {
            rule.runOnIdle { vm.clearConversationForSignOut() }
            server.shutdown()
        }
    }

    private fun capture(
        name: String,
        tag: String = "console-root",
    ) {
        val bitmap = rule.onNodeWithTag(tag).captureToImage().asAndroidBitmap()
        val file = File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "console-$name.png")
        file.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun categoryFilterSurvivesConversationAndResizeThenRetiresWhenCatalogChanges() =
        withShell { vm, _, _ ->
            val utilities = hasText("Utilities") and hasClickAction()
            rule.onNode(utilities).performClick().assertIsSelected()
            rule.runOnIdle { vm.showConsoleConversation() }
            rule.onNodeWithText("AstralDeep Console").assertDoesNotExist()
            rule.runOnIdle {
                width = 1440
                vm.receiveInbound(Inbound.RoteConfig(geometry(width)))
                vm.showConsoleDashboard()
            }
            rule.onNode(utilities).assertIsSelected()
            rule.runOnIdle {
                val menu = requireNotNull(vm.state.value.chromeMenu)
                val console = requireNotNull(menu.console)
                vm.receiveInbound(Inbound.ChromeMenu(menu.copy(console = console.copy(catalog = console.catalog.copy(categories = emptyList(), scenarios = emptyList())))))
            }
            rule.onNodeWithText("All").assertIsSelected()
            rule.onNode(utilities).assertDoesNotExist()
        }

    @Test fun landingAndComposerRemainReachableAcrossRoteLayoutsAndLargeText() =
        withShell { vm, _, _ ->
            for (viewport in listOf(320, 390, 768, 834, 1024, 1280, 1440)) {
                rule.runOnIdle {
                    width = viewport
                    height = if (viewport < 768) 844 else 900
                    vm.receiveInbound(Inbound.RoteConfig(geometry(viewport)))
                }
                rule.onNodeWithText("AstralDeep Console").assertIsDisplayed()
                rule.onNodeWithText("Load prompt").assertIsDisplayed()
                rule.onNodeWithContentDescription("More options").assertIsDisplayed()
                val root = rule.onNodeWithTag("console-root").fetchSemanticsNode().boundsInRoot
                val send = rule.onNodeWithTag("composer-send").fetchSemanticsNode().boundsInRoot
                assertEquals(viewport.toFloat(), root.width / fittedDensity, 1f)
                assertTrue(send.left >= root.left && send.right <= root.right && send.bottom <= root.bottom)
                capture("landing-$viewport")
            }
            rule.onNodeWithText("Load prompt").performClick()
            assertEquals("Roll six dice", vm.state.value.composerDraft)
            rule.onNodeWithContentDescription("More options").performClick()
            rule.onNodeWithText("Run in background").performClick()
            assertTrue(vm.state.value.backgroundNextSend)
            rule.runOnIdle {
                width = 320
                fontScale = 1.6f
                vm.receiveInbound(Inbound.RoteConfig(geometry(320)))
            }
            rule.onNodeWithTag("chat-input").assertIsDisplayed()
            rule.onNodeWithContentDescription("Send message").assertIsDisplayed()
            assertEquals("Roll six dice", vm.state.value.composerDraft)
            val layout = mutableListOf<TextLayoutResult>()
            rule.onNodeWithContentDescription("View active conversation").performSemanticsAction(SemanticsActions.GetTextLayoutResult) {
                it(layout)
            }
            assertTrue(layout.isNotEmpty())
            capture("landing-320-large-text")
            assertFalse("Turn layout: ${layout.single().size}; ${layout.single().layoutInput.constraints}", layout.single().didOverflowWidth)
            val field = rule.onNodeWithTag("chat-input").fetchSemanticsNode().boundsInRoot
            assertTrue("Message field width: ${field.width / fittedDensity}", field.width / fittedDensity >= 280)
            capture("landing-320-large-text")
        }

    @Test fun drawerSearchAndSettingsUseCurrentServerOffers() =
        withShell { vm, frames, _ ->
            rule.onNodeWithContentDescription("Show the agent directory").performClick()
            rule.onNodeWithContentDescription("Search agents").performTextInput("Dice")
            rule.onNodeWithText("Dice Roller").assertIsDisplayed()
            rule.onNodeWithContentDescription("Hide the agent directory").performClick()
            rule.onNodeWithContentDescription("Show the agent directory").performClick()
            rule.onNodeWithContentDescription("Search agents").assertTextContains("Dice")
            repeat(3) {
                rule.runOnIdle {
                    width = 1440
                    vm.receiveInbound(Inbound.RoteConfig(geometry(1440)))
                }
                rule.onNodeWithContentDescription("Search agents").assertTextContains("Dice")
                rule.onNodeWithContentDescription("Settings").performClick()
                rule.waitUntil { frames.any { it["action"]?.jsonPrimitive?.content == "chrome_open" } }
                assertEquals("agents", vm.state.value.pendingSurfaceKey)
                rule.onNodeWithText("LLM settings").performClick()
                assertEquals("llm", vm.state.value.pendingSurfaceKey)
                rule.onNodeWithContentDescription("Close").performClick()
                assertEquals(Screen.Chat, vm.state.value.screen)
                assertFalse(vm.state.value.consoleDrawerOpen)
                rule.runOnIdle {
                    width = 390
                    vm.receiveInbound(Inbound.RoteConfig(geometry(390)))
                }
                rule.onNodeWithContentDescription("Show the agent directory").performClick()
                rule.onNodeWithContentDescription("Search agents").assertTextContains("Dice")
                rule.onNodeWithContentDescription("Hide the agent directory").performClick()
            }
        }

    @Test fun introductionsRejectStaleResponsesAndLoadOnlyTheirOfferedPrompt() =
        withShell { vm, _, _ ->
            for (viewport in listOf(390, 1440)) {
                rule.runOnIdle {
                    width = viewport
                    vm.receiveInbound(Inbound.RoteConfig(geometry(viewport)))
                    vm.openConsoleAgent(vm.state.value.console!!.catalog.agents.first())
                }
                rule.waitUntil { vm.state.value.privateSurfaceRequest != null }
                val request = vm.state.value.privateSurfaceRequest!!.requestGeneration
                rule.runOnIdle {
                    vm.receiveInbound(Wire.decode(fixture("agent-intro")))
                    assertEquals(null, vm.state.value.pendingSurface)
                    vm.receiveInbound(Wire.decode(JsonObject(fixture("agent-intro") + ("request_generation" to JsonPrimitive(request)))))
                }
                rule.onNodeWithContentDescription("Load: Six dice").assertIsDisplayed()
                capture("intro-$viewport", "console-surface")
                rule.onNodeWithContentDescription("Load: Six dice").performClick()
                assertEquals("Roll exactly six six-sided dice and show the normalized results.", vm.state.value.composerDraft)
                assertEquals(Screen.Chat, vm.state.value.screen)
            }
        }

    @Test fun mandatorySetupCannotExposeUnderlyingNavigationOrComposer() =
        withShell { vm, _, _ ->
            rule.runOnIdle {
                vm.receiveInbound(Inbound.ChromeSurface("llm", "Required setup", emptyList(), "mandatory"))
            }
            rule.onNodeWithText("Required setup").assertIsDisplayed()
            rule.onNodeWithContentDescription("Close").assertDoesNotExist()
            rule.onNodeWithContentDescription("More options").assertDoesNotExist()
            rule.onNodeWithText("Sign out").assertIsDisplayed()
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            rule.waitForIdle()
            assertTrue(vm.state.value.mandatorySurface)
            assertEquals(Screen.Surface, vm.state.value.screen)
        }

    @Test fun historyDeletionKeepsFailedRowsAndClearsOnlyConfirmedActiveContent() =
        withShell { vm, _, server ->
            val id = "00000000-0000-4000-8000-000000000001"
            rule.runOnIdle {
                vm.receiveInbound(Inbound.HistoryList(listOf(ChatSummary(id, "Synthetic saved chat"))))
                vm.openChat(id)
                vm.updateComposerDraft("Draft in the removed chat")
                vm.setConsoleDrawer(true)
            }
            server.enqueue(MockResponse().setResponseCode(403))
            rule.onNodeWithText("Synthetic saved chat").performTouchInput { longClick() }
            rule.onNodeWithText("Delete conversation").performClick()
            rule.waitUntil(5000) { vm.state.value.banner?.contains("Could not delete") == true }
            assertEquals(id, vm.state.value.activeChatId)
            assertEquals(1, vm.state.value.history.size)
            server.enqueue(MockResponse().setResponseCode(204))
            rule.onNodeWithText("Synthetic saved chat").performTouchInput { longClick() }
            rule.onNodeWithText("Delete conversation").performClick()
            rule.waitUntil(5000) { vm.state.value.history.isEmpty() }
            assertEquals(null, vm.state.value.activeChatId)
            assertEquals("", vm.state.value.composerDraft)
            assertTrue(vm.state.value.consoleDashboardVisible)
            assertFalse(vm.state.value.consoleDrawerOpen)
            server.takeRequest()
            repeat(2) {
                val request = server.takeRequest()
                assertEquals("DELETE", request.method)
                assertEquals("/api/chats/$id", request.path)
            }
            rule.runOnIdle { vm.deleteChat("not-in-current-history") }
            assertEquals(3, server.requestCount)
        }

    private fun webViews(view: View): List<WebView> =
        when (view) {
            is WebView -> listOf(view)
            is ViewGroup -> (0 until view.childCount).flatMap { webViews(view.getChildAt(it)) }
            else -> emptyList()
        }

    private fun chart(): WebView = webViews((ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).first() as ComponentActivity).window.decorView).single()

    @Test fun fullscreenCollapseAndResizeKeepTheSameChartDocument() =
        withShell { vm, _, _ ->
            rule.runOnIdle {
                val component = Component.fromJson(Json.parseToJsonElement("""{"type":"line_chart","id":"retained-chart","title":"Synthetic result","labels":["A","B","C"],"datasets":[{"data":[2,5,3]}]}""").jsonObject)
                vm.receiveInbound(Inbound.UiRender("canvas", listOf(component)))
                vm.showConsoleConversation()
            }
            rule.waitForIdle()
            runBlocking {
                val web = withContext(Dispatchers.Main) { chart() }
                withTimeout(15000) { while (web.exportScript("document.documentElement.dataset.chartState") != "\"ready\"") delay(50) }
                web.exportScript("window.__retainedConsole=true;Plotly.relayout(document.getElementById('chart'),{'xaxis.range':[0.5,1.5]});true")
                delay(200)
                rule.onNodeWithContentDescription("Full Screen").performClick()
                rule.onNodeWithContentDescription("Exit Full Screen").assertIsDisplayed()
                assertSame(web, withContext(Dispatchers.Main) { chart() })
                assertEquals("true", web.exportScript("window.__retainedConsole"))
                rule.runOnIdle {
                    width = 768
                    vm.receiveInbound(Inbound.RoteConfig(geometry(768)))
                }
                rule.waitForIdle()
                assertSame(web, withContext(Dispatchers.Main) { chart() })
                rule.onNodeWithContentDescription("Exit Full Screen").performClick()
                rule.onNodeWithContentDescription("Collapse container").performClick()
                rule.onNodeWithContentDescription("Expand container").performClick()
                assertEquals("true", web.exportScript("window.__retainedConsole"))
                assertEquals("[0.5,1.5]", web.exportScript("document.getElementById('chart').layout.xaxis.range"))
                withTimeout(10000) {
                    while (web.exportScript("Math.abs(document.getElementById('chart')._fullLayout.width-document.getElementById('chart').clientWidth)<2") != "true") delay(50)
                }
                capture("retained-result-768")
            }
        }
}
