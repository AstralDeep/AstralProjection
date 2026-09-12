package com.personalailabs.astraldeep.app.render

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.personalailabs.astraldeep.app.ui.WorkspaceContext
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject

/** Emits a `ui_event` back to the orchestrator (e.g. a rendered button's action). */
fun interface Emit {
    fun event(
        action: String,
        payload: JsonObject,
    )
}

/** Downloads an authed backend file (a `file_download`/`download_card`) to the device. */
fun interface Download {
    fun file(
        url: String,
        filename: String,
    )
}

/**
 * Applies a theme spec locally (feature 044 US5). A `theme_apply` component or an
 * interactive `color_picker` calls this with the raw spec object
 * (`preset`|`colors`|`color_key`+`color_value`) so the whole app restyles live,
 * without waiting for a server round-trip.
 */
fun interface ThemeSink {
    fun apply(spec: JsonObject)
}

/**
 * A renderer for one primitive type — an extension composable on [Renderer] so it
 * can render children via `render(child)` and emit events via `emit`.
 */
typealias ComponentRenderer = @Composable Renderer.(Component) -> Unit

/**
 * The type→Composable registry (the Android twin of the Windows renderer
 * `REGISTRY`). Renderers register per primitive type; an unknown type falls back
 * to a labeled [Placeholder] (FR-005). [supportedTypes] is exactly what the
 * client advertises to ROTE in `register_ui`.
 */
class Renderer(
    val emit: Emit,
    val download: Download = Download { _, _ -> },
    val theme: ThemeSink = ThemeSink { },
) {
    internal var capture: CanvasCaptureRegistry? = null
    internal var captureContext: (() -> WorkspaceContext?)? = null
    private val registry = LinkedHashMap<String, ComponentRenderer>()

    fun register(
        type: String,
        renderer: ComponentRenderer,
    ): Renderer {
        registry[type] = renderer
        return this
    }

    val supportedTypes: Set<String> get() = registry.keys

    @Composable
    fun render(
        component: Component,
        path: String? = null,
    ) {
        val parent = LocalCanvasCapture.current
        val resolved = path ?: parent?.childPath(component)
        val location = if (resolved != null && capture != null) CaptureLocation(capture!!, resolved, component) else null
        CompositionLocalProvider(LocalCanvasCapture provides location) {
            val renderer = registry[component.type]
            if (renderer != null) renderer(this, component) else Placeholder(component)
        }
    }
}

/** Labeled placeholder for an unsupported/unknown component type. */
@Composable
fun Placeholder(component: Component) {
    Text(
        text = "[${component.type}]",
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(8.dp),
    )
}

internal data class CaptureLocation(val registry: CanvasCaptureRegistry, val path: String, val component: Component) {
    fun childPath(child: Component): String? {
        val index = component.children.indexOfFirst { it === child }
        if (index < 0) return null
        val key = if (component.attributes.containsKey("content")) "content" else "children"
        return "$path/$key/$index"
    }
}

internal val LocalCanvasCapture = staticCompositionLocalOf<CaptureLocation?> { null }
