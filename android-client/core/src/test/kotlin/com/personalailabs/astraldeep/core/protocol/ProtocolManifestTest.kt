// Tests that ProtocolManifest's HANDLED/IGNORED table exactly covers every frame type in the committed
// ui_protocol.json manifest, failing the build on undeclared drift.

package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class ProtocolManifestTest {
    @Test
    fun safety_controls_preserve_server_revision_and_request_correlation() {
        val root = manifestRoot()
        val contract = root.getValue("presentation_contracts").jsonObject.getValue("owner_safety").jsonObject
        val fixture = Json.parseToJsonElement(File(manifestFile().parentFile.parentFile, contract.getValue("fixture").jsonPrimitive.content).readText()).jsonObject
        val expected = setOf("chrome_safety_stop", "chrome_safety_resume", "chrome_safety_verify")
        assertEquals(expected, contract.getValue("actions").jsonObject.keys)
        assertTrue(root.getValue("accept_actions").jsonArray.map { it.jsonPrimitive.content }.containsAll(expected))
        val generation = fixture.getValue("request_generation").jsonPrimitive.content
        for (button in fixture.getValue("buttons").jsonArray) {
            val fields = button.jsonObject
            val action = fields.getValue("action").jsonPrimitive.content
            val payload = fields.getValue("payload").jsonObject
            val submission = "44444444-4444-4444-8444-444444444444"
            val frame = Json.parseToJsonElement(Wire.encodeUiEvent(action, null, payload, generation, submission)).jsonObject
            assertEquals(action, frame.getValue("action").jsonPrimitive.content)
            assertEquals(generation, frame.getValue("request_generation").jsonPrimitive.content)
            assertEquals(submission, frame.getValue("submission_id").jsonPrimitive.content)
            assertEquals(payload, frame.getValue("payload"))
        }
    }

    private val admissionRefusalCodes =
        listOf(
            "capacity_exceeded",
            "registration_required",
            "registration_timeout",
            "idempotency_conflict",
            "connection_closing",
            "service_draining",
            "invalid_input",
            "registration_queue_full",
            "operation_failed",
        )

    private fun manifestFile(): File {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "contracts/ui_protocol.json")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        error("contracts/ui_protocol.json not found walking up from ${File(".").absolutePath}")
    }

    private fun manifestPushTypes(): Set<String> {
        val root = Json.parseToJsonElement(manifestFile().readText()).jsonObject
        return root.getValue("push_types").jsonArray
            .map { it.jsonObject.getValue("name").jsonPrimitive.content }
            .toSet()
    }

    private fun manifestRoot() = Json.parseToJsonElement(manifestFile().readText()).jsonObject

    private fun evidenceFixture() =
        Json.parseToJsonElement(File(manifestFile().parentFile, "fixtures/evidence/inspection_surface.json").readText()).jsonObject

    @Test
    fun evidence_inspection_preserves_existing_modal_vocabulary_and_explicit_watch_handoff() {
        val root = manifestRoot()
        val contract = root.getValue("presentation_contracts").jsonObject.getValue("evidence_inspection").jsonObject
        val fixture = evidenceFixture()
        assertEquals("1", contract.getValue("version").jsonPrimitive.content)
        assertEquals("evidence", contract.getValue("surface_key").jsonPrimitive.content)
        assertEquals("chrome_open", contract.getValue("navigation").jsonObject.getValue("action").jsonPrimitive.content)
        val dispositions = contract.getValue("dispositions").jsonObject.mapValues { it.value.jsonPrimitive.content }
        assertEquals(
            mapOf(
                "browser" to "correlated_modal",
                "windows" to "correlated_modal",
                "android" to "correlated_modal",
                "macos" to "correlated_modal",
                "ios" to "correlated_modal",
                "watchos" to "phone_desktop_handoff",
            ),
            dispositions,
        )
        val request = fixture.getValue("request").jsonObject
        val generation = request.getValue("request_generation").jsonPrimitive.content
        assertEquals(4, UUID.fromString(generation).version())
        assertEquals(generation, UUID.fromString(generation).toString())
        assertEquals("chrome_open", request.getValue("action").jsonPrimitive.content)
        assertEquals("evidence", request.getValue("payload").jsonObject.getValue("surface").jsonPrimitive.content)
        for ((name, response, frameType) in listOf(
            Triple("native_frame", "native_response", "chrome_surface"),
            Triple("web_frame", "web_response", "chrome_render"),
        )) {
            val frame = fixture.getValue(name).jsonObject
            assertEquals(contract.getValue(response).jsonObject.getValue("exact_fields").jsonArray.map { it.jsonPrimitive.content }.toSet(), frame.keys)
            assertEquals(frameType, frame.getValue("type").jsonPrimitive.content)
            assertEquals(generation, frame.getValue("request_generation").jsonPrimitive.content)
            assertEquals("modal", frame.getValue("region").jsonPrimitive.content)
            assertEquals("replace", frame.getValue("mode").jsonPrimitive.content)
        }
        assertEquals(141, root.getValue("accept_actions").jsonArray.size)
        assertEquals(72, manifestPushTypes().size)
        assertTrue(ProtocolManifest.isHandled("chrome_surface"))
        assertTrue(manifestPushTypes().none { it.startsWith("evidence") })
        val watch = fixture.getValue("watch_components").jsonArray
        val text = fixture.getValue("source_text").jsonPrimitive.content
        assertFalse(JsonPrimitive(text).toString() in watch.toString())
        assertTrue(watch.any { "phone or desktop" in it.jsonObject["message"]?.jsonPrimitive?.content.orEmpty() })
        assertTrue(watch.all { it.jsonObject.getValue("type").jsonPrimitive.content in setOf("badge", "keyvalue", "alert") })
    }

    @Test
    fun evidence_golden_decodes_exact_literal_text_in_the_generic_surface() {
        val fixture = evidenceFixture()
        val frame = fixture.getValue("native_frame").jsonObject
        val decoded = assertIs<Inbound.ChromeSurface>(Wire.decode(frame))
        assertEquals("evidence", decoded.surfaceKey)
        assertEquals(frame.getValue("request_generation").jsonPrimitive.content, decoded.requestGeneration)
        assertEquals(frame.getValue("components").jsonArray.size, decoded.components.size)
        val source = decoded.components.single { it.type == "keyvalue" }.attributes.getValue("items").jsonArray.single().jsonObject
        assertEquals(fixture.getValue("source_text"), source.getValue("value"))
        val page = "🙂".repeat(4096)
        assertEquals(16_384, page.toByteArray(Charsets.UTF_8).size)
        val full =
            JsonObject(
                frame + (
                    "components" to
                        JsonArray(
                            listOf(
                                JsonObject(
                                    mapOf(
                                        "type" to JsonPrimitive("keyvalue"),
                                        "items" to
                                            JsonArray(
                                                listOf(
                                                    JsonObject(
                                                        mapOf(
                                                            "key" to JsonPrimitive("Permitted text"), "value" to JsonPrimitive(page),
                                                        ),
                                                    ),
                                                ),
                                            ),
                                    ),
                                ),
                            ),
                        )
                ),
            )
        val decodedPage = assertIs<Inbound.ChromeSurface>(Wire.decode(full)).components.single()
        assertEquals(page, decodedPage.attributes.getValue("items").jsonArray.single().jsonObject.getValue("value").jsonPrimitive.content)
    }

    @Test
    fun evidence_whole_frame_rejects_missing_generation_and_malformed_metadata() {
        val frame = evidenceFixture().getValue("native_frame").jsonObject
        val changes =
            listOf(
                "request_generation" to JsonPrimitive("bad"), "request_generation" to JsonPrimitive(7),
                "request_generation" to JsonPrimitive("F384F57F-2362-4545-92E8-61B1CE0C112E"),
                "region" to JsonPrimitive("canvas"), "mode" to JsonPrimitive("mandatory"),
                "admin_only" to JsonPrimitive(true), "title" to JsonPrimitive(7),
                "extra" to JsonPrimitive("untrusted"), "components" to JsonObject(emptyMap()),
                "components" to JsonArray(listOf(JsonPrimitive("untrusted"))),
            )
        assertIs<Inbound.Unknown>(Wire.decode(JsonObject(frame - "request_generation")))
        for ((key, value) in changes) {
            assertIs<Inbound.Unknown>(Wire.decode(JsonObject(frame + (key to value))), key)
        }
    }

    @Test
    fun classification_covers_manifest_exactly() {
        val push = manifestPushTypes()
        val classified = ProtocolManifest.classification.keys
        val missing = (push - classified).sorted()
        val stale = (classified - push).sorted()
        assertTrue(missing.isEmpty(), "server frame types the app has not classified: $missing")
        assertTrue(stale.isEmpty(), "app classifies frame types the server no longer sends: $stale")
    }

    @Test
    fun classification_values_are_valid() {
        val allowed = setOf(ProtocolManifest.HANDLED, ProtocolManifest.IGNORED)
        assertTrue(ProtocolManifest.classification.values.all { it in allowed })
    }

    @Test
    fun persistent_assignment_actions_use_existing_generic_surface() {
        val expected =
            setOf(
                "chrome_assignment_create",
                "chrome_assignment_revise",
                "chrome_assignment_pause",
                "chrome_assignment_resume",
                "chrome_assignment_stop",
                "chrome_assignment_revoke",
                "chrome_assignment_run_now",
                "chrome_assignment_approval_decide",
            )
        val actual =
            manifestRoot().getValue("accept_actions").jsonArray
                .map { it.jsonPrimitive.content }
                .filter { it.startsWith("chrome_assignment_") }
                .toSet()
        assertEquals(expected, actual)
        listOf("chrome_surface", "ui_render", "notification").forEach { frame ->
            assertTrue(ProtocolManifest.isHandled(frame))
        }
    }

    @Test
    fun feature_088_guidance_actions_are_closed_and_contracted_without_new_frames() {
        val root = manifestRoot()
        val actions = root.getValue("accept_actions").jsonArray.map { it.jsonPrimitive.content }
        assertEquals(141, actions.size, "Closed accepted-action inventory including native prompt loading")
        assertEquals(actions.size, actions.toSet().size)
        assertTrue(actions.containsAll(listOf("chrome_declarative_view", "chrome_declarative_command", "chrome_turn_selection_set")))
        val contracts = root.getValue("presentation_contracts").jsonObject
        val guidance = listOf("guidance_notes_088", "guidance_skills_088", "guidance_agents_088", "guidance_selection_088")
        assertEquals(
            listOf("guidance_notes_v1", "guidance_skills_v1", "guidance_agents_v1", "guidance_selection_v1"),
            guidance.map { contracts.getValue(it).jsonObject.getValue("client_capability").jsonPrimitive.content },
        )
        guidance.forEach { name ->
            val contract = contracts.getValue(name).jsonObject
            assertEquals("guidance", contract.getValue("surface_key").jsonPrimitive.content)
            assertEquals("chrome_surface", contract.getValue("native_response").jsonObject.getValue("type").jsonPrimitive.content)
        }
        assertTrue(manifestPushTypes().none { it.startsWith("guidance") || it.startsWith("declarative") })
    }

    @Test
    fun feature_088_save_recurring_and_saved_results_are_closed_and_contracted_without_new_frames() {
        val root = manifestRoot()
        val actions = root.getValue("accept_actions").jsonArray.map { it.jsonPrimitive.content }
        assertEquals(141, actions.size, "Closed accepted-action inventory including native prompt loading")
        assertEquals(actions.size, actions.toSet().size)
        assertTrue(actions.containsAll(listOf("chrome_work_result_save", "chrome_job_stop")))
        val contracts = root.getValue("presentation_contracts").jsonObject
        val names = listOf("work_save_088", "recurring_work_088", "saved_results_088")
        assertEquals(
            listOf("work_save_v1", "recurring_work_v1", "saved_results_v1"),
            names.map { contracts.getValue(it).jsonObject.getValue("client_capability").jsonPrimitive.content },
        )
        assertEquals(
            listOf("work", "personalization", "saved_results"),
            names.map { contracts.getValue(it).jsonObject.getValue("surface_key").jsonPrimitive.content },
        )
        names.forEach { name ->
            val contract = contracts.getValue(name).jsonObject
            assertEquals("chrome_surface", contract.getValue("native_response").jsonObject.getValue("type").jsonPrimitive.content)
        }
        val commands = contracts.getValue("work_save_088").jsonObject.getValue("commands").jsonObject
        assertEquals(setOf("propose", "save"), commands.keys)
        assertTrue(manifestPushTypes().none { it.startsWith("work_save") || it.startsWith("recurring_work") || it.startsWith("saved_result") })
    }

    @Test
    fun core_loop_frames_are_handled() {
        listOf(
            "ui_render", "ui_upsert", "chat_status", "error", "auth_required",
            "chrome_menu", "chrome_surface", "user_message_acked", "chat_step",
            "tool_progress", "task_started", "task_completed", "notification",
            "user_preferences", "workspace_timeline_mode", "conversation_snapshot",
            "operation_status", "agent_lifecycle",
        ).forEach { frame ->
            assertTrue(ProtocolManifest.isHandled(frame), "$frame must be handled per the parity matrix")
        }
    }

    @Test
    fun conversational_voice_frames_are_required_and_handled() {
        listOf(
            "composer_state",
            "voice_control_binding",
            "voice_session_state",
            "voice_turn_state",
            "voice_submission_rejected",
            "voice_transcript",
            "voice_announcement_media",
            "voice_local_announcement",
            "voice_local_final_rejected",
            "voice_local_session_ready",
            "voice_local_turn_bound",
        ).forEach { frame ->
            assertEquals(
                ProtocolManifest.HANDLED,
                ProtocolManifest.classification[frame],
                "$frame is required by feature 065 and may not drift to ignored",
            )
        }
    }

    @Test
    fun client_local_voice_contract_is_pinned_to_closed_v2_dispositions() {
        val contract = manifestRoot().getValue("frame_contracts").jsonObject.getValue("voice_075").jsonObject
        assertEquals("2", contract.getValue("schema_version").jsonPrimitive.content)
        assertEquals("client_local/v1", contract.getValue("local_frame_contract").jsonPrimitive.content)
        assertEquals(
            listOf("ready", "typed_fallback", "rejected", "permission_denied", "final", "speaking", "finished"),
            contract.getValue("required_dispositions").jsonArray.map { it.jsonPrimitive.content },
        )
    }

    @Test
    fun author_only_client_explicitly_ignores_host_control_frames() {
        listOf(
            "agent_host_inventory_reconciled",
            "agent_host_registered",
            "agent_host_registration_refused",
        ).forEach { frame ->
            assertEquals(
                ProtocolManifest.IGNORED,
                ProtocolManifest.classification[frame],
                "Android is author-only and must explicitly ignore $frame",
            )
        }
    }

    @Test
    fun manifest_declares_structured_host_registration() {
        val registrations =
            manifestRoot().getValue("additive_fields").jsonArray.filter { entry ->
                val value = entry.jsonObject
                value["field"]?.jsonPrimitive?.content == "agent_host" &&
                    value["carried_on"]?.jsonArray?.map { it.jsonPrimitive.content } == listOf("register_ui")
            }
        assertEquals(1, registrations.size)
        assertEquals(
            setOf(
                "host_id",
                "supported_runtime_contract_versions",
                "runtime_lock_sha256",
                "platform",
                "client_version",
            ),
            registrations.single().jsonObject.getValue("shape").jsonObject.keys,
        )
    }

    @Test
    fun manifest_declares_exact_admission_refusal_contract() {
        val contract =
            manifestRoot()
                .getValue("frame_contracts")
                .jsonObject
                .getValue("admission_refusal")
                .jsonObject

        assertEquals("error", contract.getValue("type").jsonPrimitive.content)
        assertEquals(
            listOf(
                "type",
                "submission_id",
                "accepted",
                "code",
                "message",
                "retryable",
                "retry_after_ms",
            ),
            contract.getValue("exact_fields").jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals(
            "canonical_lowercase_uuid4",
            contract.getValue("submission_id").jsonPrimitive.content,
        )
        assertEquals(false, contract.getValue("accepted").jsonPrimitive.boolean)
        assertEquals(false, contract.getValue("additional_fields").jsonPrimitive.boolean)
        assertEquals(
            admissionRefusalCodes,
            contract.getValue("codes").jsonArray.map { it.jsonPrimitive.content },
        )
    }
}
