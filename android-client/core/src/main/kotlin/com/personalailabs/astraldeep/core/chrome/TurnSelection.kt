// Retains exact agent, skill and note revisions selected for one conversation.
// Validated nonempty values are sent unchanged for server-side authorization.

package com.personalailabs.astraldeep.core.chrome

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID

data class TurnSelection(
    val agent: Agent?,
    val skills: List<Reference>,
    val notes: List<Reference>,
    val json: JsonObject,
) {
    data class Agent(val agentId: String, val revisionId: String)

    data class Reference(val id: String, val revision: Long)

    val isEmpty: Boolean get() = agent == null && skills.isEmpty() && notes.isEmpty()
    val isGuidanceSelection: Boolean get() = agent?.let { runCatching { uuid(JsonPrimitive(it.agentId)) }.isSuccess } ?: true

    companion object {
        val EMPTY = requireNotNull(fromJson(Json.parseToJsonElement("""{"version":1,"agent":null,"skills":[],"notes":[]}""")))

        fun fromJson(value: JsonElement?): TurnSelection? =
            ConsoleDecoding.decode {
                val root = ConsoleDecoding.obj(value)
                require(root.keys == setOf("version", "agent", "skills", "notes"))
                require(ConsoleDecoding.number(root["version"], 1.0, 1.0) == 1.0)
                val agent =
                    if (root["agent"] == JsonNull) {
                        null
                    } else {
                        val fields = ConsoleDecoding.obj(root["agent"])
                        require(fields.keys == setOf("agent_id", "revision_id"))
                        val id = ConsoleDecoding.text(fields["agent_id"], 255)
                        require(id == id.trim())
                        Agent(id, uuid(fields["revision_id"]))
                    }
                TurnSelection(agent, references(root["skills"], "skill_id", 20), references(root["notes"], "note_id", 8), root)
            }

        private fun uuid(value: JsonElement?): String {
            val raw = ConsoleDecoding.text(value, 36)
            val uuid = UUID.fromString(raw)
            require(uuid.version() == 4 && uuid.variant() == 2 && uuid.toString() == raw)
            return raw
        }

        private fun references(
            value: JsonElement?,
            identity: String,
            maximum: Int,
        ): List<Reference> {
            val result =
                ConsoleDecoding.rows(value, maximum).map {
                    val row = ConsoleDecoding.obj(it)
                    require(row.keys == setOf(identity, "revision"))
                    val revision = ConsoleDecoding.number(row["revision"], 1.0, 9_007_199_254_740_991.0)
                    require(revision.toLong().toDouble() == revision)
                    Reference(uuid(row[identity]), revision.toLong())
                }
            require(result.map { it.id }.distinct().size == result.size)
            return result
        }
    }
}
