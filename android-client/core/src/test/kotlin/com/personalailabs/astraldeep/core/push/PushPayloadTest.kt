// Tests the minimal push payload decode: server-mirrored identity and text bounds, typed
// malformed results, level vocabulary, chat binding, and the stable OS notification id.

package com.personalailabs.astraldeep.core.push

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PushPayloadTest {
    @Test
    fun decodes_minimal_payload_with_defaults() {
        val decoded = decodePushPayload(payloadJson(id = "notif-0001"))
        val payload = decoded as PushPayloadResult.Decoded
        assertEquals("notif-0001", payload.payload.notificationId)
        assertEquals("Hello", payload.payload.title)
        assertEquals("Body text", payload.payload.body)
        assertEquals("info", payload.payload.level)
        assertNull(payload.payload.chatId)
    }

    @Test
    fun decodes_optional_level_and_chat_binding() {
        val decoded = decodePushPayload(payloadJson(id = "notif-0002", title = null, level = "error", chatId = "chat-9")) as PushPayloadResult.Decoded
        assertEquals("error", decoded.payload.level)
        assertEquals("chat-9", decoded.payload.chatId)
        assertNull(decoded.payload.title)
    }

    @Test
    fun ignores_unknown_additive_fields() {
        val decoded =
            decodePushPayload(
                buildJsonObject {
                    put("notification_id", "notif-0003")
                    put("title", "Hello")
                    put("body", "Body text")
                    put("future_field", "reserved")
                },
            ) as PushPayloadResult.Decoded
        assertEquals("notif-0003", decoded.payload.notificationId)
    }

    @Test
    fun display_id_is_stable_and_distinct() {
        assertEquals(displayIdFor("notif-0001"), PushPayload("notif-0001", "t", null).displayId)
        assertTrue(displayIdFor("notif-0001") != displayIdFor("notif-0002"))
    }

    @Test
    fun rejects_missing_or_malformed_identity() {
        assertMalformed(buildJsonObject { put("title", "Hello") })
        assertMalformed(payloadJson(id = "short"))
        assertMalformed(payloadJson(id = "bad id with spaces and!"))
        assertMalformed(payloadJson(id = "x".repeat(129)))
        assertMalformed(payloadJson(id = "control\u0007id"))
    }

    @Test
    fun accepts_opaque_notification_without_private_text() {
        assertIs<PushPayloadResult.Decoded>(decodePushPayload(payloadJson(title = null, body = null)))
        assertIs<PushPayloadResult.Decoded>(decodePushPayload(payloadJson(title = "   ", body = "  ")))
    }

    @Test
    fun rejects_oversized_or_control_text() {
        assertMalformed(payloadJson(title = "t".repeat(129)))
        assertMalformed(payloadJson(body = "b".repeat(257)))
        assertMalformed(payloadJson(title = "title\u0007"))
        assertMalformed(payloadJson(body = "body\u001b"))
        assertMalformed(payloadJson(chatId = "c".repeat(129)))
        assertMalformed(payloadJson(chatId = "chat\u0000"))
    }

    @Test
    fun rejects_unknown_level() {
        assertMalformed(payloadJson(level = "critical"))
    }

    @Test
    fun rejects_non_primitive_field_values() {
        assertMalformed(buildJsonObject { put("notification_id", 12345) })
        assertMalformed(
            buildJsonObject {
                put("notification_id", "notif-0001")
                put("title", "text")
                put("body", buildJsonObject { put("nested", "object") })
            },
        )
    }

    @Test
    fun json_null_fields_are_treated_as_absent() {
        val decoded = decodePushPayload(jsonNullPayload()) as PushPayloadResult.Decoded
        assertNull(decoded.payload.title)
        assertEquals("text", decoded.payload.body)
    }

    private fun jsonNullPayload(): JsonObject =
        buildJsonObject {
            put("notification_id", "notif-0001")
            put("title", JsonNull)
            put("body", "text")
        }

    private fun assertMalformed(data: JsonObject) {
        val decoded = decodePushPayload(data)
        assertTrue(decoded is PushPayloadResult.Malformed, "expected malformed for $data")
        val reason = (decoded as PushPayloadResult.Malformed).reason
        assertTrue(reason.isNotBlank())
    }

    private fun payloadJson(
        id: String = "notif-0001",
        title: String? = "Hello",
        body: String? = "Body text",
        level: String? = null,
        chatId: String? = null,
    ): JsonObject =
        buildJsonObject {
            put("notification_id", id)
            title?.let { put("title", it) }
            body?.let { put("body", it) }
            level?.let { put("level", it) }
            chatId?.let { put("chat_id", it) }
        }
}
