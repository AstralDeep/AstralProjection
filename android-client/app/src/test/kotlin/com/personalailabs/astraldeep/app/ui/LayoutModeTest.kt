package com.personalailabs.astraldeep.app.ui

import androidx.lifecycle.viewModelScope
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LayoutModeTest {
    private val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))

    private fun contract(path: String): JsonObject {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "contracts/$path")
            if (candidate.isFile) return Json.parseToJsonElement(candidate.readText()).jsonObject
            dir = dir.parentFile
        }
        error("Missing shared contract $path")
    }

    private val fixture get() = contract("fixtures/workspace_088/welcome.json")
    private val welcome get() = Component.listFromJson(fixture.getValue("components").jsonArray)

    @Test
    fun layout_boundaries_match_shared_web_contract() {
        val layout =
            contract("ui_protocol.json").getValue("presentation_contracts").jsonObject
                .getValue("workspace_088").jsonObject.getValue("layout").jsonObject
        val stackedBelow = layout.getValue("stacked_below").jsonPrimitive.int
        val splitFrom = layout.getValue("split_from").jsonPrimitive.int
        assertEquals(LayoutMode.Stacked, layoutModeFor(stackedBelow - 1))
        assertEquals(LayoutMode.Collapsed, layoutModeFor(stackedBelow))
        assertEquals(LayoutMode.Collapsed, layoutModeFor(splitFrom - 1))
        assertEquals(LayoutMode.Split, layoutModeFor(splitFrom))
    }

    @Test
    fun actual_server_welcome_uses_shared_slots_with_and_without_ids() {
        val roles = fixture.getValue("expected_roles").jsonArray.map { it.jsonPrimitive.content }
        assertEquals(roles, welcome.map(::welcomePlacementRole))
        assertEquals(roles, welcome.map { welcomePlacementRole(it.copy(id = null)) })
        assertTrue(UiState(canvas = welcome, composerDraft = "unfinished").showsStart)
    }

    @Test
    fun results_and_nested_welcome_hints_cannot_hide_real_canvas_content() {
        for (key in listOf("result", "nested_result")) {
            val result = Component.fromJson(fixture.getValue(key).jsonObject)
            assertNull(welcomePlacementRole(result))
            assertFalse(UiState(canvas = welcome + result).showsStart)
        }
        val unknown = Component("unknown", null, JsonObject(emptyMap()), emptyList())
        assertFalse(UiState(canvas = listOf(unknown)).showsStart)
    }

    @Test
    fun active_work_history_and_conversation_never_use_start_layout() {
        assertFalse(UiState(turnActive = true).showsStart)
        assertFalse(UiState(pendingReplace = true).showsStart)
        assertFalse(UiState(turns = listOf(ChatTurn("user", "hello"))).showsStart)
        assertTrue(UiState(activeChatId = "metadata-only").showsStart)
        assertFalse(UiState(viewingIndex = 0).showsStart)
        assertFalse(UiState(timelineReadOnly = true).showsStart)
        assertFalse(UiState(workspaceStarted = true).showsStart)
    }

    @Test
    fun send_and_connection_failure_preserve_workspace_and_unsent_next_draft() {
        val working = vm.armTurn(UiState(canvas = welcome, composerDraft = "next request"))
        val disconnected = vm.reduceConnectionState(working, ConnectionState.Disconnected)
        assertFalse(disconnected.showsStart)
        assertEquals("next request", disconnected.composerDraft)
        assertTrue(working.canvas.isEmpty())
    }

    @Test
    fun late_welcome_cannot_clobber_existing_result_or_reopen_start_screen() {
        val result = Component.fromJson(fixture.getValue("result").jsonObject)
        val state = UiState(canvas = listOf(result), workspaceStarted = true)
        val actual = vm.reduce(state, Inbound.UiRender(target = "canvas", components = welcome))
        assertEquals(state, actual)
        assertFalse(actual.showsStart)
    }

    @Test
    fun new_chat_metadata_keeps_start_layout_and_accepts_only_welcome_under_generation_fence() {
        val created = vm.reduce(UiState(connectionGeneration = "connected"), Inbound.ChatCreated("new-chat", fromMessage = false))
        assertTrue(created.showsStart)
        val delivered = vm.reduce(created, Inbound.UiRender("canvas", welcome))
        assertEquals(welcome, delivered.canvas)
        assertTrue(delivered.showsStart)
        val foreign = Component.fromJson(fixture.getValue("result").jsonObject)
        assertEquals(delivered, vm.reduce(delivered, Inbound.UiRender("canvas", listOf(foreign))))
    }

    @Test
    fun example_action_uses_typed_send_background_and_attachment_semantics() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val model = AppViewModel(client, AstralRest("http://localhost:9"))
        model.toggleBackgroundNextSend()
        val example = welcome.first { it.type == "grid" }.children.first()
        model.sendEvent("chat_message", example.attributes.getValue("payload").jsonObject)
        assertFalse(model.state.value.backgroundNextSend)
        assertFalse(model.state.value.showSkeleton)
        assertTrue(model.state.value.pendingTurns.single().text.isNotBlank())
        val sent = mutableListOf<String>()
        client.replayPendingForTest(
            connectionGeneration = "22222222-2222-4222-8222-222222222222",
            onGeneration = {},
            onQueuedSubmission = {},
            send = sent::add,
        )
        assertEquals(
            "true",
            Json.parseToJsonElement(sent.single()).jsonObject
                .getValue("payload").jsonObject.getValue("async_mode").jsonPrimitive.content,
        )
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun production_signout_erases_private_state_and_queued_frames_before_credentials_then_same_owner_login_is_fresh() {
        Dispatchers.setMain(StandardTestDispatcher())
        val client = OrchestratorClient("ws://localhost:9/ws")
        val model = AppViewModel(client, AstralRest("http://localhost:9"))
        val body = """{"iss":"https://iam.example/realms/Astral","sub":"same-owner"}"""
        val token = "header.${Base64.getUrlEncoder().withoutPadding().encodeToString(body.toByteArray())}.signature"
        try {
            model.start(token, DeviceCapabilities(400, 800))
            model.sendChat("private queued request")
            model.updateComposerDraft("owner private draft")
            model.toggleBackgroundNextSend()
            assertTrue(model.state.value.pendingTurns.isNotEmpty())
            var credentialsRemoved = false
            assertTrue(
                model.signOut {
                    assertEquals(UiState(), model.state.value)
                    val sent = mutableListOf<String>()
                    client.replayPendingForTest(
                        connectionGeneration = "22222222-2222-4222-8222-222222222222",
                        onGeneration = {},
                        onQueuedSubmission = {},
                        send = sent::add,
                    )
                    assertTrue(sent.isEmpty())
                    credentialsRemoved = true
                },
            )
            assertTrue(credentialsRemoved)
            model.start(token, DeviceCapabilities(400, 800))
            assertEquals(UiState(), model.state.value)
        } finally {
            model.viewModelScope.cancel()
            Dispatchers.resetMain()
        }
    }

    @Test
    fun background_arms_exactly_one_ordinary_send_and_disarms_afterward() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val model = AppViewModel(client, AstralRest("http://localhost:9"))
        model.updateComposerDraft("first")
        model.toggleBackgroundNextSend()
        model.sendChat("first")
        assertEquals("", model.state.value.composerDraft)
        assertFalse(model.state.value.backgroundNextSend)
        assertFalse(model.state.value.showSkeleton)
        assertFalse(vm.reduce(model.state.value, Inbound.UserMessageAcked(null, "m")).showSkeleton)
        model.sendChat("second")
        val sent = mutableListOf<String>()
        client.replayPendingForTest(
            connectionGeneration = "22222222-2222-4222-8222-222222222222",
            onGeneration = {},
            onQueuedSubmission = {},
            send = sent::add,
        )
        val payloads = sent.map { Json.parseToJsonElement(it).jsonObject.getValue("payload").jsonObject }
        assertEquals("true", payloads[0].getValue("async_mode").jsonPrimitive.content)
        assertTrue("async_mode" !in payloads[1])
    }

    @Test
    fun empty_send_preserves_draft_and_background_selection() {
        vm.updateComposerDraft("draft")
        vm.toggleBackgroundNextSend()
        vm.sendChat("")
        assertEquals("draft", vm.state.value.composerDraft)
        assertTrue(vm.state.value.backgroundNextSend)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun same_owner_reconnect_retains_draft_and_verified_owner_switch_erases_it() {
        Dispatchers.setMain(StandardTestDispatcher())

        fun token(subject: String): String {
            val body = """{"iss":"https://iam.example/realms/Astral","sub":"$subject"}"""
            return "header.${Base64.getUrlEncoder().withoutPadding().encodeToString(body.toByteArray())}.signature"
        }
        try {
            vm.start(token("first-owner"), DeviceCapabilities(400, 800))
            vm.updateComposerDraft("private draft")
            vm.toggleBackgroundNextSend()
            vm.start(token("first-owner"), DeviceCapabilities(800, 400))
            assertEquals("private draft", vm.state.value.composerDraft)
            assertTrue(vm.state.value.backgroundNextSend)
            vm.start(token("second-owner"), DeviceCapabilities(400, 800))
            assertEquals("", vm.state.value.composerDraft)
            assertFalse(vm.state.value.backgroundNextSend)
        } finally {
            vm.viewModelScope.cancel()
            Dispatchers.resetMain()
        }
    }
}
