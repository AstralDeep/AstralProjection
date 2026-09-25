// Hosts the ROTE-selected console shell and a single result renderer across preview and full screen.
// Result bounds follow the transcript while the renderer retains component and export state.

package com.personalailabs.astraldeep.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.personalailabs.astraldeep.app.R
import com.personalailabs.astraldeep.app.render.CanvasChrome
import com.personalailabs.astraldeep.app.render.CanvasHost
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.core.chrome.ConsoleModel
import com.personalailabs.astraldeep.core.chrome.ConsolePresentation
import com.personalailabs.astraldeep.core.chrome.TopBarControl
import kotlin.math.roundToInt

@Composable
internal fun ConsoleShell(
    vm: AppViewModel,
    renderer: Renderer,
    onSignOut: () -> Unit,
    onWorkspaceAction: (TopBarControl) -> Unit,
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val voice by vm.voiceState.collectAsStateWithLifecycle()
    val console = state.console ?: return
    val presentation = state.consolePresentation ?: return
    val colors = MaterialTheme.colorScheme
    var historyOpen by rememberSaveable { mutableStateOf(true) }
    var agentQuery by rememberSaveable { mutableStateOf("") }
    var category by rememberSaveable { mutableStateOf<String?>(null) }
    var rootOrigin by remember { mutableStateOf(Offset.Zero) }
    var resultBounds by remember { mutableStateOf<Rect?>(null) }
    var lastResultBounds by remember { mutableStateOf(Rect.Zero) }
    var viewport by remember { mutableStateOf(Rect.Zero) }
    LaunchedEffect(state.connectionGeneration) { vm.sendEvent("get_history") }
    LaunchedEffect(presentation.navigationMode) { if (presentation.navigationMode == "sidebar") vm.setConsoleDrawer(false) }
    BackHandler(state.consoleFullscreen || state.consoleDrawerOpen || state.mandatorySurface) {
        when {
            state.mandatorySurface -> Unit
            state.consoleFullscreen -> vm.setConsoleFullscreen(false)
            else -> vm.setConsoleDrawer(false)
        }
    }
    BoxWithConstraints(
        Modifier.fillMaxSize().background(colors.background).safeDrawingPadding().imePadding().onGloballyPositioned {
            rootOrigin = it.positionInRoot()
        },
    ) {
        val overlayOpen = state.screen == Screen.Surface || state.consoleDrawerOpen || state.consoleFullscreen
        Row(Modifier.fillMaxSize().then(if (overlayOpen) Modifier.clearAndSetSemantics {} else Modifier)) {
            if (presentation.navigationMode == "sidebar") {
                Box(Modifier.width(presentation.sidebarWidth.dp)) {
                    ConsoleSidebar(state, console, presentation, vm, historyOpen, { historyOpen = it }, agentQuery, { agentQuery = it })
                }
            }
            Column(Modifier.weight(1f).fillMaxSize()) {
                ConsoleHeader(state, console, presentation, vm)
                connectionStripLabel(state.connection, state.everConnected)?.let { ConnectionStrip(it) }
                state.banner?.let { BannerBar(it, state.bannerKind == "error", vm::dismissBanner) }
                Box(
                    Modifier.weight(
                        1f,
                    ).fillMaxWidth().background(Brush.verticalGradient(listOf(colors.primary.copy(alpha = 0.07f), colors.background))),
                ) {
                    Box(
                        Modifier.fillMaxSize().graphicsLayer {
                            alpha = if (state.consoleDashboardVisible) 0f else 1f
                        }.then(if (state.consoleDashboardVisible) Modifier.clearAndSetSemantics {} else Modifier),
                    ) {
                        ConsoleTranscript(state, console, presentation, renderer, onViewport = { viewport = it }, onResultBounds = {
                            resultBounds = it
                            if (it != null && !it.isEmpty) lastResultBounds = it
                        })
                    }
                    if (state.consoleDashboardVisible) ConsoleLanding(state, console, presentation, vm, category, { category = it })
                }
                HorizontalDivider(color = colors.outline)
                Column(Modifier.padding(presentation.composerPadding.padding())) {
                    state.turnSelection?.let(console::selectionSummary)?.let { label ->
                        Row(
                            Modifier.fillMaxWidth().background(
                                colors.primary.copy(alpha = 0.12f),
                                RoundedCornerShape(8.dp),
                            ).padding(start = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(label, color = colors.onSurface, fontSize = 12.sp, modifier = Modifier.weight(1f))
                            ConsoleButton(
                                "×",
                                vm::clearTurnSelection,
                                Modifier.semantics { contentDescription = console.label("clear_selection") },
                            )
                        }
                        Spacer(Modifier.height(6.dp))
                    }
                    InputBar(
                        state.composerDraft, vm::updateComposerDraft, state.staged, state.mutationsLocked || state.mandatorySurface,
                        voice, vm::invokeVoiceControl, vm::sendChat, vm::stageAttachment, vm::removeAttachment,
                        { vm.openSurface("attachments") }, state.backgroundNextSend, vm::toggleBackgroundNextSend,
                        console = console, onConsoleAction = vm::invokeConsoleAction,
                    )
                }
            }
        }
        if (state.workspaceCanvas.isNotEmpty() || state.showSkeleton) {
            val density = LocalDensity.current
            val root = Rect(rootOrigin, Size(with(density) { maxWidth.toPx() }, with(density) { maxHeight.toPx() }))
            val bounds = if (state.consoleFullscreen) root else lastResultBounds
            val visible =
                if (state.consoleFullscreen) {
                    root
                } else if (resultBounds == null || state.consoleDashboardVisible) {
                    Rect.Zero
                } else {
                    bounds.intersect(viewport)
                }
            val clipped = if (visible.isEmpty) Rect(bounds.topLeft, Size.Zero) else visible
            Box(
                Modifier.offset { IntOffset((clipped.left - rootOrigin.x).roundToInt(), (clipped.top - rootOrigin.y).roundToInt()) }
                    .requiredSize(
                        with(density) {
                            clipped.width.coerceAtLeast(0f).toDp()
                        },
                        with(density) { clipped.height.coerceAtLeast(0f).toDp() },
                    ).clipToBounds().then(
                        if (state.consoleDrawerOpen || state.screen == Screen.Surface) Modifier.clearAndSetSemantics {} else Modifier,
                    ),
            ) {
                Box(
                    Modifier.offset { IntOffset((bounds.left - clipped.left).roundToInt(), (bounds.top - clipped.top).roundToInt()) }
                        .requiredSize(
                            with(density) { bounds.width.coerceAtLeast(1f).toDp() },
                            with(density) { bounds.height.coerceAtLeast(1f).toDp() },
                        ),
                ) {
                    ConsoleResultPane(state, console, presentation, renderer, vm, onWorkspaceAction)
                }
            }
        }
        if (presentation.navigationMode == "drawer" && state.consoleDrawerOpen) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.48f)).clickable { vm.setConsoleDrawer(false) })
            Box(Modifier.width(minOf(maxWidth.value.toDouble(), presentation.sidebarWidth).dp).fillMaxSize()) {
                ConsoleSidebar(state, console, presentation, vm, historyOpen, { historyOpen = it }, agentQuery, { agentQuery = it })
            }
        }
        if (state.screen == Screen.Surface) ConsoleSurfaceOverlay(state, console, presentation, renderer, vm, onSignOut)
    }
}

@Composable
private fun ConsoleTranscript(
    state: UiState,
    console: ConsoleModel,
    presentation: ConsolePresentation,
    renderer: Renderer,
    onViewport: (Rect) -> Unit,
    onResultBounds: (Rect?) -> Unit,
) {
    val scroll = rememberLazyListState()
    val turns = state.visibleTurns.filter { it.hasVisibleContent }
    val hasResult = state.workspaceCanvas.isNotEmpty() || state.showSkeleton
    LaunchedEffect(state.activeChatId, turns, state.workspaceCanvas, state.statusText) {
        val count = turns.size + (if (state.statusText != null) 1 else 0) + (if (hasResult) 1 else 0)
        scroll.scrollToItem(count)
    }
    LazyColumn(
        Modifier.fillMaxSize().onGloballyPositioned {
            onViewport(it.boundsInRoot())
        }.testTag(
            "conversation-message-scroll",
        ),
        state = scroll,
        contentPadding = presentation.contentPadding.padding(),
        verticalArrangement = Arrangement.spacedBy(28.dp),
    ) {
        itemsIndexed(turns, key = { index, turn -> "turn-${turn.messageId ?: index}" }) { _, turn -> ChatBubble(turn, renderer) }
        state.statusText?.let { status -> item { Text(status, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp) } }
        if (hasResult) {
            item(key = "result") {
                DisposableEffect(Unit) { onDispose { onResultBounds(null) } }
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(
                        state.consoleResultAgent,
                        color = MaterialTheme.colorScheme.onSurface,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(
                        Modifier.fillMaxWidth().height(
                            if (state.consoleResultCollapsed) 54.dp else presentation.resultPreviewMaxHeight.dp,
                        ).onGloballyPositioned {
                            onResultBounds(Rect(it.positionInRoot(), Size(it.size.width.toFloat(), it.size.height.toFloat())))
                        },
                    )
                }
            }
        }
        item(key = "bottom") { Spacer(Modifier.height(1.dp)) }
    }
}

@Composable
private fun ConsoleResultPane(
    state: UiState,
    console: ConsoleModel,
    presentation: ConsolePresentation,
    renderer: Renderer,
    vm: AppViewModel,
    onWorkspaceAction: (TopBarControl) -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val fullscreen = state.consoleFullscreen
    BoxWithConstraints(
        Modifier.fillMaxSize().clip(
            RoundedCornerShape(if (fullscreen) 0.dp else 10.dp),
        ).background(colors.surface).testTag("console-result"),
    ) {
        val bodyHeight =
            if (fullscreen) (maxHeight - 65.dp).coerceAtLeast(1.dp) else presentation.resultBodyMaxHeight.dp
        Column {
            Row(
                Modifier.fillMaxWidth().height(if (fullscreen) 64.dp else 54.dp).padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    console.label("result_title").replace("{agent}", state.consoleResultAgent),
                    color = colors.onSurface,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (!fullscreen) {
                    ConsoleButton(
                        if (state.consoleResultCollapsed) "⌄" else "⌃",
                        {
                            vm.setConsoleResultCollapsed(!state.consoleResultCollapsed)
                        },
                        Modifier.semantics {
                            contentDescription = console.label(if (state.consoleResultCollapsed) "expand" else "collapse")
                        },
                    )
                    ConsoleButton(
                        "⛶",
                        { vm.setConsoleFullscreen(true) },
                        Modifier.semantics { contentDescription = console.label("fullscreen") },
                    )
                }
                workspaceControls(state).forEach {
                        control ->
                    ConsoleIcon(
                        control.label.orEmpty(),
                        if (control.operation == "export_canvas") R.drawable.ic_workspace_export else R.drawable.ic_workspace_share,
                    ) {
                        onWorkspaceAction(control)
                    }
                }
                if (fullscreen) {
                    ConsoleButton("×", {
                        vm.setConsoleFullscreen(false)
                    }, Modifier.semantics { contentDescription = console.label("exit_fullscreen") })
                }
            }
            HorizontalDivider(color = colors.outline)
            Box(
                Modifier.fillMaxWidth().height(
                    bodyHeight,
                ),
            ) {
                Box(Modifier.fillMaxSize().then(if (!fullscreen) Modifier.clearAndSetSemantics {} else Modifier)) {
                    CanvasHost(
                        state.workspaceCanvas,
                        renderer,
                        Modifier.fillMaxSize(),
                        CanvasChrome(state.activeChatId, state.mutationsLocked || state.isViewingHistory),
                        state.showSkeleton,
                    )
                }
                if (!fullscreen) {
                    Box(Modifier.fillMaxSize().clickable { vm.setConsoleFullscreen(true) }.clearAndSetSemantics {})
                    Box(
                        Modifier.fillMaxWidth().height(
                            90.dp,
                        ).align(Alignment.BottomCenter).background(Brush.verticalGradient(listOf(Color.Transparent, colors.surface))),
                    )
                    ConsoleButton(console.label("result_preview_action"), {
                        vm.setConsoleFullscreen(true)
                    }, Modifier.align(Alignment.BottomCenter).padding(bottom = 14.dp).background(colors.surface))
                }
            }
        }
    }
}
