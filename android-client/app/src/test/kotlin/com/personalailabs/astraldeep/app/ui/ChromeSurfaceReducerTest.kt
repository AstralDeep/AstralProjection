// Tests for AppViewModel's chrome_surface reducer: the blank-key close frame, a mismatched-key error surfaced
// via banner, and a mandatory surface accepted and pinned unsolicited.

package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.ConversationGenerationBinding
import com.personalailabs.astraldeep.app.transport.LocalSubmission
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.OperationStatusError
import com.personalailabs.astraldeep.core.protocol.Wire
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ChromeSurfaceReducerTest {
    private val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))

    private fun evidenceFixture(): JsonObject {
        var directory: File? = File(".").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "contracts/fixtures/evidence/inspection_surface.json")
            if (candidate.isFile) return Json.parseToJsonElement(candidate.readText()).jsonObject
            directory = directory.parentFile
        }
        error("evidence inspection fixture missing")
    }

    private fun pendingEvidence(): Pair<UiState, Inbound.ChromeSurface> {
        val frame = assertIs<Inbound.ChromeSurface>(Wire.decode(evidenceFixture().getValue("native_frame").jsonObject))
        val connection = "22222222-2222-4222-8222-222222222222"
        val start =
            UiState(
                connection = ConnectionState.Connected,
                connectionGeneration = connection,
                activeChatId = "44444444-4444-4444-8444-444444444444",
                screen = Screen.Surface,
                pendingSurfaceKey = "evidence",
                privateSurfaceRequest = PrivateSurfaceRequest(frame.requestGeneration!!, connection, "evidence", conversationId = "44444444-4444-4444-8444-444444444444"),
            )
        return start to frame
    }

    @Test
    fun evidence_current_generation_releases_one_literal_modal_reply() {
        val (start, frame) = pendingEvidence()
        val settled = vm.reduce(start, frame)
        assertEquals(frame, settled.pendingSurface)
        assertNull(settled.privateSurfaceRequest)
        assertEquals(start.canvas, settled.canvas)
        assertEquals(start.turns, settled.turns)
        assertEquals(settled, vm.reduce(settled, frame.copy(title = "Duplicate")))
        val source = frame.components.single { it.type == "keyvalue" }.attributes.getValue("items").jsonArray.single().jsonObject
        assertEquals(evidenceFixture().getValue("source_text"), source.getValue("value"))
    }

    @Test
    fun evidence_stale_uncorrelated_unsolicited_and_close_replies_never_release_text() {
        val (start, frame) = pendingEvidence()
        for (invalid in listOf(
            frame.copy(requestGeneration = null),
            frame.copy(requestGeneration = "33333333-3333-4333-8333-333333333333"),
            frame.copy(requestGeneration = "bad"),
            frame.copy(mode = "mandatory"),
            frame.copy(surfaceKey = "other"),
            surface(""),
            surface("llm", "Uncorrelated", mode = "mandatory"),
        )) assertEquals(start, vm.reduce(start, invalid))
        val unsolicited = UiState(connection = ConnectionState.Connected)
        assertEquals(unsolicited, vm.reduce(unsolicited, frame))
        assertEquals(unsolicited, vm.reduce(unsolicited, frame.copy(requestGeneration = null)))
        for (changed in listOf(start.copy(activeChatId = null), start.copy(connectionGeneration = "33333333-3333-4333-8333-333333333333"))) {
            assertEquals(changed, vm.reduce(changed, frame))
        }
        val closed = vm.reduce(start, frame.copy(surfaceKey = "", title = "", components = emptyList()))
        assertNull(closed.privateSurfaceRequest)
        assertNull(closed.pendingSurface)
        assertEquals(Screen.Chat, closed.screen)
        assertNull(vm.reduce(closed, frame).pendingSurface)
        val rawClose =
            JsonObject(
                evidenceFixture().getValue("native_frame").jsonObject +
                    mapOf(
                        "surface_key" to JsonPrimitive(""), "title" to JsonPrimitive(""), "components" to JsonArray(emptyList()),
                    ),
            )
        val malformed = assertIs<Inbound.ChromeSurface>(Wire.decode(JsonObject(rawClose - "region")))
        assertEquals(start, vm.reduce(start, malformed))
        assertFalse(malformed.evidenceEnvelopeValid)
        val wireClose = assertIs<Inbound.ChromeSurface>(Wire.decode(rawClose))
        assertTrue(wireClose.evidenceEnvelopeValid)
        assertEquals(Screen.Chat, vm.reduce(start, wireClose).screen)
    }

    @Test
    fun evidence_disconnect_and_conversation_send_erase_temporary_text() {
        val (start, frame) = pendingEvidence()
        for (state in listOf(start, vm.reduce(start, frame))) {
            for (connection in listOf(ConnectionState.Disconnected, ConnectionState.AuthRequired)) {
                val retired = vm.reduceConnectionState(state, connection)
                assertNull(retired.pendingSurface)
                assertNull(retired.privateSurfaceRequest)
                assertNull(vm.reduce(retired, frame).pendingSurface)
            }
            val sent = vm.armTurn(state)
            assertNull(sent.pendingSurface)
            assertNull(sent.privateSurfaceRequest)
            assertNull(vm.reduce(sent, frame).pendingSurface)
            for (binding in listOf(
                ConversationGenerationBinding("33333333-3333-4333-8333-333333333333", state.activeChatId, null, null),
                ConversationGenerationBinding(state.connectionGeneration!!, "55555555-5555-4555-8555-555555555555", null, null),
            )) {
                val bound = vm.bindConversationGeneration(state, binding)
                assertNull(bound.pendingSurface)
                assertNull(bound.privateSurfaceRequest)
                assertNull(vm.reduce(bound, frame).pendingSurface)
            }
        }
    }

    @Test
    fun evidence_actual_navigation_retry_timeout_owner_and_failed_send_retire_without_queue() =
        kotlinx.coroutines.test.runTest {
            kotlinx.coroutines.Dispatchers.setMain(kotlinx.coroutines.test.StandardTestDispatcher(testScheduler))
            val client = OrchestratorClient("ws://localhost:9/ws")
            val model = AppViewModel(client, AstralRest("http://localhost:9"))
            val connection = "22222222-2222-4222-8222-222222222222"
            val socket = EvidenceSocket()

            fun token(owner: String): String =
                "header." +
                    java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(
                        """{"iss":"https://example.invalid/realm","sub":"$owner"}""".toByteArray(),
                    ) + ".signature"
            try {
                model.start(token("owner-a"), com.personalailabs.astraldeep.core.protocol.DeviceCapabilities(800, 600))
                client.installOpenSocketForTest(socket)
                client.replayPendingForTest(connection, {}, {}, { true })
                val payload = evidenceFixture().getValue("request").jsonObject.getValue("payload").jsonObject
                model.sendEvent("chrome_open", payload)
                val first = model.state.value.privateSurfaceRequest!!
                model.retryPendingSurface()
                val retry = model.state.value.privateSurfaceRequest!!
                assertFalse(first.requestGeneration == retry.requestGeneration)
                model.timeoutPrivateSurface(first.requestGeneration)
                assertEquals(retry, model.state.value.privateSurfaceRequest)
                model.timeoutPrivateSurface(retry.requestGeneration)
                assertNull(model.state.value.privateSurfaceRequest)
                assertNull(model.state.value.pendingSurface)
                assertTrue(model.state.value.privateSurfaceFailed)
                model.retryPendingSurface()
                val current = model.state.value.privateSurfaceRequest!!
                assertFalse(current.requestGeneration == retry.requestGeneration)
                for (raw in socket.frames) {
                    val frame = Json.parseToJsonElement(raw).jsonObject
                    assertEquals("null", frame.getValue("session_id").toString())
                    assertEquals(setOf("surface", "params", "submission_id", "request_generation"), frame.getValue("payload").jsonObject.keys)
                }
                val sent = socket.frames.size
                model.sendEvent("chrome_close", buildJsonObject { put("surface", "evidence") })
                assertEquals(sent, socket.frames.size)
                assertNull(model.state.value.privateSurfaceRequest)
                assertEquals(Screen.Chat, model.state.value.screen)
                model.openSurface("evidence", payload.getValue("params").jsonObject)
                model.newChat()
                assertNull(model.state.value.privateSurfaceRequest)
                model.openSurface("evidence")
                model.goTo(Screen.Chat)
                assertNull(model.state.value.privateSurfaceRequest)
                model.openSurface("evidence")
                model.start(token("owner-b"), com.personalailabs.astraldeep.core.protocol.DeviceCapabilities(800, 600))
                assertNull(model.state.value.privateSurfaceRequest)
                assertNull(model.state.value.pendingSurface)
                assertTrue(client.pendingActions().isEmpty())
                client.installOpenSocketForTest(socket)
                client.replayPendingForTest(connection, {}, {}, { true })
                socket.accept = false
                model.openSurface("evidence")
                assertNull(model.state.value.privateSurfaceRequest)
                assertTrue(model.state.value.privateSurfaceFailed)
                assertNull(model.state.value.pendingSurface)
            } finally {
                model.clearConversationForSignOut()
                kotlinx.coroutines.Dispatchers.resetMain()
            }
        }

    private class EvidenceSocket : okhttp3.WebSocket {
        val frames = mutableListOf<String>()
        var accept = true

        override fun request(): okhttp3.Request = okhttp3.Request.Builder().url("ws://localhost:9/ws").build()

        override fun queueSize(): Long = 0

        override fun send(text: String): Boolean {
            if (accept) frames.add(text)
            return accept
        }

        override fun send(bytes: okio.ByteString): Boolean = false

        override fun close(
            code: Int,
            reason: String?,
        ): Boolean = true

        override fun cancel() = Unit
    }

    @Test
    fun audit_and_agents_open_shared_server_surface_with_filters_and_preserve_draft() {
        val params = buildJsonObject { put("q", "deny") }
        vm.updateComposerDraft("keep drafting")
        for (surfaceKey in listOf("audit", "agents")) {
            vm.openSurface(surfaceKey, params)
            assertEquals(Screen.Surface, vm.state.value.screen)
            assertEquals(surfaceKey, vm.state.value.pendingSurfaceKey)
            assertEquals(params, vm.state.value.pendingSurfaceParams)
            assertEquals("keep drafting", vm.state.value.composerDraft)
            assertFalse(vm.state.value.auditLoading)
        }
    }

    @Test
    fun nested_surface_buttons_set_the_requested_owner_and_parameters() {
        val params = buildJsonObject { put("view", "drafts") }
        vm.sendEvent(
            "chrome_open",
            buildJsonObject {
                put("surface", "author")
                put("params", params)
            },
        )
        assertEquals(Screen.Surface, vm.state.value.screen)
        assertEquals("author", vm.state.value.pendingSurfaceKey)
        assertEquals(params, vm.state.value.pendingSurfaceParams)
    }

    private fun alert(message: String): Component =
        Component(
            type = "alert",
            id = null,
            attributes = buildJsonObject { put("message", message) },
            children = emptyList(),
        )

    private fun surface(
        key: String,
        title: String = "",
        components: List<Component> = emptyList(),
        mode: String = "replace",
    ) = Inbound.ChromeSurface(surfaceKey = key, title = title, components = components, mode = mode)

    private val onSurface =
        UiState(
            screen = Screen.Surface,
            pendingSurfaceKey = "theme",
            pendingSurface = Inbound.ChromeSurface("theme", "Theme", emptyList()),
        )

    @Test
    fun matching_surface_is_delivered() {
        val delivered = surface("theme", "Theme", listOf(alert("hi")))
        val s = vm.reduce(pendingSettings().copy(pendingSurface = null), delivered)
        assertEquals(delivered, s.pendingSurface)
        assertEquals(Screen.Surface, s.screen)
    }

    @Test
    fun ordinary_result_matches_its_request_and_retires_pending_state() {
        val generation = "11111111-1111-4111-8111-111111111111"
        val connection = "22222222-2222-4222-8222-222222222222"
        val request = PrivateSurfaceRequest(generation, connection, "theme", "save_theme")
        val start = onSurface.copy(connectionGeneration = connection, privateSurfaceRequest = request)
        val delivered = surface("theme", "Theme", listOf(alert("Saved"))).copy(requestGeneration = generation)
        val settled = vm.reduce(start, delivered)
        assertEquals(delivered, settled.pendingSurface)
        assertNull(settled.privateSurfaceRequest)
    }

    @Test
    fun a_legacy_result_retires_the_single_current_ordinary_request() {
        val generation = "11111111-1111-4111-8111-111111111111"
        val connection = "22222222-2222-4222-8222-222222222222"
        val request = PrivateSurfaceRequest(generation, connection, "theme", "save_theme")
        val start = onSurface.copy(connectionGeneration = connection, privateSurfaceRequest = request)
        val delivered = surface("theme", "Theme", listOf(alert("Saved")))
        val settled = vm.reduce(start, delivered)
        assertEquals(delivered, settled.pendingSurface)
        assertNull(settled.privateSurfaceRequest)
    }

    @Test
    fun unrelated_or_stale_result_keeps_the_current_request() {
        val generation = "11111111-1111-4111-8111-111111111111"
        val connection = "22222222-2222-4222-8222-222222222222"
        val request = PrivateSurfaceRequest(generation, connection, "theme", "save_theme")
        val start = onSurface.copy(connectionGeneration = connection, privateSurfaceRequest = request)
        val stale = surface("theme").copy(requestGeneration = "33333333-3333-4333-8333-333333333333")
        assertEquals(start, vm.reduce(start, stale))
        assertEquals(start, vm.reduce(start, surface("llm").copy(requestGeneration = generation)))
    }

    private fun pendingSettings(
        key: String = "theme",
        action: String = "save_theme",
    ): UiState =
        onSurface.copy(
            connection = ConnectionState.Connected,
            connectionGeneration = "22222222-2222-4222-8222-222222222222",
            pendingSurfaceKey = key,
            privateSurfaceRequest =
                PrivateSurfaceRequest(
                    "11111111-1111-4111-8111-111111111111",
                    "22222222-2222-4222-8222-222222222222",
                    key,
                    action,
                ),
        )

    @Test
    fun matching_error_keeps_edited_form_and_exposes_retryable_failure() {
        val start = pendingSettings()
        val failed =
            vm.reduce(
                start,
                surface("error", "Cannot save", listOf(alert("Try again")))
                    .copy(requestGeneration = start.privateSurfaceRequest!!.requestGeneration),
            )
        assertEquals(start.pendingSurface, failed.pendingSurface)
        assertEquals("Cannot save: Try again", failed.surfaceErrorMessage)
        assertNull(failed.privateSurfaceRequest)
        assertFalse(failed.surfaceReloadRequired)
    }

    @Test
    fun owned_alert_failure_keeps_loaded_controls_and_draft_values() {
        val start = pendingSettings()
        val failure =
            Component(
                "alert",
                null,
                buildJsonObject {
                    put("variant", "error")
                    put("message", "The action failed. Please retry.")
                },
                emptyList(),
            )
        val settled =
            vm.reduce(
                start,
                surface("theme", components = listOf(failure))
                    .copy(requestGeneration = start.privateSurfaceRequest!!.requestGeneration),
            )
        assertEquals(start.pendingSurface, settled.pendingSurface)
        assertNull(settled.privateSurfaceRequest)
        assertEquals("The action failed. Please retry.", settled.surfaceErrorMessage)
    }

    @Test
    fun disconnect_requires_reload_before_repeating_an_unconfirmed_mutation() {
        val start = pendingSettings()
        val interrupted = vm.reduceConnectionState(start, ConnectionState.Disconnected)
        assertNull(interrupted.privateSurfaceRequest)
        assertEquals(start.pendingSurface, interrupted.pendingSurface)
        assertTrue(interrupted.surfaceReloadRequired)
        assertTrue(interrupted.surfaceErrorMessage!!.contains("Reload"))
        assertTrue(vm.reduceConnectionState(interrupted, ConnectionState.Connected).surfaceReloadRequired)
        assertEquals(interrupted, vm.reduce(interrupted, surface("theme", "Late legacy response")))
    }

    @Test
    fun blank_close_completes_current_provider_save_but_rejects_stale_close() {
        val start = pendingSettings("llm", "chrome_llm_save").copy(mandatorySurface = true)
        val stale = surface("").copy(requestGeneration = "33333333-3333-4333-8333-333333333333")
        assertEquals(start, vm.reduce(start, stale))
        val closed = vm.reduce(start, surface(""))
        assertEquals(Screen.Chat, closed.screen)
        assertNull(closed.privateSurfaceRequest)
        assertFalse(closed.mandatorySurface)
    }

    @Test
    fun mandatory_provider_setup_can_replace_an_ordinary_pending_surface() {
        val start = pendingSettings()
        val gate = surface("llm", "Set up your AI provider", mode = "mandatory")
        val pinned = vm.reduce(start, gate)
        assertEquals(gate, pinned.pendingSurface)
        assertTrue(pinned.mandatorySurface)
        assertNull(pinned.privateSurfaceRequest)
    }

    @Test
    fun accepted_theme_updates_before_lazy_controls_are_composed() {
        val start = pendingSettings()
        val component =
            Component(
                "theme_apply",
                null,
                buildJsonObject {
                    putJsonObject("colors") { put("accent", "#123456") }
                },
                emptyList(),
            )
        val result =
            surface("theme", components = listOf(component))
                .copy(requestGeneration = start.privateSurfaceRequest!!.requestGeneration)
        assertEquals("#123456", vm.reduce(start, result).themePalette?.accent)
        assertEquals(start.themePalette, vm.reduce(start, result.copy(requestGeneration = "33333333-3333-4333-8333-333333333333")).themePalette)
    }

    @Test
    fun explicit_service_failure_releases_only_the_matching_request() {
        val initial = pendingSettings("llm", "chrome_llm_save")
        val request = initial.privateSurfaceRequest!!
        val start =
            initial.copy(
                pendingSubmissions =
                    mapOf(
                        request.requestGeneration to
                            LocalSubmission(
                                request.action, null, "33333333-3333-4333-8333-333333333333", request.requestGeneration,
                            ),
                    ),
            )
        val status =
            Inbound.OperationStatus(
                "44444444-4444-4444-8444-444444444444", request.action, "llm_settings", null,
                request.connectionGeneration, request.requestGeneration, 1UL, "failed", "failed", "Provider unavailable", true, false,
                OperationStatusError("provider_unavailable", "Provider unavailable"), null, "2026-07-15T18:41:00Z",
            )
        assertEquals(start, vm.reduce(start, status.copy(requestGeneration = "55555555-5555-4555-8555-555555555555")))
        val failed = vm.reduce(start, status)
        assertNull(failed.privateSurfaceRequest)
        assertEquals(start.pendingSurface, failed.pendingSurface)
        assertEquals("Provider unavailable", failed.surfaceErrorMessage)
        assertFalse(failed.surfaceReloadRequired)
        val completed = vm.reduce(start, status.copy(state = "completed", error = null))
        assertEquals(request, completed.privateSurfaceRequest)
    }

    @Test
    fun close_frame_pops_the_surface_screen() {
        val s = vm.reduce(onSurface, surface(key = ""))
        assertEquals(Screen.Chat, s.screen)
        assertNull(s.pendingSurface)
        assertEquals("", s.pendingSurfaceKey)
        assertEquals(JsonObject(emptyMap()), s.pendingSurfaceParams)
    }

    @Test
    fun close_frame_off_the_surface_screen_is_a_noop() {
        val start = UiState(screen = Screen.Chat)
        assertEquals(start, vm.reduce(start, surface(key = "")))
    }

    @Test
    fun error_keyed_frame_on_a_surface_banners_and_keeps_the_surface_content() {
        val s = vm.reduce(onSurface, surface("error", "Not authorized", listOf(alert("Admin role required."))))
        assertEquals("Not authorized: Admin role required.", s.banner)
        assertEquals("error", s.bannerKind)
        assertEquals(Screen.Surface, s.screen)
        assertEquals(onSurface.pendingSurface, s.pendingSurface)
    }

    @Test
    fun mismatched_frame_never_yanks_the_screen_but_is_not_silent() {
        val start = UiState(screen = Screen.Chat)
        val s = vm.reduce(start, surface("error", "Not available", listOf(alert("Unknown action: frob"))))
        assertEquals(Screen.Chat, s.screen)
        assertNull(s.pendingSurface)
        assertEquals("Not available: Unknown action: frob", s.banner)
        assertEquals("error", s.bannerKind)
    }

    @Test
    fun mandatory_surface_is_accepted_unsolicited_and_pins() {
        val start = UiState(screen = Screen.Chat)
        val gate = surface("llm", "Set up your AI provider", listOf(alert("Choose a provider.")), mode = "mandatory")
        val s = vm.reduce(start, gate)
        assertEquals(Screen.Surface, s.screen)
        assertEquals("llm", s.pendingSurfaceKey)
        assertEquals(gate, s.pendingSurface)
        assertTrue(s.mandatorySurface)
        assertNull(s.banner)
    }

    @Test
    fun blank_close_clears_the_mandatory_pin() {
        val gated =
            UiState(
                screen = Screen.Surface,
                pendingSurfaceKey = "llm",
                pendingSurface = surface("llm", "Set up your AI provider", mode = "mandatory"),
                mandatorySurface = true,
            )
        val s = vm.reduce(gated, surface(key = ""))
        assertEquals(Screen.Chat, s.screen)
        assertNull(s.pendingSurface)
        assertFalse(s.mandatorySurface)
    }

    @Test
    fun saved_provider_connection_warning_keeps_the_closed_saved_state() {
        val saved = pendingSettings("llm", "chrome_llm_save").copy(mandatorySurface = true)
        val closed = vm.reduce(saved, surface(""))
        val warning =
            vm.reduce(
                closed,
                Inbound.Notification(
                    title = "Provider settings saved",
                    body = "Connection test failed. Your saved settings remain available.",
                    level = "warning",
                ),
            )
        assertEquals(Screen.Chat, warning.screen)
        assertFalse(warning.mandatorySurface)
        assertNull(warning.privateSurfaceRequest)
        assertEquals("warning", warning.bannerKind)
        assertTrue(warning.banner!!.contains("Provider settings saved"))
    }

    @Test
    fun non_mandatory_unsolicited_surface_still_demotes_to_banner() {
        val start = UiState(screen = Screen.Chat)
        val s = vm.reduce(start, surface("llm", "Set up your AI provider", listOf(alert("Choose a provider."))))
        assertEquals(Screen.Chat, s.screen)
        assertNull(s.pendingSurface)
        assertFalse(s.mandatorySurface)
        assertEquals("Set up your AI provider: Choose a provider.", s.banner)
        assertEquals("error", s.bannerKind)
    }
}
