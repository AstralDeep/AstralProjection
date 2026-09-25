// Exercises negotiated console registration, server ROTE updates and exact revision forwarding.
// Shared guidance fixtures qualify the picker and confirmation boundary without bypassing request fences.

package com.personalailabs.astraldeep.core.protocol

import com.personalailabs.astraldeep.core.chrome.ConsoleModel
import com.personalailabs.astraldeep.core.chrome.ConsolePresentation
import com.personalailabs.astraldeep.core.chrome.TurnSelection
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
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ConsoleWireTest {
    private fun fixture(path: String): JsonObject {
        var directory: File? = File(".").absoluteFile
        while (directory != null) {
            val file = File(directory, "contracts/fixtures/$path.json")
            if (file.isFile) return Json.parseToJsonElement(file.readText()).jsonObject
            directory = directory.parentFile
        }
        error("Missing shared fixture: $path")
    }

    private fun parse(value: String) = Json.parseToJsonElement(value).jsonObject

    @Test fun deletionFramesRequireAnExactConversationIdentifier() {
        val id = "00000000-0000-4000-8000-000000000001"
        assertEquals(Inbound.ChatDeleted(id), Wire.decode(parse("""{"type":"chat_deleted","chat_id":"$id"}""")))
        for (value in listOf("null", "false", "{}", "123", "\"\"", "\"$id/other\"")) {
            assertIs<Inbound.Unknown>(Wire.decode(parse("""{"type":"chat_deleted","chat_id":$value}""")))
        }
        assertIs<Inbound.Unknown>(Wire.decode(parse("""{"type":"chat_deleted"}""")))
        assertEquals(ProtocolManifest.HANDLED, ProtocolManifest.classification["chat_deleted"])
    }

    @Test
    fun opt_in_and_capability_updates_share_the_actual_device_snapshot() {
        val device = DeviceCapabilities(1170, 2532, 390, 844, 3.0, hasTouch = true, hasCamera = true, hasFileSystem = true, connectionType = "cellular", pointerType = "coarse", reducedMotion = true, consoleContract = ConsoleModel.CONTRACT)
        val frame = parse(Wire.encodeRegisterUi("synthetic", null, device, guidanceNotes = true))
        assertTrue(frame.getValue("capabilities").jsonArray.contains(JsonPrimitive("guidance_selection_v1")))
        val values = frame.getValue("device").jsonObject
        assertEquals(JsonPrimitive("console/v2"), values["console_contract"])
        assertEquals(JsonPrimitive(390), values["viewport_width"])
        assertEquals(JsonPrimitive(844), values["viewport_height"])
        assertEquals(JsonPrimitive(3.0), values["pixel_ratio"])
        assertEquals(JsonPrimitive(true), values["has_camera"])
        assertEquals(JsonPrimitive(true), values["has_file_system"])
        assertEquals(JsonPrimitive(true), values["reduced_motion"])
        assertEquals(JsonPrimitive("cellular"), values["connection_type"])
        assertEquals(JsonPrimitive("coarse"), values["pointer_type"])
        val update = parse(Wire.encodeUpdateDevice(device, "chat"))
        assertEquals(JsonPrimitive("update_device"), update["action"])
        assertEquals(values, update.getValue("payload").jsonObject["device"])
        for (contract in listOf(null, "console/v3")) {
            val legacy = parse(Wire.encodeRegisterUi("synthetic", null, device.copy(consoleContract = contract)))
            assertFalse(legacy.getValue("capabilities").jsonArray.contains(JsonPrimitive("guidance_selection_v1")))
            assertNull(legacy.getValue("device").jsonObject["console_contract"])
        }
    }

    @Test
    fun all_server_rote_fixtures_decode_without_local_breakpoint_policy() {
        fixture("console/rote-console").getValue("cases").jsonArray.forEach { entry ->
            val raw = entry.jsonObject.getValue("presentation")
            val frame = JsonObject(mapOf("type" to JsonPrimitive("rote_config"), "device_profile" to JsonObject(mapOf("console" to raw))))
            assertEquals(ConsolePresentation.fromJson(raw), assertIs<Inbound.RoteConfig>(Wire.decode(frame)).console)
        }
        for (raw in listOf("{}", """{"console":{"version":3}}""", "null")) {
            assertNull(assertIs<Inbound.RoteConfig>(Wire.decode("""{"type":"rote_config","device_profile":$raw}""")).console)
        }
    }

    @Test
    fun picker_and_confirmation_keep_exact_revision_selections() {
        val picker = fixture("guidance_088/selection_surface").getValue("frames").jsonObject.getValue("picker").jsonObject
        assertIs<Inbound.ChromeSurface>(Wire.decode(picker))
        fixture("console/guidance-confirmation").getValue("cases").jsonArray.forEach { entry ->
            val raw = entry.jsonObject.getValue("frame").jsonObject
            val frame = assertIs<Inbound.ChromeSurface>(Wire.decode(raw))
            val selection = assertNotNull(frame.selection)
            assertEquals(raw["selection"], selection.json)
            assertTrue(selection.isGuidanceSelection)
            val message = parse(Wire.encodeChatMessage("hello", "chat", selection = selection))
            assertEquals(if (selection.isEmpty) null else selection.json, message.getValue("payload").jsonObject["selection"])
        }
        assertNull(parse(Wire.encodeChatMessage("hello", null)).getValue("payload").jsonObject["selection"])
        assertNull(parse(Wire.encodeChatMessage("hello", null, selection = TurnSelection.EMPTY)).getValue("payload").jsonObject["selection"])
    }

    @Test
    fun guidance_rejects_forged_non_declarative_agents_and_unknown_confirmations() {
        val picker = fixture("guidance_088/selection_surface").getValue("frames").jsonObject.getValue("picker").jsonObject
        val nonDeclarative = parse("""{"version":1,"agent":{"agent_id":"built_in_agent","revision_id":"11111111-1111-4111-8111-111111111111"},"skills":[],"notes":[]}""")
        assertFalse(assertNotNull(TurnSelection.fromJson(nonDeclarative)).isGuidanceSelection)
        for (selection in listOf(JsonNull, JsonObject(emptyMap()), nonDeclarative)) {
            assertIs<Inbound.Unknown>(Wire.decode(JsonObject(picker + ("selection" to selection))))
        }
        val invalid = JsonObject(picker + ("selection" to TurnSelection.EMPTY.json) + ("surface_key" to JsonPrimitive("agent_intro")))
        assertIs<Inbound.Unknown>(Wire.decode(invalid))
        val badComponents = picker.getValue("components").jsonArray.map { corruptSelection(it, nonDeclarative) }
        assertIs<Inbound.Unknown>(Wire.decode(JsonObject(picker + ("components" to JsonArray(badComponents)))))
    }

    private fun corruptSelection(
        value: JsonElement,
        replacement: JsonObject,
    ): JsonElement {
        if (value !is JsonObject) return value
        if (value["action"] == JsonPrimitive("chrome_turn_selection_set")) return JsonObject(value + ("payload" to replacement))
        val content = value["content"] as? JsonArray ?: return value
        return JsonObject(value + ("content" to JsonArray(content.map { corruptSelection(it, replacement) })))
    }

    @Test
    fun intro_requires_current_request_correlation_like_other_private_surfaces() {
        val intro = fixture("console/agent-intro")
        assertTrue(isPrivateChromeSurface("agent_intro"))
        assertIs<Inbound.ChromeSurface>(Wire.decode(intro))
        assertIs<Inbound.Unknown>(Wire.decode(JsonObject(intro - "request_generation")))
        assertIs<Inbound.Unknown>(Wire.decode(JsonObject(intro + ("mode" to JsonPrimitive("append")))))
        assertIs<Inbound.Unknown>(Wire.decode(JsonObject(intro + ("request_generation" to JsonPrimitive("stale")))))
    }
}
