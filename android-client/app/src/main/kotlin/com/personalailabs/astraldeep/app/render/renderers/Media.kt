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

/** Register media primitives (US2). `image` is a native improvement over the
 *  Windows placeholder; `audio` stays excluded (placeholder) until added. */
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
    // Feature 076: screenshots of the user's own computer arrive as
    // `data:image/…;base64,…` URLs (the same form the web and Windows
    // renderers already accept). Coil has no data-URI fetcher, so decode the
    // bytes here and hand Coil a ByteBuffer; every other source is unchanged.
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

/**
 * The decoded bytes of a base64 `data:image/…` URL, or null for any other
 * source (including a malformed data URL — the caller then falls back to the
 * string, which Coil reports as a load failure rather than a crash).
 */
internal fun dataUriBytes(source: String?): ByteArray? {
    if (source == null || !source.startsWith("data:image/", ignoreCase = true)) return null
    val comma = source.indexOf(',')
    if (comma < 0 || !source.substring(0, comma).endsWith(";base64", ignoreCase = true)) return null
    return runCatching { Base64.getMimeDecoder().decode(source.substring(comma + 1)) }
        .getOrNull()
        ?.takeIf { it.isNotEmpty() }
}
