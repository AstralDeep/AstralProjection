package com.personalailabs.astraldeep.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.personalailabs.astraldeep.app.ui.theme.AstralSans
import com.personalailabs.astraldeep.core.protocol.ChatSummary
import java.util.Locale

private val HistoryTextStyle = TextStyle(fontFamily = AstralSans)

@Composable
internal fun HistoryHeader(
    title: String,
    count: Int,
) {
    val colors = MaterialTheme.colorScheme
    Row(
        Modifier.fillMaxWidth().padding(start = 6.dp, end = 6.dp, top = 2.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            ChatSummary.displayText(title).ifEmpty { "Recent chats" }.uppercase(Locale.ROOT),
            style = HistoryTextStyle,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.88.sp,
            color = colors.onSurfaceVariant,
        )
        Text(
            count.toString(),
            style = HistoryTextStyle,
            fontSize = 11.sp,
            lineHeight = 16.5.sp,
            fontWeight = FontWeight.SemiBold,
            color = colors.onSurface.copy(alpha = 0.78f),
            modifier =
                Modifier.background(colors.onSurface.copy(alpha = 0.06f), RoundedCornerShape(999.dp))
                    .padding(horizontal = 8.dp, vertical = 1.dp),
        )
    }
}

@Composable
internal fun HistoryRow(
    chat: ChatSummary,
    onOpen: (String) -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val hovered by interaction.collectIsHoveredAsState()
    val shape = RoundedCornerShape(10.dp)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(shape)
            .background(if (hovered) colors.onSurface.copy(alpha = 0.04f) else Color.Transparent)
            .border(
                if (focused) 2.dp else 1.dp,
                colors.primary.copy(
                    alpha =
                        if (focused) {
                            0.75f
                        } else if (hovered) {
                            0.28f
                        } else {
                            0f
                        },
                ),
                shape,
            )
            .hoverable(interaction)
            .clickable(
                interactionSource = interaction,
                indication = null,
                role = Role.Button,
                onClickLabel = "Open chat: ${chat.displayTitle}",
            ) { onOpen(chat.id) }
            .padding(1.dp).padding(horizontal = 8.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        val icon = chat.serverIcon.orEmpty()
        val iconShape = RoundedCornerShape(8.dp)
        val iconBackground =
            if (icon.isNotEmpty()) {
                Brush.linearGradient(listOf(colors.primary.copy(alpha = 0.22f), colors.secondary.copy(alpha = 0.14f)))
            } else {
                Brush.linearGradient(List(2) { colors.onSurface.copy(alpha = 0.05f) })
            }
        Box(
            Modifier.size(28.dp).background(iconBackground, iconShape)
                .border(1.dp, if (icon.isEmpty()) colors.onSurface.copy(alpha = 0.08f) else colors.primary.copy(alpha = 0.20f), iconShape)
                .clearAndSetSemantics {},
            contentAlignment = Alignment.Center,
        ) {
            Text(icon, style = HistoryTextStyle, fontSize = 15.sp, lineHeight = 15.sp)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    chat.displayTitle,
                    style = HistoryTextStyle,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).alignByBaseline(),
                )
                val time = chat.relativeTime()
                if (time.isNotEmpty()) {
                    Text(
                        time,
                        fontSize = 11.sp,
                        color = colors.onSurfaceVariant,
                        style = HistoryTextStyle.copy(fontFeatureSettings = "tnum"),
                        modifier = Modifier.alignByBaseline(),
                    )
                }
            }
            if (chat.displayPreview.isNotEmpty()) {
                Text(
                    chat.displayPreview,
                    style = HistoryTextStyle,
                    fontSize = 12.sp,
                    color = colors.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (chat.hasSavedComponents) {
            Text(
                "★",
                style = HistoryTextStyle,
                fontSize = 11.sp,
                lineHeight = 11.sp,
                color = colors.tertiary,
                modifier = Modifier.clearAndSetSemantics { contentDescription = "Has saved components" },
            )
        }
    }
}

@Composable
internal fun HistoryEmpty() {
    val colors = MaterialTheme.colorScheme
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            "💬",
            style = HistoryTextStyle,
            fontSize = 22.sp,
            color =
                colors.onSurface.copy(
                    alpha = 0.7f,
                ),
            modifier =
                Modifier.clearAndSetSemantics {
                },
        )
        Text(
            "No conversations yet.",
            style = HistoryTextStyle,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = colors.onSurface.copy(alpha = 0.78f),
        )
        Text("Start one below.", style = HistoryTextStyle, fontSize = 11.sp, color = colors.onSurfaceVariant)
    }
}
