// Registers the input/code/file primitives (forms, selects, checklists, theme picker, color picker, file
// actions); enforces the wire contract that option keys — never labels — round-trip verbatim to the chrome_*
// handlers.

package com.personalailabs.astraldeep.app.render.renderers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.personalailabs.astraldeep.app.render.Download
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.LocalGuidanceNotes
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.ThemeSink
import com.personalailabs.astraldeep.app.ui.theme.AstralMono
import com.personalailabs.astraldeep.app.ui.theme.channelSwatchOptions
import com.personalailabs.astraldeep.app.ui.theme.hexToColor
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

private const val SUBMIT_FAILSAFE_MS = 12_000L

fun Renderer.registerInputRenderers(): Renderer =
    apply {
        register("input") { c -> InputPrimitive(c, emit) }
        register("param_picker") { c -> ParamPickerPrimitive(c, emit) }
        register("color_picker") { c -> ColorPickerPrimitive(c, emit, theme) }
        register("theme_apply") { c -> ThemeApplyPrimitive(c, theme) }
        register("code") { c -> CodePrimitive(c) }
        register("file_upload") { c -> FileActionButton(c, emit, c.str("label") ?: "Upload") }
        register("file_download") { c -> FileDownloadPrimitive(c, download) }
        register("download_card") { c -> FileDownloadPrimitive(c, download) }
    }

@Composable
private fun InputPrimitive(
    c: Component,
    emit: Emit,
) {
    var value by remember { mutableStateOf(c.str("value").orEmpty()) }
    val action = c.str("action")
    OutlinedTextField(
        value = value,
        onValueChange = { value = it },
        modifier = Modifier.fillMaxWidth(),
        label = c.str("label")?.let { { Text(it) } },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        keyboardActions =
            KeyboardActions(
                onDone = {
                    dispatchInputDone(action, value, emit) {
                        defaultKeyboardAction(ImeAction.Done)
                    }
                },
            ),
    )
}

internal fun dispatchInputDone(
    action: String?,
    value: String,
    emit: Emit,
    defaultKeyboardAction: () -> Unit,
) {
    try {
        if (action != null) {
            emit.event(action, buildJsonObject { put("value", value) })
        }
    } finally {
        defaultKeyboardAction()
    }
}

internal fun fieldStr(
    f: JsonObject,
    key: String,
): String? = (f[key] as? JsonPrimitive)?.contentOrNull

internal fun fieldKind(f: JsonObject): String = fieldStr(f, "kind") ?: "text"

// Options are server-owned; submit the key verbatim, never relabel
internal fun fieldOptions(f: JsonObject): List<String> =
    (f["options"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList()

internal fun rendersAsDropdown(f: JsonObject): Boolean = fieldKind(f) == "select" && fieldOptions(f).isNotEmpty()

internal fun fieldIsVisible(
    f: JsonObject,
    texts: Map<String, String>,
    guidanceNotes: Boolean = false,
): Boolean {
    val vw = f["visible_when"] as? JsonObject ?: return !guidanceNotes || "visible_when" !in f
    if (guidanceNotes) {
        return vw.isNotEmpty() &&
            vw.all { (controller, expected) ->
                expected is JsonPrimitive && expected.isString && texts[controller] == expected.content
            }
    }
    val controller = fieldStr(vw, "field") ?: return true
    val expected = fieldStr(vw, "equals") ?: return true
    val current = texts[controller] ?: fieldStr(vw, "default") ?: ""
    return current == expected
}

internal fun selectInitial(
    default: String?,
    options: List<String>,
): String =
    when {
        options.isEmpty() -> default.orEmpty()
        default != null && default in options -> default
        else -> options.first()
    }

internal fun checklistInitial(
    default: JsonElement?,
    options: List<String>,
): Set<String> =
    (default as? JsonArray)
        ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        ?.filterTo(mutableSetOf()) { it in options } ?: emptySet()

internal fun initialTexts(fields: List<JsonObject>): Map<String, String> =
    fields.mapNotNull { f ->
        val name = fieldStr(f, "name") ?: return@mapNotNull null
        when (fieldKind(f)) {
            "boolean", "checklist" -> null
            "select" -> name to selectInitial(fieldStr(f, "default"), fieldOptions(f))
            else -> name to (fieldStr(f, "default") ?: "")
        }
    }.toMap()

internal fun initialBools(fields: List<JsonObject>): Map<String, Boolean> =
    fields.mapNotNull { f ->
        val name = fieldStr(f, "name") ?: return@mapNotNull null
        if (fieldKind(f) == "boolean") name to ((f["default"] as? JsonPrimitive)?.booleanOrNull ?: false) else null
    }.toMap()

internal fun initialChecks(fields: List<JsonObject>): Map<String, Set<String>> =
    fields.mapNotNull { f ->
        val name = fieldStr(f, "name") ?: return@mapNotNull null
        if (fieldKind(f) == "checklist") name to checklistInitial(f["default"], fieldOptions(f)) else null
    }.toMap()

internal fun collectFields(
    fields: List<JsonObject>,
    texts: Map<String, String>,
    bools: Map<String, Boolean>,
    checks: Map<String, Set<String>>,
    extra: JsonObject = JsonObject(emptyMap()),
): JsonObject =
    buildJsonObject {
        putJsonObject("fields") {
            fields.forEach { f ->
                val name = fieldStr(f, "name") ?: return@forEach
                when (fieldKind(f)) {
                    "boolean" -> put(name, bools[name] ?: false)
                    "checklist" -> {
                        val on = checks[name] ?: emptySet()
                        putJsonArray(name) { fieldOptions(f).filter { it in on }.forEach { add(it) } }
                    }
                    else -> put(name, texts[name] ?: "")
                }
            }
        }
        extra.forEach { (k, v) -> put(k, v) }
    }

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ParamPickerPrimitive(
    c: Component,
    emit: Emit,
) {
    val fields = c.arr("fields")?.mapNotNull { it as? JsonObject } ?: emptyList()
    val texts = remember(c) { mutableStateMapOf<String, String>().apply { putAll(initialTexts(fields)) } }
    val bools = remember(c) { mutableStateMapOf<String, Boolean>().apply { putAll(initialBools(fields)) } }
    val checks = remember(c) { mutableStateMapOf<String, Set<String>>().apply { putAll(initialChecks(fields)) } }

    fun collect(extra: JsonObject) = collectFields(fields, texts, bools, checks, extra)

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            c.str("title")?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.titleSmall)
            }
            fields.forEach { f ->
                val name = fieldStr(f, "name") ?: return@forEach
                // Hidden fields still submit their state; only rendering stops
                if (!fieldIsVisible(f, texts, guidanceNotes = LocalGuidanceNotes.current)) return@forEach
                val label = fieldStr(f, "label") ?: name
                val kind = fieldKind(f)
                when {
                    kind == "boolean" ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Switch(checked = bools[name] ?: false, onCheckedChange = { bools[name] = it })
                            Text(label, modifier = Modifier.padding(start = 8.dp))
                        }
                    kind == "checklist" ->
                        ChecklistField(
                            label = label,
                            options = fieldOptions(f),
                            selected = checks[name] ?: emptySet(),
                            onToggle = { opt ->
                                val on = checks[name] ?: emptySet()
                                checks[name] = if (opt in on) on - opt else on + opt
                            },
                        )
                    rendersAsDropdown(f) ->
                        SelectField(
                            label = label,
                            options = fieldOptions(f),
                            selected = texts[name] ?: "",
                            onSelect = { texts[name] = it },
                        )
                    else ->
                        OutlinedTextField(
                            value = texts[name] ?: "",
                            onValueChange = { texts[name] = it },
                            modifier = Modifier.fillMaxWidth(),
                            label = { Text(label) },
                            singleLine = kind != "textarea",
                            visualTransformation =
                                if (kind == "password") PasswordVisualTransformation() else VisualTransformation.None,
                        )
                }
                fieldStr(f, "help")?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            val actions = c.arr("actions")?.mapNotNull { it as? JsonObject } ?: emptyList()
            var submitting by remember(c) { mutableStateOf(false) }
            if (submitting) {
                LaunchedEffect(Unit) {
                    kotlinx.coroutines.delay(SUBMIT_FAILSAFE_MS)
                    submitting = false
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text("Saving…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (actions.isNotEmpty()) {
                        actions.forEach { a ->
                            val action = (a["action"] as? JsonPrimitive)?.contentOrNull ?: return@forEach
                            val alabel = (a["label"] as? JsonPrimitive)?.contentOrNull ?: "Submit"
                            val extra = (a["payload"] as? JsonObject) ?: JsonObject(emptyMap())
                            Button(onClick = {
                                submitting = true
                                emit.event(action, collect(extra))
                            }) { Text(alabel) }
                        }
                    } else {
                        c.str("submit_action")?.let { sa ->
                            val extra = (c.attributes["submit_payload"] as? JsonObject) ?: JsonObject(emptyMap())
                            Button(onClick = {
                                submitting = true
                                emit.event(sa, collect(extra))
                            }) {
                                Text(c.str("submit_label") ?: "Save")
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SelectField(
    label: String,
    options: List<String>,
    selected: String,
    onSelect: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Box {
            Row(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(4.dp))
                        .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(4.dp))
                        .clickable(role = Role.DropdownList) { open = true }
                        .padding(horizontal = 12.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(selected, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                Text("▾", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                options.forEach { opt ->
                    DropdownMenuItem(
                        text = { Text(opt, color = MaterialTheme.colorScheme.onSurface) },
                        onClick = {
                            open = false
                            onSelect(opt)
                        },
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ChecklistField(
    label: String,
    options: List<String>,
    selected: Set<String>,
    onToggle: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (options.isEmpty()) {
            Text(
                "(no options provided)",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                options.forEach { opt ->
                    FilterChip(
                        selected = opt in selected,
                        onClick = { onToggle(opt) },
                        label = { Text(opt) },
                    )
                }
            }
        }
    }
}

@Composable
private fun ColorPickerPrimitive(
    c: Component,
    emit: Emit,
    theme: ThemeSink,
) {
    val key = c.str("color_key").orEmpty()
    val label = c.str("label") ?: key
    var current by remember(c) { mutableStateOf(c.str("value") ?: "") }
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .clickable(enabled = key.isNotBlank()) { open = true }
                    .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            ColorSwatch(current)
            Text(label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Text(
                current,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            channelSwatchOptions(key, current).forEach { hex ->
                DropdownMenuItem(
                    text = {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            ColorSwatch(hex)
                            Text(hex, color = MaterialTheme.colorScheme.onSurface)
                        }
                    },
                    onClick = {
                        open = false
                        current = hex
                        val spec =
                            buildJsonObject {
                                put("color_key", key)
                                put("color_value", hex)
                            }
                        theme.apply(spec)
                        emit.event("save_theme", buildJsonObject { put("theme", spec) })
                    },
                )
            }
        }
    }
}

@Composable
private fun ColorSwatch(hex: String) {
    val color = hexToColor(hex) ?: MaterialTheme.colorScheme.surfaceVariant
    Box(
        modifier =
            Modifier
                .size(18.dp)
                .clip(RoundedCornerShape(4.dp))
                .background(color)
                .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(4.dp)),
    )
}

@Composable
private fun ThemeApplyPrimitive(
    c: Component,
    theme: ThemeSink,
) {
    LaunchedEffect(c) { theme.apply(c.attributes) }
}

@Composable
private fun CodePrimitive(c: Component) {
    Surface(color = MaterialTheme.colorScheme.surfaceVariant, modifier = Modifier.fillMaxWidth()) {
        Text(
            text = c.str("content") ?: c.str("code").orEmpty(),
            fontFamily = AstralMono,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(12.dp),
        )
    }
}

@Composable
private fun FileActionButton(
    c: Component,
    emit: Emit,
    label: String,
) {
    val action = c.str("action")
    Button(
        onClick = { if (action != null) emit.event(action, c.payload()) },
        enabled = action != null,
    ) { Text(label) }
}

@Composable
private fun FileDownloadPrimitive(
    c: Component,
    download: Download,
) {
    val url = c.str("url") ?: c.str("download_url")
    val filename = c.str("filename") ?: c.str("title") ?: "download"
    val label = c.str("label") ?: "Download $filename"
    Button(
        onClick = { if (url != null) download.file(url, filename) },
        enabled = url != null,
    ) { Text(label) }
}
