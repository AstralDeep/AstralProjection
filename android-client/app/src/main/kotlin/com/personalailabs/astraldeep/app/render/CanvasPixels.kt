package com.personalailabs.astraldeep.app.render

import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.webkit.WebView
import androidx.core.graphics.drawable.toBitmap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import java.io.ByteArrayOutputStream
import java.util.Base64
import kotlin.coroutines.resume

internal suspend fun WebView.exportScript(script: String): String =
    withContext(Dispatchers.Main.immediate) {
        suspendCancellableCoroutine { continuation ->
            evaluateJavascript(script) { value -> if (continuation.isActive) continuation.resume(value ?: "null") }
        }
    }

/** Only an already loaded drawable is copied; this path has no image loader or URL access. */
internal fun loadedCanvasPixels(drawable: Drawable): CanvasPixels =
    object : CanvasPixels {
        override fun retainedBytes(): Long =
            (drawable as? BitmapDrawable)?.bitmap?.allocationByteCount?.toLong()
                ?: (drawable.intrinsicWidth.toLong().coerceAtLeast(0) * drawable.intrinsicHeight.coerceAtLeast(0) * 4)

        override suspend fun png(): String {
            val bitmap =
                withContext(Dispatchers.Main.immediate) {
                    val loadedBitmap = (drawable as? BitmapDrawable)?.bitmap
                    val width = loadedBitmap?.width ?: drawable.intrinsicWidth
                    val height = loadedBitmap?.height ?: drawable.intrinsicHeight
                    if (width !in 1..4096 || height !in 1..4096) throw CanvasCaptureUnavailable()
                    val loaded = loadedBitmap ?: drawable.toBitmap(width, height)
                    loaded.copy(Bitmap.Config.ARGB_8888, false) ?: throw CanvasCaptureUnavailable()
                }
            return try {
                withContext(Dispatchers.Default) {
                    val bytes =
                        object : ByteArrayOutputStream() {
                            override fun write(value: Int) {
                                if (size() >= 6 * 1024 * 1024) throw CanvasCaptureUnavailable()
                                super.write(value)
                            }

                            override fun write(
                                bytes: ByteArray,
                                offset: Int,
                                length: Int,
                            ) {
                                if (size().toLong() + length > 6 * 1024 * 1024) throw CanvasCaptureUnavailable()
                                super.write(bytes, offset, length)
                            }
                        }
                    if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes) || bytes.size() > 6 * 1024 * 1024) {
                        throw CanvasCaptureUnavailable()
                    }
                    "data:image/png;base64," + Base64.getEncoder().encodeToString(bytes.toByteArray())
                }
            } finally {
                bitmap.recycle()
            }
        }
    }

/** A current Plotly graph is snapshotted, including its zoom and legend state, never reconstructed. */
internal class CurrentChartPixels(private var web: WebView?, private val generation: String) : CanvasPixels {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutex = Mutex()
    private var retained: String? = null
    private var released = false
    private var closed = false

    override fun close() {
        closed = true
        retained = null
        scope.cancel()
        if (released) {
            web?.stopLoading()
            web?.destroy()
            web = null
        }
    }

    override suspend fun png(): String =
        mutex.withLock {
            if (closed) throw CanvasCaptureUnavailable()
            val view = web ?: return@withLock retained ?: throw CanvasCaptureUnavailable()
            withTimeout(5000) {
                val started = view.exportScript(START_CHART_CAPTURE.replace("__GENERATION__", JsonPrimitive(generation).toString()))
                if (started != "true") throw CanvasCaptureUnavailable()
                var ready = false
                repeat(100) {
                    if (!ready) {
                        val state = view.exportScript("window.__astralNativePixels && window.__astralNativePixels.state")
                        if (state == "\"error\"") throw CanvasCaptureUnavailable()
                        ready = state == "\"ready\""
                        if (!ready) delay(40)
                    }
                }
                if (!ready) throw CanvasCaptureUnavailable()
                val encoded = view.exportScript("window.__astralNativePixels.png")
                val pixels = (Json.parseToJsonElement(encoded) as? JsonPrimitive)?.content ?: throw CanvasCaptureUnavailable()
                if (!pixels.startsWith("data:image/png;base64,") || pixels.length > 8 * 1024 * 1024) throw CanvasCaptureUnavailable()
                retained = pixels
                pixels
            }
        }

    /** Detached rows retain only the latest successful pixels, then destroy their private graph. */
    fun release() {
        if (closed) {
            web?.stopLoading()
            web?.destroy()
            web = null
            return
        }
        if (released) return
        released = true
        scope.launch {
            try {
                png()
            } catch (
                _: Exception,
            ) {
                retained = null
            } finally {
                web?.stopLoading()
                web?.destroy()
                web = null
                scope.cancel()
            }
        }
    }

    companion object {
        private val START_CHART_CAPTURE =
            """
            (function() {
              var marker=document.querySelector('meta[name=astral-native-chart-generation]');
              if(!marker||marker.content!==__GENERATION__)return false;
              var gd=document.getElementById('chart');
              if(document.documentElement.dataset.chartState!=='ready'||!gd||!gd._fullLayout||!window.Plotly)return false;
              var width=gd._fullLayout.width, height=gd._fullLayout.height;
              if(!Number.isFinite(width)||!Number.isFinite(height)||width<=0||height<=0||width>4096||height>4096)return false;
              if(!gd.__astralCaptureObserved){
                gd.__astralCaptureObserved=true;gd.__astralCaptureRevision=0;
                ['plotly_relayout','plotly_restyle','plotly_afterplot'].forEach(function(event){gd.on(event,function(){gd.__astralCaptureRevision++;});});
              }
              var version=gd.__astralCaptureRevision, result={state:'loading'};
              window.__astralNativePixels=result;
              Plotly.toImage(gd,{format:'png',width:width,height:height}).then(function(png){
                if(window.__astralNativePixels!==result)return;
                if(gd.__astralCaptureRevision!==version){result.state='error';return;}
                if(png.length>8*1024*1024){result.state='error';return;}result.png=png;result.state='ready';
              },function(){result.state='error';});return true;
            })()
            """.trimIndent()
    }
}
