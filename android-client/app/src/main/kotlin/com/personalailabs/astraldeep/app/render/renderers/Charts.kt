// A sandboxed WebView hosting the shared Plotly chart renderer, fed data only; backs offline chart export and
// CanvasCapture's chart pixel snapshots.

package com.personalailabs.astraldeep.app.render.renderers

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.personalailabs.astraldeep.app.render.CurrentChartPixels
import com.personalailabs.astraldeep.app.render.LocalCanvasCapture
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.ui.theme.AstralWebStyle
import com.personalailabs.astraldeep.app.ui.theme.astralCardSurface
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import java.io.ByteArrayInputStream
import java.util.Base64
import java.util.Locale
import java.util.UUID

fun Renderer.registerChartRenderers(): Renderer =
    apply {
        for (type in listOf("bar_chart", "line_chart", "pie_chart", "plotly_chart")) {
            register(type) { component -> OfflineChart(component) }
        }
    }

internal const val CHART_ORIGIN = "https://astral-chart.invalid/"

internal fun offlineChartHeight(
    component: Component,
    slotWidth: Int,
    viewportWidth: Int = slotWidth,
): Int {
    if (slotWidth < 500) return 260
    val layout = if (component.type == "plotly_chart") component.attributes["layout"] as? JsonObject else null
    val requested =
        if (layout?.containsKey("height") == true) {
            (layout["height"] as? JsonPrimitive)?.doubleOrNull?.takeIf { it.isFinite() && it != 0.0 } ?: 320.0
        } else if (viewportWidth < 640) {
            240.0
        } else {
            320.0
        }
    return requested.coerceIn(160.0, 1200.0).toInt()
}

internal fun offlineChartPayload(
    component: Component,
    viewportWidth: Int,
): String =
    Base64.getEncoder().encodeToString(
        buildJsonObject {
            put("component", JsonObject(component.attributes + ("type" to JsonPrimitive(component.type))))
            put("viewport_width", viewportWidth.coerceAtLeast(1))
        }.toString().toByteArray(Charsets.UTF_8),
    )

private object OfflineChartAssets {
    private var template: String? = null

    @Synchronized
    fun document(
        context: Context,
        payload: String,
    ): String {
        val shared =
            template ?: run {
                val html = context.assets.open("chart.html").bufferedReader().use { it.readText() }
                val vendor = context.assets.open("plotly.min.js").bufferedReader().use { it.readText() }
                require(html.contains("__ASTRAL_PLOTLY_VENDOR__") && html.contains("__ASTRAL_CHART_PAYLOAD_BASE64__"))
                html.replace("__ASTRAL_PLOTLY_VENDOR__", vendor).also { template = it }
            }
        return shared.replace("__ASTRAL_CHART_PAYLOAD_BASE64__", payload)
    }
}

// Sandboxed: no app JS bridge and no network access, data only
internal class ChartWebView(context: Context) : WebView(context) {
    @Volatile var chartDocument: ByteArray? = null
    internal var exportPixels: CurrentChartPixels? = null
    private var layoutRevision = 0
    private var preferredHeight: Int? = null
    private var layoutFailure: () -> Unit = {}

    override fun onSizeChanged(
        w: Int,
        h: Int,
        oldw: Int,
        oldh: Int,
    ) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w > 0 && h > 0 && (w != oldw || h != oldh) && tag != null) {
            preferredHeight?.let { updateChartLayout(it, layoutFailure) }
        }
    }

    fun updateChartLayout(
        preferredHeight: Int,
        onFailure: () -> Unit,
    ) {
        this.preferredHeight = preferredHeight
        this.layoutFailure = onFailure
        val revision = ++layoutRevision
        val content = tag
        var applied = false

        fun check(attempt: Int) {
            postDelayed({
                if (tag != content || tag == null || revision != layoutRevision) return@postDelayed
                evaluateJavascript(
                    "[document.documentElement.dataset.chartState,document.documentElement.dataset.nativeLayout].join(':')",
                ) { result ->
                    if (tag != content || revision != layoutRevision) return@evaluateJavascript
                    when {
                        result.startsWith("\"empty:") || result == "\"ready:$revision\"" -> Unit
                        result.startsWith("\"error:") || result.endsWith(":error\"") || attempt >= 100 -> onFailure()
                        else -> {
                            if (!applied && result.startsWith("\"ready:")) {
                                applied = true
                                evaluateJavascript(
                                    """
                                    (function(){
                                      var chart=document.getElementById('chart');
                                      var height=chart.getBoundingClientRect().width<500?260:$preferredHeight;
                                      document.documentElement.dataset.nativeLayout='pending';
                                      Promise.resolve(Plotly.relayout(chart,{height:height,width:chart.getBoundingClientRect().width}))
                                        .then(function(){return Plotly.Plots.resize(chart);})
                                        .then(function(){document.documentElement.dataset.nativeLayout='$revision';})
                                        .catch(function(){document.documentElement.dataset.nativeLayout='error';});
                                    })();
                                    """.trimIndent(),
                                    null,
                                )
                            }
                            check(attempt + 1)
                        }
                    }
                }
            }, 100)
        }
        check(0)
    }
}

@SuppressLint("SetJavaScriptEnabled")
internal fun isolatedChartWebView(context: Context): ChartWebView =
    ChartWebView(context).apply {
        isSaveEnabled = false
        setBackgroundColor(android.graphics.Color.TRANSPARENT)
        settings.apply {
            javaScriptEnabled = true
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            allowFileAccess = false
            allowContentAccess = false
            blockNetworkLoads = true
            blockNetworkImage = true
            domStorageEnabled = false
            databaseEnabled = false
            setGeolocationEnabled(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_NO_CACHE
            mediaPlaybackRequiresUserGesture = true
        }
        webChromeClient = WebChromeClient()
        webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView?,
                    request: WebResourceRequest?,
                ): Boolean = true

                override fun shouldInterceptRequest(
                    view: WebView?,
                    request: WebResourceRequest?,
                ): WebResourceResponse {
                    val document = chartDocument
                    if (request?.isForMainFrame == true && request.method == "GET" &&
                        request.url.toString() == CHART_ORIGIN && document != null
                    ) {
                        return WebResourceResponse("text/html", "UTF-8", ByteArrayInputStream(document))
                    }
                    return WebResourceResponse("text/plain", "utf-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
                }
            }
    }

@Composable
private fun OfflineChart(component: Component) {
    val capture = LocalCanvasCapture.current
    val context = LocalContext.current
    val viewport = LocalConfiguration.current.screenWidthDp
    val colors = MaterialTheme.colorScheme
    val appearance =
        listOf(colors.surface, colors.onSurface, colors.onSurfaceVariant).map {
            String.format(Locale.ROOT, "#%06X", it.toArgb() and 0xFFFFFF)
        }
    val payload = remember(component, appearance) { offlineChartPayload(component, viewport) }
    val content = payload to appearance
    val document =
        remember(content) {
            runCatching {
                OfflineChartAssets.document(context, payload).replace(
                    "</head>",
                    "<style>html,body{background:${appearance[0]};color:${appearance[1]}}#status{color:${appearance[2]}}</style></head>",
                )
            }
        }
    var failed by remember(content) { mutableStateOf(document.isFailure) }
    if (failed) {
        Text("Chart could not be displayed. Reopen this result to try again.", color = MaterialTheme.colorScheme.error)
        return
    }
    val padding = if (viewport < 700) 8.dp else 12.dp
    Column(Modifier.fillMaxWidth().astralCardSurface().padding(padding + 1.dp)) {
        component.str("title")?.let {
            Text(
                it,
                style = AstralWebStyle.ChartTitle,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(bottom = 12.dp),
            )
        }
        BoxWithConstraints(Modifier.fillMaxWidth().testTag("offline-chart")) {
            val chartHeight = offlineChartHeight(component, maxWidth.value.toInt(), viewport).dp
            AndroidView(
                factory = ::isolatedChartWebView,
                modifier = Modifier.fillMaxWidth().height(chartHeight),
                update = { web ->
                    if (web.tag != content) {
                        val generation = UUID.randomUUID().toString()
                        web.exportPixels = CurrentChartPixels(web, generation)
                        capture?.registry?.pixels(capture.path, web.exportPixels)
                        web.tag = content
                        web.chartDocument =
                            document.getOrThrow().replace(
                                "<head>", "<head><meta name=\"astral-native-chart-generation\" content=\"$generation\">",
                            ).toByteArray(Charsets.UTF_8)
                        web.loadUrl(CHART_ORIGIN)
                    }
                    web.updateChartLayout(offlineChartHeight(component, 500, viewport)) { failed = true }
                },
                onRelease = { web ->
                    web.tag = null
                    web.chartDocument = null
                    val pixels = web.exportPixels
                    if (pixels != null) {
                        pixels.release()
                    } else {
                        web.stopLoading()
                        web.destroy()
                    }
                },
            )
        }
    }
}
