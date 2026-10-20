// Verifies the shared terminal monitor fixture decodes as a correlated generic chrome surface and
// advertises only read-only list/refresh/close controls with literal sanitized output.

package com.personalailabs.astraldeep.core.protocol

import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class TerminalMonitorTest {
    private fun fixture(): JsonObject {
        var directory: File? = File(".").absoluteFile
        while (directory != null) {
            val file = File(directory, "contracts/fixtures/terminal/monitor_surface.json")
            if (file.isFile) return Json.parseToJsonElement(file.readText()).jsonObject
            directory = directory.parentFile
        }
        error("Missing terminal monitor fixture")
    }

    private fun manifest(): JsonObject {
        var directory: File? = File(".").absoluteFile
        while (directory != null) {
            val file = File(directory, "contracts/ui_protocol.json")
            if (file.isFile) return Json.parseToJsonElement(file.readText()).jsonObject
            directory = directory.parentFile
        }
        error("Missing UI protocol manifest")
    }

    private fun walk(components: List<Component>, found: MutableList<Component> = mutableListOf()): List<Component> {
        components.forEach { component ->
            found.add(component)
            walk(component.children, found)
        }
        return found
    }

    @Test
    fun correlated_surface_decodes_with_exact_read_only_actions() {
        val source = fixture()
        val frame = source.getValue("native_frame").jsonObject
        val decoded = assertIs<Inbound.ChromeSurface>(Wire.decode(frame))
        assertEquals("terminal", decoded.surfaceKey)
        assertTrue(isPrivateChromeSurface("terminal"))
        assertFalse(isPrivateChromeSurface("Terminal"))
        assertEquals(source.getValue("request").jsonObject.getValue("request_generation").jsonPrimitive.content, decoded.requestGeneration)
        val nodes = walk(decoded.components)
        val actions = nodes.filter { it.type == "button" }.map { it.attributes.getValue("action").jsonPrimitive.content }
        assertEquals(listOf("chrome_open", "chrome_open", "chrome_close"), actions)
        assertEquals(setOf("chrome_open", "chrome_close"), actions.toSet())
        assertFalse(nodes.any { it.type in setOf("input", "param_picker") })
        val accepted = manifest().getValue("accept_actions").jsonArray.map { it.jsonPrimitive.content }.toSet()
        assertTrue(accepted.containsAll(actions))
        val contract = manifest().getValue("presentation_contracts").jsonObject.getValue("terminal_monitor").jsonObject
        assertEquals(frame.keys, contract.getValue("native_response").jsonObject.getValue("exact_fields").jsonArray.map { it.jsonPrimitive.content }.toSet())
    }

    @Test
    fun literal_output_is_sanitized_and_watch_handoff_is_content_free() {
        val source = fixture()
        val frame = assertIs<Inbound.ChromeSurface>(Wire.decode(source.getValue("native_frame").jsonObject))
        val code = walk(frame.components).single { it.type == "code" }
        val text = code.attributes.getValue("code").jsonPrimitive.content
        assertEquals(source.getValue("expected_sanitized_text").jsonPrimitive.content, text)
        assertFalse(text.contains("\u001b"))
        assertFalse(text.contains("evil.example"))
        assertFalse(text.contains("clipboard theft"))
        val watch = source.getValue("watch_components").jsonArray.map { it.jsonObject }
        assertEquals(setOf("badge", "alert"), watch.map { it.getValue("type").jsonPrimitive.content }.toSet())
        assertFalse(watch.any { it.getValue("type").jsonPrimitive.content == "button" })
        val private = listOf("term_01JABCDEF", "ops@staging.example", "/srv/astral/work", "hello")
        private.forEach { assertFalse(watch.toString().contains(it)) }
        assertTrue(watch.any { (it["message"]?.jsonPrimitive?.content ?: "").contains("phone or desktop") })
    }

    @Test
    fun missing_stale_extra_or_non_replace_envelopes_are_refused() {
        val frame = fixture().getValue("native_frame").jsonObject
        assertIs<Inbound.Unknown>(Wire.decode(JsonObject(frame - "request_generation")))
        assertIs<Inbound.Unknown>(
            Wire.decode(JsonObject(frame + ("request_generation" to JsonPrimitive("stale")))),
        )
        assertIs<Inbound.Unknown>(
            Wire.decode(JsonObject(frame + ("mode" to JsonPrimitive("append")))),
        )
        assertIs<Inbound.Unknown>(
            Wire.decode(JsonObject(frame + ("extra" to JsonPrimitive("untrusted")))),
        )
        assertIs<Inbound.Unknown>(
            Wire.decode(JsonObject(frame + ("components" to JsonArray(listOf(JsonPrimitive("untrusted")))))),
        )
    }
}