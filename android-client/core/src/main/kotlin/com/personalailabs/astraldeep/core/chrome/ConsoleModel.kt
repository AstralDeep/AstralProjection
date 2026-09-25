// Decodes the shared console catalog, copy, identity and composer actions with bounded validation.
// The native shell consumes this immutable contract independently of legacy chrome.

package com.personalailabs.astraldeep.core.chrome

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

data class ChromeAvailability(val mode: String, val message: String?) {
    companion object {
        fun fromJson(value: JsonElement?): ChromeAvailability? =
            ConsoleDecoding.decode {
                val fields = ConsoleDecoding.obj(value)
                val mode = ConsoleDecoding.text(fields["mode"], 20)
                require(mode in setOf("native", "handoff"))
                require(fields.keys == if (mode == "native") setOf("mode") else setOf("mode", "message"))
                ChromeAvailability(mode, if (mode == "handoff") ConsoleDecoding.text(fields["message"], 500) else null)
            }
    }
}

data class ConsoleIdentity(val name: String, val role: String, val initials: String)

data class ConsoleScenario(val id: String, val title: String, val description: String, val prompt: String, val category: String)

data class ConsoleAgent(
    val id: String,
    val name: String,
    val description: String,
    val state: String,
    val owned: Boolean,
    val availability: ChromeAvailability?,
)

data class ConsoleCatalog(val categories: List<String>, val scenarios: List<ConsoleScenario>, val agents: List<ConsoleAgent>)

data class ConsoleComposerAction(
    val key: String,
    val kind: String,
    val label: String,
    val icon: String,
    val action: SurfaceRef?,
    val availability: ChromeAvailability?,
)

data class ConsoleModel(
    val labels: Map<String, String>,
    val identity: ConsoleIdentity,
    val catalog: ConsoleCatalog,
    val composerActions: List<ConsoleComposerAction>,
    val showVoiceAvailabilityBanner: Boolean,
) {
    fun selectionSummary(selection: TurnSelection): String? {
        if (selection.isEmpty) return null
        val template = labels["selection_summary"] ?: return null
        val parts = mutableListOf<String>()
        for ((kind, count) in listOf(
            "agent" to if (selection.agent == null) 0 else 1,
            "skill" to selection.skills.size,
            "note" to selection.notes.size,
        )) {
            if (count == 0) continue
            val label = labels["selection_${kind}_${if (count == 1) "singular" else "plural"}"] ?: return null
            parts += label.replace("{count}", count.toString())
        }
        return template.replace("{selection}", parts.joinToString(", "))
    }

    companion object {
        const val CONTRACT = "console/v2"
        private val requiredLabels =
            setOf(
                "brand", "title", "subtitle", "start_here", "history", "agent_directory", "search_agents",
                "dashboard", "dashboard_suffix", "new_chat", "all_categories", "example", "run", "load_prompt",
                "empty_title", "empty_subtitle", "message_placeholder", "attach", "more", "send", "background",
                "advanced", "fullscreen", "exit_fullscreen", "collapse", "expand", "clear_selection",
            )

        fun fromJson(value: JsonElement?): ConsoleModel? =
            ConsoleDecoding.decode {
                val root = ConsoleDecoding.obj(value)
                require(ConsoleDecoding.number(root["version"], 2.0, 2.0) == 2.0)
                val labelFields = ConsoleDecoding.obj(root["labels"])
                require(labelFields.size <= 64 && labelFields.keys.containsAll(requiredLabels))
                val labels =
                    labelFields.map { (key, label) ->
                        ConsoleDecoding.text(JsonPrimitive(key), 80) to ConsoleDecoding.text(label, 500)
                    }.toMap()
                val identity = ConsoleDecoding.obj(root["identity"])
                val catalog = ConsoleDecoding.obj(root["catalog"])
                val categories = ConsoleDecoding.rows(catalog["categories"], 16).map { ConsoleDecoding.text(it, 80) }
                require(categories.distinct().size == categories.size)
                val scenarios =
                    ConsoleDecoding.rows(catalog["scenarios"], 64).map {
                        val row = ConsoleDecoding.obj(it)
                        val category = ConsoleDecoding.text(row["category"], 80)
                        require(category in categories)
                        ConsoleScenario(
                            ConsoleDecoding.text(row["id"], 200),
                            ConsoleDecoding.text(row["title"], 200),
                            ConsoleDecoding.text(row["description"], 2000, true),
                            ConsoleDecoding.text(row["prompt"], 8000),
                            category,
                        )
                    }
                val agents =
                    ConsoleDecoding.rows(catalog["agents"], 60).map {
                        val row = ConsoleDecoding.obj(it)
                        val state = ConsoleDecoding.text(row["state"], 20)
                        require(state in setOf("ready", "offline"))
                        ConsoleAgent(
                            ConsoleDecoding.text(row["id"], 200),
                            ConsoleDecoding.text(row["name"], 200),
                            ConsoleDecoding.text(row["description"], 2000, true),
                            state,
                            ConsoleDecoding.boolean(row["owned"]),
                            ConsoleDecoding.availability(row),
                        )
                    }
                require(scenarios.map { it.id }.distinct().size == scenarios.size)
                require(agents.map { it.id }.distinct().size == agents.size)
                val actions =
                    ConsoleDecoding.rows(root["composer_actions"], 16).map {
                        val row = ConsoleDecoding.obj(it)
                        val key = ConsoleDecoding.text(row["key"], 80)
                        val kind = ConsoleDecoding.text(row["kind"], 20)
                        require(kind in setOf("toggle", "action"))
                        val action =
                            if (kind == "toggle") {
                                require(key == "background" && "action" !in row)
                                null
                            } else {
                                val reference = ConsoleDecoding.obj(row["action"])
                                val surface = ConsoleDecoding.text(reference["surface"], 80)
                                require(Regex("[a-z][a-z0-9_]*").matches(surface))
                                val params = ConsoleDecoding.obj(reference["params"])
                                require(params.toString().toByteArray(Charsets.UTF_8).size <= 16_384)
                                SurfaceRef(surface, params)
                            }
                        ConsoleComposerAction(
                            key,
                            kind,
                            ConsoleDecoding.text(row["label"], 200),
                            ConsoleDecoding.text(row["icon"], 80),
                            action,
                            ConsoleDecoding.availability(row),
                        )
                    }
                require(actions.map { it.key }.distinct().size == actions.size)
                ConsoleModel(
                    labels,
                    ConsoleIdentity(
                        ConsoleDecoding.text(identity["name"], 120),
                        ConsoleDecoding.text(identity["role"], 40),
                        ConsoleDecoding.text(identity["initials"], 40),
                    ),
                    ConsoleCatalog(categories, scenarios, agents),
                    actions,
                    ConsoleDecoding.boolean(root["show_voice_availability_banner"]),
                )
            }
    }
}

internal object ConsoleDecoding {
    fun <T> decode(block: () -> T): T? =
        try {
            block()
        } catch (_: IllegalArgumentException) {
            null
        }

    fun obj(value: JsonElement?): JsonObject = value as? JsonObject ?: throw IllegalArgumentException()

    fun text(
        value: JsonElement?,
        maximum: Int,
        empty: Boolean = false,
    ): String {
        val primitive = value as? JsonPrimitive ?: throw IllegalArgumentException()
        require(primitive.isString)
        val result = primitive.content
        require(result.codePointCount(0, result.length) <= maximum && '\u0000' !in result && (empty || result.isNotBlank()))
        return result
    }

    fun rows(
        value: JsonElement?,
        maximum: Int,
    ): JsonArray {
        val array = value as? JsonArray ?: throw IllegalArgumentException()
        require(array.size <= maximum)
        return array
    }

    fun number(
        value: JsonElement?,
        minimum: Double,
        maximum: Double,
    ): Double {
        val primitive = value as? JsonPrimitive ?: throw IllegalArgumentException()
        require(!primitive.isString)
        val number = primitive.doubleOrNull ?: throw IllegalArgumentException()
        require(number.isFinite() && number in minimum..maximum)
        return number
    }

    fun boolean(value: JsonElement?): Boolean {
        val primitive = value as? JsonPrimitive ?: throw IllegalArgumentException()
        require(!primitive.isString)
        return primitive.booleanOrNull ?: throw IllegalArgumentException()
    }

    fun availability(row: JsonObject): ChromeAvailability? =
        if ("availability" in row) requireNotNull(ChromeAvailability.fromJson(row["availability"])) else null
}
