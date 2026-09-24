// Compose screens for Agents, History, Audit, and SDUI settings surfaces (chrome_surface), reusing the chat
// canvas's component renderer. surfaceViewState and connectionStripLabel are pure state rules also used by
// AppViewModel.

package com.personalailabs.astraldeep.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.personalailabs.astraldeep.app.render.LocalGuidanceNotes
import com.personalailabs.astraldeep.app.render.LocalWorkReadText
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.rest.AuditEvent
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.ui.theme.AstralMono
import com.personalailabs.astraldeep.core.protocol.Agent
import com.personalailabs.astraldeep.core.protocol.ChatSummary
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.isPrivateChromeSurface
import kotlinx.coroutines.delay
import java.util.concurrent.atomic.AtomicInteger

@Composable
fun AgentsScreen(
    agents: List<Agent>,
    loading: Boolean,
    onToggleAgent: (Agent, Boolean) -> Unit,
    onToggleTool: (Agent, String, Boolean) -> Unit,
    onEnableRecommended: () -> Unit,
) {
    if (loading && agents.isEmpty()) {
        SkeletonList()
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Agents", style = MaterialTheme.typography.titleLarge)
                Button(onClick = onEnableRecommended) { Text("Enable recommended") }
            }
        }
        items(agents, key = { it.id }) { agent -> AgentCard(agent, onToggleAgent, onToggleTool) }
        if (agents.isEmpty()) {
            item { Text("No agents loaded yet.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

@Composable
private fun AgentCard(
    agent: Agent,
    onToggleAgent: (Agent, Boolean) -> Unit,
    onToggleTool: (Agent, String, Boolean) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val agentEnabled = agent.permissions.values.any { it }
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Column(modifier = Modifier.weight(1f).clickable { expanded = !expanded }) {
                    Text(
                        (if (expanded) "▼ " else "▶ ") + agent.name,
                        style = MaterialTheme.typography.titleMedium,
                    )
                    if (agent.description.isNotBlank()) {
                        Text(
                            agent.description,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    val enabled = agent.permissions.values.count { it }
                    Text(
                        "$enabled / ${agent.tools.size} tools enabled",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = agentEnabled,
                    onCheckedChange = { onToggleAgent(agent, it) },
                    modifier =
                        Modifier
                            .testTag("agent-toggle:${agent.id}")
                            .semantics {
                                contentDescription = "Enable ${agent.name} agent"
                                stateDescription = if (agentEnabled) "Enabled" else "Disabled"
                            }.focusable(),
                )
            }
            if (expanded) {
                if (agent.tools.isEmpty()) {
                    Text(
                        "This agent exposes no tools.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                agent.tools.forEach { tool ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(tool, style = MaterialTheme.typography.bodyMedium)
                            agent.toolDescriptions[tool]?.takeIf { it.isNotBlank() }?.let {
                                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        Switch(
                            checked = agent.permissions[tool] ?: false,
                            onCheckedChange = { onToggleTool(agent, tool, it) },
                            modifier =
                                Modifier
                                    .testTag("agent-tool-toggle:${agent.id}:$tool")
                                    .semantics {
                                        contentDescription = "Enable $tool for ${agent.name}"
                                        stateDescription =
                                            if (agent.permissions[tool] == true) "Enabled" else "Disabled"
                                    }.focusable(),
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun HistoryScreen(
    chats: List<ChatSummary>,
    loading: Boolean,
    onOpen: (String) -> Unit,
    title: String = "Recent chats",
) {
    if (loading && chats.isEmpty()) {
        SkeletonList()
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        if (chats.isEmpty()) {
            item { HistoryEmpty() }
        } else {
            item { HistoryHeader(title, chats.size) }
            itemsIndexed(chats, key = { index, chat -> "$index:${chat.id}" }) { _, chat -> HistoryRow(chat, onOpen) }
        }
    }
}

@Composable
fun AuditScreen(
    events: List<AuditEvent>,
    loading: Boolean,
) {
    if (loading && events.isEmpty()) {
        SkeletonList()
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(events) { event -> AuditCard(event) }
        if (events.isEmpty()) {
            item { Text("No audit events.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

@Composable
private fun AuditCard(event: AuditEvent) {
    var expanded by remember { mutableStateOf(false) }
    Card(modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded }) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = listOfNotNull(event.eventClass, event.action).joinToString(" · ").ifBlank { "event" },
                style = MaterialTheme.typography.titleSmall,
            )
            Text(
                text = listOfNotNull(event.outcome, event.recordedAt).joinToString("  "),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (expanded) {
                event.outcomeDetail?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                event.detail?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, fontFamily = AstralMono)
                }
                event.id?.let {
                    Text("id: $it", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (event.outcomeDetail == null && event.detail == null) {
                    Text(
                        "No additional detail recorded.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/** The three states of an SDUI settings surface while/after it is requested (T039). */
enum class SurfaceViewState { Loaded, Loading, TimedOut }

fun surfaceViewState(
    hasSurface: Boolean,
    timedOut: Boolean,
): SurfaceViewState =
    when {
        hasSurface -> SurfaceViewState.Loaded
        timedOut -> SurfaceViewState.TimedOut
        else -> SurfaceViewState.Loading
    }

private const val SURFACE_TIMEOUT_MS = 10_000L

@Composable
fun SurfaceScreen(
    surface: Inbound.ChromeSurface?,
    surfaceKey: String,
    renderer: Renderer,
    onRetry: () -> Unit,
    requestGeneration: String? = null,
    loadFailed: Boolean = false,
    onTimeout: (String?) -> Unit = {},
) {
    var attempt by remember(surfaceKey, requestGeneration) { mutableStateOf(0) }
    var timedOut by remember(surfaceKey, requestGeneration) { mutableStateOf(false) }
    val hasSurface = surface != null
    LaunchedEffect(surfaceKey, requestGeneration, attempt, hasSurface) {
        if (!hasSurface) {
            timedOut = false
            delay(SURFACE_TIMEOUT_MS)
            onTimeout(requestGeneration)
            timedOut = true
        }
    }
    when (surfaceViewState(hasSurface, timedOut || loadFailed)) {
        SurfaceViewState.Loaded -> SurfaceContent(surface!!, renderer)
        SurfaceViewState.Loading -> SkeletonList()
        SurfaceViewState.TimedOut ->
            SurfaceTimeout(
                onRetry = {
                    attempt += 1
                    onRetry()
                },
            )
    }
}

private val surfaceRevision = AtomicInteger()

@Composable
private fun SurfaceContent(
    surface: Inbound.ChromeSurface,
    renderer: Renderer,
) {
    // Keys items by revision: equal content would else keep stale state
    val revision = remember(surface) { surfaceRevision.incrementAndGet() }
    val listState = rememberLazyListState()
    LaunchedEffect(revision) { listState.scrollToItem(0) }
    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "$revision-title") {
            Text(
                surface.title.ifBlank { "Settings" },
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
        itemsIndexed(surface.components, key = { i, _ -> "$revision-$i" }) { _, comp ->
            CompositionLocalProvider(
                LocalWorkReadText provides isPrivateChromeSurface(surface.surfaceKey),
                LocalGuidanceNotes provides (surface.surfaceKey == "guidance"),
            ) {
                renderer.render(comp)
            }
        }
    }
}

@Composable
private fun SurfaceTimeout(onRetry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            "Couldn't load this settings screen",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
        )
        Text(
            "The server didn't send it in time. Check your connection and try again.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
        )
        Button(onClick = onRetry) { Text("Retry") }
    }
}

fun connectionLabel(c: ConnectionState): String =
    when (c) {
        ConnectionState.Connected -> "Connected"
        ConnectionState.Connecting -> "Connecting…"
        ConnectionState.Disconnected -> "Disconnected"
        ConnectionState.AuthRequired -> "Re-authenticating…"
    }

fun connectionStripLabel(
    c: ConnectionState,
    everConnected: Boolean,
): String? =
    when {
        !everConnected || c == ConnectionState.Connected -> null
        c == ConnectionState.AuthRequired -> connectionLabel(c)
        else -> "Reconnecting…"
    }
