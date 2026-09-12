package com.personalailabs.astraldeep.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.BitmapDrawable
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.ComponentActivity
import androidx.compose.runtime.remember
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.render.CanvasCaptureRegistry
import com.personalailabs.astraldeep.app.render.CanvasHost
import com.personalailabs.astraldeep.app.render.CurrentChartPixels
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.exportScript
import com.personalailabs.astraldeep.app.render.loadedCanvasPixels
import com.personalailabs.astraldeep.app.render.renderOfflineCanvasExport
import com.personalailabs.astraldeep.app.render.renderers.ChartWebView
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.WorkspaceContext
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.ServerSocket
import java.util.Base64

/** Synthetic data only; never installs or signs in on the user's live emulator. */
class PortableCanvasExport088UiTest {
    @get:Rule val rule = createComposeRule()

    private fun activity(): ComponentActivity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).first() as ComponentActivity

    private fun webViews(view: View): List<WebView> =
        when (view) {
            is WebView -> listOf(view)
            is ViewGroup -> (0 until view.childCount).flatMap { webViews(view.getChildAt(it)) }
            else -> emptyList()
        }

    @Test fun chartPixelsCaptureActualZoomAndClearWithOwner() =
        runBlocking {
            val capture = CanvasCaptureRegistry()
            val context = WorkspaceContext(ConversationResumeStore.AccountIdentity("synthetic", "owner"), 1, "chat", 1u, setOf("export_canvas"))
            val component = Component.fromJson(Json.parseToJsonElement("""{"type":"plotly_chart","id":"plot","title":"Synthetic zoom capture","data":[{"type":"scatter","mode":"lines","x":[0,1,2,3],"y":[2,5,1,4]}]}""").jsonObject)
            rule.setContent {
                AstralTheme {
                    val renderer =
                        remember {
                            Renderer(Emit { _, _ -> }).registerAllRenderers().also {
                                it.capture = capture
                                it.captureContext = { context }
                            }
                        }
                    CanvasHost(listOf(component), renderer)
                }
            }
            val web = withContext(Dispatchers.Main) { webViews(activity().window.decorView).single() }
            withTimeout(15000) { while (web.exportScript("document.documentElement.dataset.chartState") != "\"ready\"") delay(100) }
            val wrongGeneration = CurrentChartPixels(web, java.util.UUID.randomUUID().toString())
            assertTrue(runCatching { wrongGeneration.png() }.isFailure)
            wrongGeneration.close()
            val first = withContext(Dispatchers.Main) { capture.freeze(context) }
            val original = (first.presentation["images"] as JsonArray).single().jsonObject.getValue("data_url").jsonPrimitive.content
            web.exportScript("Plotly.relayout(document.getElementById('chart'), {'xaxis.range':[1,2], 'yaxis.range':[0,6]});true")
            delay(300)
            val next = withContext(Dispatchers.Main) { capture.freeze(context) }
            val zoomed = (next.presentation["images"] as JsonArray).single().jsonObject.getValue("data_url").jsonPrimitive.content
            assertNotEquals(original, zoomed)
            val bytes = Base64.getDecoder().decode(zoomed.substringAfter(','))
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            assertNotNull(bitmap)
            assertTrue(bitmap.width > 0 && bitmap.height > 0)
            bitmap.recycle()
            assertFalse(next.presentation.toString().contains("scatter"))
            assertFalse(next.presentation.toString().contains("\"data\""))
            web.exportScript("window.__originalToImage=Plotly.toImage;window.__captureCalls=0;Plotly.toImage=function(){window.__captureCalls++;return window.__originalToImage.apply(this,arguments)};true")
            for (dimension in listOf("width", "height")) {
                for (invalid in listOf("0", "-1", "4097", "NaN", "Infinity")) {
                    web.exportScript("window.__savedSize=document.getElementById('chart')._fullLayout.$dimension;document.getElementById('chart')._fullLayout.$dimension=$invalid;true")
                    assertTrue(runCatching { withContext(Dispatchers.Main) { capture.freeze(context) } }.isFailure)
                    web.exportScript("document.getElementById('chart')._fullLayout.$dimension=window.__savedSize;true")
                }
            }
            assertEquals("0", web.exportScript("window.__captureCalls"))
            web.exportScript("Plotly.toImage=window.__originalToImage;true")
            withContext(Dispatchers.Main) { capture.clear() }
            assertFalse(capture.isCurrent(next, context))
        }

    private fun presentation(
        activity: ComponentActivity,
        html: String,
    ): JsonObject {
        val config = activity.resources.configuration
        return buildJsonObject {
            put("version", "astral.canvas-export/v1")
            put("html", html)
            put(
                "viewport",
                buildJsonObject {
                    put("width", config.screenWidthDp - 24)
                    put("height", 300)
                    put("window_width", config.screenWidthDp)
                    put("window_height", config.screenHeightDp)
                },
            )
            put(
                "theme",
                buildJsonObject {
                    for (role in listOf("bg", "surface", "surface2", "border", "primary", "secondary", "accent", "text", "muted", "success", "warning", "error", "info")) put(role, if (role == "text") "#F3F4F6" else "#1A1E2E")
                },
            )
        }
    }

    @Test fun realPrivateDocumentEmbedsPixelsFontsAndCurrentDisclosureWithoutScripts() =
        runBlocking {
            rule.setContent { AstralTheme {} }
            val activity = withContext(Dispatchers.Main) { activity() }
            val bitmap = Bitmap.createBitmap(3, 2, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLUE) }
            val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            bitmap.recycle()
            val png = "data:image/png;base64," + Base64.getEncoder().encodeToString(bytes)
            val html = "<div class=\"dynamic-renderer\"><h2>Synthetic portable export</h2><details open><summary>Visible detail</summary><p>Current state 😀</p><img src=\"$png\" alt=\"Loaded pixels\"></details></div>"
            val file = File(activity.cacheDir, "synthetic-portable-export.html")
            try {
                renderOfflineCanvasExport(activity, presentation(activity, html), file) { true }
                val result = file.readText()
                assertTrue(result.contains("Synthetic portable export"))
                assertTrue(result.contains("Current state 😀"))
                assertTrue(result.contains("data:image/png;base64,"))
                assertTrue(result.contains("data:font/woff2;base64,"))
                assertFalse(result.contains("<script", ignoreCase = true))
                assertFalse(result.contains("data-action"))
                assertTrue(result.contains("script-src 'none'") || result.contains("script-src &#39;none&#39;"))
                val output = File(activity.getExternalFilesDir(null), "workspace-088-synthetic/portable-export.html")
                output.parentFile?.mkdirs()
                file.copyTo(output, overwrite = true)
            } finally {
                file.delete()
            }
            assertEquals(0, withContext(Dispatchers.Main) { webViews(activity.window.decorView).size })
        }

    @Test fun maliciousNetworkMarkupFailsWithoutRequestOrPreparedFile() =
        runBlocking {
            rule.setContent { AstralTheme {} }
            val activity = withContext(Dispatchers.Main) { activity() }
            ServerSocket(0).use { server ->
                server.soTimeout = 300
                val file = File(activity.cacheDir, "denied-portable-export.html")
                val payload = presentation(activity, "<img src=\"http://127.0.0.1:${server.localPort}/private\" onerror=\"alert('private')\">")
                assertTrue(runCatching { renderOfflineCanvasExport(activity, payload, file) { true } }.isFailure)
                assertFalse(file.exists())
                assertTrue(runCatching { server.accept().close() }.isFailure)
            }
            assertEquals(0, withContext(Dispatchers.Main) { webViews(activity.window.decorView).size })
        }

    @Test fun cancellationDestroysPrivateDocumentAndTemporaryOutput() =
        runBlocking {
            rule.setContent { AstralTheme {} }
            val activity = withContext(Dispatchers.Main) { activity() }
            val file = File(activity.cacheDir, "cancelled-portable-export.html")
            val pending = async { renderOfflineCanvasExport(activity, presentation(activity, "<p>Synthetic cancellation</p>"), file) { true } }
            withTimeout(5000) { while (withContext(Dispatchers.Main) { webViews(activity.window.decorView).isEmpty() }) delay(10) }
            pending.cancelAndJoin()
            assertFalse(file.exists())
            assertEquals(0, withContext(Dispatchers.Main) { webViews(activity.window.decorView).size })
        }

    @Test fun offscreenChartRetainsItsActualPixelsWithoutRefetchOrReplay() =
        runBlocking {
            val capture = CanvasCaptureRegistry()
            val context = WorkspaceContext(ConversationResumeStore.AccountIdentity("synthetic", "owner"), 1, "chat", 1u, setOf("export_canvas"))
            val chart = Component.fromJson(Json.parseToJsonElement("""{"type":"bar_chart","id":"plot","labels":["A","B"],"datasets":[{"data":[2,5]}]}""").jsonObject)
            val rows =
                listOf(chart) +
                    (1..20).map { index ->
                        Component.fromJson(
                            buildJsonObject {
                                put("type", "text")
                                put("id", "row$index")
                                put("content", (1..12).joinToString("\n") { "Synthetic row $index line $it" })
                            },
                        )
                    }
            rule.setContent {
                AstralTheme {
                    val renderer =
                        remember {
                            Renderer(Emit { _, _ -> }).registerAllRenderers().also {
                                it.capture = capture
                                it.captureContext = { context }
                            }
                        }
                    CanvasHost(rows, renderer)
                }
            }
            val web = withContext(Dispatchers.Main) { webViews(activity().window.decorView).single() }
            withTimeout(15000) { while (web.exportScript("document.documentElement.dataset.chartState") != "\"ready\"") delay(100) }
            val initial = withContext(Dispatchers.Main) { capture.freeze(context) }
            rule.onNode(hasScrollAction()).performScrollToIndex(18)
            rule.onNodeWithText("Synthetic row 18 line 1").assertIsDisplayed()
            // Compose may retain an offscreen AndroidView in its reuse pool. Exercise the
            // exact row-release callback's pixel owner as well as the actual lazy scroll.
            withContext(Dispatchers.Main) { (web as ChartWebView).exportPixels?.release() }
            val retained = withContext(Dispatchers.Main) { capture.freeze(context) }
            assertEquals(initial.presentation["images"], retained.presentation["images"])
            assertEquals(21, (retained.presentation["components"] as JsonArray).size)
        }

    @Test fun densityScaledBitmapCannotBypassPixelDimensionsOrAccounting() =
        runBlocking {
            val resources = InstrumentationRegistry.getInstrumentation().targetContext.resources
            val bitmap = Bitmap.createBitmap(5000, 1, Bitmap.Config.ARGB_8888).apply { density = 320 }
            try {
                val drawable = BitmapDrawable(resources, bitmap).apply { setTargetDensity(160) }
                assertEquals(2500, drawable.intrinsicWidth)
                val pixels = loadedCanvasPixels(drawable)
                assertEquals(bitmap.allocationByteCount.toLong(), pixels.retainedBytes())
                assertTrue(runCatching { pixels.png() }.isFailure)
            } finally {
                bitmap.recycle()
            }
        }

    @Test fun loadedNativeImageCapturesItsMeasuredLogicalBoxAndAccessibleLabel() =
        runBlocking {
            val capture = CanvasCaptureRegistry()
            val context = WorkspaceContext(ConversationResumeStore.AccountIdentity("synthetic", "owner"), 1, "chat", 1u, setOf("export_canvas"))
            val bitmap = Bitmap.createBitmap(6, 4, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.GREEN) }
            val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            bitmap.recycle()
            val source = "data:image/png;base64," + Base64.getEncoder().encodeToString(bytes)
            val image =
                Component.fromJson(
                    buildJsonObject {
                        put("type", "image")
                        put("id", "loaded")
                        put("src", source)
                        put("alt", "Synthetic pixels")
                        put("caption", "Not a visible caption")
                        put("width", 9999)
                        put("height", 8888)
                    },
                )
            rule.setContent {
                AstralTheme {
                    val renderer =
                        remember {
                            Renderer(Emit { _, _ -> }).registerAllRenderers().also {
                                it.capture = capture
                                it.captureContext = { context }
                            }
                        }
                    CanvasHost(listOf(image), renderer)
                }
            }
            val frozen =
                withTimeout(15000) {
                    var value: com.personalailabs.astraldeep.app.render.CanvasCapture? = null
                    while (value == null) {
                        value = withContext(Dispatchers.Main) { runCatching { capture.freeze(context) }.getOrNull() }
                        if (value == null) delay(100)
                    }
                    value
                }
            val bounds = rule.onNodeWithContentDescription("Synthetic pixels").fetchSemanticsNode().boundsInRoot
            val density = withContext(Dispatchers.Main) { activity().resources.displayMetrics.density }
            val actual = (frozen.presentation["components"] as JsonArray).single().jsonObject
            assertEquals(bounds.width / density, actual.getValue("width").jsonPrimitive.content.toFloat(), 0.01f)
            assertEquals(bounds.height / density, actual.getValue("height").jsonPrimitive.content.toFloat(), 0.01f)
            assertFalse(actual.containsKey("caption"))
            assertFalse(actual.containsKey("src"))
            assertEquals(1, (frozen.presentation["images"] as JsonArray).size)
        }
}
