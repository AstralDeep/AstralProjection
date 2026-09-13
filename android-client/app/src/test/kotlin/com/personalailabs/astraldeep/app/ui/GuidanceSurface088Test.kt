package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.ConversationGenerationBinding
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.Wire
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class GuidanceSurface088Test {
    private val request = "11111111-1111-4111-8111-111111111111"

    @Test fun guidance_wire_requires_exact_uuid_and_replace_mode() {
        for (identity in listOf("null", "3", "\"wrong\"", "\"11111111-1111-5111-8111-111111111111\"")) {
            assertIs<Inbound.Unknown>(Wire.decode("""{"type":"chrome_surface","surface_key":"guidance","request_generation":$identity,"components":[]}"""))
        }
        assertIs<Inbound.Unknown>(Wire.decode("""{"type":"chrome_surface","surface_key":"guidance","components":[]}"""))
        assertIs<Inbound.Unknown>(Wire.decode("""{"type":"chrome_surface","surface_key":"guidance","request_generation":"$request","mode":"mandatory","components":[]}"""))
        val current = assertIs<Inbound.ChromeSurface>(Wire.decode("""{"type":"chrome_surface","surface_key":"guidance","request_generation":"$request","components":[],"region":"modal","mode":"replace","title":"Private notes","admin_only":false}"""))
        assertEquals(request, current.requestGeneration)
    }

    @Test fun private_notes_open_search_and_mutations_are_never_queued() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val vm = AppViewModel(client, AstralRest("http://localhost:9"))
        vm.openSurface("guidance")
        vm.retryPendingSurface()
        for (action in listOf("chrome_note_search", "chrome_note_save", "chrome_note_toggle", "chrome_note_forget")) {
            vm.sendEvent(action, buildJsonObject { put("expected_revision", 7) })
            client.sendEvent(action, null, buildJsonObject { put("expected_revision", 7) })
        }
        assertTrue(client.pendingActions().isEmpty())
        assertTrue(vm.state.value.privateSurfaceFailed)
    }

    @Test fun selected_notes_refuse_uncorrelated_content_close_errors_and_mandatory_frames() {
        val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))
        val pending = UiState(screen = Screen.Surface, pendingSurfaceKey = "guidance")
        val displayed = pending.copy(pendingSurface = Inbound.ChromeSurface("guidance", "Private notes", emptyList(), requestGeneration = request))
        for (state in listOf(pending, displayed)) {
            for (frame in listOf(
                Inbound.ChromeSurface("guidance", "Old private content", emptyList()),
                Inbound.ChromeSurface("", "", emptyList()),
                Inbound.ChromeSurface("error", "Delayed error", emptyList()),
                Inbound.ChromeSurface("theme", "Delayed mandatory", emptyList(), "mandatory"),
            )) {
                assertEquals(state, vm.reduce(state, frame))
            }
        }
    }

    @Test fun only_actual_updated_client_factory_advertises_guidance() {
        val device = DeviceCapabilities(800, 600)
        assertFalse(Wire.encodeRegisterUi("synthetic", null, device).contains("guidance_notes_v1"))
        val client = OrchestratorClient("ws://localhost:9/ws")
        assertTrue(client.createRegistrationAttempt("synthetic", device, null).frame.contains("guidance_notes_v1"))
    }

    @Test fun matching_guidance_consumes_once_and_never_accepts_cross_surface_or_old_connection() =
        withClient { vm, _, _ ->
            vm.openSurface("guidance")
            val initial = vm.state.value.copy(connectionGeneration = vm.state.value.privateSurfaceRequest!!.connectionGeneration)
            val pending = initial.privateSurfaceRequest!!
            assertEquals("guidance", pending.surfaceKey)
            val reply = Inbound.ChromeSurface("guidance", "Private notes", emptyList(), requestGeneration = pending.requestGeneration)
            assertEquals(initial, vm.reduce(initial, reply.copy(surfaceKey = "work")))
            assertEquals(initial, vm.reduce(initial, reply.copy(requestGeneration = request)))
            assertEquals(initial, vm.reduce(initial, reply.copy(mode = "mandatory")))
            assertEquals(initial.copy(connectionGeneration = request), vm.reduce(initial.copy(connectionGeneration = request), reply))
            val accepted = vm.reduce(initial, reply)
            assertEquals(reply, accepted.pendingSurface)
            assertNull(accepted.privateSurfaceRequest)
            assertTrue(accepted.pendingSubmissions.isEmpty())
            assertEquals(accepted, vm.reduce(accepted, reply))
            for (frame in listOf(Inbound.ChromeSurface("", "", emptyList()), Inbound.ChromeSurface("error", "Old", emptyList()), Inbound.ChromeSurface("theme", "Old", emptyList(), "mandatory"))) {
                assertEquals(accepted, vm.reduce(accepted, frame))
            }
            val crossed = initial.copy(pendingSurfaceKey = "work")
            assertEquals(crossed, vm.reduce(crossed, reply))
        }

    @Test fun every_note_command_gets_fresh_identity_and_keeps_original_payload() =
        withClient { vm, client, socket ->
            vm.openSurface("guidance")
            val requests = mutableSetOf(vm.state.value.privateSurfaceRequest!!.requestGeneration)
            val payload =
                buildJsonObject {
                    put("note_id", request)
                    put("expected_revision", 7)
                    put(
                        "fields",
                        buildJsonObject {
                            put("value", "**literal**")
                            put("enabled", false)
                        },
                    )
                }
            for (action in listOf("chrome_note_search", "chrome_note_save", "chrome_note_toggle", "chrome_note_forget")) {
                vm.sendEvent(action, payload)
                val current = vm.state.value.privateSurfaceRequest!!
                assertTrue(requests.add(current.requestGeneration))
                assertEquals("guidance", current.surfaceKey)
                assertEquals(1, vm.state.value.pendingSubmissions.size)
                val frame = Json.parseToJsonElement(socket.frames.last()).jsonObject
                assertEquals(action, frame.getValue("action").jsonPrimitive.content)
                assertEquals(current.requestGeneration, frame.getValue("request_generation").jsonPrimitive.content)
                val nested = frame.getValue("payload").jsonObject
                assertEquals(payload, JsonObject(nested.filterKeys { it !in setOf("submission_id", "request_generation") }))
                assertTrue(frame.getValue("submission_id") != frame.getValue("request_generation"))
            }
            assertTrue(client.pendingActions().isEmpty())
            vm.openSurface("work")
            val count = socket.frames.size
            vm.sendEvent("chrome_note_forget", payload)
            assertEquals(count, socket.frames.size)
            assertEquals("work", vm.state.value.privateSurfaceRequest!!.surfaceKey)
        }

    @Test fun unknown_save_outcome_retry_is_a_new_read_without_retained_note_body() =
        withClient { vm, client, socket ->
            vm.openSurface(
                "guidance",
                buildJsonObject {
                    put("mode", "edit")
                    put("expected_revision", 7)
                    put("note_id", request)
                },
            )
            val old = vm.state.value.privateSurfaceRequest!!
            vm.sendEvent("chrome_note_save", buildJsonObject { put("fields", buildJsonObject { put("value", "Private test note") }) })
            val mutation = vm.state.value.privateSurfaceRequest!!
            vm.timeoutPrivateSurface(old.requestGeneration)
            assertEquals(mutation, vm.state.value.privateSurfaceRequest)
            vm.timeoutPrivateSurface(mutation.requestGeneration)
            assertNull(vm.state.value.privateSurfaceRequest)
            assertTrue(vm.state.value.privateSurfaceFailed)
            assertTrue(vm.state.value.pendingSurfaceParams.isEmpty())
            vm.retryPendingSurface()
            val frame = Json.parseToJsonElement(socket.frames.last()).jsonObject
            assertEquals("chrome_open", frame.getValue("action").jsonPrimitive.content)
            assertFalse(frame.toString().contains("Private test note"))
            assertTrue(vm.state.value.privateSurfaceRequest!!.requestGeneration != mutation.requestGeneration)
            assertTrue(client.pendingActions().isEmpty())
            socket.accept = false
            vm.sendEvent("chrome_note_save", buildJsonObject { put("fields", buildJsonObject { put("value", "Private test note") }) })
            assertTrue(vm.state.value.privateSurfaceFailed)
            assertNull(vm.state.value.privateSurfaceRequest)
            assertTrue(client.pendingActions().isEmpty())
        }

    @Test fun close_navigation_disconnect_and_reregister_clear_private_ownership() =
        withClient { vm, _, socket ->
            vm.openSurface("guidance")
            val state = vm.state.value.copy(connectionGeneration = vm.state.value.privateSurfaceRequest!!.connectionGeneration)
            val reply = Inbound.ChromeSurface("guidance", "Private notes", emptyList(), requestGeneration = state.privateSurfaceRequest!!.requestGeneration)
            val shown = vm.reduce(state, reply)
            for (status in listOf(ConnectionState.Disconnected, ConnectionState.AuthRequired)) {
                val retired = vm.reduceConnectionState(shown, status)
                assertNull(retired.pendingSurface)
                assertNull(retired.privateSurfaceRequest)
                assertEquals(retired, vm.reduce(retired, reply))
            }
            val reregistered = vm.bindConversationGeneration(shown, ConversationGenerationBinding(request, null, null, null))
            assertNull(reregistered.pendingSurface)
            assertEquals(reregistered, vm.reduce(reregistered, reply))
            vm.goTo(Screen.Chat)
            assertNull(vm.state.value.privateSurfaceRequest)
            vm.openSurface("guidance")
            val count = socket.frames.size
            vm.sendEvent("chrome_close")
            assertEquals(Screen.Chat, vm.state.value.screen)
            assertNull(vm.state.value.pendingSurface)
            assertNull(vm.state.value.privateSurfaceRequest)
            assertEquals(count, socket.frames.size)
            vm.openSurface("guidance")
            vm.start(token("other-owner"), DeviceCapabilities(800, 600))
            assertNull(vm.state.value.privateSurfaceRequest)
            assertNull(vm.state.value.pendingSurface)
        }

    private fun token(owner: String): String =
        "header." +
            java.util.Base64.getUrlEncoder().withoutPadding()
                .encodeToString("""{"iss":"https://example.invalid/realm","sub":"$owner"}""".toByteArray()) + ".signature"

    private fun withClient(block: (AppViewModel, OrchestratorClient, Socket) -> Unit) =
        kotlinx.coroutines.test.runTest {
            kotlinx.coroutines.Dispatchers.setMain(kotlinx.coroutines.test.StandardTestDispatcher(testScheduler))
            val client = OrchestratorClient("ws://localhost:9/ws")
            val vm = AppViewModel(client, AstralRest("http://localhost:9"))
            try {
                vm.start(token("owner"), DeviceCapabilities(800, 600))
                val socket = Socket()
                client.installOpenSocketForTest(socket)
                client.replayPendingForTest("33333333-3333-4333-8333-333333333333", {}, {}, { true })
                block(vm, client, socket)
            } finally {
                vm.clearConversationForSignOut()
                kotlinx.coroutines.Dispatchers.resetMain()
            }
        }

    private class Socket : okhttp3.WebSocket {
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
}
