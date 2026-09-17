package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.ConversationGenerationBinding
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.Wire
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class WorkSurface088Test {
    @Test fun missing_work_identity_cannot_render_or_pin() {
        val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))
        val before = UiState(screen = Screen.Surface, pendingSurfaceKey = "work")
        for (mode in listOf("replace", "mandatory")) {
            assertEquals(before, vm.reduce(before, Inbound.ChromeSurface("work", "Private result", emptyList(), mode)))
        }
    }

    @Test fun work_open_while_disconnected_is_not_replayed() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val vm = AppViewModel(client, AstralRest("http://localhost:9"))
        vm.openSurface("work")
        vm.sendEvent("chrome_open", buildJsonObject { put("surface", "work") })
        vm.retryPendingSurface()
        assertTrue(client.pendingActions().isEmpty())
    }

    @Test fun wire_refuses_work_without_canonical_request() {
        for (value in listOf("null", "3", "\"wrong\"")) {
            assertIs<Inbound.Unknown>(Wire.decode("""{"type":"chrome_surface","surface_key":"work","request_generation":$value,"components":[]}"""))
        }
    }

    private val first = "11111111-1111-4111-8111-111111111111"
    private val second = "22222222-2222-4222-8222-222222222222"
    private val connection = "33333333-3333-4333-8333-333333333333"

    @Test fun exact_latest_response_is_consumed_and_stale_or_duplicate_never_banners() {
        val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))
        val state =
            UiState(
                screen = Screen.Surface,
                pendingSurfaceKey = "work",
                connectionGeneration = connection,
                privateSurfaceRequest = PrivateSurfaceRequest(second, connection, "work"),
            )
        val stale = Inbound.ChromeSurface("work", "Private stale content", emptyList(), requestGeneration = first)
        assertEquals(state, vm.reduce(state, stale))
        val current = stale.copy(title = "Selected excerpts", requestGeneration = second)
        val accepted = vm.reduce(state, current)
        assertEquals(current, accepted.pendingSurface)
        assertNull(accepted.privateSurfaceRequest)
        assertNull(accepted.banner)
        assertEquals(accepted, vm.reduce(accepted, current.copy(title = "Duplicate")))
        assertEquals(state, vm.reduce(state, current.copy(mode = "mandatory")))
    }

    @Test fun disconnection_rotation_and_navigation_retire_sensitive_work_content() {
        val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))
        val message = Inbound.ChromeSurface("work", "Private stale content", emptyList(), requestGeneration = first)
        val state =
            UiState(
                screen = Screen.Surface,
                pendingSurfaceKey = "work",
                connectionGeneration = connection,
                pendingSurface = message,
                privateSurfaceRequest = PrivateSurfaceRequest(first, connection, "work"),
            )
        for (status in listOf(ConnectionState.Disconnected, ConnectionState.AuthRequired)) {
            val retired = vm.reduceConnectionState(state, status)
            assertNull(retired.privateSurfaceRequest)
            assertNull(retired.pendingSurface)
            assertTrue(retired.privateSurfaceFailed)
            assertEquals(retired, vm.reduce(retired, message))
        }
        val rotated = vm.bindConversationGeneration(state, ConversationGenerationBinding(second, null, null, null))
        assertNull(rotated.privateSurfaceRequest)
        assertNull(rotated.pendingSurface)
        assertEquals(rotated, vm.reduce(rotated, message))
        assertEquals(state.copy(screen = Screen.Chat), vm.reduce(state.copy(screen = Screen.Chat), message))
    }

    @Test fun selected_work_ignores_uncorrelated_legacy_close_error_and_mandatory_chrome() {
        val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))
        val pending =
            UiState(
                screen = Screen.Surface,
                pendingSurfaceKey = "work",
                connectionGeneration = connection,
                privateSurfaceRequest = PrivateSurfaceRequest(first, connection, "work"),
            )
        val displayed = vm.reduce(pending, Inbound.ChromeSurface("work", "Selected excerpts", emptyList(), requestGeneration = first))
        assertNull(displayed.privateSurfaceRequest)
        for (selected in listOf(pending, displayed, pending.copy(privateSurfaceRequest = null, privateSurfaceFailed = true))) {
            for (notice in listOf(
                Inbound.ChromeSurface("", "", emptyList()),
                Inbound.ChromeSurface("error", "Uncorrelated error", emptyList()),
                Inbound.ChromeSurface("theme", "Uncorrelated mandatory", emptyList(), "mandatory"),
                Inbound.ChromeSurface("theme", "Uncorrelated theme", emptyList()),
            )) {
                assertEquals(selected, vm.reduce(selected, notice))
            }
        }
        val navigated = displayed.copy(pendingSurfaceKey = "theme", pendingSurface = null)
        val theme = Inbound.ChromeSurface("theme", "Theme loaded", emptyList())
        assertEquals(theme, vm.reduce(navigated, theme).pendingSurface)
        assertEquals(Screen.Chat, vm.reduce(navigated, Inbound.ChromeSurface("", "", emptyList())).screen)
    }

    @Test fun valid_wire_keeps_work_echo_and_legacy_registration_is_not_opted_in() {
        val frame = assertIs<Inbound.ChromeSurface>(Wire.decode("""{"type":"chrome_surface","surface_key":"work","request_generation":"$first","components":[]}"""))
        assertEquals(first, frame.requestGeneration)
        assertIs<Inbound.Unknown>(Wire.decode("""{"type":"chrome_surface","surface_key":"theme","request_generation":"$first","components":[]}"""))
        assertFalse(Wire.encodeRegisterUi("synthetic", null, com.personalailabs.astraldeep.core.protocol.DeviceCapabilities(800, 600)).contains("work_read_v1"))
    }

    @Test fun actual_viewmodel_reads_retry_timeout_close_and_owner_replacement_retire() =
        kotlinx.coroutines.test.runTest {
            kotlinx.coroutines.Dispatchers.setMain(kotlinx.coroutines.test.StandardTestDispatcher(testScheduler))
            val client = OrchestratorClient("ws://localhost:9/ws")
            val vm = AppViewModel(client, AstralRest("http://localhost:9"))

            fun token(owner: String): String =
                "header." +
                    java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(
                        """{"iss":"https://example.invalid/realm","sub":"$owner"}""".toByteArray(),
                    ) + ".signature"
            try {
                vm.start(token("owner-a"), com.personalailabs.astraldeep.core.protocol.DeviceCapabilities(800, 600))
                val socket = WorkSocket()
                client.installOpenSocketForTest(socket)
                client.replayPendingForTest(connection, {}, {}, { true })
                vm.openSurface("work", buildJsonObject { put("mode", "list") })
                val firstRequest = vm.state.value.privateSurfaceRequest!!
                vm.sendEvent(
                    "chrome_open",
                    buildJsonObject {
                        put("surface", "work")
                        put("params", buildJsonObject { put("mode", "detail") })
                    },
                )
                val next = vm.state.value.privateSurfaceRequest!!
                assertTrue(firstRequest.requestGeneration != next.requestGeneration)
                assertEquals("detail", (vm.state.value.pendingSurfaceParams["mode"] as kotlinx.serialization.json.JsonPrimitive).content)
                vm.timeoutPrivateSurface(firstRequest.requestGeneration)
                assertEquals(next, vm.state.value.privateSurfaceRequest)
                vm.timeoutPrivateSurface(next.requestGeneration)
                assertNull(vm.state.value.privateSurfaceRequest)
                assertTrue(vm.state.value.privateSurfaceFailed)
                vm.retryPendingSurface()
                assertTrue(vm.state.value.privateSurfaceRequest!!.requestGeneration != next.requestGeneration)
                vm.goTo(Screen.Chat)
                assertNull(vm.state.value.privateSurfaceRequest)
                assertTrue(vm.state.value.pendingSubmissions.isEmpty())
                assertNull(vm.state.value.statusText)
                vm.openSurface("work")
                vm.sendEvent("attach_existing", buildJsonObject { put("attachment_id", "synthetic-upload") })
                assertNull(vm.state.value.privateSurfaceRequest)
                vm.openSurface("work")
                vm.start(token("owner-b"), com.personalailabs.astraldeep.core.protocol.DeviceCapabilities(800, 600))
                assertNull(vm.state.value.privateSurfaceRequest)
                assertNull(vm.state.value.pendingSurface)
                assertTrue(client.pendingActions().isEmpty())
                client.installOpenSocketForTest(socket)
                client.replayPendingForTest(connection, {}, {}, { true })
                socket.accept = false
                vm.openSurface("work")
                assertTrue(vm.state.value.privateSurfaceFailed)
                assertNull(vm.state.value.privateSurfaceRequest)
                vm.openSurface("theme")
                assertFalse(vm.state.value.privateSurfaceFailed)
            } finally {
                vm.clearConversationForSignOut()
                kotlinx.coroutines.Dispatchers.resetMain()
            }
        }

    private class WorkSocket : okhttp3.WebSocket {
        var accept = true

        override fun request(): okhttp3.Request = okhttp3.Request.Builder().url("ws://localhost:9/ws").build()

        override fun queueSize(): Long = 0

        override fun send(text: String): Boolean = accept

        override fun send(bytes: okio.ByteString): Boolean = false

        override fun close(
            code: Int,
            reason: String?,
        ): Boolean = true

        override fun cancel() = Unit
    }
}
