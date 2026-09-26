// Tests exact native guidance-note forms and refusal of unsupported skill and agent editing envelopes.
// Selection has its own negotiated decoder and shared fixture coverage in ConsoleWireTest.

package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class GuidanceFormWire088Test {
    private fun fixtures(): JsonObject {
        val file =
            generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
                .map { File(it, "contracts/fixtures/guidance_088/notes_surface.json") }.first { it.isFile }
        return Json.parseToJsonElement(file.readText()).jsonObject.getValue("frames").jsonObject
    }

    private fun form(mode: String = "edit"): JsonObject =
        (fixtures().getValue(mode).jsonObject.getValue("components") as JsonArray)
            .map { it.jsonObject }.first { it["type"] == JsonPrimitive("param_picker") }

    private fun frame(component: JsonElement): JsonObject =
        JsonObject(fixtures().getValue("edit").jsonObject + ("components" to JsonArray(listOf(component))))

    private fun refuse(component: JsonElement) = assertIs<Inbound.Unknown>(Wire.decode(frame(component)))

    @Test fun every_actual_shared_frame_preserves_its_complete_form() {
        for (value in fixtures().values) assertIs<Inbound.ChromeSurface>(Wire.decode(value.jsonObject))
    }

    private fun unadmittedFixtures(): Map<String, JsonObject> =
        listOf("skills", "agents").associateWith { name ->
            val file =
                generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
                    .map { File(it, "contracts/fixtures/guidance_088/${name}_surface.json") }.first { it.isFile }
            Json.parseToJsonElement(file.readText()).jsonObject.getValue("frames").jsonObject
        }

    @Test fun unadmitted_088_guidance_forms_are_refused_in_full_until_deliberately_admitted() {
        val frames = unadmittedFixtures()
        assertEquals(mapOf("skills" to 4, "agents" to 8), frames.mapValues { it.value.size })
        for ((name, modes) in frames) {
            for ((mode, frame) in modes) {
                assertIs<Inbound.Unknown>(Wire.decode(frame.jsonObject), "$name/$mode must be refused whole")
            }
        }
        val registration = Wire.encodeRegisterUi("synthetic", null, DeviceCapabilities(800, 600), guidanceNotes = true)
        assertTrue(registration.contains("guidance_notes_v1"))
        for (capability in listOf("guidance_skills_v1", "guidance_agents_v1", "guidance_selection_v1")) {
            assertFalse(registration.contains(capability), "$capability is not admitted on Android")
        }
    }

    @Test fun malformed_form_shape_or_missing_save_fields_refuses_whole_frame() {
        val valid = form()
        for (key in valid.keys) refuse(JsonObject(valid - key))
        for (value in listOf(JsonNull, JsonObject(emptyMap()), JsonArray(emptyList()), JsonPrimitive("fields"))) {
            refuse(JsonObject(valid + ("fields" to value)))
        }
        refuse(JsonObject(valid + ("submit_action" to JsonPrimitive("chrome_execute"))))
        refuse(JsonObject(valid + ("unknown" to JsonPrimitive(true))))
    }

    @Test fun field_kind_default_choices_and_visibility_must_match_exact_shared_form() {
        val valid = form()
        val fields = valid.getValue("fields") as JsonArray
        val changes =
            listOf(
                0 to ("default" to JsonPrimitive("Other")),
                0 to ("options" to JsonArray(listOf(JsonPrimitive("Context")))),
                0 to ("kind" to JsonPrimitive("text")),
                1 to ("default" to JsonPrimitive(123)),
                1 to ("default" to JsonPrimitive("x".repeat(4097))),
                1 to ("help" to JsonPrimitive(false)),
                1 to ("visible_when" to JsonObject(emptyMap())),
                1 to ("options" to JsonArray(emptyList())),
                2 to ("default" to JsonPrimitive("false")),
                3 to ("default" to JsonPrimitive("Other")),
                4 to ("visible_when" to JsonObject(mapOf("expiry" to JsonPrimitive("No expiry")))),
            )
        for ((index, change) in changes) {
            val altered = fields.toMutableList()
            altered[index] = JsonObject(altered[index].jsonObject + change)
            refuse(JsonObject(valid + ("fields" to JsonArray(altered))))
        }
        for (index in fields.indices) {
            val altered = fields.toMutableList()
            altered[index] = JsonObject(altered[index].jsonObject - "name")
            refuse(JsonObject(valid + ("fields" to JsonArray(altered))))
        }
        refuse(JsonObject(valid + ("fields" to JsonArray(fields.reversed()))))
    }

    @Test fun save_identity_requires_exact_uuid_and_integer_revision_in_live_domain() {
        val valid = form()
        val identity = valid.getValue("submit_payload").jsonObject
        for (key in identity.keys) refuse(JsonObject(valid + ("submit_payload" to JsonObject(identity - key))))
        for (value in listOf(JsonNull, JsonPrimitive(true), JsonPrimitive("3"), JsonPrimitive(1.5), JsonPrimitive(-1), JsonPrimitive(9_007_199_254_740_991L))) {
            refuse(JsonObject(valid + ("submit_payload" to JsonObject(identity + ("expected_revision" to value)))))
        }
        refuse(JsonObject(valid + ("submit_payload" to JsonObject(identity + ("note_id" to JsonPrimitive("foreign"))))))
        refuse(JsonObject(valid + ("submit_payload" to JsonObject(identity + ("extra" to JsonPrimitive(true))))))
    }

    @Test fun buttons_cannot_supply_unknown_actions_or_incomplete_revision_commands() {
        val button = (fixtures().getValue("forget").jsonObject.getValue("components") as JsonArray).last().jsonObject
        for (key in button.keys) refuse(JsonObject(button - key))
        for ((key, value) in listOf("action" to JsonPrimitive("chrome_note_save"), "local" to JsonPrimitive(true), "disabled" to JsonPrimitive("false"), "payload" to JsonObject(emptyMap()))) {
            refuse(JsonObject(button + (key to value)))
        }
        val nav = (fixtures().getValue("new").jsonObject.getValue("components") as JsonArray).first().jsonObject
        val payload = nav.getValue("payload").jsonObject
        refuse(JsonObject(nav + ("payload" to JsonObject(payload + ("surface" to JsonPrimitive("work"))))))
        refuse(JsonObject(nav + ("payload" to JsonObject(payload + ("params" to JsonObject(mapOf("mode" to JsonPrimitive("run"))))))))
    }

    private fun change(
        node: JsonObject,
        key: String,
        value: JsonElement,
    ): JsonObject = JsonObject(node + (key to value))

    @Test fun search_navigation_and_toggle_require_closed_current_identity_payloads() {
        refuse(change(form("list"), "submit_payload", JsonObject(mapOf("extra" to JsonPrimitive(true)))))
        val nav = (fixtures().getValue("new").jsonObject.getValue("components") as JsonArray).first().jsonObject
        val identifier = "11111111-1111-4111-8111-111111111111"

        fun navigation(params: JsonObject): JsonObject = change(nav, "payload", JsonObject(mapOf("surface" to JsonPrimitive("guidance"), "params" to params)))
        val list = JsonObject(mapOf("mode" to JsonPrimitive("list"), "after_id" to JsonPrimitive(identifier), "search" to JsonPrimitive("literal")))
        assertIs<Inbound.ChromeSurface>(Wire.decode(frame(navigation(list))))
        for ((key, value) in listOf("after_id" to JsonPrimitive("bad"), "search" to JsonPrimitive(false), "search" to JsonPrimitive("x".repeat(257)), "unknown" to JsonPrimitive(true))) {
            refuse(navigation(change(list, key, value)))
        }
        val edit = JsonObject(mapOf("mode" to JsonPrimitive("edit"), "note_id" to JsonPrimitive(identifier), "expected_revision" to JsonPrimitive(1)))
        assertIs<Inbound.ChromeSurface>(Wire.decode(frame(navigation(edit))))
        refuse(navigation(change(edit, "expected_revision", JsonPrimitive(0))))
        val payload = JsonObject(mapOf("note_id" to JsonPrimitive(identifier), "expected_revision" to JsonPrimitive(1), "enabled" to JsonPrimitive(false)))
        val toggle = change(change(nav, "action", JsonPrimitive("chrome_note_toggle")), "payload", payload)
        assertIs<Inbound.ChromeSurface>(Wire.decode(frame(toggle)))
        refuse(change(toggle, "payload", change(payload, "enabled", JsonPrimitive("false"))))
        refuse(change(toggle, "payload", JsonArray(emptyList())))
    }

    @Test fun complete_component_tree_and_utf8_budgets_are_bounded() {
        val text = Json.parseToJsonElement("""{"type":"text","content":"literal","variant":"body"}""").jsonObject
        for (key in text.keys) refuse(JsonObject(text - key))
        for ((key, value) in listOf("content" to JsonPrimitive(1), "content" to JsonPrimitive("bad\u0000text"), "variant" to JsonPrimitive(false), "content" to JsonPrimitive("🙂".repeat(2049)))) {
            refuse(change(text, key, value))
        }
        assertIs<Inbound.ChromeSurface>(Wire.decode(frame(change(text, "content", JsonPrimitive("🙂".repeat(2048))))))
        var nested: JsonElement = text
        repeat(8) { nested = JsonObject(mapOf("type" to JsonPrimitive("card"), "title" to JsonPrimitive("Group"), "variant" to JsonPrimitive("default"), "content" to JsonArray(listOf(nested)))) }
        assertIs<Inbound.ChromeSurface>(Wire.decode(frame(nested)))
        refuse(change(nested.jsonObject, "content", JsonArray(listOf(nested))))
        refuse(change(nested.jsonObject, "content", JsonPrimitive("dropped")))
        assertIs<Inbound.Unknown>(Wire.decode(change(frame(text), "components", JsonArray(List(1025) { text }))))
        val largeText = change(text, "content", JsonPrimitive("x".repeat(8192)))
        assertIs<Inbound.Unknown>(Wire.decode(change(frame(text), "components", JsonArray(List(128) { largeText }))))
        refuse(change(text, "extra", JsonPrimitive(true)))
    }
}
