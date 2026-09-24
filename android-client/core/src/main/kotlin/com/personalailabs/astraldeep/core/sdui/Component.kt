// The SDUI component model: a typed node with dynamic attributes and children, tolerantly decoded from the
// orchestrator's wire. Renderer looks up type in its registry and falls back to a placeholder for unknown
// types.

package com.personalailabs.astraldeep.core.sdui

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

data class Component(
    val type: String,
    val id: String?,
    val attributes: JsonObject,
    val children: List<Component>,
) {
    companion object {
        fun fromJson(obj: JsonObject): Component {
            val type = (obj["type"] as? JsonPrimitive)?.contentOrNull.orEmpty()
            // component_id wins over id — canvas identity depends on this order
            val id =
                (obj["component_id"] as? JsonPrimitive)?.contentOrNull
                    ?: (obj["id"] as? JsonPrimitive)?.contentOrNull
            return Component(type = type, id = id, attributes = obj, children = childrenOf(obj))
        }

        fun listFromJson(arr: JsonArray?): List<Component> = arr?.mapNotNull { (it as? JsonObject)?.let(::fromJson) } ?: emptyList()

        private fun childrenOf(obj: JsonObject): List<Component> =
            when (val raw = obj["content"] ?: obj["children"]) {
                is JsonArray -> raw.mapNotNull { (it as? JsonObject)?.let(::fromJson) }
                is JsonObject -> listOf(fromJson(raw))
                else -> emptyList()
            }
    }
}
