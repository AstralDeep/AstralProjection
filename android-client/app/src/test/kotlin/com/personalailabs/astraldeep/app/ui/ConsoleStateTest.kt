// Verifies console geometry replacement, selection confirmation fences and native welcome filtering.
// These reducers retain conversation content while server-selected presentation changes.

package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.chrome.ChromeMenuModel
import com.personalailabs.astraldeep.core.chrome.ConsolePresentation
import com.personalailabs.astraldeep.core.chrome.TurnSelection
import com.personalailabs.astraldeep.core.protocol.ChatSummary
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.Wire
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
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

class ConsoleStateTest {
    private val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))
    private val connection = "11111111-1111-4111-8111-111111111111"

    private fun fixture(name: String): JsonObject {
        val file =
            generateSequence(File(".").absoluteFile) { it.parentFile }
                .map { File(it, "contracts/fixtures/console/$name.json") }.first { it.isFile }
        return Json.parseToJsonElement(file.readText()).jsonObject
    }

    @Test fun deletingAnotherConversationPreservesTheVisibleWorkspace() {
        val state =
            UiState(
                activeChatId = "current",
                history = listOf(ChatSummary("current", "Current"), ChatSummary("other", "Other")),
                composerDraft = "Keep",
                turnSelection = TurnSelection.EMPTY,
                consoleFullscreen = true,
            )
        val after = vm.reduceWithPersistence(state, Inbound.ChatDeleted("other"))
        assertEquals(state.copy(history = listOf(state.history.first())), after)
        assertEquals(state, vm.reduceWithPersistence(state, Inbound.ChatDeleted("unknown")))
    }

    @Test fun deletingTheVisibleConversationRetiresItsContentAndSelection() {
        val state =
            UiState(
                activeChatId = "current",
                history = listOf(ChatSummary("current", "Current")),
                composerDraft = "Discard",
                turnSelection = TurnSelection.EMPTY,
                consoleFullscreen = true,
                workspaceStarted = true,
                turns = listOf(ChatTurn("user", "Question")),
                consoleDashboardVisible = false,
            )
        val after = vm.reduceWithPersistence(state, Inbound.ChatDeleted("current"))
        assertNull(after.activeChatId)
        assertTrue(after.history.isEmpty())
        assertTrue(after.turns.isEmpty())
        assertTrue(after.composerDraft.isEmpty())
        assertFalse(after.consoleFullscreen)
        assertFalse(after.workspaceStarted)
        assertTrue(after.consoleDashboardVisible)
        assertNull(after.turnSelection)
    }

    @Test
    fun result_title_resolves_only_current_catalog_identifiers() {
        val menu = assertNotNull(ChromeMenuModel.fromJson(fixture("chrome-console")))
        val agent = menu.console!!.catalog.agents.first()
        for (attribute in listOf("source_agent", "_source_agent", "agent_id", "agent")) {
            val component =
                Component(
                    "text",
                    id = null,
                    children = emptyList(),
                    attributes =
                        kotlinx.serialization.json.buildJsonObject {
                            put(attribute, kotlinx.serialization.json.JsonPrimitive(agent.id))
                        },
                )
            assertEquals(agent.name, UiState(chromeMenu = menu, canvas = listOf(component)).consoleResultAgent)
        }
        val unknown =
            Component(
                "text",
                id = null,
                children = emptyList(),
                attributes =
                    kotlinx.serialization.json.buildJsonObject {
                        put("source_agent", kotlinx.serialization.json.JsonPrimitive("not-a-current-agent"))
                    },
            )
        assertEquals(menu.console!!.labels["result_default_agent"], UiState(chromeMenu = menu, canvas = listOf(unknown)).consoleResultAgent)
    }

    @Test
    fun server_geometry_replacement_preserves_draft_canvas_and_selection() {
        var state = UiState(composerDraft = "Keep me", consoleFullscreen = true, turnSelection = TurnSelection.EMPTY)
        fixture("rote-console").getValue("cases").jsonArray.forEach { row ->
            val geometry = assertNotNull(ConsolePresentation.fromJson(row.jsonObject["presentation"]))
            state = vm.reduce(state, Inbound.RoteConfig(geometry))
            assertEquals(geometry, state.consolePresentation)
            assertEquals("Keep me", state.composerDraft)
            assertEquals(TurnSelection.EMPTY, state.turnSelection)
            assertTrue(state.consoleFullscreen)
        }
        assertNull(vm.reduce(state, Inbound.RoteConfig(null)).consolePresentation)
        assertNull(vm.reduceConnectionState(state, ConnectionState.Disconnected).consolePresentation)
        assertNull(vm.reduceConnectionState(state, ConnectionState.AuthRequired).consolePresentation)
    }

    @Test
    fun only_selection_command_confirmation_can_replace_the_current_chat_selection() {
        val frames = fixture("guidance-confirmation").getValue("cases").jsonArray
        val selected = assertIs<Inbound.ChromeSurface>(Wire.decode(frames.first().jsonObject.getValue("frame").jsonObject))
        val selection = assertNotNull(selected.selection)
        val request = PrivateSurfaceRequest(selected.requestGeneration!!, connection, "guidance", "chrome_turn_selection_set")
        val state = UiState(screen = Screen.Surface, connectionGeneration = connection, pendingSurfaceKey = "guidance", privateSurfaceRequest = request)
        val accepted = vm.reduce(state, selected)
        assertEquals(selection, accepted.turnSelection)
        assertEquals(selected, accepted.pendingSurface)
        assertNull(accepted.privateSurfaceRequest)
        assertEquals(state, vm.reduce(state, selected.copy(requestGeneration = "stale")))
        val wrongAction = state.copy(privateSurfaceRequest = request.copy(action = "chrome_open"))
        assertEquals(wrongAction, vm.reduce(wrongAction, selected))
        val wrongConnection = state.copy(connectionGeneration = "other")
        assertEquals(wrongConnection, vm.reduce(wrongConnection, selected))
        val closed = state.copy(screen = Screen.Chat)
        assertEquals(closed, vm.reduce(closed, selected))
        val cleared = assertIs<Inbound.ChromeSurface>(Wire.decode(frames.last().jsonObject.getValue("frame").jsonObject))
        val clearing = state.copy(turnSelection = selection, privateSurfaceRequest = request.copy(requestGeneration = cleared.requestGeneration!!))
        assertNull(vm.reduce(clearing, cleared).turnSelection)
        val noteReply = selected.copy(selection = null)
        assertEquals(selection, vm.reduce(state.copy(turnSelection = selection), noteReply).turnSelection)
    }

    @Test
    fun console_filters_legacy_welcome_before_any_conversation_starts() {
        val welcome = Component.fromJson(Json.parseToJsonElement("""{"type":"card","component_id":"wel_intro","data-welcome":"intro","content":[]}""").jsonObject)
        val result = Component.fromJson(Json.parseToJsonElement("""{"type":"text","component_id":"result","content":"Six rolls"}""").jsonObject)
        val legacy = UiState(canvas = listOf(welcome, result))
        assertEquals(listOf(welcome, result), legacy.workspaceCanvas)
        val menu = assertNotNull(ChromeMenuModel.fromJson(fixture("chrome-console")))
        val console = vm.reduce(legacy, Inbound.ChromeMenu(menu))
        assertEquals(listOf(result), console.workspaceCanvas)
        assertFalse(console.workspaceStarted)
        val active = legacy.copy(workspaceStarted = true)
        assertEquals(listOf(result), active.workspaceCanvas)
    }

    @Test
    fun starting_a_turn_hides_dashboard_without_discarding_selection() {
        val initial = UiState(turnSelection = TurnSelection.EMPTY, consoleDrawerOpen = true)
        val armed = vm.armTurn(initial)
        assertFalse(armed.consoleDashboardVisible)
        assertFalse(armed.consoleDrawerOpen)
        assertEquals(initial.turnSelection, armed.turnSelection)
    }
}
