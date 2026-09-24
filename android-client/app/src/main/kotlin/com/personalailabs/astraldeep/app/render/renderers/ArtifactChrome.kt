// Renders the artifact provenance badge and refine dialog: badges reflect only the server-stamped field,
// never client-derived trust; refine sends component_refine for the server to revalidate.

package com.personalailabs.astraldeep.app.render.renderers

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.personalailabs.astraldeep.app.ui.ComponentActionHandler
import com.personalailabs.astraldeep.core.chrome.ComponentChrome
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

enum class Provenance(
    val label: String,
    val glyph: String,
) {
    Grounded("tool data", "✓"),
    Estimated("estimated", "≈"),
    Generated("AI-generated", "✦"),
}

private val PROVENANCE_SKIP_TYPES = setOf("divider", "skeleton")

private val PROVENANCE_GROUNDED = setOf("grounded", "verified", "tool", "search", "source")
private val PROVENANCE_ESTIMATED = setOf("estimated", "uncertain", "approx", "low_confidence")
private val PROVENANCE_GENERATED = setOf("generated", "model", "ai")

// Trust badges are server-stamped only — never derived client-side
internal fun provenanceOf(c: Component): Provenance? {
    if (c.type.trim().lowercase() in PROVENANCE_SKIP_TYPES) return null
    val kind = c.str("provenance")?.trim()?.lowercase()?.takeIf { it.isNotBlank() } ?: return null
    return when {
        kind in PROVENANCE_GROUNDED -> Provenance.Grounded
        kind in PROVENANCE_ESTIMATED -> Provenance.Estimated
        kind in PROVENANCE_GENERATED -> Provenance.Generated
        else -> null
    }
}

internal fun refinePayload(instruction: String): JsonObject = buildJsonObject { put("instruction", instruction.trim()) }

internal fun exportFilename(
    base: String,
    ext: String,
): String {
    val safe =
        base
            .map { if (it.isLetterOrDigit() || it in "-_ .") it else '_' }
            .joinToString("")
            .trim()
            .ifBlank { "export" }
    return "${safe.take(60)}.$ext"
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ArtifactFooter(
    c: Component,
    handler: ComponentActionHandler?,
) {
    val provenance = provenanceOf(c)
    val context = handler?.context(c)
    val actions = context?.actions.orEmpty()
    val pending = handler?.pending?.collectAsStateWithLifecycle()?.value.orEmpty()
    if (provenance == null && actions.isEmpty()) return
    var dialog by remember(context) { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            provenance?.let { ProvenanceBadge(it) }
            if (context != null && pending.any { it.first == context.componentId }) CircularProgressIndicator(Modifier.size(16.dp))
        }
        FlowRow(
            modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End),
        ) {
            actions.forEach { action ->
                val busy =
                    pending.any {
                        it.second == action.kind && (it.first == context?.componentId || action.kind in setOf("csv", "share"))
                    }
                Row(
                    modifier =
                        Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                            .clickable(enabled = !busy, role = Role.Button) {
                                if (action.kind == "refine" || action.kind == "history") {
                                    dialog = action.kind
                                } else if (context != null) {
                                    handler.perform(context, action.kind)
                                }
                            }.semantics(mergeDescendants = true) {
                                contentDescription = action.title
                                if (busy) stateDescription = "In progress"
                            },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    val tone = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (busy) 0.38f else 0.7f)
                    Text(action.icon, fontSize = 10.sp, color = tone, modifier = Modifier.clearAndSetSemantics { })
                    Text(action.label, fontSize = 10.sp, color = tone)
                }
            }
        }
    }
    if (context != null && dialog == "refine" && actions.any { it.kind == "refine" }) {
        RefineDialog(onDismiss = { dialog = null }, onSubmit = { instruction ->
            dialog = null
            handler.perform(context, "refine", refinePayload(instruction))
        })
    }
    if (context != null && dialog == "history" && actions.any { it.kind == "history" }) {
        val versions = ComponentChrome.versions(c)
        AlertDialog(
            onDismissRequest = { dialog = null },
            title = { Text("Version history") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    if (versions.isEmpty()) Text("No earlier versions yet — refine the component to create one.")
                    versions.forEach { version ->
                        TextButton(
                            onClick = {
                                dialog = null
                                handler.perform(context, "history", buildJsonObject { put("version_no", version.versionNo) })
                            },
                            modifier =
                                Modifier.fillMaxWidth().semantics {
                                    contentDescription = "Restore this version" +
                                        if (version.reason.isEmpty()) "" else " (archived on ${version.reason})"
                                },
                        ) { Text(version.label) }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { dialog = null }) { Text("Done") } },
        )
    }
}

@Composable
private fun ProvenanceBadge(p: Provenance) {
    if (p == Provenance.Grounded) return
    val tone =
        when (p) {
            Provenance.Grounded -> Color(0xFF22C55E)
            Provenance.Estimated -> Color(0xFFFACC15)
            Provenance.Generated -> MaterialTheme.colorScheme.onSurfaceVariant
        }
    Row(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = "Provenance: ${p.label}" },
    ) {
        Text(p.glyph, color = tone.copy(alpha = 0.7f), fontSize = 10.sp, modifier = Modifier.clearAndSetSemantics { })
        Text(
            text = p.label,
            color = tone.copy(alpha = 0.7f),
            fontSize = 10.sp,
        )
    }
}

@Composable
private fun RefineDialog(
    onDismiss: () -> Unit,
    onSubmit: (String) -> Unit,
) {
    var instruction by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Refine this component") },
        text = {
            OutlinedTextField(
                value = instruction,
                onValueChange = { instruction = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("What should change?") },
                minLines = 2,
            )
        },
        confirmButton = {
            TextButton(enabled = instruction.isNotBlank(), onClick = { onSubmit(instruction) }) { Text("Refine") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
