// Android's central view model: owns the WebSocket connection, folds each Wire-decoded Inbound frame into
// UiState via reduce(), and dispatches chat/component/theme events. Read by RootScaffold, Screens, and the
// render layer.

package com.personalailabs.astraldeep.app.ui

import android.util.Log
import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore.AccountIdentity
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore.ClearReason
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.rest.AuditEvent
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.ConversationGenerationBinding
import com.personalailabs.astraldeep.app.transport.ConversationRequestPurpose
import com.personalailabs.astraldeep.app.transport.LocalSubmission
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.app.transport.QueuedSubmissionFailure
import com.personalailabs.astraldeep.app.ui.theme.ThemePalette
import com.personalailabs.astraldeep.app.ui.theme.themePaletteForSpec
import com.personalailabs.astraldeep.app.voice.VoiceMediaCapability
import com.personalailabs.astraldeep.app.voice.VoiceSessionController
import com.personalailabs.astraldeep.app.voice.VoiceUiState
import com.personalailabs.astraldeep.core.chrome.ChromeMenuModel
import com.personalailabs.astraldeep.core.chrome.MenuItem
import com.personalailabs.astraldeep.core.protocol.Agent
import com.personalailabs.astraldeep.core.protocol.ChatAttachment
import com.personalailabs.astraldeep.core.protocol.ChatSummary
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.ProtocolManifest
import com.personalailabs.astraldeep.core.protocol.VoiceControl
import com.personalailabs.astraldeep.core.protocol.isGuidanceNoteAction
import com.personalailabs.astraldeep.core.protocol.isPrivateChromeSurface
import com.personalailabs.astraldeep.core.sdui.Canvas
import com.personalailabs.astraldeep.core.sdui.CanvasOp
import com.personalailabs.astraldeep.core.sdui.Component
import com.personalailabs.astraldeep.core.streaming.streamErrorOps
import com.personalailabs.astraldeep.core.streaming.streamFrameToOps
import com.personalailabs.astraldeep.core.streaming.subscribeAckOps
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/** Canonical transcript part disposition used by the native message renderer. */
enum class ChatSegmentKind { TEXT, COMPONENTS, STRUCTURED, RECOVERY }

@Immutable
data class ChatSegment(
    val kind: ChatSegmentKind,
    val text: String,
    val components: List<Component> = emptyList(),
    val structuredValue: JsonElement? = null,
)

@Immutable
data class ChatTurn(
    val role: String,
    val text: String,
    val segments: List<ChatSegment> = emptyList(),
    val attachments: List<JsonObject> = emptyList(),
    val messageId: String? = null,
    val createdAt: String? = null,
) {
    val hasVisibleContent: Boolean
        get() = text.isNotBlank() || segments.any { it.components.isNotEmpty() } || attachments.isNotEmpty()
}

/**
 * The top-level navigable surfaces. Settings is no longer a screen — it is the
 * server-driven dropdown from the top-bar gear (feature 042); items route to the
 * native Agents/Audit screens or, for any other surface, the SDUI [Surface] screen
 * (chrome_open → chrome_surface, rendered natively).
 */
enum class Screen { Chat, Agents, History, Audit, Surface }

@Immutable
data class StagedAttachment(
    val uid: Long,
    val filename: String,
    val category: String,
    val attachmentId: String?,
    val state: String,
    val note: String? = null,
)

@Immutable
data class CanvasSnapshot(val label: String, val components: List<Component>)

@Immutable
data class PrivateSurfaceRequest(val requestGeneration: String, val connectionGeneration: String, val surfaceKey: String)

data class UiState(
    val connection: ConnectionState = ConnectionState.Disconnected,
    val screen: Screen = Screen.Chat,
    val activeChatId: String? = null,
    val turns: List<ChatTurn> = emptyList(),
    val pendingTurns: List<ChatTurn> = emptyList(),
    val canvas: List<Component> = emptyList(),
    val transientCanvas: List<Component>? = null,
    val connectionGeneration: String? = null,
    val requestGeneration: String? = null,
    val requestChatId: String? = null,
    val requestPurpose: ConversationRequestPurpose? = null,
    val usedConversationRequestGenerations: Set<String> = emptySet(),
    val expectedCommitRenderRevision: ULong? = null,
    val lastCommittedRenderRevision: ULong = 0UL,
    val lastTransientFrameSequence: ULong = 0UL,
    val hydrationApplied: Boolean = false,
    val acceptedSnapshotId: String? = null,
    val acceptedSnapshot: Inbound.ConversationSnapshot? = null,
    val pendingCanvas: List<Component> = emptyList(),
    val turnActive: Boolean = false,
    val pendingReplace: Boolean = false,
    val preTurnCanvas: List<Component> = emptyList(),
    val turnOpsApplied: Boolean = false,
    val canvasLabel: String = "",
    val pendingLabel: String = "",
    val canvasHistory: List<CanvasSnapshot> = emptyList(),
    val viewingIndex: Int? = null,
    val staged: List<StagedAttachment> = emptyList(),
    val composerDraft: String = "",
    val backgroundNextSend: Boolean = false,
    val backgroundRequested: Boolean = false,
    val workspaceStarted: Boolean = false,
    val statusText: String? = null,
    val banner: String? = null,
    val bannerKind: String = "error",
    val stepTrail: List<String> = emptyList(),
    val asyncDetached: Boolean = false,
    val everConnected: Boolean = false,
    val agents: List<Agent> = emptyList(),
    val pendingSubmissions: Map<String, LocalSubmission> = emptyMap(),
    val operationStatuses: Map<String, Inbound.OperationStatus> = emptyMap(),
    val agentLifecycles: Map<String, Inbound.AgentLifecycle> = emptyMap(),
    val history: List<ChatSummary> = emptyList(),
    val historyTitle: String = "Recent chats",
    val audit: List<AuditEvent> = emptyList(),
    val agentsLoading: Boolean = false,
    val historyLoading: Boolean = false,
    val auditLoading: Boolean = false,
    val chromeMenu: ChromeMenuModel? = null,
    val pendingSurfaceKey: String = "",
    val pendingSurfaceParams: JsonObject = JsonObject(emptyMap()),
    val pendingSurface: Inbound.ChromeSurface? = null,
    val privateSurfaceRequest: PrivateSurfaceRequest? = null,
    val privateSurfaceFailed: Boolean = false,
    val themePalette: ThemePalette? = null,
    val timelineReadOnly: Boolean = false,
    val mandatorySurface: Boolean = false,
) {
    val visibleCanvas: List<Component>
        get() = viewingIndex?.let { canvasHistory.getOrNull(it)?.components } ?: (transientCanvas ?: canvas)

    val visibleTurns: List<ChatTurn> get() = turns + pendingTurns

    val isViewingHistory: Boolean get() = viewingIndex != null

    val activeOperationStatus: Inbound.OperationStatus?
        get() =
            operationStatuses.values
                .asSequence()
                .filter {
                    !it.terminal &&
                        it.connectionGeneration == connectionGeneration &&
                        (it.chatId == null || it.chatId == activeChatId)
                }
                .maxWithOrNull(compareBy<Inbound.OperationStatus> { it.updatedAt }.thenBy { it.operationId })

    val hasActiveWork: Boolean
        get() = turnActive || pendingSubmissions.isNotEmpty() || activeOperationStatus != null

    val workingStatusText: String?
        get() =
            activeOperationStatus?.label
                ?: statusText?.takeIf { turnActive }
                ?: "Submitting…".takeIf { pendingSubmissions.isNotEmpty() }

    val showSkeleton: Boolean
        get() = pendingReplace && !turnOpsApplied && viewingIndex == null

    val mutationsLocked: Boolean get() = timelineReadOnly
}

internal fun isTimelineMutation(action: String): Boolean = action in TIMELINE_MUTATIONS

internal fun isExpectedVoiceChatCreation(
    state: UiState,
    pending: LocalSubmission,
    message: Inbound.ChatCreated,
): Boolean =
    state.activeChatId == null &&
        message.chatId != null &&
        message.fromMessage == false &&
        message.connectionGeneration == state.connectionGeneration &&
        message.submissionId == pending.submissionId &&
        message.requestGeneration == pending.requestGeneration

internal fun voiceControlNeedsChatPreflight(action: String): Boolean = action == "voice_session_start" || action == "voice_session_takeover"

private val TIMELINE_MUTATIONS =
    setOf("chat_message", "component_action", "component_refine", "component_restore", "table_paginate", "save_theme")

class AppViewModel(
    private val client: OrchestratorClient,
    private val rest: AstralRest,
    private val resumeStore: ConversationResumeStore? = null,
    private val voiceController: VoiceSessionController? = null,
) : ViewModel() {
    private data class PendingVoiceActivation(
        val action: String,
        val capability: VoiceMediaCapability,
        val submission: LocalSubmission,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()
    private val unavailableVoice = MutableStateFlow(VoiceUiState.Unavailable)
    val voiceState: StateFlow<VoiceUiState> = voiceController?.state ?: unavailableVoice.asStateFlow()

    private var session: Job? = null
    private var snapshotTimeout: Job? = null
    private var token: String? = null
    private var device: DeviceCapabilities? = null

    @Volatile private var account: AccountIdentity? = null

    @Volatile private var workspaceEpoch: Long = 0

    internal fun workspaceContext(): WorkspaceContext? = workspaceContext(_state.value, account, workspaceEpoch)

    internal fun componentContext(component: Component): ComponentActionContext? =
        componentActionContext(_state.value, account, workspaceEpoch, component)

    private var attachSeq: Long = 0
    private val seqState = mutableMapOf<String, Int>()
    private var pendingVoiceActivation: PendingVoiceActivation? = null

    init {
        voiceController?.setTranscriptSubmitter { transcript, connectionGeneration ->
            client.sendVoiceTranscript(transcript, connectionGeneration) { submission ->
                _state.update { current ->
                    if (current.pendingSubmissions.containsKey(submission.requestGeneration)) {
                        projectLocalSubmission(current, submission)
                    } else {
                        val armed = armTurn(current)
                        projectLocalSubmission(
                            armed.copy(
                                pendingTurns = armed.pendingTurns + ChatTurn("user", transcript.text),
                                pendingLabel = transcript.text.take(80),
                            ),
                            submission,
                        )
                    }
                }
            }
        }
        voiceController?.setPlayoutReporter(client::sendVoicePlayoutEvent)
    }

    fun start(
        token: String,
        device: DeviceCapabilities,
    ) {
        _state.update { retirePrivateSurface(it) }
        this.token = token
        this.device = device
        val nextAccount = ConversationResumeStore.accountFromAccessToken(token)
        val previousAccount = account
        if (previousAccount != nextAccount) workspaceEpoch++
        if (previousAccount != null && nextAccount != null && previousAccount != nextAccount) {
            viewModelScope.coroutineContext.cancelChildren()
            client.clearOwnerSession()
            resumeStore?.clear(previousAccount, ClearReason.ACCOUNT_SWITCH_OR_REMOVAL)
        }
        account = nextAccount
        val locatedChat = nextAccount?.let { resumeStore?.load(it)?.chatId }
        if (previousAccount != nextAccount) {
            _state.value =
                UiState(
                    activeChatId = locatedChat,
                    themePalette = _state.value.themePalette,
                )
        } else if (_state.value.activeChatId == null && locatedChat != null) {
            _state.value = _state.value.copy(activeChatId = locatedChat)
        }
        session?.cancel()
        snapshotTimeout?.cancel()
        seqState.clear()
        client.observeConversationGenerations(::installConversationGeneration)
        session =
            viewModelScope.launch {
                launch {
                    client
                        .stream(
                            token = token,
                            device = device,
                            sessionId = { _state.value.activeChatId },
                            onGeneration = ::installConversationGeneration,
                            onQueuedSubmission = ::installQueuedSubmission,
                        ).collect { msg ->
                            voiceController?.handleInbound(msg)
                            val before = _state.value
                            val retryChat = snapshotRetryTarget(before, msg)
                            val after = reduceWithPersistence(before, msg)
                            _state.value = after
                            handleVoiceAfterReduction(before, after, msg)
                            when {
                                retryChat != null -> {
                                    snapshotTimeout?.cancel()
                                    _state.update { current ->
                                        current.copy(statusText = "Conversation restore failed; retrying…")
                                    }
                                    requestChatRefresh(retryChat)
                                }
                                msg is Inbound.ConversationCommitReady && after !== before &&
                                    after.requestGeneration == msg.requestGeneration &&
                                    after.expectedCommitRenderRevision == msg.renderRevision -> {
                                    scheduleSnapshotTimeout(
                                        ConversationGenerationBinding(
                                            connectionGeneration = msg.connectionGeneration,
                                            chatId = msg.chatId,
                                            requestGeneration = msg.requestGeneration,
                                            purpose = ConversationRequestPurpose.COMMIT,
                                        ),
                                        msg.renderRevision,
                                    )
                                }
                                msg is Inbound.ConversationSnapshot && after !== before &&
                                    after.lastCommittedRenderRevision == msg.renderRevision -> {
                                    snapshotTimeout?.cancel()
                                }
                            }
                            continuityReloadTarget(before, msg)?.let(::requestChatRefresh)
                            if (msg is Inbound.ComputerPresence &&
                                after.screen == Screen.Surface &&
                                after.pendingSurfaceKey == "my_computers"
                            ) {
                                retryPendingSurface()
                            }
                        }
                }
                launch {
                    client.state.collect { c ->
                        _state.update { current -> reduceConnectionState(current, c) }
                        if (c == ConnectionState.Disconnected) {
                            snapshotTimeout?.cancel()
                            voiceController?.connectionLost()
                        }
                    }
                }
                launch {
                    client.dropped.collect { action ->
                        _state.value =
                            _state.value.copy(
                                banner = "Not sent while offline: $action (queue full)",
                                bannerKind = "error",
                            )
                    }
                }
                launch {
                    client.queuedFailures.collect { failure ->
                        _state.update { current -> reduceQueuedFailure(current, failure) }
                    }
                }
            }
    }

    fun dismissBanner() {
        _state.value = _state.value.copy(banner = null)
    }

    fun updateComposerDraft(text: String) {
        _state.update { if (it.mutationsLocked) it else it.copy(composerDraft = text) }
    }

    fun toggleBackgroundNextSend() {
        _state.update { if (it.mutationsLocked) it else it.copy(backgroundNextSend = !it.backgroundNextSend) }
    }

    fun sendChat(text: String) {
        val s = _state.value
        if (s.timelineReadOnly) return
        val ready = s.staged.filter { it.state == "ready" && it.attachmentId != null }
        if (text.isBlank() && ready.isEmpty()) return
        val bubble =
            if (ready.isEmpty()) {
                text
            } else {
                (text + "\n📎 " + ready.joinToString(", ") { it.filename }).trim()
            }
        _state.value =
            armTurn(s, background = s.backgroundNextSend).copy(
                pendingTurns = s.pendingTurns + ChatTurn("user", bubble),
                pendingLabel = (text.ifBlank { ready.firstOrNull()?.filename ?: "" }).take(80),
                staged = emptyList(),
                composerDraft = "",
                backgroundNextSend = false,
            )
        val attachments = ready.map { ChatAttachment(it.attachmentId!!, it.filename, it.category) }
        client.sendChat(text, _state.value.activeChatId, attachments, asyncMode = s.backgroundNextSend) { submission ->
            _state.update { current -> projectLocalSubmission(current, submission) }
        }
    }

    fun invokeVoiceControl(
        control: VoiceControl,
        capability: VoiceMediaCapability,
    ) {
        val controller = voiceController ?: return
        if (!control.visible || !control.enabled || _state.value.timelineReadOnly) return
        if (control.action in setOf("voice_session_start", "voice_session_takeover") && _state.value.activeChatId == null) {
            controller.awaitingChat()
            val submission = client.createChatForVoice()
            if (submission == null) {
                controller.activationFailed("network_interrupted", "Voice needs a live connection. You can keep typing.")
            } else {
                pendingVoiceActivation = PendingVoiceActivation(control.action, capability, submission)
            }
            return
        }
        if (voiceControlNeedsChatPreflight(control.action)) {
            _state.value.activeChatId?.let(controller::updateVisibleChatLocally)
        }
        viewModelScope.launch {
            when (control.action) {
                "voice_session_start" -> controller.activate(capability)
                "voice_session_takeover" -> controller.takeOver(capability)
                "voice_session_end" -> controller.end()
                "voice_microphone_set" -> controller.setMicrophoneEnabled(!control.pressed)
                "voice_speech_stop" -> controller.stopSpeech()
                "voice_speech_mute_set" -> controller.setSpeechMuted(!control.pressed)
                "voice_visible_chat_update" -> _state.value.activeChatId?.let(controller::updateVisibleChatLocally)
                "voice_sensitive_recap_request" ->
                    _state.update {
                        it.copy(
                            banner = "Sensitive spoken recap consent is not available on this build.",
                            bannerKind = "info",
                        )
                    }
            }
        }
    }

    fun reportVoiceCapability(capability: VoiceMediaCapability) {
        val controller = voiceController ?: return
        viewModelScope.launch { controller.activate(capability) }
    }

    private fun handleVoiceAfterReduction(
        before: UiState,
        after: UiState,
        message: Inbound,
    ) {
        val controller = voiceController ?: return
        if (before.activeChatId != after.activeChatId) controller.updateVisibleChatLocally(after.activeChatId)
        val pending = pendingVoiceActivation ?: return
        if (
            message is Inbound.ChatCreated &&
            before.activeChatId != null &&
            message.connectionGeneration == before.connectionGeneration &&
            message.submissionId == pending.submission.submissionId &&
            message.requestGeneration == pending.submission.requestGeneration
        ) {
            pendingVoiceActivation = null
            controller.activationFailed(
                "chat_context_unavailable",
                "Voice start was cancelled because you changed conversations.",
            )
            return
        }
        if (
            message !is Inbound.ChatCreated || message.chatId == null || message.chatId != after.activeChatId ||
            message.fromMessage != false || message.connectionGeneration != after.connectionGeneration ||
            message.submissionId != pending.submission.submissionId ||
            message.requestGeneration != pending.submission.requestGeneration
        ) {
            return
        }
        pendingVoiceActivation = null
        viewModelScope.launch {
            when (pending.action) {
                "voice_session_start" -> controller.activate(pending.capability)
                "voice_session_takeover" -> controller.takeOver(pending.capability)
            }
        }
    }

    internal fun sendComponentEvent(
        context: ComponentActionContext,
        action: String,
        payload: JsonObject,
        onSubmission: (LocalSubmission) -> Unit,
    ): Boolean {
        if (componentContext(context.component) != context) return false
        if (action !in setOf("component_refine", "component_restore")) return false
        val kind = if (action == "component_refine") "refine" else "history"
        if (context.actions.none { it.kind == kind }) return false
        val sent =
            client.sendCurrentEvent(action, context.chatId, payload, { componentContext(context.component) == context }) { submission ->
                _state.update { current -> projectLocalSubmission(current, submission) }
                onSubmission(submission)
            }
        if (!sent && componentContext(context.component) == context) {
            _state.update { it.copy(banner = "Reconnect before changing this component.", bannerKind = "error") }
        }
        return sent
    }

    fun sendEvent(
        action: String,
        payload: JsonObject = JsonObject(emptyMap()),
    ) {
        val surface = (payload["surface"] as? JsonPrimitive)?.contentOrNull.orEmpty()
        if (action == "chrome_open" && isPrivateChromeSurface(surface)) {
            openSurface(surface, payload["params"] as? JsonObject ?: JsonObject(emptyMap()))
            return
        }
        if (isGuidanceNoteAction(action)) {
            val current = _state.value
            if (current.screen == Screen.Surface && current.pendingSurfaceKey == "guidance") {
                requestPrivateSurface("guidance", JsonObject(emptyMap()), action, payload)
            }
            return
        }
        if (action == "chrome_close" && isPrivateChromeSurface(_state.value.pendingSurfaceKey)) {
            _state.update {
                retirePrivateSurface(it).copy(screen = Screen.Chat, pendingSurfaceKey = "", pendingSurfaceParams = JsonObject(emptyMap()))
            }
            return
        }
        if (action == "chrome_open" || action == "chrome_close") _state.update { retirePrivateSurface(it) }
        if (action == "attach_existing") {
            if (stageExistingAttachment(payload)) {
                val filename = (payload["filename"] as? JsonPrimitive)?.contentOrNull ?: "file"
                _state.value =
                    retirePrivateSurface(_state.value).copy(
                        screen = Screen.Chat,
                        banner = "Attached $filename — it will be sent with your next message",
                        bannerKind = "info",
                    )
            }
            return
        }
        if (_state.value.timelineReadOnly && isTimelineMutation(action)) return
        if (action == "chat_message") {
            val message = (payload["message"] as? JsonPrimitive)?.contentOrNull ?: return
            sendChat(message)
            return
        }
        client.sendEvent(action, _state.value.activeChatId, payload) { submission ->
            _state.update { current -> projectLocalSubmission(current, submission) }
        }
    }

    internal fun projectLocalSubmission(
        s: UiState,
        submission: LocalSubmission,
    ): UiState =
        s.copy(
            pendingSubmissions = s.pendingSubmissions + (submission.requestGeneration to submission),
            statusText = "Submitting…",
        )

    private fun installQueuedSubmission(submission: LocalSubmission) {
        _state.update { current -> projectLocalSubmission(current, submission) }
    }

    internal fun reduceQueuedFailure(
        s: UiState,
        failure: QueuedSubmissionFailure,
    ): UiState {
        if (s.pendingSubmissions[failure.submission.requestGeneration] != failure.submission) return s
        val retained =
            s.pendingSubmissions.filterValues {
                it.submissionId != failure.submission.submissionId
            }
        val ownsCurrentChatTurn =
            failure.submission.action == "chat_message" &&
                (
                    failure.submission.requestGeneration == s.requestGeneration ||
                        (
                            s.requestGeneration == null &&
                                s.pendingSubmissions.keys.lastOrNull() == failure.submission.requestGeneration
                        )
                )
        val settled =
            s.copy(
                pendingSubmissions = retained,
                statusText =
                    when {
                        !ownsCurrentChatTurn && s.turnActive -> s.statusText
                        retained.isNotEmpty() -> "Submitting…"
                        else -> null
                    },
                banner = "Not sent while offline: ${failure.submission.action} (${failure.reason})",
                bannerKind = "error",
                turnActive = if (ownsCurrentChatTurn) false else s.turnActive,
                pendingReplace = if (ownsCurrentChatTurn) false else s.pendingReplace,
                pendingCanvas = if (ownsCurrentChatTurn) emptyList() else s.pendingCanvas,
                preTurnCanvas = if (ownsCurrentChatTurn) emptyList() else s.preTurnCanvas,
                turnOpsApplied = if (ownsCurrentChatTurn) false else s.turnOpsApplied,
                transientCanvas = if (ownsCurrentChatTurn) null else s.transientCanvas,
                pendingTurns = if (ownsCurrentChatTurn) emptyList() else s.pendingTurns,
                lastTransientFrameSequence = if (ownsCurrentChatTurn) 0UL else s.lastTransientFrameSequence,
                stepTrail = if (ownsCurrentChatTurn) emptyList() else s.stepTrail,
                asyncDetached = if (ownsCurrentChatTurn) false else s.asyncDetached,
            )
        return if (ownsCurrentChatTurn) retireCurrentCommit(settled, failure.submission.requestGeneration) else settled
    }

    internal fun armTurn(
        s: UiState,
        background: Boolean = false,
    ): UiState {
        val live = s.canvas.dropWelcome()
        return s.copy(
            workspaceStarted = true,
            canvas = live,
            preTurnCanvas = live,
            turnOpsApplied = false,
            turnActive = true,
            pendingReplace = !background,
            backgroundRequested = background,
            pendingCanvas = emptyList(),
            viewingIndex = null,
            banner = null,
            stepTrail = emptyList(),
            asyncDetached = false,
        )
    }

    fun newChat() {
        _state.update { retirePrivateSurface(it) }
        workspaceEpoch++
        if (!clearResumeLocator(ClearReason.EXPLICIT_NEW_CHAT)) {
            _state.value =
                _state.value.copy(
                    banner = "Could not start a new chat because the current selection was not saved.",
                    bannerKind = "error",
                )
            return
        }
        snapshotTimeout?.cancel()
        seqState.clear()
        _state.value =
            _state.value.copy(
                activeChatId = null,
                composerDraft = "",
                backgroundNextSend = false,
                workspaceStarted = false,
                turns = emptyList(),
                pendingTurns = emptyList(),
                canvas = emptyList(),
                transientCanvas = null,
                pendingCanvas = emptyList(),
                preTurnCanvas = emptyList(),
                turnOpsApplied = false,
                canvasHistory = emptyList(),
                viewingIndex = null,
                turnActive = false, backgroundRequested = false,
                pendingReplace = false,
                canvasLabel = "",
                pendingLabel = "",
                staged = emptyList(),
                statusText = null,
                banner = null,
                stepTrail = emptyList(),
                asyncDetached = false,
                requestGeneration = null,
                requestChatId = null,
                requestPurpose = null,
                expectedCommitRenderRevision = null,
                lastCommittedRenderRevision = 0UL,
                lastTransientFrameSequence = 0UL,
                hydrationApplied = false,
                acceptedSnapshotId = null,
                acceptedSnapshot = null,
            )
        voiceController?.updateVisibleChatLocally(null)
        sendEvent("new_chat")
    }

    fun stageAttachment(
        filename: String,
        mimeType: String?,
        bytes: ByteArray,
    ) {
        val t = token ?: return
        val uid = ++attachSeq
        _state.value =
            _state.value.copy(
                staged = _state.value.staged + StagedAttachment(uid, filename, "file", null, "uploading"),
            )
        viewModelScope.launch {
            val up = runCatching { rest.uploadAttachment(t, filename, mimeType, bytes) }.getOrNull()
            _state.value =
                _state.value.copy(
                    staged =
                        _state.value.staged.map { a ->
                            when {
                                a.uid != uid -> a
                                up == null -> a.copy(state = "failed", note = "upload failed")
                                else ->
                                    a.copy(
                                        attachmentId = up.attachmentId,
                                        category = up.category,
                                        state = "ready",
                                        note = parserNote(up.parserStatus),
                                    )
                            }
                        },
                )
        }
    }

    fun removeAttachment(uid: Long) {
        _state.value = _state.value.copy(staged = _state.value.staged.filterNot { it.uid == uid })
    }

    fun viewCanvasSnapshot(index: Int) {
        if (index in _state.value.canvasHistory.indices) {
            _state.value = _state.value.copy(viewingIndex = index)
        }
    }

    fun backToLiveCanvas() {
        _state.value = _state.value.copy(viewingIndex = null)
    }

    fun goTo(screen: Screen) {
        if (screen != Screen.Surface) _state.update { retirePrivateSurface(it) }
        _state.value =
            _state.value.copy(
                screen = screen,
                agentsLoading = screen == Screen.Agents || _state.value.agentsLoading,
                historyLoading = screen == Screen.History || _state.value.historyLoading,
                auditLoading = screen == Screen.Audit || _state.value.auditLoading,
            )
        when (screen) {
            Screen.Agents -> sendEvent("discover_agents")
            Screen.History -> sendEvent("get_history")
            Screen.Audit -> loadAudit()
            Screen.Chat -> Unit
            Screen.Surface -> Unit
        }
    }

    fun openMenuItem(item: MenuItem) = openSurface(item.surface, item.params)

    fun openSurface(
        surface: String,
        params: JsonObject = JsonObject(emptyMap()),
    ) {
        _state.update { retirePrivateSurface(it) }
        if (isPrivateChromeSurface(surface)) {
            requestPrivateSurface(surface, params)
            return
        }
        sendEvent(
            "chrome_open",
            buildJsonObject {
                put("surface", surface)
                put("params", params)
            },
        )
        _state.value =
            _state.value.copy(
                screen = Screen.Surface,
                pendingSurfaceKey = surface,
                pendingSurfaceParams = params,
                pendingSurface = null,
                privateSurfaceFailed = false,
            )
    }

    fun retryPendingSurface() {
        val st = _state.value
        if (isPrivateChromeSurface(st.pendingSurfaceKey)) {
            requestPrivateSurface(st.pendingSurfaceKey, st.pendingSurfaceParams)
            return
        }
        if (st.pendingSurfaceKey.isNotBlank()) {
            sendEvent(
                "chrome_open",
                buildJsonObject {
                    put("surface", st.pendingSurfaceKey)
                    put("params", st.pendingSurfaceParams)
                },
            )
        }
    }

    private fun requestPrivateSurface(
        surface: String,
        params: JsonObject,
        action: String = "chrome_open",
        payload: JsonObject =
            buildJsonObject {
                put("surface", surface)
                put("params", params)
            },
    ) {
        val owner = account
        val epoch = workspaceEpoch
        _state.update {
            retirePrivateSurface(it).copy(
                screen = Screen.Surface,
                pendingSurfaceKey = surface,
                pendingSurfaceParams = params,
                pendingSurface = null,
                privateSurfaceRequest = null,
                privateSurfaceFailed = false,
            )
        }
        var issued: PrivateSurfaceRequest? = null
        val sent =
            client.sendCurrentSurfaceEvent(surface, action, payload, {
                account == owner && workspaceEpoch == epoch && _state.value.screen == Screen.Surface &&
                    _state.value.pendingSurfaceKey == surface && _state.value.privateSurfaceRequest == issued
            }) { submission, connection ->
                issued = PrivateSurfaceRequest(submission.requestGeneration, connection, surface)
                _state.update { projectLocalSubmission(it, submission).copy(privateSurfaceRequest = issued) }
            }
        if (!sent && _state.value.privateSurfaceRequest == issued && _state.value.pendingSurfaceKey == surface) {
            _state.update { finishPrivateSurface(it).copy(privateSurfaceFailed = true) }
        }
    }

    internal fun timeoutPrivateSurface(requestGeneration: String?) {
        if (requestGeneration != null && _state.value.privateSurfaceRequest?.requestGeneration == requestGeneration) {
            _state.update { finishPrivateSurface(it).copy(privateSurfaceFailed = true) }
        }
    }

    private fun finishPrivateSurface(s: UiState): UiState {
        val request = s.privateSurfaceRequest?.requestGeneration
        val remaining = if (request == null) s.pendingSubmissions else s.pendingSubmissions - request
        return s.copy(
            privateSurfaceRequest = null,
            pendingSubmissions = remaining,
            statusText = if (request != null && remaining.isEmpty()) null else s.statusText,
        )
    }

    private fun retirePrivateSurface(s: UiState): UiState =
        finishPrivateSurface(s).copy(
            pendingSurface = if (isPrivateChromeSurface(s.pendingSurfaceKey)) null else s.pendingSurface,
            privateSurfaceFailed = isPrivateChromeSurface(s.pendingSurfaceKey),
        )

    private fun stageExistingAttachment(payload: JsonObject): Boolean {
        val id = (payload["attachment_id"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() } ?: return false
        if (_state.value.staged.any { it.attachmentId == id }) return true
        val filename = (payload["filename"] as? JsonPrimitive)?.contentOrNull ?: "attachment"
        val category = (payload["category"] as? JsonPrimitive)?.contentOrNull ?: "file"
        _state.value =
            _state.value.copy(
                staged = _state.value.staged + StagedAttachment(++attachSeq, filename, category, id, "ready"),
            )
        return true
    }

    fun applyTheme(spec: JsonObject) {
        _state.value = _state.value.copy(themePalette = themePaletteForSpec(_state.value.themePalette, spec))
    }

    fun openChat(chatId: String) {
        _state.update { retirePrivateSurface(it) }
        workspaceEpoch++
        if (!persistActiveChat(chatId)) {
            _state.value =
                _state.value.copy(
                    banner = "Could not save the selected conversation.",
                    bannerKind = "error",
                )
            return
        }
        val switching = _state.value.activeChatId != chatId
        _state.value =
            _state.value.copy(
                activeChatId = chatId,
                composerDraft = if (switching) "" else _state.value.composerDraft,
                backgroundNextSend = if (switching) false else _state.value.backgroundNextSend,
                screen = Screen.Chat,
                viewingIndex = null,
                lastCommittedRenderRevision = if (switching) 0UL else _state.value.lastCommittedRenderRevision,
                transientCanvas = null,
                pendingTurns = emptyList(),
            )
        voiceController?.updateVisibleChatLocally(chatId)
        requestChatRefresh(chatId, locatorAlreadyPersisted = true)
    }

    private fun requestChatRefresh(
        chatId: String,
        locatorAlreadyPersisted: Boolean = false,
    ) {
        if (!locatorAlreadyPersisted && !persistActiveChat(chatId)) {
            _state.value =
                _state.value.copy(
                    banner = "Could not save the selected conversation.",
                    bannerKind = "error",
                )
            return
        }
        sendEvent("load_chat", buildJsonObject { put("chat_id", chatId) })
    }

    fun setToolEnabled(
        agent: Agent,
        tool: String,
        enabled: Boolean,
    ) {
        patchAgent(agent.id) { it.copy(permissions = it.permissions + (tool to enabled)) }
        val t = token ?: return
        val kind = agent.toolScopeMap[tool] ?: "tools:read"
        viewModelScope.launch {
            runCatching { rest.setToolPermission(t, agent.id, tool, kind, enabled) }
            sendEvent("discover_agents")
        }
    }

    fun setAgentEnabled(
        agent: Agent,
        enabled: Boolean,
    ) {
        patchAgent(agent.id) { a -> a.copy(permissions = a.tools.associateWith { enabled }) }
        val kinds = agent.toolScopeMap.values.toSet().ifEmpty { agent.scopes.keys }
        sendEvent(
            "set_agent_permissions",
            buildJsonObject {
                put("agent_id", agent.id)
                putJsonObject("scopes") { kinds.forEach { put(it, enabled) } }
                putJsonObject("tool_overrides") { agent.tools.forEach { put(it, enabled) } }
            },
        )
        sendEvent("discover_agents")
    }

    private fun patchAgent(
        agentId: String,
        transform: (Agent) -> Agent,
    ) {
        _state.value =
            _state.value.copy(
                agents = _state.value.agents.map { if (it.id == agentId) transform(it) else it },
            )
    }

    fun enableRecommended() {
        sendEvent("enable_recommended_agents")
        sendEvent("discover_agents")
    }

    private fun loadAudit() {
        val t = token
        if (t == null) {
            _state.value = _state.value.copy(auditLoading = false)
            return
        }
        viewModelScope.launch {
            val events = runCatching { rest.audit(t) }.getOrDefault(emptyList())
            _state.value = _state.value.copy(audit = events, auditLoading = false)
        }
    }

    internal fun reduceConnectionState(
        s: UiState,
        connection: ConnectionState,
    ): UiState =
        when (connection) {
            ConnectionState.AuthRequired -> retirePrivateSurface(s).copy(connection = connection)
            ConnectionState.Disconnected ->
                retirePrivateSurface(s).copy(
                    connection = connection,
                    turnActive = false, backgroundRequested = false,
                    pendingReplace = false,
                    pendingCanvas = emptyList(),
                    preTurnCanvas = emptyList(),
                    turnOpsApplied = false,
                    transientCanvas = null,
                    pendingTurns = emptyList(),
                    connectionGeneration = null,
                    usedConversationRequestGenerations = emptySet(),
                    requestGeneration = null,
                    requestChatId = null,
                    requestPurpose = null,
                    expectedCommitRenderRevision = null,
                    hydrationApplied = false,
                    acceptedSnapshotId = null,
                    acceptedSnapshot = null,
                    lastTransientFrameSequence = 0UL,
                    agentsLoading = false,
                    historyLoading = false,
                    auditLoading = false,
                    pendingSubmissions = emptyMap(),
                    statusText = null,
                )
            ConnectionState.Connected -> s.copy(connection = connection, everConnected = true)
            else -> s.copy(connection = connection)
        }

    internal fun reduce(
        s: UiState,
        msg: Inbound,
    ): UiState =
        when (msg) {
            is Inbound.UiRender -> reduceUiRender(s, msg)
            is Inbound.UiUpsert -> reduceUiUpsert(s, msg)
            is Inbound.ChatCreated -> {
                val pendingVoice = pendingVoiceActivation?.submission
                if (pendingVoice != null && !isExpectedVoiceChatCreation(s, pendingVoice, msg)) {
                    s
                } else {
                    bindAcknowledgedChat(s, msg.chatId)
                }
            }
            is Inbound.UserMessageAcked ->
                if (msg.chatId != null && s.requestChatId != null && msg.chatId != s.requestChatId) {
                    s
                } else {
                    bindAcknowledgedChat(if (s.pendingReplace || s.backgroundRequested) s else armTurn(s), msg.chatId)
                }
            is Inbound.ChatLoaded ->
                if (s.connectionGeneration == null) reduceLegacyChatLoaded(s, msg) else s
            is Inbound.ConversationSnapshot -> reduceConversationSnapshot(s, msg)
            is Inbound.ConversationCommitReady -> reduceConversationCommitReady(s, msg)
            is Inbound.ChatStatus -> reduceStatus(s, msg)
            is Inbound.AgentList -> s.copy(agents = msg.agents, agentsLoading = false)
            is Inbound.HistoryList -> s.copy(history = msg.chats, historyTitle = "Recent chats", historyLoading = false)
            is Inbound.UiStreamData -> reduceUiStreamData(s, msg)
            is Inbound.StreamSubscribed ->
                if (hasGenerationScopedConversation(s)) {
                    s
                } else {
                    applyCanvasOps(s, subscribeAckOps(msg, canvasIds(s)))
                }
            is Inbound.StreamErrorMsg ->
                if (hasGenerationScopedConversation(s)) {
                    s.copy(
                        banner = msg.error.message ?: msg.error.code ?: "Stream error",
                        bannerKind = "error",
                    )
                } else {
                    applyCanvasOps(s, streamErrorOps(msg))
                }
            is Inbound.ChromeMenu -> s.copy(chromeMenu = msg.model)
            is Inbound.ChromeSurface ->
                when {
                    s.screen == Screen.Surface && isPrivateChromeSurface(s.pendingSurfaceKey) && msg.surfaceKey != s.pendingSurfaceKey -> s
                    isPrivateChromeSurface(msg.surfaceKey) || msg.requestGeneration != null -> {
                        val request = s.privateSurfaceRequest
                        if (!isPrivateChromeSurface(msg.surfaceKey) || msg.mode != "replace" || request == null ||
                            request.surfaceKey != msg.surfaceKey ||
                            msg.requestGeneration != request.requestGeneration ||
                            request.connectionGeneration != s.connectionGeneration ||
                            s.screen != Screen.Surface || s.pendingSurfaceKey != request.surfaceKey
                        ) {
                            s
                        } else {
                            finishPrivateSurface(s).copy(pendingSurface = msg, privateSurfaceFailed = false)
                        }
                    }
                    msg.surfaceKey.isBlank() && msg.components.isEmpty() ->
                        if (s.screen == Screen.Surface) {
                            finishPrivateSurface(s).copy(
                                screen = Screen.Chat,
                                pendingSurface = null,
                                privateSurfaceRequest = null,
                                privateSurfaceFailed = false,
                                pendingSurfaceKey = "",
                                pendingSurfaceParams = JsonObject(emptyMap()),
                                mandatorySurface = false,
                            )
                        } else {
                            s.copy(mandatorySurface = false)
                        }
                    msg.mode == "mandatory" ->
                        retirePrivateSurface(s).copy(
                            screen = Screen.Surface,
                            pendingSurface = msg,
                            pendingSurfaceKey = msg.surfaceKey,
                            pendingSurfaceParams = JsonObject(emptyMap()),
                            mandatorySurface = true,
                        )
                    s.screen == Screen.Surface && s.pendingSurfaceKey == msg.surfaceKey ->
                        s.copy(pendingSurface = msg)
                    else -> {
                        val text =
                            listOf(msg.title, noticeText(msg.components))
                                .filter { it.isNotBlank() }
                                .joinToString(": ")
                        if (text.isBlank()) s else s.copy(banner = text, bannerKind = "error")
                    }
                }
            is Inbound.UserPreferences -> s.copy(themePalette = themePaletteForSpec(s.themePalette, msg.theme))
            is Inbound.WorkspaceTimelineMode -> s.copy(timelineReadOnly = msg.active)
            is Inbound.AdmissionRefusal -> reduceAdmissionRefusal(s, msg)
            is Inbound.ErrorFrame -> reduceErrorFrame(s, msg)
            is Inbound.ChatStep ->
                s.copy(stepTrail = trailUpsert(s.stepTrail, stepLine(msg)))
            is Inbound.ToolProgress ->
                s.copy(stepTrail = trailUpsert(s.stepTrail, "• ${msg.label}"))
            is Inbound.OperationStatus -> reduceOperationStatus(s, msg)
            is Inbound.AgentLifecycle -> reduceAgentLifecycle(s, msg)
            is Inbound.TaskStarted ->
                if (forOpenChat(msg.chatId, s)) {
                    s.copy(statusText = "Working in the background…", asyncDetached = true)
                } else {
                    s.copy(banner = "Background task started in another chat", bannerKind = "info")
                }
            is Inbound.TaskCompleted ->
                if (forOpenChat(msg.chatId, s)) {
                    val settled =
                        if (s.connectionGeneration == null) {
                            commitTurn(s)
                        } else {
                            s.copy(statusText = null, asyncDetached = false)
                        }
                    settled.copy(banner = "Background task finished", bannerKind = "info")
                } else {
                    s.copy(banner = "Background task finished in another chat — open it from History", bannerKind = "info")
                }
            is Inbound.Notification -> {
                val text =
                    listOfNotNull(
                        msg.title?.takeIf { it.isNotBlank() },
                        msg.body?.takeIf { it.isNotBlank() },
                    ).joinToString(": ")
                if (text.isBlank()) {
                    s
                } else {
                    s.copy(banner = text, bannerKind = if (msg.level == "error") "error" else "info")
                }
            }
            is Inbound.ComponentSaved ->
                s.copy(
                    banner = msg.title?.takeIf { it.isNotBlank() }?.let { "Saved $it" } ?: "Component saved",
                    bannerKind = "info",
                )
            is Inbound.ComponentSaveError ->
                s.copy(banner = msg.error ?: "Couldn't save component", bannerKind = "error")
            is Inbound.ComponentDeleted ->
                if (hasGenerationScopedConversation(s)) {
                    s
                } else {
                    msg.componentId?.takeIf { it.isNotBlank() }
                        ?.let { applyCanvasOps(s, listOf(CanvasOp("remove", it))) } ?: s
                }
            is Inbound.CombineStatus -> s.copy(statusText = msg.message ?: msg.status)
            is Inbound.CombineError ->
                s.copy(statusText = null, banner = msg.error ?: "Couldn't combine components", bannerKind = "error")
            is Inbound.ComponentsReplaced -> {
                if (hasGenerationScopedConversation(s)) {
                    s.copy(statusText = null)
                } else {
                    val ops =
                        msg.removedIds.map { CanvasOp("remove", it) } +
                            msg.newComponents.mapNotNull { c -> c.id?.let { CanvasOp("upsert", it, c) } }
                    applyCanvasOps(s.copy(statusText = null), ops)
                }
            }
            is Inbound.SavedComponentsList -> {
                Log.i(TAG, "saved_components_list acked (${msg.count} components)")
                s
            }
            is Inbound.Unknown -> {
                if (ProtocolManifest.isClassified(msg.type)) {
                    Log.i(TAG, "ignored frame type=${msg.type}")
                } else {
                    Log.w(TAG, "unhandled frame type=${msg.type}")
                }
                s
            }
            else -> s
        }

    internal fun bindConversationGeneration(
        s: UiState,
        binding: ConversationGenerationBinding,
    ): UiState {
        val switchingChats =
            binding.chatId != null && s.activeChatId != null && binding.chatId != s.activeChatId
        val current = if (s.connectionGeneration != binding.connectionGeneration) retirePrivateSurface(s) else s
        return current.copy(
            activeChatId = binding.chatId ?: s.activeChatId,
            connectionGeneration = binding.connectionGeneration,
            requestGeneration = binding.requestGeneration,
            requestChatId = binding.chatId,
            requestPurpose = binding.purpose,
            usedConversationRequestGenerations =
                (if (binding.connectionGeneration == s.connectionGeneration) s.usedConversationRequestGenerations else emptySet()) +
                    listOfNotNull(binding.requestGeneration),
            expectedCommitRenderRevision = null,
            lastCommittedRenderRevision = if (switchingChats) 0UL else s.lastCommittedRenderRevision,
            lastTransientFrameSequence = 0UL,
            transientCanvas = null,
            pendingTurns = if (binding.purpose == ConversationRequestPurpose.HYDRATION) emptyList() else s.pendingTurns,
            hydrationApplied = false,
            acceptedSnapshotId = null,
            acceptedSnapshot = null,
        )
    }

    private fun installConversationGeneration(binding: ConversationGenerationBinding) {
        _state.update { current -> bindConversationGeneration(current, binding) }
        val currentToken = token
        val currentDevice = device
        val deviceId = currentDevice?.deviceId
        if (currentToken != null && deviceId != null) {
            voiceController?.installUiConnection(
                token = currentToken,
                deviceId = deviceId,
                connectionGeneration = binding.connectionGeneration,
                visibleChatId = binding.chatId ?: _state.value.activeChatId,
            )
        }
        snapshotTimeout?.cancel()
        if (binding.purpose == ConversationRequestPurpose.HYDRATION) {
            scheduleSnapshotTimeout(binding)
        }
    }

    private fun scheduleSnapshotTimeout(
        binding: ConversationGenerationBinding,
        expectedCommitRevision: ULong? = null,
    ) {
        val chatId = binding.chatId ?: return
        val requestGeneration = binding.requestGeneration ?: return
        snapshotTimeout?.cancel()
        snapshotTimeout =
            viewModelScope.launch {
                delay(SNAPSHOT_TIMEOUT_MS)
                val current = _state.value
                val stillWaiting =
                    current.activeChatId == chatId &&
                        current.connectionGeneration == binding.connectionGeneration &&
                        current.requestGeneration == requestGeneration &&
                        current.requestPurpose == binding.purpose &&
                        current.expectedCommitRenderRevision == expectedCommitRevision &&
                        !(binding.purpose == ConversationRequestPurpose.HYDRATION && current.hydrationApplied)
                if (!stillWaiting) return@launch
                _state.value =
                    current.copy(
                        statusText = "Conversation restore timed out; retrying…",
                        transientCanvas = null,
                        pendingTurns = emptyList(),
                        lastTransientFrameSequence = 0UL,
                    )
                requestChatRefresh(chatId)
            }
    }

    internal fun snapshotRetryTarget(
        s: UiState,
        msg: Inbound,
    ): String? {
        val error = msg as? Inbound.ErrorFrame ?: return null
        if (error.code != SNAPSHOT_RETRYABLE_CODE || !error.retryable) return null
        val chatId = error.chatId ?: return null
        return chatId.takeIf {
            s.requestPurpose != null &&
                s.requestGeneration != null &&
                chatId == s.activeChatId &&
                error.connectionGeneration == s.connectionGeneration &&
                error.requestGeneration == s.requestGeneration
        }
    }

    internal fun reduceWithPersistence(
        s: UiState,
        msg: Inbound,
    ): UiState {
        if (msg is Inbound.ErrorFrame && isDefinitiveCurrentChatMiss(s, msg)) {
            if (!clearResumeLocator(ClearReason.CONFIRMED_DELETION)) {
                return s.copy(
                    banner = "Conversation was removed, but local recovery state could not be cleared.",
                    bannerKind = "error",
                )
            }
            return clearConversationState(s).copy(
                banner = "Conversation not found.",
                bannerKind = "error",
            )
        }

        val candidate = reduce(s, msg)
        val acknowledgedChat =
            when (msg) {
                is Inbound.ChatCreated ->
                    msg.chatId?.takeIf { candidate.activeChatId == it && candidate !== s }
                is Inbound.UserMessageAcked ->
                    msg.chatId?.takeIf { candidate.activeChatId == it && candidate !== s }
                is Inbound.ConversationSnapshot ->
                    msg.chatId.takeIf {
                        candidate !== s &&
                            candidate.activeChatId == msg.chatId &&
                            candidate.lastCommittedRenderRevision == msg.renderRevision
                    }
                else -> null
            }
        if (acknowledgedChat != null && !persistActiveChat(acknowledgedChat)) {
            return s.copy(
                banner = "Could not save the active conversation; the update was not applied.",
                bannerKind = "error",
            )
        }
        return candidate
    }

    private fun persistActiveChat(chatId: String): Boolean {
        val owner = account ?: return resumeStore == null
        val store = resumeStore ?: return true
        return store.save(owner, chatId)
    }

    private fun clearResumeLocator(reason: ClearReason): Boolean {
        val owner = account ?: return resumeStore == null
        val store = resumeStore ?: return true
        return store.clear(owner, reason)
    }

    fun signOut(clearCredentials: () -> Unit): Boolean {
        val cleared = clearConversationForSignOut()
        clearCredentials()
        return cleared
    }

    fun clearConversationForSignOut(): Boolean {
        workspaceEpoch++
        voiceController?.logout()
        viewModelScope.coroutineContext.cancelChildren()
        session = null
        snapshotTimeout = null
        client.clearOwnerSession()
        val cleared = clearResumeLocator(ClearReason.DEFINITIVE_SIGN_OUT)
        token = null
        device = null
        account = null
        pendingVoiceActivation = null
        attachSeq = 0
        seqState.clear()
        _state.value = UiState()
        return cleared
    }

    private fun isDefinitiveCurrentChatMiss(
        s: UiState,
        error: Inbound.ErrorFrame,
    ): Boolean =
        error.code in DEFINITIVE_CHAT_MISS_CODES &&
            error.chatId == s.activeChatId &&
            error.connectionGeneration == s.connectionGeneration &&
            error.requestGeneration == s.requestGeneration &&
            !error.retryable

    private fun clearConversationState(s: UiState): UiState =
        s.copy(
            activeChatId = null,
            turns = emptyList(),
            pendingTurns = emptyList(),
            canvas = emptyList(),
            transientCanvas = null,
            pendingCanvas = emptyList(),
            preTurnCanvas = emptyList(),
            turnOpsApplied = false,
            canvasHistory = emptyList(),
            viewingIndex = null,
            turnActive = false, backgroundRequested = false,
            pendingReplace = false,
            canvasLabel = "",
            pendingLabel = "",
            statusText = null,
            stepTrail = emptyList(),
            asyncDetached = false,
            requestGeneration = null,
            requestChatId = null,
            requestPurpose = null,
            expectedCommitRenderRevision = null,
            lastCommittedRenderRevision = 0UL,
            lastTransientFrameSequence = 0UL,
            hydrationApplied = false,
            acceptedSnapshotId = null,
            acceptedSnapshot = null,
        )

    private fun bindAcknowledgedChat(
        s: UiState,
        chatId: String?,
    ): UiState {
        if (chatId == null) return s
        if (s.requestChatId != null && s.requestChatId != chatId) return s
        return s.copy(activeChatId = chatId, requestChatId = chatId)
    }

    private fun retireCurrentCommit(
        s: UiState,
        requestGeneration: String,
    ): UiState {
        if (s.requestPurpose != ConversationRequestPurpose.COMMIT || s.requestGeneration != requestGeneration) return s
        return s.copy(
            requestGeneration = null,
            requestChatId = null,
            requestPurpose = null,
            expectedCommitRenderRevision = null,
            transientCanvas = null,
            lastTransientFrameSequence = 0UL,
        )
    }

    private fun reduceConversationCommitReady(
        s: UiState,
        ready: Inbound.ConversationCommitReady,
    ): UiState {
        if (
            ready.schemaVersion != 1 ||
            ready.chatId != s.activeChatId ||
            ready.connectionGeneration != s.connectionGeneration ||
            ready.requestGeneration in s.usedConversationRequestGenerations ||
            ready.renderRevision <= s.lastCommittedRenderRevision
        ) {
            Log.i(TAG, "conversation_commit_ready ignored: stale or foreign scope")
            return s
        }
        if (s.requestPurpose == ConversationRequestPurpose.COMMIT && s.requestGeneration != null) {
            Log.i(TAG, "commit_request_busy")
            return s
        }
        return s.copy(
            requestGeneration = ready.requestGeneration,
            requestChatId = ready.chatId,
            requestPurpose = ConversationRequestPurpose.COMMIT,
            usedConversationRequestGenerations = s.usedConversationRequestGenerations + ready.requestGeneration,
            expectedCommitRenderRevision = ready.renderRevision,
            lastTransientFrameSequence = 0UL,
            transientCanvas = null,
            hydrationApplied = false,
            acceptedSnapshotId = null,
            acceptedSnapshot = null,
        )
    }

    private fun reduceConversationSnapshot(
        s: UiState,
        snapshot: Inbound.ConversationSnapshot,
    ): UiState {
        val expectedPurpose =
            when (s.requestPurpose) {
                ConversationRequestPurpose.HYDRATION -> "hydration"
                ConversationRequestPurpose.COMMIT -> "commit"
                null -> null
            }
        if (
            snapshot.schemaVersion != 1 ||
            snapshot.chatId != s.activeChatId ||
            (s.requestChatId != null && snapshot.chatId != s.requestChatId) ||
            snapshot.connectionGeneration != s.connectionGeneration ||
            snapshot.requestGeneration != s.requestGeneration ||
            snapshot.snapshotPurpose != expectedPurpose
        ) {
            Log.i(TAG, "conversation snapshot ignored: wrong scope or purpose")
            return s
        }
        if (
            s.expectedCommitRenderRevision != null &&
            snapshot.renderRevision != s.expectedCommitRenderRevision
        ) {
            Log.w(TAG, "conversation snapshot ignored: commit-ready revision mismatch")
            return s
        }
        if (snapshot.renderRevision < s.lastCommittedRenderRevision) {
            Log.i(TAG, "stale_frame_ignored")
            return s
        }
        if (snapshot.renderRevision == s.lastCommittedRenderRevision) {
            if (
                s.requestPurpose == ConversationRequestPurpose.HYDRATION &&
                !s.hydrationApplied
            ) {
                return applyConversationSnapshot(s, snapshot)
            }
            if (s.hydrationApplied && s.acceptedSnapshotId == snapshot.snapshotId) {
                if (s.acceptedSnapshot == snapshot) return s
                Log.w(TAG, "revision_conflict: snapshot identity content changed")
                return s
            }
            if (s.hydrationApplied) Log.w(TAG, "revision_conflict") else Log.i(TAG, "unexpected_equal_commit")
            return s
        }
        return applyConversationSnapshot(s, snapshot)
    }

    private fun applyConversationSnapshot(
        s: UiState,
        snapshot: Inbound.ConversationSnapshot,
    ): UiState {
        val transcript = decodeTranscript(snapshot.transcript)
        if (transcript == null) {
            Log.w(TAG, "conversation snapshot rejected: semantic transcript decode failed")
            return s
        }
        val hydration = s.requestPurpose == ConversationRequestPurpose.HYDRATION
        return s.copy(
            activeChatId = snapshot.chatId,
            turns = transcript,
            pendingTurns = emptyList(),
            canvas = snapshot.canvas.components,
            transientCanvas = null,
            pendingCanvas = emptyList(),
            preTurnCanvas = emptyList(),
            turnOpsApplied = false,
            canvasHistory = emptyList(),
            viewingIndex = null,
            turnActive = false, backgroundRequested = false,
            pendingReplace = false,
            canvasLabel = "",
            pendingLabel = "",
            statusText = null,
            stepTrail = emptyList(),
            asyncDetached = false,
            lastCommittedRenderRevision = snapshot.renderRevision,
            lastTransientFrameSequence = 0UL,
            hydrationApplied = hydration,
            acceptedSnapshotId = if (hydration) snapshot.snapshotId else null,
            acceptedSnapshot = if (hydration) snapshot else null,
            requestGeneration = if (hydration) s.requestGeneration else null,
            requestChatId = if (hydration) snapshot.chatId else null,
            requestPurpose = if (hydration) s.requestPurpose else null,
            expectedCommitRenderRevision = null,
        )
    }

    private fun decodeTranscript(messages: List<JsonObject>): List<ChatTurn>? =
        messages.map { message -> decodeTranscriptMessage(message) ?: return null }

    private fun decodeTranscriptMessage(message: JsonObject): ChatTurn? {
        val messageId = message.string("message_id") ?: return null
        val role = message.string("role") ?: return null
        val createdAt = message.string("created_at") ?: return null
        val rawParts = message["parts"] as? JsonArray ?: return null
        val rawAttachments = message["attachments"] as? JsonArray ?: return null
        if (rawParts.isEmpty() || rawAttachments.any { it !is JsonObject }) return null
        val segments = rawParts.map { decodeTranscriptPart(it as? JsonObject ?: return null) }
        return ChatTurn(
            role = role,
            text = segments.joinToString("\n") { it.text }.trim(),
            segments = segments,
            attachments = rawAttachments.map { it.jsonObject },
            messageId = messageId,
            createdAt = createdAt,
        )
    }

    private fun decodeTranscriptPart(part: JsonObject): ChatSegment {
        val recovery =
            ChatSegment(
                kind = ChatSegmentKind.RECOVERY,
                text = RECOVERY_MESSAGE,
            )
        return when (part.string("type")) {
            "text" -> {
                val text = part.string("text")
                if (text.isNullOrBlank()) recovery else ChatSegment(ChatSegmentKind.TEXT, text)
            }
            "structured" -> {
                val plain = part.string("plain_text")
                if (plain.isNullOrBlank() || !part.containsKey("value")) {
                    recovery
                } else {
                    ChatSegment(
                        kind = ChatSegmentKind.STRUCTURED,
                        text = plain,
                        structuredValue = part["value"],
                    )
                }
            }
            "components" -> {
                val values = part["components"] as? JsonArray
                if (values == null || values.isEmpty() || values.any { it !is JsonObject }) {
                    recovery
                } else {
                    val components = Component.listFromJson(values)
                    val text =
                        flattenSemanticComponentText(components).ifBlank {
                            components.joinToString(", ") { "[${it.type.ifBlank { "component" }}]" }
                        }
                    ChatSegment(ChatSegmentKind.COMPONENTS, text, components)
                }
            }
            "recovery" -> {
                val message = part.string("message")
                ChatSegment(ChatSegmentKind.RECOVERY, message?.takeIf { it.isNotBlank() } ?: RECOVERY_MESSAGE)
            }
            else -> recovery
        }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun flattenSemanticComponentText(components: List<Component>): String =
        components.joinToString("\n") { component ->
            val own =
                SEMANTIC_TEXT_KEYS.mapNotNull { key ->
                    (component.attributes[key] as? JsonPrimitive)?.contentOrNull
                }.joinToString(" ")
            listOf(own, flattenSemanticComponentText(component.children))
                .filter { it.isNotBlank() }
                .joinToString("\n")
        }.trim()

    private fun reduceErrorFrame(
        s: UiState,
        error: Inbound.ErrorFrame,
    ): UiState {
        val banner =
            if (error.code != null && error.code != "internal") {
                "${error.message} (${error.code})"
            } else {
                error.message
            }
        return s.copy(
            banner = banner,
            bannerKind = "error",
            turnActive = false, backgroundRequested = false,
            pendingReplace = false,
            pendingCanvas = emptyList(),
            preTurnCanvas = emptyList(),
            turnOpsApplied = false,
            transientCanvas = null,
            pendingTurns = emptyList(),
            lastTransientFrameSequence = 0UL,
            agentsLoading = false,
            historyLoading = false,
            auditLoading = false,
            statusText = null,
            asyncDetached = false,
        )
    }

    private fun reduceAdmissionRefusal(
        s: UiState,
        refusal: Inbound.AdmissionRefusal,
    ): UiState {
        val pending =
            s.pendingSubmissions.entries.firstOrNull { (_, submission) ->
                submission.submissionId == refusal.submissionId
            } ?: return s
        val chatSubmission = pending.value.action == "chat_message"
        val ownsCurrentChatTurn =
            chatSubmission &&
                (
                    pending.key == s.requestGeneration ||
                        (s.requestGeneration == null && s.pendingSubmissions.keys.lastOrNull() == pending.key)
                )
        val retained = s.pendingSubmissions - pending.key
        val settled =
            s.copy(
                banner = "${refusal.message} (${refusal.code})",
                bannerKind = "error",
                pendingSubmissions = retained,
                statusText =
                    when {
                        !ownsCurrentChatTurn && s.turnActive -> s.statusText
                        retained.isNotEmpty() -> "Submitting…"
                        else -> null
                    },
                turnActive = if (ownsCurrentChatTurn) false else s.turnActive,
                pendingReplace = if (ownsCurrentChatTurn) false else s.pendingReplace,
                pendingCanvas = if (ownsCurrentChatTurn) emptyList() else s.pendingCanvas,
                preTurnCanvas = if (ownsCurrentChatTurn) emptyList() else s.preTurnCanvas,
                turnOpsApplied = if (ownsCurrentChatTurn) false else s.turnOpsApplied,
                transientCanvas = if (ownsCurrentChatTurn) null else s.transientCanvas,
                pendingTurns = if (ownsCurrentChatTurn) emptyList() else s.pendingTurns,
                lastTransientFrameSequence = if (ownsCurrentChatTurn) 0UL else s.lastTransientFrameSequence,
                stepTrail = if (ownsCurrentChatTurn) emptyList() else s.stepTrail,
                asyncDetached = if (ownsCurrentChatTurn) false else s.asyncDetached,
            )
        return if (ownsCurrentChatTurn) retireCurrentCommit(settled, pending.key) else settled
    }

    private fun reduceOperationStatus(
        s: UiState,
        status: Inbound.OperationStatus,
    ): UiState {
        if (status.connectionGeneration != s.connectionGeneration) {
            return s
        }
        val pendingOperation = s.pendingSubmissions[status.requestGeneration]
        val inScope =
            if (status.chatId != null) {
                status.chatId == s.activeChatId &&
                    (
                        status.requestGeneration == s.requestGeneration ||
                            pendingOperation?.action == status.action
                    )
            } else {
                pendingOperation != null && pendingOperation.action == status.action
            }
        if (!inScope) return s
        val current = s.operationStatuses[status.operationId]
        if (current != null && (current.terminal || status.sequence <= current.sequence)) {
            return s
        }
        val visible = status.error?.message ?: status.label
        val retained = s.operationStatuses + (status.operationId to status)
        val pending =
            if (status.terminal) {
                s.pendingSubmissions - status.requestGeneration
            } else {
                s.pendingSubmissions
            }
        val chatOperation = status.action == "chat_message"
        val ownsCurrentChatTurn = chatOperation && status.requestGeneration == s.requestGeneration
        // Completion can race ahead of the snapshot; overlay stays until it lands
        val discardsCurrentChatPreview = ownsCurrentChatTurn && status.state != "completed"
        return if (status.terminal) {
            val errorNotice =
                status.error?.let { error ->
                    "${error.message} (${error.code})"
                }
            val settled =
                s.copy(
                    operationStatuses = retained,
                    pendingSubmissions = pending,
                    statusText =
                        when {
                            !ownsCurrentChatTurn && s.turnActive -> s.statusText
                            pending.isNotEmpty() -> "Submitting…"
                            else -> null
                        },
                    banner = errorNotice ?: s.banner,
                    bannerKind = if (errorNotice != null) "error" else s.bannerKind,
                    turnActive = if (ownsCurrentChatTurn) false else s.turnActive,
                    pendingReplace = if (ownsCurrentChatTurn) false else s.pendingReplace,
                    pendingCanvas = if (discardsCurrentChatPreview) emptyList() else s.pendingCanvas,
                    preTurnCanvas = if (discardsCurrentChatPreview) emptyList() else s.preTurnCanvas,
                    turnOpsApplied = if (discardsCurrentChatPreview) false else s.turnOpsApplied,
                    transientCanvas = if (discardsCurrentChatPreview) null else s.transientCanvas,
                    pendingTurns = if (discardsCurrentChatPreview) emptyList() else s.pendingTurns,
                    lastTransientFrameSequence =
                        if (discardsCurrentChatPreview) 0UL else s.lastTransientFrameSequence,
                    stepTrail = if (ownsCurrentChatTurn) emptyList() else s.stepTrail,
                    asyncDetached = if (ownsCurrentChatTurn) false else s.asyncDetached,
                )
            if (discardsCurrentChatPreview) retireCurrentCommit(settled, status.requestGeneration) else settled
        } else {
            s.copy(
                operationStatuses = retained,
                pendingSubmissions = pending,
                statusText = visible,
                turnActive = if (ownsCurrentChatTurn) true else s.turnActive,
            )
        }
    }

    private fun reduceAgentLifecycle(
        s: UiState,
        lifecycle: Inbound.AgentLifecycle,
    ): UiState {
        val current = s.agentLifecycles[lifecycle.agentId]
        if (
            current != null &&
            (
                lifecycle.lifecycleGeneration < current.lifecycleGeneration ||
                    (
                        lifecycle.lifecycleGeneration == current.lifecycleGeneration &&
                            lifecycle.stateRevision <= current.stateRevision
                    )
            )
        ) {
            return s
        }
        return s.copy(
            agentLifecycles = s.agentLifecycles + (lifecycle.agentId to lifecycle),
            banner = "${lifecycle.agentId}: ${lifecycle.label}",
            bannerKind = if (lifecycle.state == "failed") "error" else "info",
        )
    }

    private fun transientScopeMatches(
        s: UiState,
        scope: com.personalailabs.astraldeep.core.protocol.TransientFrameScope,
    ): Boolean =
        scope.chatId == s.activeChatId &&
            scope.connectionGeneration == s.connectionGeneration &&
            scope.requestGeneration == s.requestGeneration &&
            scope.baseRenderRevision == s.lastCommittedRenderRevision &&
            scope.frameSequence > s.lastTransientFrameSequence

    private fun hasGenerationScopedConversation(s: UiState): Boolean = s.connectionGeneration != null && s.activeChatId != null

    private fun reduceUiRender(
        s: UiState,
        msg: Inbound.UiRender,
    ): UiState {
        if (msg.target == "history") {
            if (msg.scope != null) return s
            val history = msg.components.firstOrNull { it.type == "chat_history" }
            if (history != null) {
                val items = history.attributes["items"] as? JsonArray ?: return s
                val chats = items.mapNotNull { (it as? JsonObject)?.let(ChatSummary::fromHistoryItem) }
                val title = (history.attributes["title"] as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()
                return s.copy(
                    history = chats,
                    historyTitle = ChatSummary.displayText(title).ifEmpty { "Recent chats" },
                    historyLoading = false,
                )
            }
            return if (msg.components.any(::isSkeleton)) s.copy(historyLoading = true) else s
        }
        if (msg.target != "chat" && !s.acceptsStartWelcome && msg.components.isNotEmpty() &&
            msg.components.all { welcomePlacementRole(it) != null }
        ) {
            return s
        }
        val scope = msg.scope
        if (scope != null) {
            if (!transientScopeMatches(s, scope)) return s
            if (msg.target == "chat") {
                val text = flattenText(msg.components)
                return s.copy(
                    pendingTurns =
                        if (text.isBlank()) s.pendingTurns else s.pendingTurns + ChatTurn("assistant", text),
                    lastTransientFrameSequence = scope.frameSequence,
                )
            }
            return s.copy(
                transientCanvas = msg.components.filterNot(::isSkeleton),
                lastTransientFrameSequence = scope.frameSequence,
                turnOpsApplied = s.turnOpsApplied || s.pendingReplace,
            )
        }
        if (s.connectionGeneration != null && s.activeChatId != null &&
            !(
                s.acceptsStartWelcome && msg.target != "chat" && msg.components.isNotEmpty() &&
                    msg.components.all { welcomePlacementRole(it) != null }
            )
        ) {
            return s
        }
        return reduceLegacyUiRender(s, msg)
    }

    private fun reduceLegacyUiRender(
        s: UiState,
        msg: Inbound.UiRender,
    ): UiState =
        if (msg.target == "chat") {
            val text = flattenText(msg.components)
            if (text.isBlank() || text.contains(DOC_ON_CANVAS_MARKER, ignoreCase = true)) {
                s
            } else {
                s.copy(turns = s.turns + ChatTurn("assistant", text))
            }
        } else {
            val (reasoning, rest0) = msg.components.partition(::isReasoning)
            val canvasComps =
                rest0.filterNot {
                    isDocCard(it.id) || isSkeleton(it) || (!s.acceptsStartWelcome && welcomePlacementRole(it) != null)
                }
            val reasoningTurns =
                reasoning.mapNotNull { component ->
                    flattenText(component.children).ifBlank { flattenText(listOf(component)) }
                        .takeIf { it.isNotBlank() }
                        ?.let { ChatTurn("reasoning", it) }
                }
            val next = if (reasoningTurns.isEmpty()) s else s.copy(turns = s.turns + reasoningTurns)
            if (next.pendingReplace) {
                if (canvasComps.isEmpty()) {
                    next
                } else {
                    next.copy(pendingCanvas = Canvas.apply(next.pendingCanvas, renderToOps(canvasComps)))
                }
            } else {
                next.copy(
                    canvas = canvasComps,
                    pendingCanvas = emptyList(),
                    workspaceStarted = next.workspaceStarted || canvasComps.any { welcomePlacementRole(it) == null },
                )
            }
        }

    private fun reduceUiUpsert(
        s: UiState,
        msg: Inbound.UiUpsert,
    ): UiState {
        val scope = msg.scope
        if (scope != null) {
            if (!transientScopeMatches(s, scope)) return s
            val preview = Canvas.apply(s.transientCanvas ?: s.canvas, msg.ops)
            return s.copy(
                transientCanvas = preview,
                lastTransientFrameSequence = scope.frameSequence,
                turnOpsApplied = s.turnOpsApplied || s.pendingReplace,
            )
        }
        if (s.connectionGeneration != null && s.activeChatId != null) return s
        if (msg.chatId != null && s.activeChatId != null && msg.chatId != s.activeChatId) return s
        val docTurns =
            msg.ops.mapNotNull { op ->
                if (op.op != "remove" && isDocCard(op.componentId)) {
                    op.component?.let { flattenText(listOf(it)) }
                        ?.takeIf { it.isNotBlank() }
                        ?.let { ChatTurn("assistant", it) }
                } else {
                    null
                }
            }
        val canvasOps = msg.ops.filterNot { isDocCard(it.componentId) || isSkeleton(it.component) }
        val next = if (docTurns.isEmpty()) s else s.copy(turns = s.turns + docTurns)
        return applyCanvasOps(next, canvasOps)
    }

    private fun reduceUiStreamData(
        s: UiState,
        msg: Inbound.UiStreamData,
    ): UiState {
        val scope = msg.scope
        val ops = streamFrameToOps(msg, s.activeChatId, seqState)
        if (scope != null) {
            if (!transientScopeMatches(s, scope)) return s
            return s.copy(
                transientCanvas = Canvas.apply(s.transientCanvas ?: s.canvas, ops),
                lastTransientFrameSequence = scope.frameSequence,
                turnOpsApplied = s.turnOpsApplied || (s.pendingReplace && ops.isNotEmpty()),
            )
        }
        if (s.connectionGeneration != null && s.activeChatId != null) return s
        return applyCanvasOps(s, ops)
    }

    private fun reduceLegacyChatLoaded(
        s: UiState,
        msg: Inbound.ChatLoaded,
    ): UiState =
        s.copy(
            activeChatId = msg.chat.id ?: s.activeChatId,
            turns = msg.chat.messages.map { ChatTurn(it.role, it.content) },
            canvas = emptyList(),
            pendingCanvas = emptyList(),
            preTurnCanvas = emptyList(),
            turnOpsApplied = false,
            canvasHistory = emptyList(),
            viewingIndex = null,
            turnActive = false, backgroundRequested = false,
            pendingReplace = false,
            canvasLabel = "",
            pendingLabel = "",
            statusText = null,
            stepTrail = emptyList(),
            asyncDetached = false,
        )

    private fun forOpenChat(
        chatId: String?,
        s: UiState,
    ): Boolean = chatId == null || s.activeChatId == null || chatId == s.activeChatId

    internal fun continuityReloadTarget(
        s: UiState,
        msg: Inbound,
    ): String? =
        when (msg) {
            is Inbound.TaskCompleted -> msg.chatId?.takeIf { it == s.activeChatId }
            is Inbound.Notification -> msg.chatId?.takeIf { it == s.activeChatId }
            else -> null
        }

    private fun stepLine(step: Inbound.ChatStep): String {
        val icon =
            when (step.status) {
                "completed" -> "✓"
                "errored" -> "✗"
                else -> "•"
            }
        return "$icon ${step.name ?: "step"}"
    }

    private fun trailKey(line: String): String = line.substringAfter(" ").replace(TRAIL_PCT, "")

    private fun trailUpsert(
        trail: List<String>,
        line: String,
    ): List<String> {
        val key = trailKey(line)
        val idx = trail.indexOfLast { trailKey(it) == key }
        val next = if (idx >= 0) trail.toMutableList().also { it[idx] = line } else trail + line
        return next.takeLast(MAX_TRAIL)
    }

    private fun canvasIds(s: UiState): Set<String> = s.canvas.mapNotNullTo(HashSet()) { it.id }

    private fun applyCanvasOps(
        s: UiState,
        ops: List<CanvasOp>,
    ): UiState {
        if (ops.isEmpty()) return s
        return s.copy(
            canvas = Canvas.apply(s.canvas, ops),
            turnOpsApplied = s.turnOpsApplied || s.pendingReplace,
        )
    }

    private fun renderToOps(components: List<Component>): List<CanvasOp> =
        components.mapIndexed { i, c ->
            val id = c.id ?: "xr-${c.type}-$i"
            CanvasOp(op = "upsert", componentId = id, component = if (c.id == null) c.copy(id = id) else c)
        }

    private fun reduceStatus(
        s: UiState,
        msg: Inbound.ChatStatus,
    ): UiState {
        val label = msg.message?.takeIf { it.isNotBlank() } ?: msg.status
        return when (msg.status) {
            "done", "idle", "completed" ->
                if (s.connectionGeneration == null) {
                    commitTurn(s)
                } else {
                    s.copy(turnActive = false, backgroundRequested = false, statusText = null, stepTrail = emptyList())
                }
            "thinking", "executing", "fixing", "processing_async" ->
                s.copy(turnActive = true, statusText = label)
            "info" ->
                label?.takeIf { it.isNotBlank() }
                    ?.let {
                        s.copy(
                            statusText = if (s.turnActive) s.statusText else null,
                            banner = it,
                            bannerKind = "info",
                        )
                    }
                    ?: s
            else -> if (s.hasActiveWork) s else s.copy(statusText = null)
        }
    }

    private fun commitTurn(s: UiState): UiState {
        if (!s.pendingReplace) {
            return s.copy(
                turnActive = false,
                backgroundRequested = false,
                statusText = null,
                stepTrail = emptyList(),
                asyncDetached = false,
            )
        }
        if (s.pendingCanvas.isEmpty() && !s.turnOpsApplied) {
            return s.copy(
                canvas = s.canvas.dropWelcome(),
                preTurnCanvas = emptyList(),
                turnActive = false,
                backgroundRequested = false,
                pendingReplace = false,
                statusText = null,
                stepTrail = emptyList(),
                asyncDetached = false,
            )
        }
        // Buffered render merges onto live canvas; must not drop applied upserts
        val live = s.canvas.dropWelcome()
        val committed = if (s.pendingCanvas.isEmpty()) live else Canvas.apply(live, renderToOps(s.pendingCanvas))
        val archived = s.preTurnCanvas.dropWelcome()
        val newHistory =
            if (archived.isNotEmpty()) {
                s.canvasHistory +
                    CanvasSnapshot(
                        label = s.canvasLabel.ifBlank { "Canvas ${s.canvasHistory.size + 1}" },
                        components = archived,
                    )
            } else {
                s.canvasHistory
            }
        return s.copy(
            canvas = committed,
            pendingCanvas = emptyList(),
            preTurnCanvas = emptyList(),
            turnOpsApplied = false,
            canvasHistory = newHistory,
            canvasLabel = s.pendingLabel,
            pendingLabel = "",
            turnActive = false, backgroundRequested = false,
            pendingReplace = false,
            statusText = null,
            stepTrail = emptyList(),
            asyncDetached = false,
        )
    }

    private fun isReasoning(c: Component): Boolean =
        c.type.equals("collapsible", ignoreCase = true) &&
            ((c.attributes["title"] as? JsonPrimitive)?.contentOrNull ?: "")
                .equals("Reasoning", ignoreCase = true)

    private fun isDocCard(id: String?): Boolean = id != null && id.startsWith("doc_")

    private fun isSkeleton(c: Component?): Boolean = c != null && c.type.equals("skeleton", ignoreCase = true)

    private fun List<Component>.dropWelcome(): List<Component> =
        filterNot { it.id?.startsWith("wel_") == true || welcomePlacementRole(it) != null }

    private fun flattenText(components: List<Component>): String =
        components.joinToString("\n") { c ->
            val own =
                (c.attributes["content"] as? JsonPrimitive)?.contentOrNull
                    ?: (c.attributes["text"] as? JsonPrimitive)?.contentOrNull
                    ?: ""
            (own + "\n" + flattenText(c.children)).trim()
        }.trim()

    private fun noticeText(components: List<Component>): String =
        components.joinToString("\n") { c ->
            val own =
                (c.attributes["message"] as? JsonPrimitive)?.contentOrNull
                    ?: (c.attributes["content"] as? JsonPrimitive)?.contentOrNull
                    ?: (c.attributes["text"] as? JsonPrimitive)?.contentOrNull
                    ?: ""
            (own + "\n" + noticeText(c.children)).trim()
        }.trim()

    private fun parserNote(status: String?): String? =
        when (status) {
            "preparing" -> "preparing reader…"
            "pending_admin_approval" -> "reader pending admin"
            "unavailable" -> "no reader yet"
            else -> null
        }

    companion object {
        private const val TAG = "AppViewModel"

        private const val SNAPSHOT_TIMEOUT_MS = 5_000L
        private const val SNAPSHOT_RETRYABLE_CODE = "snapshot_retryable"
        private const val RECOVERY_MESSAGE = "A saved response could not be displayed."
        private val DEFINITIVE_CHAT_MISS_CODES = setOf("chat_not_found", "chat_deleted")
        private val SEMANTIC_TEXT_KEYS =
            listOf("content", "text", "message", "label", "title", "value", "caption")

        private const val MAX_TRAIL = 20

        private val TRAIL_PCT = Regex("""\s*\(\d+(\.\d+)?%\)$""")

        // Suppresses the doc-card's chat lead; mobile shows the full answer in chat
        private const val DOC_ON_CANVAS_MARKER = "full write-up is on the canvas"

        fun factory(
            client: OrchestratorClient,
            rest: AstralRest,
            resumeStore: ConversationResumeStore? = null,
            voiceController: VoiceSessionController? = null,
        ) = viewModelFactory {
            initializer { AppViewModel(client, rest, resumeStore, voiceController) }
        }
    }

    override fun onCleared() {
        voiceController?.close()
        super.onCleared()
    }
}
