// Registers the image media renderer, decoding data:image/… base64 URLs (used for local screenshots) since
// Coil has no built-in data-URI fetcher; every other source loads through Coil normally.

package com.personalailabs.astraldeep.app.render.renderers

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import coil.compose.AsyncImage
import com.personalailabs.astraldeep.app.render.LocalCanvasCapture
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.loadedCanvasPixels
import com.personalailabs.astraldeep.core.sdui.Component
import java.nio.ByteBuffer
import java.util.Base64

fun Renderer.registerMediaRenderers(): Renderer =
    apply {
        register("image") { c -> ImagePrimitive(c) }
    }

@Composable
private fun ImagePrimitive(c: Component) {
    val capture = LocalCanvasCapture.current
    val node = capture?.registry?.node(capture.path)
    val density = LocalDensity.current.density
    val source = c.str("url") ?: c.str("src")
    val model: Any? =
        remember(source) { dataUriBytes(source)?.let { ByteBuffer.wrap(it) } ?: source }
    AsyncImage(
        model = model,
        onLoading = { if (capture?.registry?.node(capture.path) === node) capture?.registry?.pixels(capture.path, null) },
        onError = { if (capture?.registry?.node(capture.path) === node) capture?.registry?.pixels(capture.path, null) },
        onSuccess = {
            if (capture?.registry?.node(capture.path) === node) {
                capture?.registry?.pixels(
                    capture.path,
                    loadedCanvasPixels(it.result.drawable),
                )
            }
        },
        contentDescription = c.str("alt") ?: c.str("caption"),
        modifier =
            Modifier.fillMaxWidth().onSizeChanged { size ->
                if (capture?.registry?.node(capture.path) === node) {
                    capture?.registry?.imageSize(capture.path, size.width.toDouble() / density, size.height.toDouble() / density)
                }
            },
    )
}

internal fun dataUriBytes(source: String?): ByteArray? {
    if (source == null || !source.startsWith("data:image/", ignoreCase = true)) return null
    val comma = source.indexOf(',')
    if (comma < 0 || !source.substring(0, comma).endsWith(";base64", ignoreCase = true)) return null
    return runCatching { Base64.getMimeDecoder().decode(source.substring(comma + 1)) }
        .getOrNull()
        ?.takeIf { it.isNotEmpty() }
}
