// Exercises negotiated viewport hydration and its stale-scope, busy, and rollback fences.
// Settled content and local drafts must survive layout replacement without admitting late transient frames.

package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.ConversationGenerationBinding
import com.personalailabs.astraldeep.app.transport.ConversationRequestPurpose
import com.personalailabs.astraldeep.app.transport.LocalSubmission
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.chrome.ConsoleInsets
import com.personalailabs.astraldeep.core.chrome.ConsolePresentation
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.SnapshotCanvas
import com.personalailabs.astraldeep.core.protocol.TransientFrameScope
import com.personalailabs.astraldeep.core.protocol.Wire
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class ViewportRefreshTest {
    private val vm = AppViewModel(OrchestratorClient("ws://localhost:9/ws"), AstralRest("http://localhost:9"))
    private val device = DeviceCapabilities(1440, 900, viewportWidth = 1440, deviceId = CHAT)
    private val narrow = Component("container", "result", attributes = JsonObject(mapOf("direction" to JsonPrimitive("column"))), children = emptyList())
    private val wide = narrow.copy(attributes = JsonObject(mapOf("direction" to JsonPrimitive("row"))))
    private val settled =
        UiState(
            connection = ConnectionState.Connected,
            activeChatId = CHAT,
            connectionGeneration = CONNECTION,
            lastCommittedRenderRevision = 7UL,
            viewportSnapshotSupported = true,
            canvas = listOf(narrow),
            consoleDashboardVisible = false,
            composerDraft = "Keep my unfinished question",
            staged = listOf(StagedAttachment(1, "sample.csv", "document", "attachment", "ready")),
            consoleFullscreen = true,
            consoleResultCollapsed = true,
        )

    private fun pending(state: UiState = settled): UiState {
        val pending = ViewportRefresh(REQUEST, SNAPSHOT, device, state)
        return vm.bindConversationGeneration(
            state.copy(viewportRefresh = pending),
            ConversationGenerationBinding(CONNECTION, CHAT, REQUEST, ConversationRequestPurpose.HYDRATION),
        )
    }

    private fun snapshot() =
        Inbound.ConversationSnapshot(
            1, SNAPSHOT, CHAT, CONNECTION, REQUEST, "hydration", 7UL, "2026-09-26T00:00:00Z",
            emptyList(), SnapshotCanvas("canvas", listOf(wide)),
        )

    @Test fun negotiatedSameRevisionHydrationReflowsAndRetainsLocalState() {
        val before = pending()
        assertEquals(listOf(narrow), before.canvas)
        val after = vm.reduce(before, snapshot())
        assertEquals(listOf(wide), after.canvas)
        assertEquals(7UL, after.lastCommittedRenderRevision)
        assertEquals(settled.composerDraft, after.composerDraft)
        assertEquals(settled.staged, after.staged)
        assertEquals(settled.consoleFullscreen, after.consoleFullscreen)
        assertEquals(settled.consoleResultCollapsed, after.consoleResultCollapsed)
        assertTrue(after.hydrationApplied)
        assertNull(after.viewportRefresh)
        assertTrue(viewportRefreshReady(after, false, false))
        assertSame(after, vm.reduce(after, snapshot()))
    }

    @Test fun staleForeignAndWrongPurposeSnapshotsNeverReplaceSettledCanvas() {
        val before = pending()
        listOf(
            snapshot().copy(chatId = SNAPSHOT),
            snapshot().copy(connectionGeneration = SNAPSHOT),
            snapshot().copy(requestGeneration = SNAPSHOT),
            snapshot().copy(snapshotPurpose = "commit"),
            snapshot().copy(renderRevision = 6UL),
            snapshot().copy(renderRevision = 8UL),
        ).forEach { assertSame(before, vm.reduce(before, it)) }
    }

    @Test fun busyConversationSurfacesUploadsVoiceAndInteractionDeferRefresh() {
        assertTrue(viewportRefreshReady(settled, false, false))
        listOf(
            settled.copy(viewportSnapshotSupported = false),
            settled.copy(connection = ConnectionState.Disconnected),
            settled.copy(activeChatId = null),
            settled.copy(connectionGeneration = null),
            pending(),
            settled.copy(turnActive = true),
            settled.copy(pendingSubmissions = mapOf(REQUEST to LocalSubmission("chat_message", CHAT, SNAPSHOT, REQUEST))),
            settled.copy(requestPurpose = ConversationRequestPurpose.COMMIT),
            settled.copy(requestPurpose = ConversationRequestPurpose.HYDRATION),
            settled.copy(screen = Screen.Surface, pendingSurfaceKey = "guidance"),
            settled.copy(screen = Screen.Surface, pendingSurfaceKey = "work"),
            settled.copy(timelineReadOnly = true),
            settled.copy(mandatorySurface = true),
            settled.copy(viewingIndex = 0),
            settled.copy(consoleDrawerOpen = true),
            settled.copy(staged = listOf(settled.staged.single().copy(state = "uploading"))),
        ).forEach { assertFalse(viewportRefreshReady(it, false, false), it.toString()) }
        assertFalse(viewportRefreshReady(settled, true, false))
        assertFalse(viewportRefreshReady(settled, false, true))
    }

    @Test fun scopedFailureRestoresOnlyRequestFenceAndKeepsNewDraft() {
        val before = pending().copy(composerDraft = "Edited while awaiting layout")
        val error =
            Inbound.ErrorFrame(
                "viewport_snapshot_retryable",
                "Layout refresh failed",
                CHAT,
                CONNECTION,
                REQUEST,
                true,
            )
        val after = vm.reduceWithPersistence(before, error)
        assertEquals("Edited while awaiting layout", after.composerDraft)
        assertEquals(settled.canvas, after.canvas)
        assertEquals(settled.requestGeneration, after.requestGeneration)
        assertNull(after.viewportRefresh)
        assertTrue(after.viewportRefreshFailed)
        assertTrue(REQUEST in after.usedConversationRequestGenerations)
        assertSame(before, vm.reduceWithPersistence(before, error.copy(requestGeneration = SNAPSHOT)))
        assertSame(before, vm.reduceWithPersistence(before, error.copy(connectionGeneration = SNAPSHOT)))
        assertSame(before, vm.reduceWithPersistence(before, error.copy(chatId = SNAPSHOT)))
    }

    @Test fun timeoutCannotRestoreOverNewerRequestOrRevision() {
        val before = pending()
        val refresh = assertNotNull(before.viewportRefresh)
        listOf(
            before.copy(requestGeneration = SNAPSHOT),
            before.copy(lastCommittedRenderRevision = 8UL),
            before.copy(connectionGeneration = SNAPSHOT),
            before.copy(activeChatId = SNAPSHOT),
            before.copy(hydrationApplied = true),
            before.copy(viewportRefresh = null),
        ).forEach { assertSame(it, restoreViewportRefresh(it, refresh)) }
        val restored = restoreViewportRefresh(before, refresh)
        assertEquals(settled.canvas, restored.canvas)
        assertTrue(restored.viewportRefreshFailed)
    }

    @Test fun disconnectClearsRefreshAndNegotiationWithoutDroppingSettledDraft() {
        val after = vm.reduceConnectionState(pending(), ConnectionState.Disconnected)
        assertNull(after.viewportRefresh)
        assertFalse(after.viewportSnapshotSupported)
        assertEquals(settled.canvas, after.canvas)
        assertEquals(settled.composerDraft, after.composerDraft)
    }

    @Test fun transientFramesAreRejectedDuringAndAfterViewportHydration() {
        val before = pending()
        val frame =
            Inbound.UiRender(
                target = "canvas",
                components = listOf(wide),
                scope = TransientFrameScope(CHAT, CONNECTION, REQUEST, 7UL, 1UL),
            )
        assertSame(before, vm.reduce(before, frame))
        val accepted = vm.reduce(before, snapshot())
        assertSame(accepted, vm.reduce(accepted, frame))
    }

    @Test fun negotiationRequiresLiteralTrue() {
        for (value in listOf("false", "null", "\"true\"", "1")) {
            val msg = Wire.decode("""{"type":"rote_config","viewport_snapshot_supported":$value}""") as Inbound.RoteConfig
            assertFalse(msg.viewportSnapshotSupported)
        }
        val msg = Wire.decode("""{"type":"rote_config","viewport_snapshot_supported":true}""") as Inbound.RoteConfig
        assertTrue(vm.reduce(settled.copy(viewportSnapshotSupported = false), msg).viewportSnapshotSupported)
    }

    @Test fun scopedConfigWaitsForSnapshotAndForeignOrMalformedScopeCannotChangeChrome() {
        val before = pending()
        val insets = ConsoleInsets(8.0, 8.0, 8.0, 8.0)
        val presentation =
            ConsolePresentation(
                "sidebar", 280.0, insets, insets, 3, "dialog", "vertical", 600.0, 800.0, 0.8, 160.0, 480.0, 600.0, 12.0, 44.0,
            )
        val config = Inbound.RoteConfig(presentation, true, CHAT, CONNECTION, REQUEST)
        val held = vm.reduce(before, config)
        assertEquals(before.consolePresentation, held.consolePresentation)
        assertEquals(config, held.pendingViewportConfig)
        assertSame(held, vm.reduce(held, config.copy(requestGeneration = SNAPSHOT)))
        assertSame(held, vm.reduce(held, config.copy(connectionGeneration = SNAPSHOT)))
        assertSame(held, vm.reduce(held, config.copy(chatId = SNAPSHOT)))
        val accepted = vm.reduce(held, snapshot())
        assertEquals(presentation, accepted.consolePresentation)
        assertNull(accepted.pendingViewportConfig)
        assertNull(accepted.viewportRefresh)
        val failed = restoreViewportRefresh(held, assertNotNull(held.viewportRefresh))
        assertNull(failed.pendingViewportConfig)
        for (scope in listOf(
            "\"chat_id\":\"$CHAT\"",
            "\"chat_id\":null,\"connection_generation\":\"$CONNECTION\",\"request_generation\":\"$REQUEST\"",
            "\"chat_id\":\"$CHAT\",\"connection_generation\":\"invalid\",\"request_generation\":\"$REQUEST\"",
        )) {
            assertTrue(Wire.decode("""{"type":"rote_config",$scope}""") is Inbound.Unknown)
        }
    }

    @Test fun ownOperationStatusesDoNotBlockRefreshAndTerminalFailuresRestoreOnlyMatchingScope() {
        val before = pending()
        val status =
            Inbound.OperationStatus(
                SNAPSHOT, "update_device", "chat", CHAT, CONNECTION, REQUEST, 1UL,
                "running", "running", "Refreshing layout", false, false, null, null, "2026-09-26T00:00:00Z",
            )
        for (state in listOf("accepted", "running", "completed")) {
            val result = vm.reduce(before, status.copy(state = state, terminal = state == "completed"))
            assertSame(before, result)
            assertFalse(result.hasActiveWork)
        }
        val failed = status.copy(state = "failed", terminal = true)
        assertTrue(vm.reduce(before, failed).viewportRefreshFailed)
        assertSame(before, vm.reduce(before, failed.copy(requestGeneration = SNAPSHOT)))
        assertSame(before, vm.reduce(before, failed.copy(connectionGeneration = SNAPSHOT)))
        assertSame(before, vm.reduce(before, failed.copy(chatId = SNAPSHOT)))
        val accepted = vm.reduce(before, snapshot())
        assertSame(accepted, vm.reduce(accepted, status))
    }

    @Test fun admissionRefusalRequiresExactCurrentSubmission() {
        val before = pending()
        val refusal = Inbound.AdmissionRefusal(SNAPSHOT, "rate_limit", "Try later", true, null)
        val result = vm.reduce(before, refusal)
        assertTrue(result.viewportRefreshFailed)
        assertNull(result.viewportRefresh)
        assertSame(before, vm.reduce(before, refusal.copy(submissionId = REQUEST)))
        assertSame(result, vm.reduce(result, refusal))
    }

    @Test fun authenticationLossRetiresViewportGenerationBeforeClearingItsMarker() {
        val before = pending()
        val after = vm.reduceConnectionState(before, ConnectionState.AuthRequired)
        assertNull(after.viewportRefresh)
        assertNull(after.pendingViewportConfig)
        assertEquals(settled.requestGeneration, after.requestGeneration)
        assertEquals(settled.requestPurpose, after.requestPurpose)
        assertEquals(settled.composerDraft, after.composerDraft)
        assertTrue(REQUEST in after.usedConversationRequestGenerations)
    }

    companion object {
        private const val CHAT = "00000000-0000-4000-8000-000000000001"
        private const val CONNECTION = "00000000-0000-4000-8000-000000000002"
        private const val REQUEST = "00000000-0000-4000-8000-000000000003"
        private const val SNAPSHOT = "00000000-0000-4000-8000-000000000004"
    }
}
