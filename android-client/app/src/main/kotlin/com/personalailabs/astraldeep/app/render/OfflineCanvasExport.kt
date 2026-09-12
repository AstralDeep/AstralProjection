package com.personalailabs.astraldeep.app.render

import android.annotation.SuppressLint
import android.graphics.Color
import android.view.View
import android.view.ViewGroup
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.util.Base64

internal const val EXPORT_ORIGIN = "https://astral-export.invalid/"
internal const val MAX_PORTABLE_EXPORT = 32 * 1024 * 1024

/** Fixed bundled code consumes only an inert presentation, with no credentials or action bridge. */
@SuppressLint("SetJavaScriptEnabled")
internal suspend fun renderOfflineCanvasExport(
    activity: ComponentActivity,
    presentation: JsonObject,
    destination: File,
    current: () -> Boolean,
) = withContext(Dispatchers.Main.immediate) {
    val viewport = presentation["viewport"] as? JsonObject ?: throw CanvasCaptureUnavailable()
    val width = (viewport["window_width"] as? JsonPrimitive)?.intOrNull ?: throw CanvasCaptureUnavailable()
    val height = (viewport["window_height"] as? JsonPrimitive)?.intOrNull ?: throw CanvasCaptureUnavailable()
    if (width !in 64..16384 || height !in 32..16384 || !current()) throw CanvasCaptureUnavailable()
    val raw = presentation.toString().toByteArray(Charsets.UTF_8)
    if (raw.size > MAX_PORTABLE_EXPORT) throw CanvasCaptureUnavailable()
    val template = activity.assets.open("export.html").bufferedReader().use { it.readText() }
    val marker = "__ASTRAL_EXPORT_PRESENTATION_BASE64__"
    if (template.indexOf(marker) < 0 || template.indexOf(marker) != template.lastIndexOf(marker)) throw CanvasCaptureUnavailable()
    var document: ByteArray? = template.replace(marker, Base64.getEncoder().encodeToString(raw)).toByteArray(Charsets.UTF_8)
    var failed = false
    var complete = false
    val parent = activity.window.decorView as ViewGroup
    val holder =
        FrameLayout(activity).apply {
            alpha = 0f
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            isClickable = false
            isFocusable = false
        }
    val web =
        WebView(activity).apply {
            isSaveEnabled = false
            setBackgroundColor(Color.TRANSPARENT)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
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
                    ) = true

                    override fun shouldInterceptRequest(
                        view: WebView?,
                        request: WebResourceRequest?,
                    ): WebResourceResponse {
                        val bytes = document
                        if (request?.isForMainFrame == true && request.method == "GET" &&
                            request.url.toString() == EXPORT_ORIGIN && bytes != null
                        ) {
                            return WebResourceResponse("text/html", "UTF-8", ByteArrayInputStream(bytes))
                        }
                        return WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
                    }

                    override fun onReceivedError(
                        view: WebView?,
                        request: WebResourceRequest?,
                        error: WebResourceError?,
                    ) {
                        failed = true
                    }

                    override fun onRenderProcessGone(
                        view: WebView?,
                        detail: RenderProcessGoneDetail?,
                    ): Boolean {
                        failed = true
                        return true
                    }
                }
        }
    try {
        val density = activity.resources.displayMetrics.density
        val params = FrameLayout.LayoutParams((width * density).toInt(), (height * density).toInt())
        holder.addView(web, params)
        parent.addView(holder, params)
        withTimeout(25_000) {
            web.loadUrl(EXPORT_ORIGIN)
            var ready = false
            while (!ready) {
                ensureActive()
                if (failed || !current()) throw CanvasCaptureUnavailable()
                when (web.exportScript("document.documentElement.dataset.exportState")) {
                    "\"ready\"" -> ready = true
                    "\"error\"" -> throw CanvasCaptureUnavailable()
                    else -> delay(50)
                }
            }
            val rawLength = web.exportScript("window.AstralExportResult.html.length")
            val length = (Json.parseToJsonElement(rawLength) as? JsonPrimitive)?.intOrNull ?: throw CanvasCaptureUnavailable()
            if (length !in 1..MAX_PORTABLE_EXPORT) throw CanvasCaptureUnavailable()
            Files.newOutputStream(
                destination.toPath(),
                StandardOpenOption.CREATE,
                StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE,
                LinkOption.NOFOLLOW_LINKS,
            ).use {
                    output ->
                var offset = 0
                var total = 0
                while (offset < length) {
                    ensureActive()
                    if (!current() || failed) throw CanvasCaptureUnavailable()
                    val result =
                        web.exportScript(
                            """
                            (function(){
                              var s=window.AstralExportResult.html,e=Math.min($offset+16384,s.length);
                              if(e<s.length&&s.charCodeAt(e-1)>=55296&&s.charCodeAt(e-1)<=56319)e--;
                              return {next:e,text:s.slice($offset,e)};
                            })()
                            """.trimIndent(),
                        )
                    val chunk = Json.parseToJsonElement(result) as? JsonObject ?: throw CanvasCaptureUnavailable()
                    val next = (chunk["next"] as? JsonPrimitive)?.intOrNull ?: throw CanvasCaptureUnavailable()
                    val text = (chunk["text"] as? JsonPrimitive)?.content ?: throw CanvasCaptureUnavailable()
                    if (next <= offset || next > length || text.length != next - offset) throw CanvasCaptureUnavailable()
                    val bytes = text.toByteArray(Charsets.UTF_8)
                    total += bytes.size
                    if (total > MAX_PORTABLE_EXPORT) throw CanvasCaptureUnavailable()
                    withContext(Dispatchers.IO) { output.write(bytes) }
                    offset = next
                }
            }
            if (!current()) throw CanvasCaptureUnavailable()
            complete = true
        }
    } finally {
        document = null
        web.stopLoading()
        holder.removeView(web)
        parent.removeView(holder)
        web.webChromeClient = null
        web.destroy()
        if (!complete) destination.delete()
    }
}
