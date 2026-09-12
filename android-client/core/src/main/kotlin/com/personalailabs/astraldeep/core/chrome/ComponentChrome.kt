package com.personalailabs.astraldeep.core.chrome

import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Closed presentation metadata. These descriptors never authorize a server operation. */
data class ComponentAction(val kind: String, val label: String, val icon: String, val title: String, val context: String)

data class ComponentVersion(val versionNo: Long, val reason: String, val createdAt: String, val title: String) {
    val label: String
        get() =
            "v$versionNo" + title.takeIf { it.isNotEmpty() }.let { if (it == null) "" else " · $it" } +
                createdAt.replace('T', ' ').take(16).takeIf { it.isNotEmpty() }.let { if (it == null) "" else " · $it" }
}

object ComponentChrome {
    private val contexts =
        linkedMapOf("refine" to "live_canvas", "history" to "live_canvas", "csv" to "owned_chat", "share" to "owned_chat")
    private val fields = setOf("kind", "label", "icon", "title", "context")

    fun actions(component: Component): List<ComponentAction> {
        val root = component.attributes["component_chrome"] as? JsonObject ?: return emptyList()
        if (root.keys != setOf("version", "actions") || integer(root["version"] as? JsonPrimitive) != 1L) return emptyList()
        val rows = root["actions"] as? JsonArray ?: return emptyList()
        if (rows.size > 16) return emptyList()
        val seen = mutableSetOf<String>()
        val duplicates = mutableSetOf<String>()
        val valid = mutableMapOf<String, ComponentAction>()
        rows.forEach { raw ->
            val row = raw as? JsonObject ?: return@forEach
            val kind = row.string("kind", 16) ?: return@forEach
            if (kind !in contexts) return@forEach
            if (!seen.add(kind)) duplicates.add(kind)
            if (row.keys != fields || row["context"] != JsonPrimitive(contexts.getValue(kind))) return@forEach
            val label = row.string("label", 96) ?: return@forEach
            val icon = row.string("icon", 8) ?: return@forEach
            val title = row.string("title", 160) ?: return@forEach
            valid[kind] = ComponentAction(kind, label, icon, title, contexts.getValue(kind))
        }
        return contexts.keys.filterNot { it in duplicates }.mapNotNull(valid::get)
    }

    /** Only bounded server rows are shown. No local component body becomes a version. */
    fun versions(component: Component): List<ComponentVersion> {
        val rows = component.attributes["versions"] as? JsonArray ?: return emptyList()
        val first = rows.take(5).mapNotNull { it as? JsonObject }
        val numbers = first.map { integer(it["version_no"] as? JsonPrimitive) }
        return first.mapNotNull { row ->
            val version = integer(row["version_no"] as? JsonPrimitive)?.takeIf { it in 1..9007199254740991L } ?: return@mapNotNull null
            if (numbers.count { it == version } != 1) return@mapNotNull null
            ComponentVersion(
                version,
                row.versionText("reason", 32) ?: return@mapNotNull null,
                row.versionText("created_at", 64) ?: return@mapNotNull null,
                row.versionText("title", 120) ?: return@mapNotNull null,
            )
        }
    }

    /** The endpoint identity is the canonical server component_id, never a layout id alias. */
    fun identity(component: Component): String? {
        val id = component.attributes.string("component_id", 128)?.takeIf { it.isNotBlank() } ?: return null
        return id.takeIf { component.id == id && id.none(Char::isISOControl) }
    }

    private fun JsonObject.versionText(
        key: String,
        max: Int,
    ): String? {
        val value = this[key] ?: return ""
        if (value == JsonNull) return ""
        val text = (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        return text.substring(0, text.offsetByCodePoints(0, minOf(max, text.codePointCount(0, text.length))))
    }

    private fun integer(value: JsonPrimitive?): Long? =
        value?.takeUnless { it.isString }?.content?.toBigDecimalOrNull()?.let { runCatching { it.longValueExact() }.getOrNull() }

    private fun JsonObject.string(
        key: String,
        max: Int,
        empty: Boolean = false,
    ): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf {
            (empty || it.isNotEmpty()) && it.codePointCount(0, it.length) <= max
        }
}
