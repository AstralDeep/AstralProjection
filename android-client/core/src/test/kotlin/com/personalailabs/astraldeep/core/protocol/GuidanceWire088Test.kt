package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class GuidanceWire088Test {
    @Test fun private_surface_vocabulary_and_wire_echo_are_exact() {
        for (surface in listOf("guidance", "work")) {
            assertTrue(isPrivateChromeSurface(surface))
            val request = "11111111-1111-4111-8111-111111111111"
            val valid = assertIs<Inbound.ChromeSurface>(Wire.decode("""{"type":"chrome_surface","surface_key":"$surface","request_generation":"$request","components":[],"region":"modal","mode":"replace","title":"Private notes","admin_only":false}"""))
            assertEquals(request, valid.requestGeneration)
            for (bad in listOf("null", "3", "true", "[]", "{}", "\"11111111-1111-5111-8111-111111111111\"")) {
                assertIs<Inbound.Unknown>(Wire.decode("""{"type":"chrome_surface","surface_key":"$surface","request_generation":$bad,"components":[],"region":"modal","mode":"replace","title":"Private notes","admin_only":false}"""))
            }
        }
        assertFalse(isPrivateChromeSurface("GUIDANCE"))
        assertFalse(isPrivateChromeSurface("theme"))
        for (action in listOf("chrome_note_search", "chrome_note_save", "chrome_note_toggle", "chrome_note_forget")) assertTrue(isGuidanceNoteAction(action))
        assertFalse(isGuidanceNoteAction("chrome_note_other"))
        val legacy = Wire.encodeRegisterUi("synthetic", null, DeviceCapabilities(800, 600))
        assertFalse(legacy.contains("guidance_notes_v1"))
        assertTrue(Wire.encodeRegisterUi("synthetic", null, DeviceCapabilities(800, 600), guidanceNotes = true).contains("guidance_notes_v1"))
    }

    private fun notesFrame(): JsonObject =
        Json.parseToJsonElement(
            """{"type":"chrome_surface","surface_key":"guidance","region":"modal","title":"Private notes","admin_only":false,"components":[],"mode":"replace","request_generation":"11111111-1111-4111-8111-111111111111"}""",
        ).jsonObject

    @Test fun notes_refuse_non_modal_or_missing_explicit_replace_before_delivery() {
        val valid = notesFrame()
        assertIs<Inbound.ChromeSurface>(Wire.decode(valid))
        for ((key, value) in listOf("region" to "topbar", "mode" to "mandatory")) {
            assertIs<Inbound.Unknown>(Wire.decode(JsonObject(valid + (key to JsonPrimitive(value)))))
        }
        for (key in listOf("region", "mode")) assertIs<Inbound.Unknown>(Wire.decode(JsonObject(valid - key)))
    }

    @Test fun notes_outer_fields_are_closed_and_typed_without_partial_components() {
        val valid = notesFrame()
        val tree = Json.parseToJsonElement("""[{"type":"card","title":"Complete","variant":"default","content":[{"type":"text","content":"literal","variant":"body"},{"type":"badge","label":"Enabled","variant":"default"}]},{"type":"alert","message":"Complete","variant":"info"}]""")
        assertEquals(2, assertIs<Inbound.ChromeSurface>(Wire.decode(JsonObject(valid + ("components" to tree)))).components.size)
        for (key in valid.keys) assertIs<Inbound.Unknown>(Wire.decode(JsonObject(valid - key)), "missing $key")
        assertIs<Inbound.Unknown>(Wire.decode(JsonObject(valid + ("unknown" to JsonPrimitive(true)))))
        for (key in listOf("region", "mode", "title", "admin_only", "components")) {
            for (value in listOf(JsonNull, JsonPrimitive(3), JsonPrimitive(true), JsonObject(emptyMap()))) {
                assertIs<Inbound.Unknown>(Wire.decode(JsonObject(valid + (key to value))), "invalid $key")
            }
        }
        assertIs<Inbound.Unknown>(Wire.decode(JsonObject(valid + ("admin_only" to JsonPrimitive("false")))))
        for (component in listOf("null", "3", "[]", "{}", "{\"type\":3}", "{\"type\":\"unsupported\"}", "{\"type\":\"text\",\"content\":3}", "{\"type\":\"card\",\"children\":\"dropped\"}", "{\"type\":\"card\",\"content\":[null]}")) {
            val components = JsonArray(listOf(Json.parseToJsonElement("""{"type":"text","content":"kept"}"""), Json.parseToJsonElement(component)))
            assertIs<Inbound.Unknown>(Wire.decode(JsonObject(valid + ("components" to components))), "partial component")
        }
    }
}
