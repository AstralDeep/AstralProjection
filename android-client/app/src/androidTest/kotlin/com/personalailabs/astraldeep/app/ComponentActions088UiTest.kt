package com.personalailabs.astraldeep.app

import android.Manifest
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.ui.Screen
import com.personalailabs.astraldeep.app.workspace.ComponentControllerFixture
import com.personalailabs.astraldeep.app.workspace.DOCUMENT_AUTHORITY
import com.personalailabs.astraldeep.app.workspace.WorkspaceControllerFixture
import com.personalailabs.astraldeep.app.workspace.WorkspaceControllerFixture.Companion.await
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ComponentActions088UiTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Before fun provider() {
        InstrumentationRegistry.getInstrumentation().uiAutomation.adoptShellPermissionIdentity(Manifest.permission.MANAGE_DOCUMENTS)
        InstrumentationRegistry.getInstrumentation().targetContext.contentResolver.call(DOCUMENT_AUTHORITY, "test-reset", null, null)
    }

    @After fun cleanup() {
        InstrumentationRegistry.getInstrumentation().targetContext.contentResolver.call(DOCUMENT_AUTHORITY, "test-reset", null, null)
        InstrumentationRegistry.getInstrumentation().uiAutomation.dropShellPermissionIdentity()
    }

    @Test fun share_is_single_attempt_private_until_explicit_copy() =
        ComponentControllerFixture().use {
            with(it) {
                val entered = CountDownLatch(1)
                val release = CountDownLatch(1)
                base.response = { request ->
                    base.normalResponse(request).also {
                        entered.countDown()
                        check(release.await(10, TimeUnit.SECONDS))
                    }
                }
                perform("share")
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                perform("share")
                assertEquals(1, base.requests.size)
                release.countDown()
                await { controller.share.value != null }
                base.awaitCallCompletion("/api/share")
                val link = controller.share.value!!
                assertEquals("unchanged", base.clipboard())
                assertEquals("""{"chat_id":"${WorkspaceControllerFixture.CHAT}","scope":"component","component_id":"wc_a"}""", base.requests.single().body.readUtf8())
                base.scenario.onActivity { controller.copy(link) }
                assertEquals(link.url, base.clipboard())
                base.scenario.onActivity { controller.dismiss(link) }
                assertNull(controller.share.value)
                assertTrue(files().isEmpty())
            }
        }

    @Test fun late_owner_change_and_replaced_component_cannot_deliver_or_retarget_share() =
        ComponentControllerFixture().use {
            with(it) {
                val entered = CountDownLatch(1)
                val release = CountDownLatch(1)
                base.response = { request ->
                    base.normalResponse(request).also {
                        entered.countDown()
                        check(release.await(10, TimeUnit.SECONDS))
                    }
                }
                perform("share")
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                invalidate { base.token = WorkspaceControllerFixture.syntheticToken("other") }
                release.countDown()
                base.awaitCallCompletion("/api/share")
                await { controller.pending.value.isEmpty() }
                assertNull(controller.share.value)
                assertEquals("unchanged", base.clipboard())
                invalidate { base.token = WorkspaceControllerFixture.syntheticToken("owner") }
                base.response = base::normalResponse
                perform("share")
                await { controller.share.value != null }
                val old = controller.share.value!!
                replace(ComponentControllerFixture.component("Changed component"))
                assertNull(controller.share.value)
                base.scenario.onActivity { controller.copy(old) }
                assertEquals("unchanged", base.clipboard())
                perform("share")
                await { controller.share.value != null }
                assertEquals(3, base.requests.size)
            }
        }

    @Test fun share_phi_refusal_and_uncertain_response_never_become_links_or_retry() =
        ComponentControllerFixture().use {
            with(it) {
                base.response = { MockResponse().setResponseCode(403).setBody("""{"error":"phi_blocked","detail":"private"}""") }
                perform("share")
                base.awaitCallCompletion("/api/share")
                await { controller.pending.value.isEmpty() }
                assertNull(controller.share.value)
                base.response = { MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST) }
                perform("share")
                base.awaitCallCompletion("/api/share", 1)
                await { controller.pending.value.isEmpty() }
                assertNull(controller.share.value)
                base.response = base::normalResponse
                perform("share")
                await { controller.share.value != null }
                assertEquals(3, base.requests.size)
                assertEquals("unchanged", base.clipboard())
            }
        }

    @Test fun server_versions_restore_and_refine_use_normal_websocket_dispatch_and_exact_chat() =
        ComponentControllerFixture().use {
            with(it) {
                perform("history", buildJsonObject { put("version_no", 2) })
                await { base.outboundFrames.any { it["action"] == JsonPrimitive("component_restore") } }
                val restore = base.outboundFrames.single { it["action"] == JsonPrimitive("component_restore") }
                val payload = restore.getValue("payload").jsonObject
                assertEquals(JsonPrimitive(2), payload["version_no"])
                assertEquals(JsonPrimitive("wc_a"), payload["component_id"])
                assertEquals(JsonPrimitive(WorkspaceControllerFixture.CHAT), payload["chat_id"])
                perform("refine", buildJsonObject { put("instruction", "  Add a total  ") })
                await { base.outboundFrames.any { it["action"] == JsonPrimitive("component_refine") } }
                assertEquals("Add a total", base.outboundFrames.single { it["action"] == JsonPrimitive("component_refine") }.getValue("payload").jsonObject.getValue("instruction").jsonPrimitive.content)
                val captured = context()
                perform("history", buildJsonObject { put("version_no", 999) })
                perform("refine", buildJsonObject { put("instruction", " ") })
                replace(ComponentControllerFixture.component("Replacement"))
                perform("history", buildJsonObject { put("version_no", 2) }, captured)
                // A later allowed action is a queue barrier; no invalid restore crossed the real socket.
                perform("refine", buildJsonObject { put("instruction", "Barrier") })
                await { base.outboundFrames.count { it["action"] == JsonPrimitive("component_refine") } == 2 }
                assertEquals(1, base.outboundFrames.count { it["action"] == JsonPrimitive("component_restore") })
            }
        }

    @Test fun csv_download_saves_only_current_private_bytes_and_picker_cancel_releases_them() =
        ComponentControllerFixture().use {
            with(it) {
                csv()
                assertEquals(1, files().size)
                val uri = base.document("csv")
                complete(uri)
                await { base.status(uri).getLong("size") > 0 && files().isEmpty() }
                assertEquals("a,b\n1,2", base.resolver.openInputStream(uri)!!.bufferedReader().use { reader -> reader.readText() })
                csv()
                complete(null)
                await { files().isEmpty() }
            }
        }

    @Test fun stale_csv_picker_cleans_empty_result_but_preserves_nonempty_destination() =
        ComponentControllerFixture().use {
            with(it) {
                csv()
                val empty = base.document("empty")
                invalidate { base.model.newChat() }
                complete(empty)
                await { !base.status(empty).getBoolean("exists") && files().isEmpty() }
                assertFalse(base.status(empty).getBoolean("opened"))
            }
            ComponentControllerFixture().use { next ->
                with(next) {
                    csv()
                    val uri = base.document("preserve")
                    base.resolver.openOutputStream(uri)!!.use { output -> output.write("existing".toByteArray()) }
                    invalidate { base.model.goTo(Screen.History) }
                    complete(uri)
                    await { files().isEmpty() }
                    assertEquals("existing", base.resolver.openInputStream(uri)!!.bufferedReader().use { reader -> reader.readText() })
                }
            }
        }

    @Test fun component_change_while_downloading_cancels_without_opening_a_picker() =
        ComponentControllerFixture().use {
            with(it) {
                val entered = CountDownLatch(1)
                val release = CountDownLatch(1)
                base.response = {
                    entered.countDown()
                    check(release.await(10, TimeUnit.SECONDS))
                    MockResponse().setBody("old")
                }
                perform("csv")
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                replace(ComponentControllerFixture.component("New"))
                release.countDown()
                base.awaitCallCompletion("/api/export/component/wc_a.csv")
                assertTrue(registry.launches.isEmpty())
                assertTrue(files().isEmpty())
                base.response = { MockResponse().setBody("new") }
                csv()
                assertEquals(1, registry.launches.size)
                complete(null)
            }
        }

    @Test fun partial_csv_cancel_removes_only_owned_destination_and_activity_destroy_releases_files() =
        ComponentControllerFixture().use {
            with(it) {
                base.response = { MockResponse().setBody("large synthetic csv\n".repeat(40000)) }
                csv()
                val neighbor = base.document("neighbor")
                base.resolver.openOutputStream(neighbor)!!.use { output -> output.write("keep".toByteArray()) }
                val uri = base.document("paused")
                complete(uri)
                await { base.status(uri).getLong("size") > 0 }
                assertTrue("Copy must still be active before cancellation", files().isNotEmpty())
                invalidate { base.token = null }
                base.release(uri)
                await { !base.status(uri).getBoolean("exists") && files().isEmpty() }
                assertEquals("keep", base.resolver.openInputStream(neighbor)!!.bufferedReader().use { reader -> reader.readText() })
            }
            ComponentControllerFixture().use { next ->
                next.csv()
                val file = next.files().single()
                next.base.scenario.moveToState(Lifecycle.State.DESTROYED)
                await { !file.exists() }
            }
        }

    @Test fun reconnected_socket_never_replays_a_stale_component_decision() =
        ComponentControllerFixture().use {
            with(it) {
                val captured = context()
                base.reconnect()
                invalidate { }
                perform("refine", buildJsonObject { put("instruction", "stale decision") }, captured)
                replace(ComponentControllerFixture.component("After reconnect"))
                perform("history", buildJsonObject { put("version_no", 2) }, captured)
                perform("refine", buildJsonObject { put("instruction", "current decision") })
                await { base.outboundFrames.any { frame -> frame["action"] == JsonPrimitive("component_refine") } }
                assertEquals(1, base.outboundFrames.count { frame -> frame["action"] == JsonPrimitive("component_refine") })
                assertFalse(base.outboundFrames.any { frame -> frame["action"] == JsonPrimitive("component_restore") })
                assertEquals("current decision", base.outboundFrames.single { frame -> frame["action"] == JsonPrimitive("component_refine") }.getValue("payload").jsonObject.getValue("instruction").jsonPrimitive.content)
            }
        }

    @Test fun inline_decisions_stay_disabled_through_running_and_release_only_on_exact_terminal() =
        ComponentControllerFixture().use {
            with(it) {
                for (kind in listOf("refine", "history")) {
                    val event = if (kind == "refine") "component_refine" else "component_restore"
                    val payload =
                        buildJsonObject {
                            if (kind == "refine") put("instruction", "Keep current context") else put("version_no", 2)
                        }
                    compose.onNodeWithText(kind).assertIsEnabled().performClick()
                    if (kind == "refine") {
                        compose.onNode(hasSetTextAction()).performTextInput("Keep current context")
                        compose.onNodeWithText("Refine").performClick()
                    } else {
                        compose.onNodeWithText("v2 · Earlier · 2026-09-12 12:34").performClick()
                    }
                    await { base.outboundFrames.any { frame -> frame["action"] == JsonPrimitive(event) } }
                    val frame = base.outboundFrames.single { frame -> frame["action"] == JsonPrimitive(event) }
                    val generation = frame.getValue("request_generation").jsonPrimitive.content
                    assertTrue(base.model.state.value.pendingSubmissions.containsKey(generation))
                    // UI progress state must not invalidate the exact component that was just submitted.
                    assertTrue(controller.pending.value.contains("wc_a" to kind))
                    compose.onNodeWithText(kind).assertIsNotEnabled()
                    perform(kind, payload)
                    base.send(operation(frame, "accepted", 1))
                    await { base.model.state.value.operationStatuses[generation]?.state == "accepted" }
                    assertTrue(base.model.state.value.pendingSubmissions.containsKey(generation))
                    base.send(refusal("00000000-0000-4000-8000-000000000099"))
                    base.send(operation(frame, "running", 2))
                    await { base.model.state.value.operationStatuses[generation]?.state == "running" }
                    compose.onNodeWithText(kind).assertIsNotEnabled()
                    perform(kind, payload)
                    base.send(operation(frame, "completed", 3))
                    await { !controller.pending.value.contains("wc_a" to kind) }
                    compose.onNodeWithText(kind).assertIsEnabled()
                    // A new current submission is a real socket barrier after all duplicate attempts.
                    perform(kind, payload)
                    await { base.outboundFrames.count { f -> f["action"] == JsonPrimitive(event) } == 2 }
                    val second = base.outboundFrames.last { f -> f["action"] == JsonPrimitive(event) }
                    base.send(refusal(second.getValue("submission_id").jsonPrimitive.content))
                    await { !controller.pending.value.contains("wc_a" to kind) }
                    assertEquals(2, base.outboundFrames.count { f -> f["action"] == JsonPrimitive(event) })
                }
            }
        }

    @Test fun replacing_same_component_id_retires_old_decision_without_releasing_its_successor() =
        ComponentControllerFixture().use {
            with(it) {
                val payload = buildJsonObject { put("instruction", "Synthetic decision") }
                perform("refine", payload)
                await { base.outboundFrames.any { f -> f["action"] == JsonPrimitive("component_refine") } }
                val old = base.outboundFrames.last { f -> f["action"] == JsonPrimitive("component_refine") }
                replace(ComponentControllerFixture.component("Same ID, new actual contents"))
                await { controller.pending.value.isEmpty() }
                compose.onNodeWithText("refine").assertIsEnabled()
                perform("refine", payload)
                await { base.outboundFrames.count { f -> f["action"] == JsonPrimitive("component_refine") } == 2 }
                val next = base.outboundFrames.last { f -> f["action"] == JsonPrimitive("component_refine") }
                base.send(operation(old, "completed", 1))
                base.send(operation(next, "running", 1))
                val generation = next.getValue("request_generation").jsonPrimitive.content
                await { base.model.state.value.operationStatuses[generation]?.state == "running" }
                compose.onNodeWithText("refine").assertIsNotEnabled()
                assertTrue(controller.pending.value.contains("wc_a" to "refine"))
                base.send(refusal(next.getValue("submission_id").jsonPrimitive.content))
                await { controller.pending.value.isEmpty() }
                compose.onNodeWithText("refine").assertIsEnabled()
                perform("refine", payload)
                await { base.outboundFrames.count { f -> f["action"] == JsonPrimitive("component_refine") } == 3 }
                invalidate { base.token = null }
                assertTrue(controller.pending.value.isEmpty())
            }
        }

    private fun ComponentControllerFixture.operation(
        frame: JsonObject,
        state: String,
        sequence: Int,
    ) =
        buildJsonObject {
            put("type", "operation_status")
            put("operation_id", frame.getValue("request_generation"))
            put("action", frame.getValue("action"))
            put("surface", "canvas")
            put("chat_id", WorkspaceControllerFixture.CHAT)
            put("connection_generation", base.model.state.value.connectionGeneration)
            put("request_generation", frame.getValue("request_generation"))
            put("sequence", sequence)
            put("state", state)
            put("phase", state)
            put("label", "Synthetic component operation")
            put("terminal", state == "completed")
            put("retryable", false)
            put("error", JsonNull)
            put("retry_after_ms", JsonNull)
            put("updated_at", "2026-09-12T12:34:00Z")
        }

    private fun refusal(submission: String) =
        buildJsonObject {
            put("type", "error")
            put("submission_id", submission)
            put("accepted", false)
            put("code", "capacity_exceeded")
            put("message", "Synthetic refusal")
            put("retryable", true)
            put("retry_after_ms", 1000)
        }
}
