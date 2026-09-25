// Verifies live capability updates and reconnect registration use the newest device facts.
// Capability churn is coalesced without queuing stale viewport frames or disturbing conversation identity.

package com.personalailabs.astraldeep.app.transport

import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Request
import okhttp3.WebSocket
import okio.ByteString
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DeviceUpdateTest {
    private val initial = DeviceCapabilities(1080, 2340, 393, 851, 2.75, deviceId = "00000000-0000-4000-8000-000000000001")
    private val connection = "00000000-0000-4000-8000-000000000002"

    @Test fun updatesAreDeduplicatedAndDoNotCreateConversationRequests() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val socket = Socket()
        client.replayPendingForTest(connection, {}, {}, { true })
        client.installOpenSocketForTest(socket)
        var conversationChanges = 0
        client.observeConversationGenerations { conversationChanges++ }
        assertTrue(client.updateDevice(initial, "chat"))
        assertTrue(client.updateDevice(initial, "chat"))
        assertEquals(1, socket.frames.size)
        assertEquals("update_device", socket.frames.single().getValue("action").jsonPrimitive.content)
        assertEquals(393, socket.frames.single().getValue("payload").jsonObject.getValue("device").jsonObject.getValue("viewport_width").jsonPrimitive.content.toInt())
        assertEquals(connection, client.currentConnectionGeneration())
        assertEquals(0, conversationChanges)
        assertTrue(client.pendingActions().isEmpty())
    }

    @Test fun offlineChangesCollapseIntoTheNextRegistrationAndOwnerClearDiscardsThem() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        repeat(100) { index -> assertFalse(client.updateDevice(initial.copy(viewportWidth = 500 + index), null)) }
        val latest = initial.copy(viewportWidth = 1280, hasAudioOutput = true, pointerType = "fine", reducedMotion = true)
        assertFalse(client.updateDevice(latest, null))
        assertTrue(client.pendingFrames().isEmpty())
        val frame = Json.parseToJsonElement(client.createRegistrationAttempt("synthetic", initial, null).frame).jsonObject
        val device = frame.getValue("device").jsonObject
        assertEquals("1280", device.getValue("viewport_width").jsonPrimitive.content)
        assertEquals("true", device.getValue("has_audio_output").jsonPrimitive.content)
        assertEquals("fine", device.getValue("pointer_type").jsonPrimitive.content)
        assertEquals("true", device.getValue("reduced_motion").jsonPrimitive.content)
        client.clearOwnerSession()
        val reset = Json.parseToJsonElement(client.createRegistrationAttempt("synthetic", initial, null).frame).jsonObject
        assertEquals("393", reset.getValue("device").jsonObject.getValue("viewport_width").jsonPrimitive.content)
    }

    @Test fun failedUpdateIsRetriedAndDifferentDevicesDoNotInheritCachedFacts() {
        val client = OrchestratorClient("ws://localhost:9/ws")
        val socket = Socket().apply { accepted = false }
        client.replayPendingForTest(connection, {}, {}, { true })
        client.installOpenSocketForTest(socket)
        assertFalse(client.updateDevice(initial.copy(hasTouch = false), null))
        socket.accepted = true
        assertTrue(client.updateDevice(initial.copy(hasTouch = false), null))
        assertEquals(2, socket.frames.size)
        assertTrue(client.pendingFrames().isEmpty())
        val different = initial.copy(deviceId = "00000000-0000-4000-8000-000000000003")
        val frame = Json.parseToJsonElement(client.createRegistrationAttempt("synthetic", different, null).frame).jsonObject
        assertEquals("true", frame.getValue("device").jsonObject.getValue("has_touch").jsonPrimitive.content)
    }

    private class Socket : WebSocket {
        val frames = mutableListOf<JsonObject>()
        var accepted = true

        override fun request(): Request = Request.Builder().url("ws://localhost:9/ws").build()

        override fun queueSize(): Long = 0

        override fun send(text: String): Boolean {
            frames += Json.parseToJsonElement(text).jsonObject
            return accepted
        }

        override fun send(bytes: ByteString): Boolean = false

        override fun close(
            code: Int,
            reason: String?,
        ): Boolean = true

        override fun cancel() = Unit
    }
}
