// Tests that attach_existing (the attachments-library Attach button) stages a file as a ready chip locally
// and is never forwarded to the server as a wire event.

package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AttachExistingTest {
    private val client = OrchestratorClient("ws://localhost:9/ws")
    private val vm = AppViewModel(client, AstralRest("http://localhost:9"))

    @Test
    fun attach_existing_stages_a_ready_chip_and_sends_no_frame() {
        vm.sendEvent(
            "attach_existing",
            buildJsonObject {
                put("attachment_id", "att-1")
                put("filename", "report.pdf")
                put("category", "document")
            },
        )
        val staged = vm.state.value.staged
        assertEquals(1, staged.size)
        assertEquals("att-1", staged.first().attachmentId)
        assertEquals("report.pdf", staged.first().filename)
        assertEquals("document", staged.first().category)
        assertEquals("ready", staged.first().state)
        assertTrue(client.pendingActions().isEmpty())
    }

    @Test
    fun a_normal_event_is_still_enqueued() {
        vm.sendEvent("discover_agents")
        assertEquals(listOf("discover_agents"), client.pendingActions())
    }

    @Test
    fun a_duplicate_attach_existing_is_ignored() {
        val payload =
            buildJsonObject {
                put("attachment_id", "att-1")
                put("filename", "a.pdf")
                put("category", "document")
            }
        vm.sendEvent("attach_existing", payload)
        vm.sendEvent("attach_existing", payload)
        assertEquals(1, vm.state.value.staged.size)
    }

    @Test
    fun attach_from_the_library_returns_to_the_chat_with_a_banner() {
        vm.openSurface("attachments")
        assertEquals(Screen.Surface, vm.state.value.screen)
        vm.sendEvent(
            "attach_existing",
            buildJsonObject {
                put("attachment_id", "att-9")
                put("filename", "data.csv")
                put("category", "spreadsheet")
            },
        )
        assertEquals(Screen.Chat, vm.state.value.screen)
        assertEquals(1, vm.state.value.staged.size)
        assertTrue(vm.state.value.banner.orEmpty().contains("data.csv"))
        assertEquals("info", vm.state.value.bannerKind)
    }

    @Test
    fun a_duplicate_attach_still_returns_to_the_chat() {
        val payload =
            buildJsonObject {
                put("attachment_id", "att-1")
                put("filename", "a.pdf")
                put("category", "document")
            }
        vm.sendEvent("attach_existing", payload)
        vm.openSurface("attachments")
        vm.sendEvent("attach_existing", payload)
        assertEquals(1, vm.state.value.staged.size)
        assertEquals(Screen.Chat, vm.state.value.screen)
    }

    @Test
    fun a_malformed_attach_payload_stages_nothing_and_stays_put() {
        vm.openSurface("attachments")
        vm.sendEvent("attach_existing", buildJsonObject { put("filename", "x.pdf") })
        assertEquals(0, vm.state.value.staged.size)
        assertEquals(Screen.Surface, vm.state.value.screen)
    }
}
