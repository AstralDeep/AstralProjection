// Tests for guidance-surface field rendering helpers used by the native notes/guidance view.

package com.personalailabs.astraldeep.app.render

import com.personalailabs.astraldeep.app.render.renderers.fieldIsVisible
import com.personalailabs.astraldeep.app.render.renderers.initialBools
import com.personalailabs.astraldeep.app.render.renderers.initialTexts
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class GuidanceFields088Test {
    @Test fun only_note_forms_interpret_the_shared_equality_map() {
        val field = Json.parseToJsonElement("""{"visible_when":{"expiry":"Set a date"}}""").jsonObject
        assertFalse(fieldIsVisible(field, mapOf("expiry" to "No expiry"), guidanceNotes = true))
        assertFalse(fieldIsVisible(field, emptyMap(), guidanceNotes = true))
        assertTrue(fieldIsVisible(field, mapOf("expiry" to "Set a date"), guidanceNotes = true))
        assertTrue(fieldIsVisible(field, mapOf("expiry" to "No expiry")))
        val legacy = Json.parseToJsonElement("""{"visible_when":{"field":"expiry","equals":"Set a date","default":"No expiry"}}""").jsonObject
        assertFalse(fieldIsVisible(legacy, emptyMap()))
        assertTrue(fieldIsVisible(legacy, mapOf("expiry" to "Set a date")))
        for (invalid in listOf("{}", "null", "[]", "{\"expiry\":true}")) {
            val malformed = Json.parseToJsonElement("""{"visible_when":$invalid}""").jsonObject
            assertFalse(fieldIsVisible(malformed, emptyMap(), guidanceNotes = true))
        }
        assertTrue(fieldIsVisible(JsonObject(emptyMap()), emptyMap(), guidanceNotes = true))
    }

    @Test fun note_select_and_boolean_defaults_remain_the_server_values() {
        val fields =
            listOf(
                """{"name":"category","kind":"select","default":"Context","options":["Profession","Context"]}""",
                """{"name":"expiry","kind":"select","default":"Keep current expiry","options":["Keep current expiry","No expiry","Set a date"]}""",
                """{"name":"enabled","kind":"boolean","default":true}""",
            ).map { Json.parseToJsonElement(it).jsonObject }
        assertEquals(mapOf("category" to "Context", "expiry" to "Keep current expiry"), initialTexts(fields))
        assertEquals(mapOf("enabled" to true), initialBools(fields))
    }
}
