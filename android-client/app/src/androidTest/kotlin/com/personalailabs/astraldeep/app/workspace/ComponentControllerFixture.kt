package com.personalailabs.astraldeep.app.workspace

import android.net.Uri
import androidx.activity.compose.setContent
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.Lifecycle
import com.personalailabs.astraldeep.app.ComponentActionController
import com.personalailabs.astraldeep.app.ComponentShareDialog
import com.personalailabs.astraldeep.app.render.CanvasChrome
import com.personalailabs.astraldeep.app.render.CanvasHost
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.ComponentActionContext
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.mockwebserver.MockResponse
import java.io.File

/** Reuses the existing isolated WebSocket/Activity/SAF fixture; no user auth or product debug path. */
internal class ComponentControllerFixture : AutoCloseable {
    val base = WorkspaceControllerFixture()
    val registry = WorkspaceResultRegistry()
    lateinit var controller: ComponentActionController
    var component = component()
        private set
    private var revision = 1

    init {
        base.response = { request ->
            if (request.path?.startsWith("/api/export/component/") == true) {
                MockResponse().setBody("a,b\n1,2")
            } else {
                base.normalResponse(request)
            }
        }
        base.scenario.moveToState(Lifecycle.State.CREATED)
        base.scenario.onActivity { activity ->
            controller = ComponentActionController(activity, { base.token }, base.rest, registry)
            activity.setContent {
                val state by base.model.state.collectAsState()
                val share by controller.share.collectAsState()
                LaunchedEffect(state) { controller.invalidateStale() }
                AstralTheme {
                    val renderer =
                        remember {
                            Renderer(Emit { action, payload -> base.model.sendEvent(action, payload) }).registerAllRenderers().also {
                                it.componentActions = controller.handler(base.model)
                            }
                        }
                    CanvasHost(state.visibleCanvas, renderer, chrome = CanvasChrome(state.activeChatId, state.timelineReadOnly))
                    share?.let { link -> ComponentShareDialog(link.url, { controller.copy(link) }, { controller.dismiss(link) }) }
                }
            }
        }
        base.scenario.moveToState(Lifecycle.State.RESUMED)
        replace(component)
    }

    fun replace(next: Component) {
        component = next
        base.commitRevision(++revision, listOf(next.attributes))
        WorkspaceControllerFixture.await { base.model.state.value.visibleCanvas.singleOrNull() == next }
        invalidate { }
    }

    fun context(): ComponentActionContext = checkNotNull(controller.handler(base.model).context(component))

    fun perform(
        kind: String,
        payload: JsonObject = JsonObject(emptyMap()),
        captured: ComponentActionContext = context(),
    ) {
        base.scenario.onActivity { controller.handler(base.model).perform(captured, kind, payload) }
    }

    fun invalidate(block: () -> Unit) {
        base.scenario.onActivity {
            block()
            controller.invalidateStale()
        }
    }

    fun csv() {
        val previous = registry.launches.size
        perform("csv")
        WorkspaceControllerFixture.await { registry.launches.size > previous }
    }

    fun complete(
        uri: Uri?,
        index: Int = registry.launches.lastIndex,
    ) {
        base.scenario.onActivity { registry.complete(index, uri) }
    }

    fun files(): List<File> {
        var result = emptyList<File>()
        base.scenario.onActivity { result = File(it.cacheDir, "component-exports").listFiles()?.toList().orEmpty() }
        return result
    }

    override fun close() = base.close()

    companion object {
        fun component(text: String = "Synthetic result"): Component =
            Component.fromJson(
                Json.parseToJsonElement(
                    """{
            "type":"table","component_id":"wc_a","title":"$text","headers":["a"],"rows":[["1"]],
            "component_chrome":{"version":1,"actions":[
            {"kind":"refine","label":"refine","icon":"✎","title":"Refine this component","context":"live_canvas"},
            {"kind":"history","label":"history","icon":"⟲","title":"Version history","context":"live_canvas"},
            {"kind":"csv","label":"csv","icon":"⬇","title":"Download CSV","context":"owned_chat"},
            {"kind":"share","label":"share","icon":"↗","title":"Share component","context":"owned_chat"}]},
            "versions":[{"version_no":2,"reason":"refine","title":"Earlier","created_at":"2026-09-12T12:34:00Z"}]}
            """,
                ).jsonObject,
            )
    }
}
