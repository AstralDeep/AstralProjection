package com.personalailabs.astraldeep.app.render

import com.personalailabs.astraldeep.app.render.renderers.arr
import com.personalailabs.astraldeep.app.render.renderers.dbl
import com.personalailabs.astraldeep.app.render.renderers.int
import com.personalailabs.astraldeep.app.render.renderers.rows
import com.personalailabs.astraldeep.app.render.renderers.str
import com.personalailabs.astraldeep.app.render.renderers.strList
import com.personalailabs.astraldeep.app.ui.WorkspaceContext
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

internal fun interface CanvasPixels {
    suspend fun png(): String

    fun retainedBytes(): Long = 16L * 1024 * 1024

    fun close() = Unit
}

internal class CanvasCaptureUnavailable : IllegalStateException("The visible canvas is not ready for export.")

internal data class CanvasCapture(val presentation: JsonObject, internal val generation: Long, internal val context: WorkspaceContext) {
    // Once bytes are frozen, later local layout/disclosure changes do not retarget the snapshot.
    // Delivery still requires current owner/session/chat/revision and server capability.
    fun canDeliver(current: WorkspaceContext?): Boolean =
        current != null && current.owner == context.owner &&
            current.epoch == context.epoch && current.chatId == context.chatId && current.revision == context.revision &&
            "export_canvas" in current.operations
}

/** Main-thread, bounded, owner-scoped display memory. It never fetches or persists content. */
internal class CanvasCaptureRegistry {
    internal class Node(val raw: JsonObject) {
        var selected = 0
        var expanded = false
        var columns: Int? = null
        var imageSize: Pair<Double, Double>? = null
        var pixels: CanvasPixels? = null
    }

    private var owner: Triple<Any, Long, String>? = null
    private var revision: ULong? = null
    private var roots: List<Component> = emptyList()
    private var displayed: List<JsonObject> = emptyList()
    private var viewport = JsonObject(emptyMap())
    private var theme = JsonObject(emptyMap())
    private var generation = 0L
    private var mounted = false
    private var attachment: Any? = null
    private var nodes = linkedMapOf<String, Node>()

    fun bind(
        context: WorkspaceContext?,
        components: List<Component>,
        width: Int,
        height: Int,
        palette: Map<String, String>,
        windowWidth: Int = width,
        windowHeight: Int = height,
        attachment: Any? = null,
    ) {
        if (context == null) {
            clear()
            return
        }
        val nextOwner = Triple(context.owner, context.epoch, context.chatId)
        if (owner != nextOwner) {
            clear()
            owner = nextOwner
        }
        val nextViewport =
            buildJsonObject {
                put("width", width)
                put("height", height)
                put("window_width", windowWidth)
                put("window_height", windowHeight)
            }
        val nextTheme = JsonObject(palette.mapValues { JsonPrimitive(it.value) })
        if (roots != components || viewport != nextViewport || theme != nextTheme || !mounted || revision != context.revision) generation++
        revision = context.revision
        if (roots != components) {
            val next = linkedMapOf<String, Node>()

            fun walk(
                raw: JsonObject,
                path: String,
                depth: Int,
            ) {
                if (depth > 32 || next.size >= 12000) return
                next[path] = nodes[path]?.takeIf { it.raw == raw } ?: Node(raw)
                for (key in listOf("content", "children")) {
                    (raw[key] as? JsonArray)?.forEachIndexed {
                            index,
                            value,
                        ->
                        (value as? JsonObject)?.let { walk(it, "$path/$key/$index", depth + 1) }
                    }
                }
                (raw["tabs"] as? JsonArray)?.forEachIndexed { index, value ->
                    (value as? JsonObject)?.let { tab ->
                        for (key in listOf("content", "children")) (tab[key] as? JsonArray)?.forEachIndexed {
                                child,
                                item,
                            ->
                            (item as? JsonObject)?.let { walk(it, "$path/tabs/$index/$key/$child", depth + 1) }
                        }
                    }
                }
            }
            var budget = 12000

            fun actual(
                component: Component,
                depth: Int,
            ): JsonObject {
                if (--budget < 0 || depth > 32) throw CanvasCaptureUnavailable()
                val raw = component.attributes.toMutableMap()
                val displayType = if (component.type == "list" && component.children.isNotEmpty()) "container" else component.type
                raw["type"] = JsonPrimitive(displayType)
                if ("id" !in raw && "component_id" !in raw && component.id != null) raw["component_id"] = JsonPrimitive(component.id)
                if (displayType in setOf("container", "card", "grid", "collapsible")) {
                    val keys = listOf("content", "children").filter(raw::containsKey)
                    if (keys.size <= 1) {
                        val key = keys.firstOrNull() ?: "children"
                        if (raw[key] == null || raw[key] is JsonArray) {
                            raw[key] = JsonArray(component.children.map { actual(it, depth + 1) })
                        }
                    }
                }
                if (component.type == "tabs") {
                    (raw["tabs"] as? JsonArray)?.let { tabs ->
                        raw["tabs"] =
                            JsonArray(
                                tabs.mapNotNull { it as? JsonObject }.map { tab ->
                                    val out = tab.toMutableMap()
                                    val keys = listOf("content", "children").filter(out::containsKey)
                                    if (keys.size <= 1) {
                                        val key = keys.firstOrNull() ?: "children"
                                        val array = out[key] as? JsonArray
                                        if (array != null) out[key] = JsonArray(Component.listFromJson(array).map { actual(it, depth + 1) })
                                    }
                                    JsonObject(out)
                                },
                            )
                    }
                }
                return JsonObject(raw)
            }
            displayed = runCatching { components.map { actual(it, 0) } }.getOrDefault(emptyList())
            displayed.forEachIndexed { index, component -> walk(component, "/components/$index", 0) }
            val retainedNodes = next.values.toSet()
            nodes.values.filterNot { it in retainedNodes }.forEach { it.pixels?.close() }
            nodes = next
        }
        this.attachment = attachment
        roots = components
        viewport = nextViewport
        theme = nextTheme
        mounted = true
    }

    fun node(path: String): Node? = nodes[path]

    fun select(
        path: String,
        selected: Int,
    ) {
        nodes[path]?.let {
            if (it.selected != selected) {
                it.selected = selected
                generation++
            }
        }
    }

    fun expand(
        path: String,
        expanded: Boolean,
    ) {
        nodes[path]?.let {
            if (it.expanded != expanded) {
                it.expanded = expanded
                generation++
            }
        }
    }

    fun columns(
        path: String,
        columns: Int,
    ) {
        nodes[path]?.let {
            if (it.columns != columns) {
                it.columns = columns
                generation++
            }
        }
    }

    fun imageSize(
        path: String,
        width: Double,
        height: Double,
    ) {
        val size =
            if (width.isFinite() && height.isFinite() && width > 0 && height > 0 && width <= 16384 && height <= 16384) {
                width to height
            } else {
                null
            }
        nodes[path]?.let {
            if (it.imageSize != size) {
                it.imageSize = size
                generation++
            }
        }
    }

    fun pixels(
        path: String,
        pixels: CanvasPixels?,
    ) {
        val node = nodes[path] ?: return
        if (node.pixels !== pixels) node.pixels?.close()
        node.pixels = pixels
        var retained = nodes.values.sumOf { it.pixels?.retainedBytes() ?: 0 }
        for (entry in nodes.values) {
            if (retained <= 64L * 1024 * 1024) break
            val source = entry.pixels ?: continue
            retained -= source.retainedBytes()
            source.close()
            entry.pixels = null
        }
    }

    fun unmount(attachment: Any? = null) {
        if (attachment === this.attachment) {
            mounted = false
            generation++
        }
    }

    fun clear() {
        owner = null
        revision = null
        roots = emptyList()
        displayed = emptyList()
        nodes.values.forEach { it.pixels?.close() }
        nodes.clear()
        mounted = false
        generation++
    }

    private fun matches(context: WorkspaceContext): Boolean =
        mounted && owner == Triple(context.owner, context.epoch, context.chatId) && revision == context.revision &&
            "export_canvas" in context.operations

    fun isCurrent(
        capture: CanvasCapture,
        context: WorkspaceContext,
    ): Boolean =
        matches(context) && capture.generation == generation && capture.context.owner == context.owner &&
            capture.context.epoch == context.epoch && capture.context.chatId == context.chatId &&
            capture.context.revision == context.revision

    suspend fun freeze(context: WorkspaceContext): CanvasCapture =
        coroutineScope {
            if (!matches(context) || displayed.isEmpty()) throw CanvasCaptureUnavailable()
            val capturedGeneration = generation
            var treeBudget = 12000

            fun validateTree(
                value: JsonElement,
                depth: Int,
            ) {
                if (--treeBudget < 0 || depth > 32) throw CanvasCaptureUnavailable()
                when (value) {
                    is JsonObject -> {
                        if (value.keys.any { it in setOf("__proto__", "constructor", "prototype") }) throw CanvasCaptureUnavailable()
                        value.values.forEach { validateTree(it, depth + 1) }
                    }
                    is JsonArray -> value.forEach { validateTree(it, depth + 1) }
                    else -> Unit
                }
            }
            displayed.forEach { validateTree(it, 0) }
            val states = mutableListOf<JsonObject>()
            val images = mutableListOf<kotlinx.coroutines.Deferred<JsonObject>>()
            var count = 0

            // Project each primitive through the same tolerant readers as its native renderer.
            // A field used by another primitive, or an undisplayed nested map, is never display data.
            fun clean(
                raw: JsonObject,
                type: String,
            ): JsonObject =
                buildJsonObject {
                    val c = Component(type, null, raw, emptyList())
                    put("type", type)
                    for (key in listOf("id", "component_id")) raw[key]?.let { value ->
                        if (value != JsonNull &&
                            (value !is JsonPrimitive || !value.isString || value.content.isEmpty() || value.content.length > 256)
                        ) {
                            throw CanvasCaptureUnavailable()
                        }
                        put(key, value)
                    }
                    if ("id" in raw && "component_id" in raw && raw["id"] != raw["component_id"]) throw CanvasCaptureUnavailable()

                    fun strings(vararg keys: String) {
                        keys.forEach { key -> c.str(key)?.let { put(key, it) } }
                    }

                    fun stringArray(values: List<String>) = JsonArray(values.map(::JsonPrimitive))
                    when (type) {
                        "text" -> put("content", c.str("content") ?: c.str("text").orEmpty())
                        "code" -> put("content", c.str("content") ?: c.str("code").orEmpty())
                        "card" -> strings("title")
                        "container" -> put("direction", if (c.str("direction") == "row") "row" else "column")
                        "collapsible" -> put("title", c.str("title") ?: "Details")
                        "alert" -> {
                            strings("title", "message")
                            c.str("variant")?.takeIf { it in setOf("error", "warning", "success", "info") }?.let { put("variant", it) }
                        }
                        "metric" -> {
                            strings("title", "value", "subtitle", "aria-label")
                            c.str("variant")?.takeIf { it in setOf("error", "warning", "success") }?.let { put("variant", it) }
                            c.dbl("progress")?.takeIf { it.isFinite() }?.let { put("progress", it) }
                        }
                        "hero" -> {
                            strings("eyebrow", "title", "subtitle")
                            put("badges", stringArray(c.strList("badges").filter(String::isNotBlank)))
                            if (c.str("variant") == "gradient") put("variant", "gradient")
                        }
                        "badge" -> put("label", c.str("label") ?: c.str("text").orEmpty())
                        "table" -> {
                            put("headers", stringArray(c.strList("headers")))
                            put("rows", JsonArray(c.rows("rows").map(::stringArray)))
                            for (key in listOf("total_rows", "page_size", "page_offset")) c.int(key)?.let { put(key, it) }
                        }
                        "list" -> put("items", stringArray(c.strList("items")))
                        "keyvalue" ->
                            put(
                                "items",
                                JsonArray(
                                    (c.arr("items") ?: c.arr("pairs")).orEmpty().mapNotNull { item ->
                                        (item as? JsonObject)?.let { value ->
                                            buildJsonObject {
                                                put("key", ((value["key"] ?: value["label"]) as? JsonPrimitive)?.contentOrNull.orEmpty())
                                                put("value", (value["value"] as? JsonPrimitive)?.contentOrNull.orEmpty())
                                            }
                                        }
                                    },
                                ),
                            )
                        "timeline" ->
                            put(
                                "items",
                                JsonArray(
                                    c.arr("items").orEmpty().mapNotNull { item ->
                                        (item as? JsonObject)?.let { value ->
                                            buildJsonObject {
                                                put(
                                                    "title",
                                                    ((value["title"] ?: value["label"] ?: value["text"]) as? JsonPrimitive)
                                                        ?.contentOrNull.orEmpty(),
                                                )
                                            }
                                        }
                                    },
                                ),
                            )
                        "rating" -> {
                            val max = c.int("max") ?: 5
                            if (max !in 0..1000) throw CanvasCaptureUnavailable()
                            put("max", max)
                            put("value", (c.dbl("value") ?: 0.0).toInt().coerceIn(0, max))
                        }
                        "progress" -> {
                            strings("label")
                            val value = c.dbl("value") ?: c.dbl("progress") ?: 0.0
                            if (!value.isFinite()) throw CanvasCaptureUnavailable()
                            put("value", (if (value > 1.0) value / 100.0 else value).coerceIn(0.0, 1.0))
                        }
                        "image" -> (c.str("alt") ?: c.str("caption"))?.let { put("alt", it) }
                        in CHARTS -> strings("title")
                    }
                }

            fun visit(
                raw: JsonObject,
                path: String,
                depth: Int,
            ): JsonObject {
                if (++count > 12000 || depth > 32) throw CanvasCaptureUnavailable()
                val type = (raw["type"] as? JsonPrimitive)?.content ?: throw CanvasCaptureUnavailable()
                if (type in OMITTED) return buildJsonObject { put("type", type) }
                if (type !in SUPPORTED || raw["css"]?.let {
                        it != JsonNull && it != JsonObject(emptyMap()) && it != JsonPrimitive("")
                    } == true || raw["style"]?.let {
                        it != JsonNull && it != JsonObject(emptyMap()) && it != JsonPrimitive("")
                    } == true
                ) {
                    throw CanvasCaptureUnavailable()
                }
                val node = nodes[path]?.takeIf { it.raw == raw } ?: throw CanvasCaptureUnavailable()
                val identity = raw["component_id"] ?: raw["id"] ?: JsonNull
                val out = clean(raw, type).toMutableMap()

                fun children(
                    source: JsonObject,
                    base: String,
                    include: Boolean,
                ): Pair<String, JsonArray> {
                    val keys = listOf("content", "children").filter(source::containsKey)
                    if (keys.size > 1) throw CanvasCaptureUnavailable()
                    val key = keys.firstOrNull() ?: "content"
                    val input = source[key] ?: JsonArray(emptyList())
                    if (input !is JsonArray) throw CanvasCaptureUnavailable()
                    return key to
                        JsonArray(
                            if (include) {
                                input.mapIndexed {
                                        index,
                                        item,
                                    ->
                                    visit(item as? JsonObject ?: throw CanvasCaptureUnavailable(), "$base/$key/$index", depth + 1)
                                }
                            } else {
                                emptyList()
                            },
                        )
                }
                if (type == "collapsible" || type == "tabs") {
                    states +=
                        buildJsonObject {
                            put("path", path)
                            put("component_id", identity)
                            put("kind", type + "_open")
                            put(
                                "value",
                                if (type == "collapsible") {
                                    JsonPrimitive(node.expanded)
                                } else {
                                    JsonArray(listOf(JsonPrimitive(node.selected)))
                                },
                            )
                        }
                }
                if (type in setOf("container", "card", "grid", "collapsible")) {
                    val (key, content) = children(raw, path, type != "collapsible" || node.expanded)
                    out[key] = content
                    if (type == "grid") out["columns"] = JsonPrimitive(node.columns ?: throw CanvasCaptureUnavailable())
                }
                if (type == "tabs") {
                    val tabs = raw["tabs"] as? JsonArray ?: throw CanvasCaptureUnavailable()
                    if (node.selected !in tabs.indices) throw CanvasCaptureUnavailable()
                    out["tabs"] =
                        JsonArray(
                            tabs.mapIndexed { index, value ->
                                val tab = value as? JsonObject ?: throw CanvasCaptureUnavailable()
                                val (key, content) = children(tab, "$path/tabs/$index", index == node.selected)
                                val label = (tab["label"] as? JsonPrimitive)?.contentOrNull ?: "Tab ${index + 1}"
                                JsonObject(mapOf("label" to JsonPrimitive(label), key to content))
                            },
                        )
                }
                if (type == "image" || type in CHARTS) {
                    val pixels = node.pixels ?: throw CanvasCaptureUnavailable()
                    if (type == "image") {
                        val size = node.imageSize ?: throw CanvasCaptureUnavailable()
                        out["width"] = JsonPrimitive(size.first)
                        out["height"] = JsonPrimitive(size.second)
                    }
                    // No source URL, raw chart inputs, request metadata or unneeded keys leave the client.
                    out.keys.retainAll(setOf("type", "id", "component_id", "title", "alt", "caption", "width", "height"))
                    images +=
                        async {
                            val png = pixels.png()
                            if (!png.startsWith("data:image/png;base64,") || png.length > 8 * 1024 * 1024) throw CanvasCaptureUnavailable()
                            buildJsonObject {
                                put("path", path)
                                put("component_id", identity)
                                put("data_url", png)
                            }
                        }
                }
                return JsonObject(out)
            }
            val components = JsonArray(displayed.mapIndexed { index, component -> visit(component, "/components/$index", 0) })
            val result =
                buildJsonObject {
                    put("version", "astral.canvas-export/v1")
                    put("components", components)
                    put("viewport", viewport)
                    put("theme", theme)
                    put("display_state", JsonArray(states))
                    put("images", JsonArray(images.map { it.await() }))
                }
            val capture = CanvasCapture(result, capturedGeneration, context)
            if (!isCurrent(capture, context) || result.toString().toByteArray(Charsets.UTF_8).size > 8 * 1024 * 1024) {
                throw CanvasCaptureUnavailable()
            }
            capture
        }

    companion object {
        val CHARTS = setOf("bar_chart", "line_chart", "pie_chart", "plotly_chart")
        private val OMITTED =
            setOf(
                "button",
                "input",
                "param_picker",
                "color_picker",
                "theme_apply",
                "file_upload",
                "file_download",
                "skeleton",
                "chat_history",
                "download_card",
            )
        private val SUPPORTED =
            setOf(
                "container",
                "text",
                "card",
                "table",
                "list",
                "alert",
                "progress",
                "metric",
                "code",
                "image",
                "grid",
                "tabs",
                "divider",
                "collapsible",
                "bar_chart",
                "line_chart",
                "pie_chart",
                "plotly_chart",
                "badge",
                "hero",
                "keyvalue",
                "timeline",
                "rating",
            )
    }
}
