// Records the displayed native composite layer for owner-scoped canvas exports.
// Disposal, missing frames, and oversized images fail closed through CanvasCaptureRegistry.

package com.personalailabs.astraldeep.app.render

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream
import java.util.Base64

internal class CompositePixels(private var layer: GraphicsLayer?) : CanvasPixels {
    var ready = false
    private var cached: String? = null
    private var snapshot: Job? = null
    private var revision = 0L
    private var cachedSize = IntSize.Zero
    var closed = false
        private set

    override fun retainedBytes(): Long = (layer?.let { it.size.width.toLong() * it.size.height * 4 } ?: 0) + (cached?.length ?: 0) * 2L

    fun recorded(
        scope: CoroutineScope,
        onRetained: () -> Unit,
    ) {
        revision++
        if (cachedSize != layer?.size) cached = null
        snapshot?.cancel()
        snapshot =
            scope.launch {
                val expected = revision
                withFrameNanos { }
                val result =
                    try {
                        captureLayer()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        null
                    }
                if (!closed && expected == revision) {
                    cached = result
                    cachedSize = layer?.size ?: IntSize.Zero
                    onRetained()
                }
            }
    }

    fun detach() {
        snapshot?.cancel()
        snapshot = null
        layer = null
    }

    override fun close() {
        closed = true
        cached = null
        detach()
    }

    override suspend fun png(): String {
        if (closed || !ready) throw CanvasCaptureUnavailable()
        return cached ?: throw CanvasCaptureUnavailable()
    }

    private suspend fun captureLayer(): String {
        if (closed || !ready) throw CanvasCaptureUnavailable()
        val current = layer ?: throw CanvasCaptureUnavailable()
        if (current.size.width.toLong() * current.size.height * 4 !in 1..16L * 1024 * 1024) throw CanvasCaptureUnavailable()
        val expected = revision
        val bitmap = current.toImageBitmap().asAndroidBitmap()
        if (closed || expected != revision) throw CanvasCaptureUnavailable()
        val output = ByteArrayOutputStream()
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output) || output.size() > 6 * 1024 * 1024) throw CanvasCaptureUnavailable()
        return "data:image/png;base64," + Base64.getEncoder().encodeToString(output.toByteArray())
    }
}

@Composable
internal fun CompositeCapture(
    component: Component,
    content: @Composable () -> Unit,
) {
    val capture = LocalCanvasCapture.current
    if (capture == null) {
        content()
        return
    }
    val layer = rememberGraphicsLayer()
    val scope = rememberCoroutineScope()
    val currentDensity = LocalDensity.current
    val colors = MaterialTheme.colorScheme
    val typography = MaterialTheme.typography
    val pixels = remember(layer, capture.registry, capture.path, component, currentDensity, colors, typography) { CompositePixels(layer) }
    DisposableEffect(pixels) { onDispose { pixels.detach() } }
    Box(
        Modifier.drawWithContent {
            layer.record { this@drawWithContent.drawContent() }
            drawLayer(layer)
            pixels.ready = size.width > 0 && size.height > 0
            if (!pixels.closed) {
                capture.registry.imageSize(capture.path, (size.width / density).toDouble(), (size.height / density).toDouble())
                capture.registry.pixels(capture.path, pixels)
                pixels.recorded(scope) { capture.registry.pixels(capture.path, pixels) }
            }
        },
    ) { content() }
}
