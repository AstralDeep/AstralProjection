// Strict decoder for the native guidance-notes view geometry, validating the exact shared shape before
// falling back to tolerant SDUI decoding; used by Screens.kt and Input.kt to render guidance forms.

package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.util.UUID

internal object GuidanceNotes {
    private val categories = listOf("Profession", "Goal", "Preference", "Workflow tag", "Context")

    fun validSurface(root: JsonObject): Boolean {
        if (!root.shape(setOf("type", "surface_key", "region", "title", "admin_only", "components", "mode", "request_generation")) ||
            root.string("type") != "chrome_surface" || root.string("surface_key") != "guidance" ||
            root.string("region") != "modal" || root.string("mode") != "replace" ||
            root.boolean("admin_only") != false || !text(root["title"], 4096) ||
            !uuid(root["request_generation"]) || root.toString().toByteArray(Charsets.UTF_8).size > 1024 * 1024
        ) {
            return false
        }
        val components = root["components"] as? JsonArray ?: return false
        val pending = ArrayDeque<Pair<JsonElement, Int>>()
        pending.addAll(components.map { it to 0 })
        var count = 0
        while (pending.isNotEmpty()) {
            val (value, depth) = pending.removeLast()
            if (++count > 1024 || depth > 8) return false
            val node = value as? JsonObject ?: return false
            val type = node.string("type")
            val required =
                when (type) {
                    "text" -> setOf("type", "content", "variant")
                    "alert" -> setOf("type", "message", "variant")
                    "badge" -> setOf("type", "label", "variant")
                    "card" -> setOf("type", "title", "content", "variant")
                    "button" -> setOf("type", "label", "action", "payload", "variant", "disabled", "local")
                    "param_picker" -> {
                        if (!validForm(node)) return false
                        continue
                    }
                    else -> return false
                }
            if (!node.shape(required, if (type == "alert") setOf("title") else emptySet()) ||
                listOf("title", "message", "label", "variant").any { it in node && !text(node[it], 8192) }
            ) {
                return false
            }
            when (type) {
                "text" -> if (!text(node["content"], 8192)) return false
                "card" -> {
                    val children = node["content"] as? JsonArray ?: return false
                    pending.addAll(children.map { it to depth + 1 })
                }
                "button" -> if (!validButton(node)) return false
            }
        }
        return true
    }

    private fun validButton(node: JsonObject): Boolean {
        if (node.boolean("local") != false || node.boolean("disabled") == null) return false
        val payload = node["payload"] as? JsonObject ?: return false
        return when (node.string("action")) {
            "chrome_note_toggle" ->
                payload.shape(setOf("note_id", "expected_revision", "enabled")) &&
                    identity(payload) && payload.boolean("enabled") != null
            "chrome_note_forget" -> payload.shape(setOf("note_id", "expected_revision")) && identity(payload)
            "chrome_open" -> {
                if (!payload.shape(setOf("surface", "params")) || payload.string("surface") != "guidance") return false
                val params = payload["params"] as? JsonObject ?: return false
                when (params.string("mode")) {
                    "list" ->
                        params.shape(setOf("mode"), setOf("search", "after_id")) &&
                            ("search" !in params || text(params["search"], 256)) && ("after_id" !in params || uuid(params["after_id"]))
                    "new" -> params.shape(setOf("mode"))
                    "edit", "forget" -> params.shape(setOf("mode", "note_id", "expected_revision")) && identity(params)
                    else -> false
                }
            }
            else -> false
        }
    }

    private fun validForm(node: JsonObject): Boolean {
        if (!node.shape(setOf("type", "title", "description", "fields", "submit_label", "submit_action", "submit_payload")) ||
            listOf("title", "description", "submit_label").any { !text(node[it], 8192) }
        ) {
            return false
        }
        val fields = node["fields"] as? JsonArray ?: return false
        val payload = node["submit_payload"] as? JsonObject ?: return false
        val names =
            when (node.string("submit_action")) {
                "chrome_note_search" -> {
                    if (payload.isNotEmpty()) return false
                    listOf("search")
                }
                "chrome_note_save" -> {
                    if (!payload.shape(setOf("note_id", "expected_revision")) || !identity(payload, create = true)) return false
                    listOf("category", "value", "enabled", "expiry", "expiry_date")
                }
                else -> return false
            }
        if (fields.map { (it as? JsonObject)?.string("name") } != names) return false
        for (value in fields) {
            val field = value as JsonObject
            val name = field.string("name")!!
            if (!field.shape(setOf("name", "label", "kind", "default"), setOf("options", "help", "visible_when")) ||
                !text(field["label"], 8192) || ("help" in field && !text(field["help"], 8192))
            ) {
                return false
            }
            val kind =
                when (name) {
                    "enabled" -> "boolean"
                    "value" -> "textarea"
                    "category", "expiry" -> "select"
                    else -> "text"
                }
            if (field.string("kind") != kind) return false
            if (kind == "boolean") {
                if (field.boolean("default") == null) return false
            } else if (!text(
                    field["default"],
                    if (name == "value") {
                        4096
                    } else if (name == "search") {
                        256
                    } else {
                        32
                    },
                )
            ) {
                return false
            }
            if (kind == "select") {
                val options =
                    if (name == "category") {
                        categories
                    } else if (payload.revision() == 0L) {
                        listOf("No expiry", "Set a date")
                    } else {
                        listOf("Keep current expiry", "No expiry", "Set a date")
                    }
                if (field["options"] != JsonArray(options.map(::JsonPrimitive)) || field.string("default") !in options) return false
            } else if ("options" in field) {
                return false
            }
            if (name == "expiry_date") {
                if (field["visible_when"] != JsonObject(mapOf("expiry" to JsonPrimitive("Set a date")))) return false
            } else if ("visible_when" in field) {
                return false
            }
        }
        return true
    }

    private fun identity(
        value: JsonObject,
        create: Boolean = false,
    ): Boolean = uuid(value["note_id"]) && value.revision()?.let { it in (if (create) 0L else 1L)..9_007_199_254_740_990L } == true

    private fun JsonObject.revision(): Long? =
        (this["expected_revision"] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toLongOrNull()

    private fun JsonObject.shape(
        required: Set<String>,
        optional: Set<String> = emptySet(),
    ): Boolean = keys.containsAll(required) && (required + optional).containsAll(keys)

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.boolean(key: String): Boolean? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

    private fun text(
        value: JsonElement?,
        maximum: Int,
    ): Boolean =
        (value as? JsonPrimitive)?.takeIf {
            it.isString
        }?.content?.let { '\u0000' !in it && it.toByteArray(Charsets.UTF_8).size <= maximum } == true

    private fun uuid(value: JsonElement?): Boolean {
        val value = (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return false
        val parsed = runCatching { UUID.fromString(value) }.getOrNull() ?: return false
        return parsed.version() == 4 && parsed.variant() == 2 && parsed.toString() == value
    }
}
