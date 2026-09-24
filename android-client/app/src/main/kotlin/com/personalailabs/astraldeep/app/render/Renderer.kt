// The type→Composable renderer registry (Android twin of the Windows REGISTRY): renderers register per
// primitive type and emit events, downloads, or live theme changes; unknown types fall back to a labeled
// Placeholder.

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

fun interface Emit {
    fun event(
        action: String,
        payload: JsonObject,
    )
}

fun interface Download {
    fun file(
        url: String,
        filename: String,
    )
}

fun interface ThemeSink {
    fun apply(spec: JsonObject)
}

typealias ComponentRenderer = @Composable Renderer.(Component) -> Unit

class Renderer(
    val emit: Emit,
    val download: Download = Download { _, _ -> },
    val theme: ThemeSink = ThemeSink { },
) {
    internal var componentActions: com.personalailabs.astraldeep.app.ui.ComponentActionHandler? = null
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
