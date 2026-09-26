// Arranges server-owned agent introductions as scenario rows and tool chips in the console dialog.
// Offered buttons use the shared renderer event sink and AppViewModel's current-surface checks.

package com.personalailabs.astraldeep.app.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

private fun Component.textAttribute(key: String) = (attributes[key] as? JsonPrimitive)?.contentOrNull.orEmpty()

@Composable
internal fun ConsoleIntroSurface(
    components: List<Component>,
    renderer: Renderer,
    compact: Boolean,
    enabled: Boolean,
) {
    LazyColumn(Modifier.fillMaxSize().padding(if (compact) 16.dp else 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        itemsIndexed(components) { _, component -> ConsoleIntroRow(component, renderer, compact, enabled) }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ConsoleIntroRow(
    component: Component,
    renderer: Renderer,
    compact: Boolean,
    enabled: Boolean,
) {
    val colors = MaterialTheme.colorScheme
    when (component.type) {
        "text" -> {
            val heading = component.textAttribute("variant") == "h3"
            Text(
                if (heading) component.textAttribute("content").uppercase() else component.textAttribute("content"),
                color = if (heading) colors.onSurfaceVariant else colors.onSurface,
                fontSize = if (heading) 12.sp else 14.sp,
                fontWeight = if (heading) FontWeight.Bold else FontWeight.Normal,
            )
        }
        "card" -> {
            val copy: @Composable () -> Unit = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(component.textAttribute("title"), color = colors.onSurface, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    component.children.filter { it.type == "text" }.forEach {
                        Text(
                            it.textAttribute("content"),
                            color = colors.onSurfaceVariant,
                            fontSize = 12.sp,
                        )
                    }
                }
            }
            val actions: @Composable () -> Unit = {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    component.children.flatMap {
                        it.children
                    }.filter { it.type == "button" }.forEach { ConsoleIntroButton(it, renderer, enabled, component.textAttribute("title")) }
                }
            }
            if (compact) {
                Column(
                    Modifier.fillMaxWidth().border(1.dp, colors.outline, RoundedCornerShape(10.dp)).padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    copy()
                    actions()
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().border(1.dp, colors.outline, RoundedCornerShape(10.dp)).padding(14.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Column(Modifier.weight(1f)) { copy() }
                    actions()
                }
            }
        }
        "list" ->
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                (component.attributes["items"] as? JsonArray)?.forEach {
                    (it as? JsonPrimitive)?.contentOrNull?.let {
                            label ->
                        Text(
                            label,
                            color = colors.onSurfaceVariant,
                            fontSize = 12.sp,
                            modifier =
                                Modifier.border(
                                    1.dp,
                                    colors.outline,
                                    RoundedCornerShape(20.dp),
                                ).padding(horizontal = 10.dp, vertical = 4.dp),
                        )
                    }
                }
            }
        "button" -> ConsoleIntroButton(component, renderer, enabled)
        else -> renderer.render(component)
    }
}

@Composable
private fun ConsoleIntroButton(
    component: Component,
    renderer: Renderer,
    enabled: Boolean,
    scenario: String? = null,
) {
    val action = component.textAttribute("action")
    val payload = component.attributes["payload"] as? JsonObject ?: JsonObject(emptyMap())
    ConsoleButton(
        component.textAttribute("label"),
        {
            renderer.emit.event(action, payload)
        },
        Modifier.semantics {
            contentDescription = listOfNotNull(component.textAttribute("label"), scenario).joinToString(": ")
        },
        primary = component.textAttribute("variant") == "primary",
        enabled = enabled && component.attributes["disabled"] != JsonPrimitive(true) && action.isNotBlank(),
    )
}
