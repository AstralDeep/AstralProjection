package com.personalailabs.astraldeep.app.workspace

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.core.app.ActivityOptionsCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.viewModelScope
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.WorkspaceActionController
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.render.CanvasCaptureRegistry
import com.personalailabs.astraldeep.app.render.CanvasHost
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.rest.WorkspaceRest
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.app.ui.AppViewModel
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.ui.workspaceControls
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import kotlinx.coroutines.cancel
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

internal const val DOCUMENT_AUTHORITY = "com.personalailabs.astraldeep.test.workspace.documents"

/** Registration and result delivery still use AndroidX's real Activity lifecycle. */
internal class WorkspaceResultRegistry : ActivityResultRegistry() {
    data class Launch(val code: Int, val intent: Intent)

    val launches = mutableListOf<Launch>()

    override fun <I, O> onLaunch(
        requestCode: Int,
        contract: ActivityResultContract<I, O>,
        input: I,
        options: ActivityOptionsCompat?,
    ) {
        launches.add(Launch(requestCode, contract.createIntent(InstrumentationRegistry.getInstrumentation().targetContext, input)))
    }

    fun complete(
        index: Int,
        uri: Uri?,
    ) {
        check(dispatchResult(launches[index].code, if (uri == null) Activity.RESULT_CANCELED else Activity.RESULT_OK, uri?.let { Intent().setData(it) }))
    }
}

/** Real local HTTP/WebSocket bytes, with an in-memory synthetic account and resume locator. */
internal class WorkspaceControllerFixture(
    callTimeoutMillis: Long = 30_000,
    private val canvasText: String = "Synthetic visible canvas",
) : AutoCloseable {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val socket = AtomicReference<WebSocket>()

    private class NetworkAttempt(val path: String, val terminal: CountDownLatch = CountDownLatch(1))

    private val networkAttempts = CopyOnWriteArrayList<NetworkAttempt>()
    private val http =
        OkHttpClient.Builder().callTimeout(callTimeoutMillis, TimeUnit.MILLISECONDS)
            .eventListenerFactory { call ->
                val attempt = NetworkAttempt(call.request().url.encodedPath).also(networkAttempts::add)
                object : EventListener() {
                    override fun callEnd(call: Call) {
                        attempt.terminal.countDown()
                    }

                    override fun callFailed(
                        call: Call,
                        ioe: IOException,
                    ) {
                        attempt.terminal.countDown()
                    }
                }
            }.build()
    val server = MockWebServer()
    val requests = CopyOnWriteArrayList<RecordedRequest>()
    val outboundFrames = CopyOnWriteArrayList<JsonObject>()
    var response: (RecordedRequest) -> MockResponse = ::normalResponse
    var token: String? = syntheticToken("owner")
    val capture = CanvasCaptureRegistry()
    val registry = WorkspaceResultRegistry()
    val model: AppViewModel
    val rest: WorkspaceRest
    val scenario: ActivityScenario<ComponentActivity>
    lateinit var controller: WorkspaceActionController
    val resolver get() = instrumentation.targetContext.contentResolver

    init {
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.path == "/ws") {
                        return MockResponse().withWebSocketUpgrade(
                            object : WebSocketListener() {
                                override fun onOpen(
                                    webSocket: WebSocket,
                                    response: Response,
                                ) {
                                    socket.set(webSocket)
                                }

                                override fun onMessage(
                                    webSocket: WebSocket,
                                    text: String,
                                ) {
                                    outboundFrames.add(Json.parseToJsonElement(text).jsonObject)
                                }
                            },
                        )
                    }
                    requests.add(request)
                    return response(request)
                }
            }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        rest = WorkspaceRest(server.url("/").toString().removeSuffix("/"), http, allowLocalHttp = true)
        val store = ConversationResumeStore(MemoryStorage())
        check(store.save(ConversationResumeStore.AccountIdentity("https://synthetic.invalid/realm", "owner"), CHAT))
        model = AppViewModel(OrchestratorClient(server.url("/ws").toString(), http), AstralRest(server.url("/").toString()), store)
        main { model.start(checkNotNull(token), DeviceCapabilities(400, 800)) }
        await { socket.get() != null && model.state.value.requestGeneration != null }
        hydrate()
        await { model.workspaceContext() != null }
        scenario = ActivityScenario.launch(ComponentActivity::class.java)
        scenario.moveToState(Lifecycle.State.CREATED)
        scenario.onActivity { activity ->
            controller = WorkspaceActionController(activity, { token }, capture, rest, registry)
            activity.lifecycle.addObserver(
                androidx.lifecycle.LifecycleEventObserver { _, event ->
                    if (event == Lifecycle.Event.ON_DESTROY) controller.clear()
                },
            )
            activity.setContent {
                val state by model.state.collectAsState()
                AstralTheme {
                    val renderer =
                        remember {
                            Renderer(Emit { action, payload -> model.sendEvent(action, payload) }).registerAllRenderers().also {
                                it.capture = capture
                                it.captureContext = { model.workspaceContext() }
                            }
                        }
                    CanvasHost(state.visibleCanvas, renderer)
                }
            }
            activity.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("sentinel", "unchanged"))
        }
        scenario.moveToState(Lifecycle.State.RESUMED)
        await { captureReady() }
    }

    private fun captureReady(): Boolean {
        var ready = false
        main { ready = capture.node("/components/0") != null }
        return ready
    }

    fun hydrate(
        revision: Int = 1,
        purpose: String = "hydration",
        components: List<JsonObject>? = null,
    ) {
        val state = model.state.value
        val frame =
            buildJsonObject {
                put("type", "conversation_snapshot")
                put("schema_version", 1)
                put("snapshot_id", UUID.randomUUID().toString())
                put("chat_id", CHAT)
                put("connection_generation", state.connectionGeneration)
                put("request_generation", state.requestGeneration)
                put("snapshot_purpose", purpose)
                put("render_revision", revision)
                put("committed_at", "2026-09-12T00:00:00Z")
                put("transcript", JsonArray(emptyList()))
                put(
                    "canvas",
                    buildJsonObject {
                        put("target", "canvas")
                        put(
                            "components",
                            JsonArray(
                                components ?: listOf(
                                    buildJsonObject {
                                        put("type", "text")
                                        put("id", "result")
                                        put("content", canvasText)
                                    },
                                ),
                            ),
                        )
                    },
                )
            }
        send(frame)
        menu()
        val marker = UUID.randomUUID().toString()
        send(
            buildJsonObject {
                put("type", "notification")
                put("title", marker)
            },
        )
        await { model.state.value.banner == marker }
        await { model.state.value.lastCommittedRenderRevision == revision.toULong() }
    }

    fun reconnect(revision: Int = model.state.value.lastCommittedRenderRevision.toInt()) {
        val previous = model.state.value.connectionGeneration
        val previousSocket = socket.get()
        main { model.start(checkNotNull(token), DeviceCapabilities(400, 800)) }
        await { socket.get() !== previousSocket && model.state.value.connectionGeneration != previous && model.state.value.requestGeneration != null }
        hydrate(revision)
    }

    fun commitRevision(
        revision: Int,
        components: List<JsonObject>? = null,
    ) {
        val request = UUID.randomUUID().toString()
        send(
            buildJsonObject {
                put("type", "conversation_commit_ready")
                put("schema_version", 1)
                put("chat_id", CHAT)
                put("connection_generation", model.state.value.connectionGeneration)
                put("request_generation", request)
                put("render_revision", revision)
            },
        )
        await { model.state.value.requestGeneration == request }
        hydrate(revision, "commit", components)
    }

    fun menu(enabled: Boolean = true) {
        val controls =
            if (enabled) {
                listOf("export_canvas", "share_canvas").map { operation ->
                    buildJsonObject {
                        put("key", operation)
                        put("kind", "workspace_action")
                        put("label", operation)
                        put("icon", "download")
                        put("operation", operation)
                        put("context", "live_canvas")
                    }
                }
            } else {
                emptyList()
            }
        send(
            buildJsonObject {
                put("type", "chrome_menu")
                put(
                    "model",
                    buildJsonObject {
                        put("version", 2)
                        put("topbar", JsonArray(controls))
                        put("menu", JsonArray(emptyList()))
                        put("signout", buildJsonObject {})
                    },
                )
            },
        )
        await { workspaceControls(model.state.value).size == if (enabled) 2 else 0 }
    }

    fun send(frame: JsonObject) {
        check(socket.get().send(frame.toString()))
    }

    fun perform(operation: String) {
        scenario.onActivity { activity ->
            controller.perform(workspaceControls(model.state.value).single { it.operation == operation }, model)
        }
    }

    fun awaitCallCompletion(
        path: String,
        index: Int = 0,
    ) {
        await { networkAttempts.count { it.path == path } > index }
        assertTrue("Exact synthetic HTTP call did not terminate", networkAttempts.filter { it.path == path }[index].terminal.await(5, TimeUnit.SECONDS))
        instrumentation.waitForIdleSync()
    }

    fun invalidate(block: () -> Unit) {
        scenario.onActivity { activity ->
            block()
            controller.invalidateStale()
        }
    }

    fun export() {
        perform("export_canvas")
        await { registry.launches.isNotEmpty() }
    }

    fun complete(
        uri: Uri?,
        index: Int = registry.launches.lastIndex,
    ) {
        scenario.onActivity { registry.complete(index, uri) }
    }

    fun clipboard(): String {
        var text = ""
        scenario.onActivity { text = it.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.toString().orEmpty() }
        return text
    }

    fun cacheFiles(): List<File> {
        var files = emptyList<File>()
        scenario.onActivity { files = File(it.cacheDir, "workspace-exports").listFiles()?.toList().orEmpty() }
        return files
    }

    fun document(name: String): Uri = checkNotNull(DocumentsContract.createDocument(resolver, DocumentsContract.buildDocumentUri(DOCUMENT_AUTHORITY, "root"), "text/html", name))

    fun status(uri: Uri): Bundle = checkNotNull(resolver.call(DOCUMENT_AUTHORITY, "test-status", DocumentsContract.getDocumentId(uri), null))

    fun release(uri: Uri) {
        resolver.call(DOCUMENT_AUTHORITY, "test-release", DocumentsContract.getDocumentId(uri), null)
    }

    fun normalResponse(request: RecordedRequest): MockResponse {
        assertTrue("Synthetic bearer mismatch", request.getHeader("Authorization") == "Bearer ${checkNotNull(token)}")
        assertEquals("no-store", request.getHeader("Cache-Control"))
        return when {
            request.path == "/api/share" -> MockResponse().setResponseCode(201).setBody("""{"share_url":"/share/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}""")
            request.method == "GET" && request.path == "/api/export/canvas/$CHAT.html?render_revision=1" ->
                MockResponse().setHeader("X-Astral-Render-Revision", "1").setBody("authorized")
            request.method == "POST" && request.path == "/api/export/canvas/$CHAT/presentation?render_revision=1" -> {
                val capture = Json.parseToJsonElement(request.body.clone().readUtf8()).jsonObject
                val response =
                    buildJsonObject {
                        put("version", "astral.canvas-export/v1")
                        put("html", "<div class=\"dynamic-renderer\"><div class=\"astral-text\">$canvasText</div></div>")
                        put("viewport", capture.getValue("viewport"))
                        put("theme", capture.getValue("theme"))
                    }
                MockResponse().setHeader("X-Astral-Render-Revision", "1").setHeader("Content-Type", "application/json").setBody(response.toString())
            }
            else -> MockResponse().setResponseCode(404)
        }
    }

    override fun close() {
        scenario.moveToState(Lifecycle.State.DESTROYED)
        main {
            model.viewModelScope.cancel()
            capture.clear()
        }
        socket.get()?.close(1000, "Synthetic fixture complete")
        http.dispatcher.executorService.shutdownNow()
        http.connectionPool.evictAll()
        server.close()
    }

    private class MemoryStorage : ConversationResumeStore.Storage {
        val values = mutableMapOf<String, String>()

        override fun get(key: String) = values[key]

        override fun put(
            key: String,
            value: String,
        ): Boolean {
            values[key] = value
            return true
        }

        override fun remove(key: String): Boolean {
            values.remove(key)
            return true
        }
    }

    companion object {
        const val CHAT = "11111111-1111-4111-8111-111111111111"

        fun syntheticToken(owner: String): String {
            val body = """{"iss":"https://synthetic.invalid/realm","sub":"$owner"}"""
            return "synthetic.${Base64.getUrlEncoder().withoutPadding().encodeToString(body.toByteArray())}.fixture"
        }

        fun main(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

        fun await(condition: () -> Boolean) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
            while (!condition()) {
                assertTrue("Synthetic controller condition did not complete", System.nanoTime() < deadline)
                Thread.sleep(20)
            }
        }
    }
}
