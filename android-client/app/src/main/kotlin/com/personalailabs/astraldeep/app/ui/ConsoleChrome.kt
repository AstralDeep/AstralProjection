// Renders the shared console catalog, navigation and settings using ROTE's selected geometry.
// AppViewModel validates offered actions and retains all authenticated surface and conversation state.

package com.personalailabs.astraldeep.app.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.personalailabs.astraldeep.app.R
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.ui.theme.AstralWebStyle
import com.personalailabs.astraldeep.core.chrome.ConsoleInsets
import com.personalailabs.astraldeep.core.chrome.ConsoleModel
import com.personalailabs.astraldeep.core.chrome.ConsolePresentation
import com.personalailabs.astraldeep.core.chrome.MenuItem

internal val LocalConsoleControlHeight = compositionLocalOf { 44.dp }

internal fun ConsoleModel.label(key: String) = labels[key].orEmpty()

internal fun ConsoleInsets.padding() = PaddingValues(left.dp, top.dp, right.dp, bottom.dp)

@Composable
internal fun ConsoleButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    primary: Boolean = false,
    enabled: Boolean = true,
    selected: Boolean = false,
) {
    val colors = MaterialTheme.colorScheme
    Box(
        modifier.clip(RoundedCornerShape(6.dp))
            .background(
                if (primary) {
                    Brush.horizontalGradient(
                        listOf(colors.primary, colors.secondary),
                    )
                } else {
                    Brush.linearGradient(
                        listOf(
                            if (selected) colors.primary.copy(alpha = 0.2f) else Color.Transparent,
                            if (selected) colors.primary.copy(alpha = 0.2f) else Color.Transparent,
                        ),
                    )
                },
            )
            .border(1.dp, if (selected) colors.primary.copy(alpha = 0.5f) else colors.outline, RoundedCornerShape(6.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { this.selected = selected }
            .heightIn(min = LocalConsoleControlHeight.current).padding(horizontal = 12.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = (if (primary) colors.onPrimary else colors.onSurface).copy(alpha = if (enabled) 1f else 0.45f),
            fontSize = 12.sp,
            fontWeight = if (primary) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}

@Composable
internal fun ConsoleIcon(
    label: String,
    icon: Int,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    IconButton(onClick, enabled = enabled, modifier = Modifier.size(44.dp)) {
        Icon(painterResource(icon), label, modifier = Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
internal fun ConsoleHeader(
    state: UiState,
    console: ConsoleModel,
    presentation: ConsolePresentation,
    vm: AppViewModel,
) {
    val compact = presentation.settingsPresentation == "sheet"
    val fontScale = LocalDensity.current.fontScale
    val turns = state.visibleTurns.count { it.role == "user" }
    val turnLabel: @Composable (Modifier) -> Unit = { modifier ->
        Text(
            "($turns ${console.label(if (turns == 1) "turn_singular" else "turn_plural")})",
            color = MaterialTheme.colorScheme.tertiary,
            fontSize = 12.sp,
            modifier =
                modifier.clickable(
                    enabled = state.workspaceStarted && !state.mandatorySurface,
                    role = Role.Button,
                    onClick = vm::showConsoleConversation,
                ).padding(vertical = 8.dp).semantics { contentDescription = "View active conversation" },
        )
    }
    Surface(color = MaterialTheme.colorScheme.surface) {
        BoxWithConstraints(
            Modifier.fillMaxWidth().padding(horizontal = if (compact) 8.dp else 24.dp, vertical = if (compact) 8.dp else 10.dp),
        ) {
            val wrapTurns = maxWidth.value < (if (compact) 132 else 232) * fontScale + 136
            Column {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(if (compact) 6.dp else 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (presentation.navigationMode == "drawer") {
                        ConsoleIcon("Show the agent directory", R.drawable.ic_menu, !state.mandatorySurface) {
                            vm.setConsoleDrawer(true)
                        }
                    }
                    ConsoleButton(
                        "← " + console.label("dashboard") + if (compact) "" else console.label("dashboard_suffix"),
                        vm::showConsoleDashboard,
                        enabled = !state.mandatorySurface,
                    )
                    if (wrapTurns) Spacer(Modifier.weight(1f)) else turnLabel(Modifier.weight(1f))
                    if (compact) {
                        ConsoleIcon(console.label("new_chat"), R.drawable.ic_plus, !state.mandatorySurface, vm::newChat)
                    } else {
                        ConsoleButton("+ " + console.label("new_chat"), vm::newChat, enabled = !state.mandatorySurface)
                    }
                }
                if (wrapTurns) turnLabel(Modifier.fillMaxWidth().padding(start = 8.dp))
            }
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun ConsoleSidebar(
    state: UiState,
    console: ConsoleModel,
    presentation: ConsolePresentation,
    vm: AppViewModel,
    historyOpen: Boolean,
    onHistoryOpen: (Boolean) -> Unit,
    query: String,
    onQuery: (String) -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Column(
        Modifier.fillMaxSize().background(colors.surface).padding(horizontal = 22.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Image(
                painterResource(R.drawable.astral_wordmark),
                console.label("brand"),
                alignment = Alignment.CenterStart,
                modifier = Modifier.weight(1f).height(42.dp).clickable(role = Role.Button, onClick = vm::showConsoleDashboard),
            )
            if (presentation.navigationMode == "drawer") {
                ConsoleButton("×", {
                    vm.setConsoleDrawer(false)
                }, Modifier.semantics { contentDescription = "Hide the agent directory" })
            }
        }
        HorizontalDivider(color = colors.outline)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                console.label("history").uppercase() + if (historyOpen) "  ⌄" else "  ›",
                color = colors.onSurfaceVariant,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.sp,
                modifier =
                    Modifier.weight(
                        1f,
                    ).clickable(role = Role.Button) {
                        onHistoryOpen(!historyOpen)
                    }.padding(vertical = 10.dp),
            )
            ConsoleIcon(console.label("new_chat"), R.drawable.ic_plus) {
                vm.newChat()
                vm.setConsoleDrawer(false)
            }
        }
        if (historyOpen && state.history.isNotEmpty()) {
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 190.dp)) {
                items(state.history, key = { it.id }) { chat ->
                    var menuOpen by rememberSaveable(chat.id) { mutableStateOf(false) }
                    Box {
                        Column(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).combinedClickable(
                                role = Role.Button,
                                onClick = { vm.openChat(chat.id) },
                                onLongClickLabel = "Conversation actions",
                                onLongClick = { menuOpen = true },
                            ).padding(vertical = 8.dp, horizontal = 4.dp),
                        ) {
                            Text(
                                chat.displayTitle,
                                color = colors.onSurface,
                                fontSize = 12.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (chat.displayPreview.isNotBlank()) {
                                Text(
                                    chat.displayPreview,
                                    color = colors.onSurfaceVariant,
                                    fontSize = 11.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        DropdownMenu(menuOpen, { menuOpen = false }) {
                            DropdownMenuItem(text = { Text("Delete conversation") }, onClick = {
                                menuOpen = false
                                vm.deleteChat(chat.id)
                            }, enabled = !state.mutationsLocked && !state.mandatorySurface)
                        }
                    }
                }
            }
        }
        Text(
            console.label("agent_directory").uppercase() + "  ${console.catalog.agents.size}",
            color = colors.onSurfaceVariant,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 1.sp,
        )
        BasicTextField(
            query,
            {
                onQuery(it)
            },
            singleLine = true,
            textStyle =
                MaterialTheme.typography.bodyMedium.copy(
                    color = colors.onSurface,
                ),
            cursorBrush =
                SolidColor(
                    colors.onSurface,
                ),
            modifier =
                Modifier.fillMaxWidth().border(1.dp, colors.outline, RoundedCornerShape(10.dp)).padding(12.dp).semantics {
                    contentDescription = console.label("search_agents")
                },
            decorationBox = {
                    field ->
                Box {
                    if (query.isBlank()) Text(console.label("search_agents"), color = colors.onSurfaceVariant, fontSize = 14.sp)
                    field()
                }
            },
        )
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(
                console.catalog.agents.filter {
                    query.isBlank() || (it.name + " " + it.description).contains(query, ignoreCase = true)
                },
                key = { it.id },
            ) { agent ->
                Row(
                    Modifier.fillMaxWidth().clip(
                        RoundedCornerShape(10.dp),
                    ).background(
                        colors.onSurface.copy(alpha = 0.025f),
                    ).border(1.dp, colors.outline, RoundedCornerShape(10.dp)).clickable(role = Role.Button) {
                        vm.openConsoleAgent(agent)
                    }.padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(agent.name, color = colors.onSurface, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        Text(
                            agent.description,
                            color = colors.onSurfaceVariant,
                            fontSize = 12.sp,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Text(
                        "●",
                        color = if (agent.state == "ready") AstralWebStyle.Success else colors.onSurfaceVariant,
                        modifier =
                            Modifier.padding(
                                start = 8.dp,
                            ).semantics {
                                contentDescription = if (agent.state == "ready") "Available" else "Offline"
                            },
                    )
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().clip(
                RoundedCornerShape(10.dp),
            ).border(1.dp, colors.outline, RoundedCornerShape(10.dp)).clickable(role = Role.Button) {
                state.chromeMenu?.allItems?.firstOrNull()?.let(vm::openMenuItem)
                vm.setConsoleDrawer(false)
            }.padding(10.dp).semantics { contentDescription = state.chromeMenu?.settingsControl?.label ?: "Settings" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Image(painterResource(R.drawable.astral_account_avatar), null, modifier = Modifier.size(32.dp))
            Column(Modifier.weight(1f)) {
                Text(console.identity.name, color = colors.onSurface, fontSize = 14.sp)
                Text(console.identity.role, color = colors.onSurfaceVariant, fontSize = 12.sp)
            }
            Icon(painterResource(R.drawable.ic_settings), null, tint = colors.onSurfaceVariant, modifier = Modifier.size(20.dp))
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ConsoleLanding(
    state: UiState,
    console: ConsoleModel,
    presentation: ConsolePresentation,
    vm: AppViewModel,
    category: String?,
    onCategory: (String?) -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    LaunchedEffect(console.catalog.categories) { if (category !in console.catalog.categories) onCategory(null) }
    LazyColumn(
        Modifier.fillMaxSize().testTag("workspace-start"),
        contentPadding = presentation.contentPadding.padding(),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(console.label("title"), color = colors.onSurface, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold)
                Text(console.label("subtitle"), color = colors.onSurfaceVariant, fontSize = 14.sp)
                HorizontalDivider(Modifier.padding(top = 8.dp), color = colors.outline)
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                Text(console.label("start_here"), color = colors.onSurface, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Row(
                    Modifier.weight(
                        1f,
                        fill = false,
                    ).padding(
                        start = 16.dp,
                    ).border(1.dp, colors.outline, RoundedCornerShape(10.dp)).horizontalScroll(rememberScrollState()).padding(5.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    ConsoleButton(console.label("all_categories"), { onCategory(null) }, selected = category == null)
                    console.catalog.categories.forEach {
                            label ->
                        ConsoleButton(label, { onCategory(label) }, selected = category == label)
                    }
                }
            }
        }
        val rows = console.catalog.scenarios.filter { category == null || it.category == category }.chunked(presentation.scenarioColumns)
        items(rows, key = { row -> row.joinToString("|") { it.id } }) { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                row.forEach { scenario ->
                    Column(
                        Modifier.weight(
                            1f,
                        ).clip(
                            RoundedCornerShape(12.dp),
                        ).background(
                            colors.onSurface.copy(alpha = 0.025f),
                        ).border(1.dp, colors.outline, RoundedCornerShape(12.dp)).padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(scenario.category, color = colors.onSurfaceVariant, fontSize = 12.sp, modifier = Modifier.weight(1f))
                            Text(
                                console.label("example"),
                                color = colors.onSurfaceVariant,
                                fontSize = 10.sp,
                                modifier =
                                    Modifier.border(
                                        1.dp,
                                        colors.outline,
                                        RoundedCornerShape(20.dp),
                                    ).padding(horizontal = 8.dp, vertical = 3.dp),
                            )
                        }
                        Text(scenario.title, color = colors.onSurface, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        Text(scenario.description, color = colors.onSurfaceVariant, fontSize = 12.sp)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            val enabled = state.connection == ConnectionState.Connected && !state.mutationsLocked && !state.mandatorySurface
                            ConsoleButton(
                                console.label("run"),
                                { vm.runConsoleScenario(scenario, true) },
                                primary = true,
                                enabled = enabled,
                            )
                            ConsoleButton(console.label("load_prompt"), { vm.runConsoleScenario(scenario, false) }, enabled = enabled)
                        }
                    }
                }
                repeat(presentation.scenarioColumns - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
internal fun ConsoleSurfaceOverlay(
    state: UiState,
    console: ConsoleModel,
    presentation: ConsolePresentation,
    renderer: Renderer,
    vm: AppViewModel,
    onSignOut: () -> Unit,
) {
    val current =
        state.chromeMenu?.allItems?.firstOrNull {
            it.surface == state.pendingSurfaceKey &&
                !(it.surface == "guidance" && state.pendingSurfaceParams["view"]?.toString() == "\"selection\"")
        }
    val navigation = current != null && !state.mandatorySurface
    val colors = MaterialTheme.colorScheme
    Dialog(
        onDismissRequest = {
            if (!state.mandatorySurface) vm.goTo(Screen.Chat)
        },
        properties =
            DialogProperties(
                dismissOnBackPress = !state.mandatorySurface,
                dismissOnClickOutside = !state.mandatorySurface,
                usePlatformDefaultWidth = false,
            ),
    ) {
        BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(
                Modifier.width(
                    minOf(maxWidth.value.toDouble(), if (navigation) presentation.settingsWidth else presentation.dialogWidth).dp,
                ).height(
                    minOf(maxHeight.value.toDouble(), presentation.settingsMaxHeight).dp,
                ).clip(
                    RoundedCornerShape(if (presentation.settingsPresentation == "sheet") 0.dp else 14.dp),
                ).background(colors.surface).testTag("console-surface"),
            ) {
                Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        state.pendingSurface?.title ?: current?.label ?: console.composerActions.firstOrNull {
                            it.action?.surface == state.pendingSurfaceKey
                        }?.label ?: "Settings",
                        color = colors.onSurface,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier =
                            Modifier.weight(
                                1f,
                            ),
                    )
                    if (state.mandatorySurface) {
                        ConsoleButton(state.chromeMenu?.signout?.label ?: "Sign out", onSignOut)
                    } else {
                        ConsoleButton("×", { vm.goTo(Screen.Chat) }, Modifier.semantics { contentDescription = "Close" })
                    }
                }
                HorizontalDivider(color = colors.outline)
                if (navigation && presentation.settingsNavigationAxis == "horizontal") {
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        state.chromeMenu?.allItems?.forEach { item -> ConsoleSettingsItem(item, current, vm) }
                        ConsoleButton(state.chromeMenu?.signout?.label ?: "Sign out", onSignOut)
                    }
                }
                Row(Modifier.weight(1f)) {
                    if (navigation && presentation.settingsNavigationAxis == "vertical") {
                        Column(
                            Modifier.width(
                                presentation.settingsNavigationWidth.dp,
                            ).fillMaxSize().background(colors.background.copy(alpha = 0.35f)).padding(12.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text(console.identity.name, color = colors.onSurface, fontWeight = FontWeight.SemiBold)
                            Text(console.identity.role, color = colors.onSurfaceVariant, fontSize = 12.sp)
                            Column(
                                Modifier.weight(1f).verticalScroll(rememberScrollState()),
                                verticalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                state.chromeMenu?.menu?.forEach { group ->
                                    Text(group.label.uppercase(), color = colors.onSurfaceVariant, fontSize = 10.sp)
                                    group.items.forEach { item -> ConsoleSettingsItem(item, current, vm, Modifier.fillMaxWidth()) }
                                }
                            }
                            ConsoleButton(state.chromeMenu?.signout?.label ?: "Sign out", onSignOut)
                        }
                    }
                    Box(Modifier.weight(1f)) {
                        if (state.pendingSurfaceKey == "agent_intro" && state.pendingSurface != null) {
                            ConsoleIntroSurface(
                                state.pendingSurface.components,
                                renderer,
                                presentation.settingsPresentation == "sheet",
                                state.connection == ConnectionState.Connected && !state.mutationsLocked,
                            )
                        } else {
                            SurfaceScreen(
                                state.pendingSurface,
                                state.pendingSurfaceKey,
                                renderer,
                                vm::retryPendingSurface,
                                state.privateSurfaceRequest?.requestGeneration,
                                state.privateSurfaceFailed,
                                vm::timeoutPrivateSurface,
                                showTitle = false,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ConsoleSettingsItem(
    item: MenuItem,
    current: MenuItem?,
    vm: AppViewModel,
    modifier: Modifier = Modifier,
) {
    ConsoleButton(item.label, { vm.openMenuItem(item) }, modifier, selected = item.key == current?.key)
}
