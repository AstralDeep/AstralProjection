// Verifies the shared terminal panel fixture decodes as a correlated generic chrome surface and
// that read-only deliveries advertise only list/refresh/close controls with literal sanitized output.

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

class TerminalPanelTest {
    private fun fixture(): JsonObject {
        var directory: File? = File(".").absoluteFile
        while (directory != null) {
            val file = File(directory, "contracts/fixtures/terminal/panel_surface.json")
            if (file.isFile) return Json.parseToJsonElement(file.readText()).jsonObject
            directory = directory.parentFile
        }
        error("Missing terminal panel fixture")
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

    private fun walk(
        components: List<Component>,
        found: MutableList<Component> = mutableListOf(),
    ): List<Component> {
        components.forEach { component ->
            found.add(component)
            walk(component.children, found)
        }
        return found
    }

    private fun actions(nodes: List<Component>): List<String> =
        nodes.filter { it.type == "button" }.map {
            it.attributes.getValue("action").jsonPrimitive.content
        }

    @Test
    fun correlated_read_only_surface_decodes_without_interactive_controls() {
        val source = fixture()
        val frame = source.getValue("read_only_frames").jsonObject.getValue("panel").jsonObject
        val decoded = assertIs<Inbound.ChromeSurface>(Wire.decode(frame))
        assertEquals("terminal", decoded.surfaceKey)
        assertTrue(isPrivateChromeSurface("terminal"))
        assertFalse(isPrivateChromeSurface("Terminal"))
        assertEquals(
            source
                .getValue("request")
                .jsonObject
                .getValue("request_generation")
                .jsonPrimitive.content,
            decoded.requestGeneration,
        )
        val nodes = walk(decoded.components)
        assertEquals(setOf("chrome_open", "chrome_close"), actions(nodes).toSet())
        assertFalse(nodes.any { it.type in setOf("input", "param_picker") })
        val accepted =
            manifest()
                .getValue("accept_actions")
                .jsonArray
                .map { it.jsonPrimitive.content }
                .toSet()
        assertTrue(accepted.containsAll(actions(nodes)))
        val contract =
            manifest()
                .getValue("presentation_contracts")
                .jsonObject
                .getValue("terminal_panel")
                .jsonObject
        assertEquals(
            frame.keys,
            contract
                .getValue("native_response")
                .jsonObject
                .getValue("exact_fields")
                .jsonArray
                .map { it.jsonPrimitive.content }
                .toSet(),
        )
    }

    @Test
    fun literal_output_is_sanitized_and_watch_handoff_is_content_free() {
        val source = fixture()
        val maliciousFrame =
            assertIs<Inbound.ChromeSurface>(
                Wire.decode(source.getValue("frames").jsonObject.getValue("malicious").jsonObject),
            )
        val code = walk(maliciousFrame.components).single { it.type == "code" }
        val text =
            code.attributes
                .getValue("code")
                .jsonPrimitive.content
        assertEquals(source.getValue("expected_sanitized_text").jsonPrimitive.content, text)
        assertFalse(text.contains("\u001b"))
        assertFalse(text.contains("evil.example"))
        assertFalse(text.contains("clipboard theft"))
        val watch = source.getValue("watch_components").jsonArray.map { it.jsonObject }
        assertEquals(setOf("badge", "alert"), watch.map { it.getValue("type").jsonPrimitive.content }.toSet())
        assertFalse(watch.any { it.getValue("type").jsonPrimitive.content == "button" })
        val privateValues = listOf("term_01JABCDEF", "ops@staging.example", "/srv/astral/work", "hello")
        privateValues.forEach { assertFalse(watch.toString().contains(it)) }
        assertTrue(watch.any { (it["message"]?.jsonPrimitive?.content ?: "").contains("phone or desktop") })
    }

    @Test
    fun interactive_operations_are_manifested_for_qualified_clients_only() {
        val source = fixture()
        val contract =
            manifest()
                .getValue("presentation_contracts")
                .jsonObject
                .getValue("terminal_panel")
                .jsonObject
        val interactive = source.getValue("frames").jsonObject.getValue("panel").jsonObject
        val nodes = walk(assertIs<Inbound.ChromeSurface>(Wire.decode(interactive)).components)
        val declared = contract.getValue("actions").jsonObject.keys
        assertTrue(
            nodes
                .mapNotNull { it.attributes["action"]?.jsonPrimitive?.content }
                .toSet()
                .isSubsetOf(declared + setOf("chrome_open", "chrome_close")),
        )
        assertEquals(
            contract.getValue("dispositions").jsonObject.getValue("android").jsonPrimitive.content,
            "read_only_monitor",
        )
        val watch = source.getValue("watch_components").jsonArray
        assertTrue(watch.all { it.jsonObject.getValue("type").jsonPrimitive.content != "param_picker" })
    }

    @Test
    fun missing_stale_extra_or_non_replace_envelopes_are_refused() {
        val frame = fixture().getValue("read_only_frames").jsonObject.getValue("panel").jsonObject
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
            Wire.decode(JsonObject(frame + ("components" to JsonArray(listOf(JsonPrimitive("param_picker")))))),
        )
    }
}

private fun Set<String>.isSubsetOf(other: Collection<String>): Boolean = other.containsAll(this)
