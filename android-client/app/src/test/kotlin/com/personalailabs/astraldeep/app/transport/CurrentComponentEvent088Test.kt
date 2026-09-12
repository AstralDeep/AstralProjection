package com.personalailabs.astraldeep.app.transport

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Request
import okhttp3.WebSocket
import okio.ByteString
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class CurrentComponentEvent088Test {
    private val chat = "11111111-1111-4111-8111-111111111111"
    private val payload =
        buildJsonObject {
            put("component_id", "wc_a")
            put("chat_id", chat)
            put("version_no", 2)
        }

    @Test fun disconnected_or_unregistered_component_actions_never_join_the_generic_queue() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        client.sendEvent("ordinary_action", chat)
        assertFalse(client.sendCurrentEvent("component_restore", chat, payload, { true }))
        val socket = Socket()
        client.installOpenSocketForTest(socket)
        assertFalse(client.sendCurrentEvent("component_restore", chat, payload, { true }))
        assertTrue(socket.frames.isEmpty())
        assertEquals(listOf("ordinary_action"), client.pendingActions())
        val replay = mutableListOf<String>()
        client.replayPendingForTest("22222222-2222-4222-8222-222222222222", {}, {}, {
            replay.add(it)
            true
        })
        assertEquals(1, replay.size)
        assertEquals("ordinary_action", Json.parseToJsonElement(replay.single()).jsonObject.getValue("action").jsonPrimitive.content)
        assertTrue(client.pendingActions().isEmpty())
    }

    @Test fun registered_send_uses_ordinary_envelope_and_socket_rejection_never_replays() =
        runTest {
            val client = OrchestratorClient("ws://localhost:9/ws")
            val socket = Socket()
            client.installOpenSocketForTest(socket)
            client.replayPendingForTest("22222222-2222-4222-8222-222222222222", {}, {}, { true })
            val submissions = mutableListOf<LocalSubmission>()
            val failures = mutableListOf<QueuedSubmissionFailure>()
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { client.queuedFailures.collect(failures::add) }
            socket.beforeSend = { assertTrue(submissions.isNotEmpty()) }
            assertTrue(client.sendCurrentEvent("component_restore", chat, payload, { true }, submissions::add))
            val frame = Json.parseToJsonElement(socket.frames.single()).jsonObject
            assertEquals("ui_event", frame.getValue("type").jsonPrimitive.content)
            assertEquals("component_restore", frame.getValue("action").jsonPrimitive.content)
            assertTrue(client.validQueuedIdentity(socket.frames.single(), submissions.single()))
            assertFalse(client.sendCurrentEvent("delete_everything", chat, payload, { true }))
            assertFalse(client.sendCurrentEvent("component_restore", "foreign", payload, { true }))
            socket.accept = false
            assertFalse(client.sendCurrentEvent("component_restore", chat, payload, { true }, submissions::add))
            assertEquals(2, submissions.size)
            assertEquals(listOf(submissions.last()), failures.map { it.submission })
            assertTrue(client.pendingActions().isEmpty())
            client.clearOwnerSession()
            assertFalse(client.sendCurrentEvent("component_restore", chat, payload, { true }))
            assertTrue(client.pendingActions().isEmpty())
        }

    @Test fun callback_owner_socket_and_component_changes_are_rechecked_before_delivery() =
        runTest {
            for (change in listOf("owner", "socket", "generation", "component")) {
                val client = OrchestratorClient("ws://localhost:9/ws")
                val socket = Socket()
                client.installOpenSocketForTest(socket)
                client.replayPendingForTest("22222222-2222-4222-8222-222222222222", {}, {}, { true })
                var current = true
                val failures = mutableListOf<QueuedSubmissionFailure>()
                backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { client.queuedFailures.collect(failures::add) }
                assertFalse(
                    client.sendCurrentEvent("component_restore", chat, payload, { current }) {
                        when (change) {
                            "owner" -> client.clearOwnerSession()
                            "socket" -> client.installOpenSocketForTest(Socket())
                            "generation" -> client.replayPendingForTest("33333333-3333-4333-8333-333333333333", {}, {}, { true })
                            else -> current = false
                        }
                    },
                )
                assertTrue(socket.frames.isEmpty())
                assertTrue(client.pendingActions().isEmpty())
                assertEquals(1, failures.size)
            }
        }

    private class Socket : WebSocket {
        val frames = mutableListOf<String>()
        var accept = true
        var beforeSend: () -> Unit = {}

        override fun request(): Request = Request.Builder().url("ws://localhost:9/ws").build()

        override fun queueSize(): Long = 0

        override fun send(text: String): Boolean {
            beforeSend()
            if (accept) frames.add(text)
            return accept
        }

        override fun send(bytes: ByteString): Boolean = false

        override fun close(
            code: Int,
            reason: String?,
        ): Boolean = true

        override fun cancel() = Unit
    }
}
