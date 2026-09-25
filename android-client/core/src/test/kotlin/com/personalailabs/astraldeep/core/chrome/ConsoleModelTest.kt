// Qualifies shared console and ROTE fixtures plus bounded, fail-closed selection decoding.
// Invalid optional console data must preserve the existing authenticated settings menu.

package com.personalailabs.astraldeep.core.chrome

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ConsoleModelTest {
    private fun fixture(name: String): JsonObject {
        var directory: File? = File(".").absoluteFile
        while (directory != null) {
            val file = File(directory, "contracts/fixtures/console/$name.json")
            if (file.isFile) return Json.parseToJsonElement(file.readText()).jsonObject
            directory = directory.parentFile
        }
        error("Missing shared fixture: $name")
    }

    private fun replace(
        value: JsonObject,
        path: String,
        replacement: JsonElement?,
    ): JsonObject {
        val keys = path.split('.', limit = 2)
        return JsonObject(
            value.toMutableMap().apply {
                if (keys.size == 2) {
                    put(keys[0], replace(getValue(keys[0]).jsonObject, keys[1], replacement))
                } else if (replacement == null) {
                    remove(keys[0])
                } else {
                    put(keys[0], replacement)
                }
            },
        )
    }

    private fun console() = fixture("chrome-console").getValue("console").jsonObject

    @Test
    fun shared_catalog_copy_actions_and_identity_remain_server_owned() {
        val source = fixture("chrome-console")
        val value = assertNotNull(ChromeMenuModel.fromJson(source)?.console)
        assertEquals("Operator", value.identity.name)
        assertEquals("Member", value.identity.role)
        assertEquals("O", value.identity.initials)
        assertEquals(listOf("Utilities"), value.catalog.categories)
        assertEquals(ConsoleScenario("dice", "Roll dice", "Six rolls", "Roll six dice", "Utilities"), value.catalog.scenarios.single())
        assertEquals(ConsoleAgent("dice", "Dice Roller", "Rolls dice", "ready", true, null), value.catalog.agents.single())
        assertEquals(listOf("background", "advanced", "timeline", "pulse", "work"), value.composerActions.map { it.key })
        assertEquals("toggle", value.composerActions[0].kind)
        assertNull(value.composerActions[0].action)
        assertEquals(SurfaceRef("guidance", JsonObject(mapOf("view" to JsonPrimitive("selection")))), value.composerActions[1].action)
        assertEquals("sliders", value.composerActions[1].icon)
        assertFalse(value.showVoiceAvailabilityBanner)
        assertEquals(value, ConsoleModel.fromJson(console()))
    }

    @Test
    fun invalid_console_falls_back_without_losing_legacy_settings() {
        val source = fixture("chrome-console")
        val existing = assertNotNull(ChromeMenuModel.fromJson(source))
        val raw = console()
        val invalid = mutableListOf<JsonElement?>(null, JsonNull, JsonArray(emptyList()), JsonPrimitive("future"))
        raw.keys.forEach { key ->
            invalid += replace(raw, key, null)
            invalid += replace(raw, key, JsonNull)
        }
        listOf(JsonPrimitive(1), JsonPrimitive(3), JsonPrimitive(2.5), JsonPrimitive(true), JsonPrimitive("2")).forEach {
            invalid += replace(raw, "version", it)
        }
        invalid.forEach { candidate ->
            val menu = assertNotNull(ChromeMenuModel.fromJson(replace(source, "console", candidate)))
            assertNull(menu.console)
            assertEquals(existing.menu, menu.menu)
            assertEquals(existing.topbar, menu.topbar)
            assertEquals(existing.signout, menu.signout)
        }
    }

    @Test
    fun text_bounds_are_unicode_aware_and_never_silently_truncated() {
        val raw = console()
        mapOf("identity.name" to 120, "identity.role" to 40, "identity.initials" to 40, "labels.title" to 500).forEach { (path, limit) ->
            assertNotNull(ConsoleModel.fromJson(replace(raw, path, JsonPrimitive("😀".repeat(limit)))))
            listOf(JsonPrimitive(" \n "), JsonPrimitive("a\u0000b"), JsonPrimitive(4), JsonPrimitive("x".repeat(limit + 1))).forEach {
                assertNull(ConsoleModel.fromJson(replace(raw, path, it)), path)
            }
        }
        assertNull(ConsoleModel.fromJson(replace(raw, "labels.title", null)))
        assertNull(ConsoleModel.fromJson(replace(raw, "labels.${"x".repeat(81)}", JsonPrimitive("label"))))
        val excess = JsonObject(raw.getValue("labels").jsonObject + (0..64).associate { "new$it" to JsonPrimitive("label") })
        assertNull(ConsoleModel.fromJson(replace(raw, "labels", excess)))
        assertNotNull(ConsoleModel.fromJson(replace(raw, "labels.future", JsonPrimitive("new server label"))))
    }

    @Test
    fun catalog_rejects_duplicates_limits_unknown_states_and_foreign_categories() {
        val raw = console()
        for ((kind, maximum) in listOf("categories" to 16, "scenarios" to 64, "agents" to 60)) {
            val row = raw.getValue("catalog").jsonObject.getValue(kind).jsonArray.first()
            for (bad in listOf(JsonNull, JsonArray(listOf(JsonNull)), JsonArray(List(maximum + 1) { row }), JsonArray(listOf(row, row)))) {
                assertNull(ConsoleModel.fromJson(replace(raw, "catalog.$kind", bad)), kind)
            }
        }
        for ((kind, bounds) in listOf("scenarios" to mapOf("id" to 200, "title" to 200, "description" to 2000, "prompt" to 8000, "category" to 80), "agents" to mapOf("id" to 200, "name" to 200, "description" to 2000))) {
            val row = raw.getValue("catalog").jsonObject.getValue(kind).jsonArray.first().jsonObject
            for ((key, limit) in bounds) {
                for (bad in listOf(JsonNull, JsonPrimitive("x".repeat(limit + 1)))) {
                    assertNull(ConsoleModel.fromJson(replace(raw, "catalog.$kind", JsonArray(listOf(replace(row, key, bad))))))
                }
            }
            assertNotNull(ConsoleModel.fromJson(replace(raw, "catalog.$kind", JsonArray(listOf(replace(row, "description", JsonPrimitive("")))))))
        }
        val agent = raw.getValue("catalog").jsonObject.getValue("agents").jsonArray.first().jsonObject
        for ((key, bad) in listOf("state" to JsonPrimitive("starting"), "owned" to JsonPrimitive("true"))) {
            assertNull(ConsoleModel.fromJson(replace(raw, "catalog.agents", JsonArray(listOf(replace(agent, key, bad))))))
        }
        assertEquals("offline", ConsoleModel.fromJson(replace(raw, "catalog.agents", JsonArray(listOf(replace(agent, "state", JsonPrimitive("offline"))))))?.catalog?.agents?.single()?.state)
        val scenario = raw.getValue("catalog").jsonObject.getValue("scenarios").jsonArray.first().jsonObject
        assertNull(ConsoleModel.fromJson(replace(raw, "catalog.scenarios", JsonArray(listOf(replace(scenario, "category", JsonPrimitive("foreign")))))))
        val empty = JsonObject(listOf("categories", "scenarios", "agents").associateWith { JsonArray(emptyList()) })
        assertNotNull(ConsoleModel.fromJson(replace(raw, "catalog", empty)))
    }

    @Test
    fun composer_operations_are_closed_bounded_and_unique() {
        val raw = console()
        val actions = raw.getValue("composer_actions").jsonArray
        val toggle = actions[0].jsonObject
        val action = actions[1].jsonObject
        val bad = mutableListOf<JsonElement>(JsonNull)
        listOf("key", "kind", "label", "icon", "action").forEach { bad += replace(action, it, null) }
        bad += replace(action, "kind", JsonPrimitive("script"))
        bad += replace(toggle, "key", JsonPrimitive("foreign"))
        bad += replace(toggle, "action", JsonNull)
        bad += replace(action, "action.surface", JsonPrimitive("javascript:bad"))
        bad += replace(action, "action.params", JsonArray(emptyList()))
        bad += replace(action, "action.params", JsonObject(mapOf("text" to JsonPrimitive("x".repeat(16_385)))))
        bad.forEach { assertNull(ConsoleModel.fromJson(replace(raw, "composer_actions", JsonArray(listOf(it))))) }
        for (rows in listOf(listOf(toggle, toggle), List(17) { action })) {
            assertNull(ConsoleModel.fromJson(replace(raw, "composer_actions", JsonArray(rows))))
        }
        assertNotNull(ConsoleModel.fromJson(replace(raw, "composer_actions", JsonArray(emptyList()))))
    }

    @Test
    fun rote_fixtures_preserve_geometry_and_reject_malformed_updates() {
        val cases = fixture("rote-console").getValue("cases").jsonArray
        cases.forEach { entry ->
            val raw = entry.jsonObject.getValue("presentation").jsonObject
            val parsed = assertNotNull(ConsolePresentation.fromJson(raw))
            assertEquals(raw["sidebar_width"].toString().toDouble(), parsed.sidebarWidth)
            assertEquals(raw["scenario_columns"].toString().toInt(), parsed.scenarioColumns)
            assertEquals(raw["composer_padding"]?.jsonObject?.get("right").toString().toDouble(), parsed.composerPadding.right)
            assertEquals(parsed, ConsolePresentation.fromJson(raw))
        }
        assertNull(ConsolePresentation.fromJson(null))
        val raw = cases.first().jsonObject.getValue("presentation").jsonObject
        raw.forEach { (key, value) ->
            assertNull(ConsolePresentation.fromJson(replace(raw, key, null)), key)
            assertNull(ConsolePresentation.fromJson(replace(raw, key, JsonNull)), key)
            if (value is JsonPrimitive && !value.isString) {
                for (bad in listOf(JsonPrimitive(-1), JsonPrimitive(16385), JsonPrimitive("1"), JsonPrimitive(true), JsonPrimitive(Double.POSITIVE_INFINITY))) {
                    assertNull(ConsolePresentation.fromJson(replace(raw, key, bad)), key)
                }
            }
        }
        for (key in listOf("navigation_mode", "settings_presentation", "settings_navigation_axis")) {
            assertNull(ConsolePresentation.fromJson(replace(raw, key, JsonPrimitive("unknown"))))
        }
        for (value in listOf(0.0, 1.5)) assertNull(ConsolePresentation.fromJson(replace(raw, "scenario_columns", JsonPrimitive(value))))
        for (key in listOf("content_padding", "composer_padding")) {
            for (edge in listOf("top", "right", "bottom", "left")) assertNull(ConsolePresentation.fromJson(replace(raw, "$key.$edge", JsonPrimitive(-1))))
        }
        assertNull(ConsolePresentation.fromJson(replace(raw, "sidebar_width", JsonPrimitive(0))))
        assertNotNull(ConsolePresentation.fromJson(replace(replace(raw, "navigation_mode", JsonPrimitive("stack")), "sidebar_width", JsonPrimitive(0))))
        assertNull(ConsolePresentation.fromJson(replace(raw, "navigation_mode", JsonPrimitive("stack"))))
    }

    @Test
    fun availability_handoffs_require_explicit_nonempty_server_copy() {
        val native = Json.parseToJsonElement("""{"mode":"native"}""")
        val handoff = Json.parseToJsonElement("""{"mode":"handoff","message":"Continue on another client"}""")
        assertEquals(ChromeAvailability("native", null), ChromeAvailability.fromJson(native))
        assertEquals(ChromeAvailability("handoff", "Continue on another client"), ChromeAvailability.fromJson(handoff))
        for (bad in listOf("null", "{}", """{"mode":"unknown"}""", """{"mode":"handoff"}""", """{"mode":"handoff","message":""}""", """{"mode":"native","message":"surprise"}""")) {
            assertNull(ChromeAvailability.fromJson(Json.parseToJsonElement(bad)))
        }
        val raw = console()
        val agent = raw.getValue("catalog").jsonObject.getValue("agents").jsonArray.first().jsonObject
        assertNotNull(ConsoleModel.fromJson(replace(raw, "catalog.agents", JsonArray(listOf(replace(agent, "availability", handoff))))))
        assertNull(ConsoleModel.fromJson(replace(raw, "catalog.agents", JsonArray(listOf(replace(agent, "availability", JsonNull))))))
        val source = fixture("chrome-console")
        val control = source.getValue("topbar").jsonArray.last().jsonObject
        val menu = assertNotNull(ChromeMenuModel.fromJson(replace(source, "topbar", JsonArray(listOf(replace(control, "availability", handoff))))))
        assertEquals("handoff", menu.topbar.single().availability?.mode)
        assertTrue(ChromeMenuModel.fromJson(replace(source, "topbar", JsonArray(listOf(replace(control, "availability", JsonNull)))))!!.topbar.isEmpty())
    }

    private val identity = "11111111-1111-4111-8111-111111111111"
    private val revision = "22222222-2222-4222-8222-222222222222"

    private fun selection() = Json.parseToJsonElement("""{"version":1,"agent":{"agent_id":"scout","revision_id":"$revision"},"skills":[{"skill_id":"$identity","revision":4}],"notes":[{"note_id":"$identity","revision":9}]}""").jsonObject

    @Test
    fun selection_retains_exact_revisions_and_uses_server_summary_copy() {
        val raw = selection()
        val value = assertNotNull(TurnSelection.fromJson(raw))
        assertEquals(TurnSelection.Agent("scout", revision), value.agent)
        assertEquals(listOf(TurnSelection.Reference(identity, 4)), value.skills)
        assertEquals(listOf(TurnSelection.Reference(identity, 9)), value.notes)
        assertEquals(raw, value.json)
        assertFalse(value.isEmpty)
        assertTrue(TurnSelection.EMPTY.isEmpty)
        val model = assertNotNull(ConsoleModel.fromJson(console()))
        assertNull(model.selectionSummary(TurnSelection.EMPTY))
        assertNotNull(model.selectionSummary(value))
        assertNull(model.copy(labels = emptyMap()).selectionSummary(value))
        assertNull(model.copy(labels = model.labels - "selection_note_singular").selectionSummary(value))
        val two = JsonArray(listOf(raw.getValue("notes").jsonArray.first(), Json.parseToJsonElement("""{"note_id":"$revision","revision":2}""")))
        assertTrue(model.selectionSummary(assertNotNull(TurnSelection.fromJson(replace(raw, "notes", two))))!!.contains("2 notes"))
    }

    @Test
    fun selection_rejects_extra_missing_keys_versions_and_invalid_agents() {
        val raw = selection()
        assertNull(TurnSelection.fromJson(null))
        assertNull(TurnSelection.fromJson(JsonArray(emptyList())))
        raw.keys.forEach { assertNull(TurnSelection.fromJson(replace(raw, it, null))) }
        for (bad in listOf(JsonPrimitive(2), JsonPrimitive(1.5), JsonPrimitive(true), JsonNull)) assertNull(TurnSelection.fromJson(replace(raw, "version", bad)))
        assertNull(TurnSelection.fromJson(replace(raw, "owner", JsonPrimitive("other"))))
        for (bad in listOf(JsonPrimitive(""), JsonPrimitive(" agent "), JsonPrimitive("a\u0000b"), JsonPrimitive("a".repeat(256)), JsonPrimitive(1))) {
            assertNull(TurnSelection.fromJson(replace(raw, "agent.agent_id", bad)))
        }
        for (bad in listOf("not-a-uuid", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "11111111-1111-1111-8111-111111111111", "11111111-1111-4111-7111-111111111111")) {
            assertNull(TurnSelection.fromJson(replace(raw, "agent.revision_id", JsonPrimitive(bad))))
        }
        assertNull(TurnSelection.fromJson(replace(raw, "agent.extra", JsonNull)))
        assertNull(assertNotNull(TurnSelection.fromJson(replace(raw, "agent", JsonNull))).agent)
    }

    @Test
    fun reference_limits_duplicate_ids_and_revision_bounds_are_enforced() {
        val raw = selection()
        for ((kind, key, limit) in listOf(Triple("skills", "skill_id", 20), Triple("notes", "note_id", 8))) {
            val rows = (0 until limit).map { index -> Json.parseToJsonElement("""{"$key":"${"%08x".format(index)}-1111-4111-8111-111111111111","revision":1}""") }
            assertNotNull(TurnSelection.fromJson(replace(raw, kind, JsonArray(rows))))
            for (bad in listOf(JsonNull, JsonArray(rows + rows[0]), JsonArray(listOf(rows[0], rows[0])), JsonArray(listOf(JsonNull)))) {
                assertNull(TurnSelection.fromJson(replace(raw, kind, bad)))
            }
            for (bad in listOf(JsonPrimitive(0), JsonPrimitive(-1), JsonPrimitive(1.5), JsonPrimitive(9_007_199_254_740_992), JsonPrimitive(true), JsonPrimitive("4"))) {
                val row = replace(rows[0].jsonObject, "revision", bad)
                assertNull(TurnSelection.fromJson(replace(raw, kind, JsonArray(listOf(row)))))
            }
            val max = replace(rows[0].jsonObject, "revision", JsonPrimitive(9_007_199_254_740_991))
            assertNotNull(TurnSelection.fromJson(replace(raw, kind, JsonArray(listOf(max)))))
            assertNull(TurnSelection.fromJson(replace(raw, kind, JsonArray(listOf(replace(rows[0].jsonObject, "extra", JsonNull))))))
        }
    }
}
