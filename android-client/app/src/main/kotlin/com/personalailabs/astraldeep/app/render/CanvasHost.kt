// Per-component artifact-chrome context (export URL scope; read-only pauses Refine) and the virtualized SDUI
// canvas keyed by component identity so streaming upserts preserve item state and scroll.

package com.personalailabs.astraldeep.app.render

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import com.personalailabs.astraldeep.app.render.renderers.ArtifactFooter
import com.personalailabs.astraldeep.app.ui.SkeletonCanvas
import com.personalailabs.astraldeep.app.ui.theme.exportPalette
import com.personalailabs.astraldeep.core.sdui.Component

@Immutable
data class CanvasChrome(
    val chatId: String?,
    val mutationsLocked: Boolean,
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CanvasHost(
    components: List<Component>,
    renderer: Renderer,
    modifier: Modifier = Modifier,
    chrome: CanvasChrome? = null,
    loading: Boolean = false,
) {
    val configuration = LocalConfiguration.current
    val padding = if (configuration.screenWidthDp < 700) 12.dp else 16.dp
    val capture = renderer.capture
    val attachment = remember { Any() }
    val palette = exportPalette(MaterialTheme.colorScheme)
    DisposableEffect(capture, attachment) { onDispose { capture?.unmount(attachment) } }
    BoxWithConstraints(modifier.fillMaxSize()) {
        capture?.bind(
            renderer.captureContext?.invoke(),
            components,
            (maxWidth - padding * 2).value.toInt(),
            maxHeight.value.toInt(),
            palette,
            configuration.screenWidthDp,
            configuration.screenHeightDp,
            attachment,
        )
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            itemsIndexed(items = components, key = { _, it -> it.id ?: it.hashCode().toString() }) { index, component ->
                if (chrome == null) {
                    renderer.render(component, "/components/$index")
                } else {
                    Column(modifier = Modifier.fillMaxWidth()) {
                        renderer.render(component, "/components/$index")
                        ArtifactFooter(
                            c = component,
                            handler = renderer.componentActions,
                        )
                    }
                }
            }
            if (loading) item { SkeletonCanvas(Modifier.fillMaxWidth().height(180.dp)) }
        }
    }
}
