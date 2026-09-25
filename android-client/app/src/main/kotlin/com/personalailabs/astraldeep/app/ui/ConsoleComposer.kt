// Presents the compact console composer while InputBar retains attachment and microphone permission handling.
// Every More action and visible voice control comes from the current server-owned offer.

package com.personalailabs.astraldeep.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.personalailabs.astraldeep.app.R
import com.personalailabs.astraldeep.app.voice.VoiceUiState
import com.personalailabs.astraldeep.core.chrome.ConsoleComposerAction
import com.personalailabs.astraldeep.core.chrome.ConsoleModel
import com.personalailabs.astraldeep.core.protocol.VoiceControl

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ConsoleComposer(
    input: String,
    onInputChange: (String) -> Unit,
    readOnly: Boolean,
    voice: VoiceUiState,
    onVoiceControl: (VoiceControl) -> Unit,
    onAttach: () -> Unit,
    onSend: () -> Unit,
    canSend: Boolean,
    console: ConsoleModel,
    background: Boolean,
    onAction: (ConsoleComposerAction) -> Unit,
) {
    var moreOpen by remember { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    val controls = voice.composer?.controls.orEmpty().filter { it.visible }
    val field: @Composable (Modifier) -> Unit = { modifier ->
        BasicTextField(
            input, onInputChange,
            modifier.border(1.dp, colors.outline, RoundedCornerShape(10.dp)).background(colors.surface, RoundedCornerShape(10.dp))
                .heightIn(min = 44.dp, max = 150.dp).padding(12.dp).testTag("chat-input")
                .semantics { contentDescription = console.label("message_placeholder") }
                .onPreviewKeyEvent { event ->
                    if (event.key == Key.Enter && event.type == KeyEventType.KeyDown && !event.isShiftPressed) {
                        if (canSend && !readOnly) onSend()
                        true
                    } else {
                        false
                    }
                },
            enabled = !readOnly,
            textStyle = MaterialTheme.typography.bodyMedium.copy(color = colors.onSurface, fontSize = 14.sp),
            maxLines = 5,
            cursorBrush = SolidColor(colors.onSurface),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { if (canSend && !readOnly) onSend() }),
            decorationBox = {
                    inner ->
                Box {
                    if (input.isEmpty()) Text(console.label("message_placeholder"), color = colors.onSurfaceVariant, fontSize = 14.sp)
                    inner()
                }
            },
        )
    }
    val actions: @Composable () -> Unit = {
        ConsoleIcon(console.label("attach"), R.drawable.ic_paperclip, !readOnly, onAttach)
        if (controls.isEmpty()) ConsoleIcon("Voice availability is being checked", R.drawable.ic_mic, false) {}
        controls.forEach { VoiceControlButton(it, voice.phase, !readOnly && it.enabled) { onVoiceControl(it) } }
        Box {
            IconButton(
                {
                    moreOpen = true
                },
                enabled = !readOnly,
                modifier =
                    Modifier.size(
                        44.dp,
                    ).background(if (background) colors.primary.copy(alpha = 0.16f) else Color.Transparent, RoundedCornerShape(8.dp)),
            ) {
                Icon(
                    painterResource(R.drawable.ic_console_more),
                    console.label("more"),
                    tint = colors.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
            DropdownMenu(moreOpen, { moreOpen = false }) {
                console.composerActions.forEach { action ->
                    DropdownMenuItem(text = {
                        Text(
                            (if (action.key == "background" && background) "✓ " else "") + action.label,
                        )
                    }, onClick = {
                        moreOpen = false
                        onAction(action)
                    })
                }
            }
        }
        IconButton(
            onSend,
            enabled = canSend && !readOnly,
            modifier =
                Modifier.size(
                    44.dp,
                ).background(
                    if (canSend && !readOnly) colors.primary else colors.surface,
                    RoundedCornerShape(10.dp),
                ).testTag("composer-send"),
        ) {
            Icon(
                painterResource(R.drawable.ic_arrow_up),
                console.label("send"),
                tint = if (canSend && !readOnly) colors.onPrimary else colors.onSurfaceVariant,
                modifier = Modifier.size(22.dp),
            )
        }
    }
    BoxWithConstraints(Modifier.fillMaxWidth().testTag("composer-surface")) {
        val controlWidth = 44 * (maxOf(1, controls.size) + 3) + 4 * (maxOf(1, controls.size) + 2)
        if (maxWidth.value >= controlWidth + 136 * LocalDensity.current.fontScale) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                field(Modifier.weight(1f).padding(end = 4.dp))
                actions()
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                field(Modifier.fillMaxWidth())
                FlowRow(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    actions()
                }
            }
        }
    }
}
