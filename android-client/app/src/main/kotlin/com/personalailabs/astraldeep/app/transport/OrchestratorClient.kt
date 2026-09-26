// The reconnecting WebSocket transport: connects to /ws, sends register_ui first on every connection, decodes
// frames via Wire, and queues outbound sends while offline for replay on reconnect. Used by MainActivity and
// AppViewModel.

package com.personalailabs.astraldeep.app.transport

import android.util.Log
import com.personalailabs.astraldeep.app.auth.ServerSessionCoordinator
import com.personalailabs.astraldeep.app.auth.ServerSessionException
import com.personalailabs.astraldeep.core.chrome.TurnSelection
import com.personalailabs.astraldeep.core.protocol.ChatAttachment
import com.personalailabs.astraldeep.core.protocol.ConversationResume
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.VoicePlayoutEvent
import com.personalailabs.astraldeep.core.protocol.VoiceTranscript
import com.personalailabs.astraldeep.core.protocol.Wire
import com.personalailabs.astraldeep.core.protocol.isGuidanceNoteAction
import com.personalailabs.astraldeep.core.protocol.isPrivateChromeSurface
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.UUID
import java.util.concurrent.TimeUnit

enum class ConnectionState { Connecting, Connected, Disconnected, AuthRequired }

/** The fixed purpose bound to one UUID4 request generation. */
enum class ConversationRequestPurpose { HYDRATION, COMMIT }

data class ConversationGenerationBinding(
    val connectionGeneration: String,
    val chatId: String?,
    val requestGeneration: String?,
    val purpose: ConversationRequestPurpose?,
)

internal data class RegistrationAttempt(
    val binding: ConversationGenerationBinding,
    val frame: String,
)

data class LocalSubmission(
    val action: String,
    val chatId: String?,
    val submissionId: String,
    val requestGeneration: String,
)

data class QueuedSubmissionFailure(
    val submission: LocalSubmission,
    val reason: String,
)

fun backoffDelayMs(
    attempt: Int,
    baseMs: Long = 1_000L,
    maxMs: Long = 30_000L,
): Long {
    if (attempt <= 1) return baseMs
    val shift = (attempt - 1).coerceIn(0, 20)
    val raw = baseMs shl shift
    return if (raw <= 0L || raw > maxMs) maxMs else raw
}

class OrchestratorClient(
    private val url: String,
    private val client: OkHttpClient = defaultClient(),
    private val uuidFactory: () -> String = { UUID.randomUUID().toString() },
    private val serverSession: ((String) -> ServerSessionCoordinator?)? = null,
) {
    private val socketClient =
        if (serverSession == null) {
            client
        } else {
            client.newBuilder()
                .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
                .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
                .apply {
                    interceptors().clear()
                    networkInterceptors().clear()
                }.build()
        }

    private data class Queued(
        val action: String,
        val frame: String,
        val submission: LocalSubmission,
        val request: ConversationRequest? = null,
    )

    private data class ConversationRequest(
        val chatId: String?,
        val requestGeneration: String,
        val purpose: ConversationRequestPurpose,
    )

    @Volatile private var ownerEpoch = 0L

    @Volatile private var socket: WebSocket? = null

    @Volatile private var open = false

    @Volatile private var connectionGeneration: String? = null
    private var observedDevice: DeviceCapabilities? = null
    private var advertisedDevice: DeviceCapabilities? = null
    private val pending = ArrayDeque<Queued>()
    private val _state = MutableStateFlow(ConnectionState.Disconnected)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _dropped = MutableSharedFlow<String>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    private val _queuedFailures =
        MutableSharedFlow<QueuedSubmissionFailure>(
            extraBufferCapacity = 8,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )

    val dropped: SharedFlow<String> = _dropped.asSharedFlow()

    val queuedFailures: SharedFlow<QueuedSubmissionFailure> = _queuedFailures.asSharedFlow()

    fun clearOwnerSession() {
        synchronized(pending) {
            ownerEpoch += 1
            open = false
            connectionGeneration = null
            observedDevice = null
            advertisedDevice = null
            generationObserver = {}
            pending.clear()
            socket?.cancel()
            socket = null
            _state.value = ConnectionState.Disconnected
        }
    }

    fun stream(
        token: String,
        device: DeviceCapabilities,
        sessionId: () -> String? = { null },
        onGeneration: (ConversationGenerationBinding) -> Unit = {},
        onQueuedSubmission: (LocalSubmission) -> Unit = {},
    ): Flow<Inbound> =
        flow {
            generationObserver = onGeneration
            var attempt = 0
            while (true) {
                emitAll(
                    connectOnce(
                        token,
                        device,
                        sessionId,
                        onGeneration,
                        onQueuedSubmission,
                    ) { attempt = 0 },
                )
                if (_state.value == ConnectionState.AuthRequired && serverSession != null) {
                    val custodyRequired =
                        try {
                            serverSession.invoke(token) != null
                        } catch (_: ServerSessionException) {
                            true
                        }
                    if (custodyRequired) return@flow
                }
                _state.value = ConnectionState.Disconnected
                attempt += 1
                delay(backoffDelayMs(attempt))
            }
        }

    private fun connectOnce(
        token: String,
        device: DeviceCapabilities,
        sessionId: () -> String?,
        onGeneration: (ConversationGenerationBinding) -> Unit,
        onQueuedSubmission: (LocalSubmission) -> Unit,
        onOpen: () -> Unit,
    ): Flow<Inbound> =
        callbackFlow {
            val epoch = ownerEpoch
            _state.value = ConnectionState.Connecting
            var custodyOwner: ServerSessionCoordinator? = null
            val custody =
                try {
                    custodyOwner = serverSession?.invoke(token)
                    custodyOwner?.socketTicket(url, token)
                } catch (_: ServerSessionException) {
                    _state.value = ConnectionState.AuthRequired
                    trySend(Inbound.AuthRequired("session_required"))
                    close()
                    return@callbackFlow
                }
            val request =
                Request.Builder().url(url).apply {
                    if (custody != null) header("Cookie", custody.cookie)
                }.build()

            fun current(): Boolean = custody == null || custodyOwner?.isCurrent(custody) == true

            fun guarded(block: () -> Unit) {
                if (custody == null) block() else custodyOwner?.withCurrent(custody, block)
            }
            val listener =
                object : WebSocketListener() {
                    override fun onOpen(
                        webSocket: WebSocket,
                        response: Response,
                    ) {
                        try {
                            guarded {
                                synchronized(pending) {
                                    if (epoch != ownerEpoch) {
                                        webSocket.cancel()
                                        return@synchronized
                                    }
                                    // register_ui must be the first frame or the server refuses the rest
                                    val capabilities = observedDevice?.takeIf { it.deviceId == device.deviceId } ?: device
                                    val registration = createRegistrationAttempt(token, device, sessionId())
                                    connectionGeneration = registration.binding.connectionGeneration
                                    onGeneration(registration.binding)
                                    if (!webSocket.send(registration.frame)) {
                                        webSocket.cancel()
                                        close()
                                        return@synchronized
                                    }
                                    advertisedDevice = capabilities
                                    socket = webSocket
                                    open = true
                                    onOpen()
                                    flushPending(webSocket, onGeneration, onQueuedSubmission)
                                    _state.value = ConnectionState.Connected
                                }
                            }
                        } catch (_: ServerSessionException) {
                            webSocket.cancel()
                            close()
                        }
                    }

                    override fun onMessage(
                        webSocket: WebSocket,
                        text: String,
                    ) {
                        if (epoch != ownerEpoch || !current()) return
                        val msg = Wire.decode(text)
                        if (msg is Inbound.AuthRequired) _state.value = ConnectionState.AuthRequired
                        trySend(msg)
                    }

                    override fun onClosing(
                        webSocket: WebSocket,
                        code: Int,
                        reason: String,
                    ) {
                        if (epoch != ownerEpoch) return
                        open = false
                        connectionGeneration = null
                        webSocket.close(NORMAL_CLOSE, null)
                        close()
                    }

                    override fun onFailure(
                        webSocket: WebSocket,
                        t: Throwable,
                        response: Response?,
                    ) {
                        if (epoch != ownerEpoch) return
                        open = false
                        connectionGeneration = null
                        if (custody == null) Log.w(TAG, "WebSocket failure: ${t.message}") else Log.w(TAG, "Session WebSocket failed")
                        close()
                    }
                }
            try {
                guarded { socket = socketClient.newWebSocket(request, listener) }
            } catch (_: ServerSessionException) {
                _state.value = ConnectionState.AuthRequired
                trySend(Inbound.AuthRequired("session_required"))
                close()
                return@callbackFlow
            }
            val connectedSocket = socket
            awaitClose {
                if (epoch == ownerEpoch && socket === connectedSocket) {
                    open = false
                    connectionGeneration = null
                }
                connectedSocket?.cancel()
            }
        }

    private fun flushPending(
        webSocket: WebSocket,
        onGeneration: (ConversationGenerationBinding) -> Unit,
        onQueuedSubmission: (LocalSubmission) -> Unit,
    ) {
        flushPending(onGeneration, onQueuedSubmission, webSocket::send)
    }

    private fun flushPending(
        onGeneration: (ConversationGenerationBinding) -> Unit,
        onQueuedSubmission: (LocalSubmission) -> Unit,
        send: (String) -> Boolean,
    ) {
        synchronized(pending) {
            while (pending.isNotEmpty()) {
                val queued = pending.removeFirst()
                queued.request?.let { bindRequest(it, onGeneration) }
                onQueuedSubmission(queued.submission)
                if (!send(queued.frame)) {
                    pending.addFirst(queued)
                    break
                }
            }
        }
    }

    private fun enqueueOrSend(
        action: String,
        frame: String,
        submission: LocalSubmission,
        request: ConversationRequest? = null,
        onGeneration: (ConversationGenerationBinding) -> Unit = generationObserver,
    ) {
        val s = socket
        if (open && s != null) {
            request?.let { bindRequest(it, onGeneration) }
            // OkHttp send() false = never enqueued; safe to retry without dupes
            if (s.send(frame)) return
        }
        if (!validQueuedIdentity(frame, submission)) {
            _queuedFailures.tryEmit(
                QueuedSubmissionFailure(submission, "invalid queued identity"),
            )
            return
        }
        val droppedActions = mutableListOf<String>()
        val droppedSubmissions = mutableListOf<LocalSubmission>()
        synchronized(pending) {
            pending.addLast(Queued(action, frame, submission, request))
            while (pending.size > MAX_QUEUE) {
                val dropped = pending.removeFirst()
                droppedActions.add(dropped.action)
                droppedSubmissions.add(dropped.submission)
            }
        }
        droppedActions.forEach { _dropped.tryEmit(it) }
        droppedSubmissions.forEach { dropped ->
            _queuedFailures.tryEmit(QueuedSubmissionFailure(dropped, "offline queue full"))
        }
    }

    fun sendChat(
        message: String,
        chatId: String?,
        attachments: List<ChatAttachment> = emptyList(),
        asyncMode: Boolean = false,
        selection: TurnSelection? = null,
        onSubmission: (LocalSubmission) -> Unit = {},
    ): LocalSubmission {
        val submission = newSubmission("chat_message", chatId)
        // Register the submission before any I/O — a fast reply must find it
        onSubmission(submission)
        val request = conversationRequest(submission, ConversationRequestPurpose.COMMIT)
        enqueueOrSend(
            "chat_message",
            Wire.encodeChatMessage(
                message = message,
                chatId = chatId,
                attachments = attachments,
                asyncMode = asyncMode,
                selection = selection,
                requestGeneration = submission.requestGeneration,
                submissionId = submission.submissionId,
            ),
            submission,
            request,
        )
        return submission
    }

    fun sendVoiceTranscript(
        transcript: VoiceTranscript,
        expectedConnectionGeneration: String,
        onSubmission: (LocalSubmission) -> Unit = {},
    ): Boolean {
        val currentSocket = socket
        if (!open || currentSocket == null || connectionGeneration != expectedConnectionGeneration) return false
        val submission =
            LocalSubmission(
                action = "chat_message",
                chatId = transcript.chatId,
                submissionId = transcript.submissionId,
                requestGeneration = transcript.requestGeneration,
            )
        val frame =
            runCatching { Wire.encodeVoiceChatMessage(transcript, expectedConnectionGeneration) }
                .getOrNull() ?: return false
        val request = conversationRequest(submission, ConversationRequestPurpose.COMMIT)
        bindRequest(request, generationObserver)
        onSubmission(submission)
        return currentSocket.send(frame)
    }

    fun sendVoicePlayoutEvent(value: VoicePlayoutEvent): Boolean {
        val currentSocket = socket
        if (
            !open || currentSocket == null ||
            connectionGeneration != value.connectionGeneration
        ) {
            return false
        }
        val frame = runCatching { Wire.encodeVoicePlayoutEvent(value) }.getOrNull() ?: return false
        return currentSocket.send(frame)
    }

    fun createChatForVoice(): LocalSubmission? {
        val currentSocket = socket
        val currentGeneration = connectionGeneration
        if (!open || currentSocket == null || currentGeneration == null) return null
        val submission = newSubmission("new_chat", null)
        val frame =
            Wire.encodeCorrelatedVoiceNewChat(
                connectionGeneration = currentGeneration,
                submissionId = submission.submissionId,
                requestGeneration = submission.requestGeneration,
            )
        return submission.takeIf { currentSocket.send(frame) }
    }

    fun currentConnectionGeneration(): String? = connectionGeneration.takeIf { open }

    internal fun loadChatForVoice(
        chatId: String,
        expectedConnection: String,
        onSubmission: (LocalSubmission) -> Unit,
    ): LocalSubmission? =
        synchronized(pending) {
            val liveSocket = socket
            val epoch = ownerEpoch
            if (!open || liveSocket == null || connectionGeneration != expectedConnection) return@synchronized null
            val submission = newSubmission("load_chat", chatId)
            val frame =
                Wire.encodeUiEvent(
                    action = "load_chat",
                    sessionId = chatId,
                    payload = buildJsonObject { put("chat_id", chatId) },
                    requestGeneration = submission.requestGeneration,
                    submissionId = submission.submissionId,
                )
            onSubmission(submission)
            bindRequest(conversationRequest(submission, ConversationRequestPurpose.HYDRATION), generationObserver)
            if (!open || socket !== liveSocket || connectionGeneration != expectedConnection ||
                ownerEpoch != epoch || !liveSocket.send(frame)
            ) {
                _queuedFailures.tryEmit(QueuedSubmissionFailure(submission, "Voice conversation could not be loaded"))
                return@synchronized null
            }
            submission
        }

    internal fun observeDevice(device: DeviceCapabilities) {
        synchronized(pending) { observedDevice = device }
    }

    fun updateDevice(
        device: DeviceCapabilities,
        sessionId: String?,
    ): Boolean =
        synchronized(pending) {
            observedDevice = device
            val current = socket
            if (!open || current == null) return@synchronized false
            if (advertisedDevice == device) return@synchronized true
            if (!current.send(Wire.encodeUpdateDevice(device, sessionId))) return@synchronized false
            advertisedDevice = device
            true
        }

    internal fun refreshViewport(
        device: DeviceCapabilities,
        chatId: String,
        baseRevision: ULong,
        expectedConnection: String,
        isCurrent: () -> Boolean,
        onSubmission: (LocalSubmission) -> Unit,
    ): Boolean =
        synchronized(pending) {
            val liveSocket = socket
            val epoch = ownerEpoch
            if (!open || liveSocket == null || connectionGeneration != expectedConnection || !isCurrent()) return@synchronized false
            val submission = newSubmission("update_device", chatId)
            val frame =
                Wire.encodeUiEvent(
                    "update_device",
                    chatId,
                    buildJsonObject {
                        put("device", Wire.deviceJson(device))
                        put("chat_id", chatId)
                        put("base_render_revision", JsonPrimitive(baseRevision.toString().toBigInteger()))
                        put("snapshot_purpose", "hydration")
                        put("connection_generation", expectedConnection)
                    },
                    submission.requestGeneration,
                    submission.submissionId,
                )
            onSubmission(submission)
            bindRequest(conversationRequest(submission, ConversationRequestPurpose.HYDRATION), generationObserver)
            if (!open || socket !== liveSocket || connectionGeneration != expectedConnection || ownerEpoch != epoch ||
                !isCurrent() || !liveSocket.send(frame)
            ) {
                return@synchronized false
            }
            observedDevice = device
            advertisedDevice = device
            true
        }

    internal fun sendCurrentEvent(
        action: String,
        sessionId: String,
        payload: JsonObject,
        isCurrent: () -> Boolean,
        onSubmission: (LocalSubmission) -> Unit = {},
    ): Boolean =
        synchronized(pending) {
            val currentSocket = socket
            val generation = connectionGeneration
            val epoch = ownerEpoch
            if (action !in setOf("component_refine", "component_restore") ||
                !open || currentSocket == null || generation == null || !isCurrent()
            ) {
                return@synchronized false
            }
            val submission = newSubmission(action, sessionId)
            val frame =
                Wire.encodeUiEvent(
                    action = action,
                    sessionId = sessionId,
                    payload = payload,
                    requestGeneration = submission.requestGeneration,
                    submissionId = submission.submissionId,
                )
            if (!validQueuedIdentity(frame, submission)) return@synchronized false
            onSubmission(submission)
            if (!open || socket !== currentSocket || connectionGeneration != generation || ownerEpoch != epoch ||
                !isCurrent() || !currentSocket.send(frame)
            ) {
                _queuedFailures.tryEmit(QueuedSubmissionFailure(submission, "component action was not sent"))
                return@synchronized false
            }
            true
        }

    internal fun sendCurrentSurfaceEvent(
        surface: String,
        action: String,
        payload: JsonObject,
        isCurrent: () -> Boolean,
        onSubmission: (LocalSubmission, String) -> Unit,
    ): Boolean =
        synchronized(pending) {
            val currentSocket = socket
            val generation = connectionGeneration
            val epoch = ownerEpoch
            if (!open || currentSocket == null || generation == null || !isCurrent()) return@synchronized false
            if (!isPrivateChromeSurface(surface) ||
                !(
                    action == "chrome_open" && (payload["surface"] as? JsonPrimitive)?.contentOrNull == surface ||
                        surface == "guidance" &&
                        (
                            isGuidanceNoteAction(action) ||
                                action == "chrome_turn_selection_set" && TurnSelection.fromJson(payload)?.isGuidanceSelection == true
                        )
                )
            ) {
                return@synchronized false
            }
            val submission = newSubmission(action, null)
            val frame = Wire.encodeUiEvent(action, null, payload, submission.requestGeneration, submission.submissionId)
            onSubmission(submission, generation)
            if (!open || socket !== currentSocket || generation != connectionGeneration || epoch != ownerEpoch ||
                !isCurrent() || !currentSocket.send(frame)
            ) {
                _queuedFailures.tryEmit(QueuedSubmissionFailure(submission, "Private surface request was not sent"))
                return@synchronized false
            }
            true
        }

    fun sendEvent(
        action: String,
        sessionId: String?,
        payload: JsonObject = JsonObject(emptyMap()),
        onSubmission: (LocalSubmission) -> Unit = {},
    ): LocalSubmission {
        val payloadChat = (payload["chat_id"] as? JsonPrimitive)?.contentOrNull
        val submission = newSubmission(action, payloadChat ?: sessionId)
        onSubmission(submission)
        if (action == "update_device" && payload["snapshot_purpose"] != null ||
            isGuidanceNoteAction(action) || action == "chrome_turn_selection_set" ||
            action == "chrome_open" && isPrivateChromeSurface((payload["surface"] as? JsonPrimitive)?.contentOrNull.orEmpty())
        ) {
            _queuedFailures.tryEmit(QueuedSubmissionFailure(submission, "Private surface request requires a current connection"))
            return submission
        }
        val request =
            when (action) {
                "load_chat" -> {
                    conversationRequest(submission, ConversationRequestPurpose.HYDRATION)
                }
                "chat_message" -> conversationRequest(submission, ConversationRequestPurpose.COMMIT)
                else -> null
            }
        enqueueOrSend(
            action,
            Wire.encodeUiEvent(
                action = action,
                sessionId = sessionId,
                payload = payload,
                requestGeneration = submission.requestGeneration,
                submissionId = submission.submissionId,
            ),
            submission,
            request,
        )
        return submission
    }

    internal fun createRegistrationAttempt(
        token: String,
        device: DeviceCapabilities,
        activeChatId: String?,
    ): RegistrationAttempt {
        val actualDevice = observedDevice?.takeIf { it.deviceId == device.deviceId } ?: device
        val connection = newUuid4()
        val request = activeChatId?.let { newUuid4() }
        val binding =
            ConversationGenerationBinding(
                connectionGeneration = connection,
                chatId = activeChatId,
                requestGeneration = request,
                purpose = request?.let { ConversationRequestPurpose.HYDRATION },
            )
        return RegistrationAttempt(
            binding = binding,
            frame =
                Wire.encodeRegisterUi(
                    token = token,
                    sessionId = activeChatId,
                    device = actualDevice,
                    connectionGeneration = connection,
                    resume = request?.let { ConversationResume(activeChatId!!, it) },
                    workReads = true,
                    guidanceNotes = true,
                ),
        )
    }

    @Volatile
    private var generationObserver: (ConversationGenerationBinding) -> Unit = {}

    internal fun observeConversationGenerations(observer: (ConversationGenerationBinding) -> Unit) {
        generationObserver = observer
    }

    private fun conversationRequest(
        submission: LocalSubmission,
        purpose: ConversationRequestPurpose,
    ) = ConversationRequest(
        chatId = submission.chatId,
        requestGeneration = submission.requestGeneration,
        purpose = purpose,
    )

    private fun newSubmission(
        action: String,
        chatId: String?,
    ): LocalSubmission {
        val submissionId = newUuid4()
        val requestGeneration = newUuid4()
        require(requestGeneration != submissionId) {
            "submission and request generation must be distinct UUID4 values"
        }
        return LocalSubmission(
            action = action,
            chatId = chatId,
            submissionId = submissionId,
            requestGeneration = requestGeneration,
        )
    }

    private fun bindRequest(
        request: ConversationRequest,
        observer: (ConversationGenerationBinding) -> Unit,
    ) {
        val connection = connectionGeneration ?: return
        observer(
            ConversationGenerationBinding(
                connectionGeneration = connection,
                chatId = request.chatId,
                requestGeneration = request.requestGeneration,
                purpose = request.purpose,
            ),
        )
    }

    private fun newUuid4(): String {
        val value = uuidFactory()
        val parsed = runCatching { UUID.fromString(value) }.getOrNull()
        require(parsed?.version() == 4 && parsed.toString() == value) { "uuidFactory must return canonical UUID4" }
        return value
    }

    internal fun validQueuedIdentity(
        frame: String,
        submission: LocalSubmission,
    ): Boolean {
        val root =
            runCatching { Json.parseToJsonElement(frame).jsonObject }
                .getOrNull() ?: return false
        val payload = root["payload"]?.let { runCatching { it.jsonObject }.getOrNull() } ?: return false
        val action = (root["action"] as? JsonPrimitive)?.contentOrNull ?: return false
        val topSubmission = (root["submission_id"] as? JsonPrimitive)?.contentOrNull
        val topRequest = (root["request_generation"] as? JsonPrimitive)?.contentOrNull
        val payloadSubmission = (payload["submission_id"] as? JsonPrimitive)?.contentOrNull
        val payloadRequest = (payload["request_generation"] as? JsonPrimitive)?.contentOrNull
        if (
            (root["type"] as? JsonPrimitive)?.contentOrNull != "ui_event" ||
            action != submission.action ||
            !SNAKE_CASE.matches(action) ||
            canonicalUuid4(topSubmission) == null ||
            canonicalUuid4(topRequest) == null ||
            topSubmission != submission.submissionId ||
            topRequest != submission.requestGeneration ||
            payloadSubmission != topSubmission ||
            payloadRequest != topRequest
        ) {
            return false
        }
        val explicitChat = (payload["chat_id"] as? JsonPrimitive)?.contentOrNull
        if (explicitChat != null && canonicalUuid4(explicitChat) == null) return false
        val sessionChat =
            (root["session_id"] as? JsonPrimitive)?.contentOrNull
                ?.takeIf { canonicalUuid4(it) != null }
        val chatId = explicitChat ?: sessionChat
        return submission.chatId == chatId &&
            (submission.chatId == null || canonicalUuid4(submission.chatId) != null)
    }

    internal fun replayPendingForTest(
        connectionGeneration: String,
        onGeneration: (ConversationGenerationBinding) -> Unit,
        onQueuedSubmission: (LocalSubmission) -> Unit,
        send: (String) -> Boolean,
    ) {
        require(canonicalUuid4(connectionGeneration) != null)
        this.connectionGeneration = connectionGeneration
        flushPending(onGeneration, onQueuedSubmission, send)
    }

    internal fun installOpenSocketForTest(webSocket: WebSocket) {
        socket = webSocket
        open = true
    }

    internal fun pendingActions(): List<String> = synchronized(pending) { pending.map { it.action } }

    internal fun pendingFrames(): List<String> = synchronized(pending) { pending.map { it.frame } }

    companion object {
        private const val TAG = "OrchestratorClient"
        private const val NORMAL_CLOSE = 1000
        private const val MAX_QUEUE = 64
        private val SNAKE_CASE = Regex("^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")

        private fun canonicalUuid4(value: String?): String? {
            val parsed = runCatching { UUID.fromString(value) }.getOrNull()
            return value?.takeIf { parsed?.version() == 4 && parsed.toString() == it }
        }

        private fun defaultClient(): OkHttpClient =
            OkHttpClient.Builder()
                .pingInterval(20, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .build()
    }
}
