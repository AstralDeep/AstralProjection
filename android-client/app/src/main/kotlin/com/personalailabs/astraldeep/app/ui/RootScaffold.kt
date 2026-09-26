// Compose app shell: top bar, connection/banner strips, and the Settings menu rendered from the server-owned
// ChromeMenuModel so every client matches. Hosted by MainActivity; a pinned mandatory surface locks
// navigation except sign-out.

package com.personalailabs.astraldeep.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.personalailabs.astraldeep.app.R
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.ui.theme.AstralWebStyle
import com.personalailabs.astraldeep.core.chrome.ChromeMenuModel
import com.personalailabs.astraldeep.core.chrome.MenuItem
import com.personalailabs.astraldeep.core.chrome.TopBarControl
import kotlinx.serialization.json.JsonObject

@Composable
fun RootScaffold(
    vm: AppViewModel,
    renderer: Renderer,
    onSignOut: () -> Unit,
    onWorkspaceAction: (TopBarControl) -> Unit,
) {
    CompositionLocalProvider(LocalViewportInteraction provides vm::viewportInteraction) {
        RootScaffoldContent(vm, renderer, onSignOut, onWorkspaceAction)
    }
}

@Composable
private fun RootScaffoldContent(
    vm: AppViewModel,
    renderer: Renderer,
    onSignOut: () -> Unit,
    onWorkspaceAction: (TopBarControl) -> Unit,
) {
    val state by vm.state.collectAsStateWithLifecycle()
    if (state.console != null && state.consolePresentation != null) {
        CompositionLocalProvider(LocalConsoleControlHeight provides maxOf(32.0, state.consolePresentation!!.minimumControlHeight).dp) {
            ConsoleShell(vm, renderer, onSignOut, onWorkspaceAction)
        }
        return
    }
    // Intentionally empty: blocks Back while the mandatory surface is pinned
    BackHandler(enabled = state.mandatorySurface) {}
    Scaffold(
        topBar = {
            AstralTopBar(
                model = state.chromeMenu,
                workspace = workspaceControls(state),
                onWorkspaceAction = onWorkspaceAction,
                navigationLocked = state.mandatorySurface,
                onNewChat = {
                    vm.newChat()
                    vm.goTo(Screen.Chat)
                },
                onRecentChats = { vm.goTo(Screen.History) },
                onOpenItem = vm::openMenuItem,
                onOpenSurface = { surface, params -> vm.openSurface(surface, params) },
                onSignOut = onSignOut,
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding()) {
            connectionStripLabel(state.connection, state.everConnected)?.let { ConnectionStrip(it) }
            state.banner?.let {
                BannerBar(
                    text = it,
                    isError = state.bannerKind == "error",
                    onDismiss = vm::dismissBanner,
                    onRetry = if (state.viewportRefreshFailed) vm::retryViewportRefresh else null,
                )
            }
            Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
                when (state.screen) {
                    Screen.Chat -> AdaptiveShell(vm, renderer)
                    Screen.Agents ->
                        AgentsScreen(
                            state.agents,
                            state.agentsLoading,
                            vm::setAgentEnabled,
                            vm::setToolEnabled,
                            vm::enableRecommended,
                        )
                    Screen.History -> HistoryScreen(state.history, state.historyLoading, vm::openChat, state.historyTitle)
                    Screen.Audit -> AuditScreen(state.audit, state.auditLoading)
                    Screen.Surface ->
                        SurfaceScreen(
                            surface = state.pendingSurface,
                            surfaceKey = state.pendingSurfaceKey,
                            renderer = renderer,
                            onRetry = vm::retryPendingSurface,
                            requestGeneration = state.privateSurfaceRequest?.requestGeneration,
                            loadFailed = state.privateSurfaceFailed,
                            onTimeout = vm::timeoutPrivateSurface,
                        )
                }
            }
        }
    }
}

@Composable
internal fun ConnectionStrip(label: String) {
    Surface(color = MaterialTheme.colorScheme.surfaceVariant, modifier = Modifier.fillMaxWidth()) {
        Text(
            label,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 12.sp,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 5.dp),
        )
    }
}

@Composable
internal fun BannerBar(
    text: String,
    isError: Boolean,
    onDismiss: () -> Unit,
    onRetry: (() -> Unit)? = null,
) {
    val bg = if (isError) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceVariant
    val fg = if (isError) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurface
    Surface(color = bg, modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(text, color = fg, fontSize = 13.sp, modifier = Modifier.weight(1f))
            onRetry?.let { retry ->
                androidx.compose.material3.TextButton(onClick = retry) { Text("Retry") }
            }
            Text(
                "✕",
                color = fg,
                fontSize = 14.sp,
                modifier =
                    Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .clickable(onClick = onDismiss)
                        .padding(horizontal = 8.dp, vertical = 2.dp),
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AstralTopBar(
    model: ChromeMenuModel?,
    workspace: List<TopBarControl> = emptyList(),
    onWorkspaceAction: (TopBarControl) -> Unit = {},
    navigationLocked: Boolean,
    onNewChat: () -> Unit,
    onRecentChats: () -> Unit,
    onOpenItem: (MenuItem) -> Unit,
    onOpenSurface: (String, JsonObject) -> Unit,
    onSignOut: () -> Unit,
) {
    Surface(color = MaterialTheme.colorScheme.surface, tonalElevation = 2.dp) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Image(
                painter = painterResource(R.drawable.app_icon),
                contentDescription = "AstralDeep",
                modifier = Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)),
            )
            FlowRow(
                modifier = Modifier.weight(1f),
                horizontalArrangement = Arrangement.spacedBy(2.dp, Alignment.End),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                NewChatButton(enabled = !navigationLocked, onClick = onNewChat)
                IconButton(
                    enabled = !navigationLocked,
                    onClick = onRecentChats,
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp),
                ) {
                    Icon(painterResource(R.drawable.ic_chat), "Recent chats", modifier = Modifier.size(22.dp))
                }
                model?.topbar?.forEach { control ->
                    when (control.kind) {
                        "action" ->
                            topBarActionView(control)?.let { view ->
                                IconButton(enabled = !navigationLocked, onClick = {
                                    onOpenSurface(view.surface, view.params)
                                }, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)) {
                                    Icon(painterResource(topBarActionIcon(view.icon)), view.label, modifier = Modifier.size(22.dp))
                                }
                            }
                        "workspace_action" ->
                            if (control in workspace) {
                                IconButton(
                                    enabled = !navigationLocked,
                                    onClick = { onWorkspaceAction(control) },
                                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp),
                                ) {
                                    Icon(
                                        painterResource(
                                            if (control.operation == "export_canvas") {
                                                R.drawable.ic_workspace_export
                                            } else {
                                                R.drawable.ic_workspace_share
                                            },
                                        ),
                                        control.label,
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.size(22.dp),
                                    )
                                }
                            }
                        "menu" ->
                            if (control == model.settingsControl) {
                                SettingsMenu(model, onOpenItem, onSignOut, navigationLocked)
                            }
                    }
                }
                if (model?.settingsControl == null) SettingsMenu(model, onOpenItem, onSignOut, navigationLocked)
            }
        }
    }
}

private fun topBarActionIcon(icon: TopBarIcon): Int =
    when (icon) {
        TopBarIcon.SPARKLE -> R.drawable.ic_sparkle
        TopBarIcon.HISTORY -> R.drawable.ic_history
        TopBarIcon.GENERIC -> R.drawable.ic_menu
    }

@Composable
internal fun SettingsMenu(
    model: ChromeMenuModel?,
    onOpenItem: (MenuItem) -> Unit,
    onSignOut: () -> Unit,
    navigationLocked: Boolean = false,
) {
    var open by remember { mutableStateOf(false) }
    ViewportInteraction(open)
    Box {
        IconButton(onClick = { open = true }, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)) {
            Icon(
                painter = painterResource(R.drawable.ic_settings),
                contentDescription = "Settings",
                tint = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.size(22.dp),
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            model?.menu?.forEach { group ->
                SectionHeader(group.label)
                group.items.forEach { item ->
                    DropdownMenuItem(
                        enabled = !navigationLocked,
                        text = { Text(item.label, color = MaterialTheme.colorScheme.onSurface) },
                        onClick = {
                            open = false
                            onOpenItem(item)
                        },
                    )
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outline)
            DropdownMenuItem(
                text = { Text(model?.signout?.label ?: "Sign out", color = MaterialTheme.colorScheme.error) },
                leadingIcon = {
                    Icon(
                        painter = painterResource(R.drawable.ic_signout),
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.error,
                        modifier = Modifier.size(20.dp),
                    )
                },
                onClick = {
                    open = false
                    onSignOut()
                },
            )
        }
    }
}

@Composable
private fun SectionHeader(label: String) {
    Text(
        label.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

@Composable
internal fun NewChatButton(
    enabled: Boolean,
    onClick: () -> Unit,
    showLabel: Boolean = LocalConfiguration.current.screenWidthDp >= 640,
) {
    Box(
        Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "New chat" }
            .testTag("new-chat-button"),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            Modifier.heightIn(min = 38.dp)
                .alpha(if (enabled) 1f else 0.5f)
                .border(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.13f), RoundedCornerShape(8.dp))
                .padding(horizontal = 11.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_plus),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.size(18.dp),
            )
            if (showLabel) Text("New chat", color = MaterialTheme.colorScheme.onSurface, style = AstralWebStyle.NewChatLabel)
        }
    }
}
