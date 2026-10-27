// Minimal OS push payload decode for the notification adapter: validates the server-delivered
// notification identity and text against the same bounds the delivery pipeline enforces, so a
// malformed provider payload surfaces as a typed failure instead of a crash or silent drop.

package com.personalailabs.astraldeep.core.push

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.nio.ByteBuffer
import java.security.MessageDigest

data class PushPayload(
    val notificationId: String,
    val title: String?,
    val body: String?,
    val level: String = LEVEL_INFO,
    val chatId: String? = null,
) {
    val displayId: Int
        get() = displayIdFor(notificationId)

    companion object {
        const val LEVEL_INFO = "info"
        const val LEVEL_WARNING = "warning"
        const val LEVEL_ERROR = "error"
        const val MAX_TITLE_CHARS = 128
        const val MAX_BODY_CHARS = 256
        const val MAX_CHAT_ID_CHARS = 128
        val LEVELS = setOf(LEVEL_INFO, LEVEL_WARNING, LEVEL_ERROR)
        val NOTIFICATION_ID_REGEX = Regex("^[A-Za-z0-9._:-]{8,128}$")
        val FIELD_KEYS = setOf("notification_id", "title", "body", "level", "chat_id")
        const val REASON_NOTIFICATION_ID = "notification_id"
        const val REASON_TEXT = "notification_text"
        const val REASON_TITLE = "title"
        const val REASON_BODY = "body"
        const val REASON_LEVEL = "level"
        const val REASON_CHAT_ID = "chat_id"
    }
}

sealed interface PushPayloadResult {
    data class Decoded(val payload: PushPayload) : PushPayloadResult

    data class Malformed(val reason: String) : PushPayloadResult
}

fun decodePushPayload(data: JsonObject): PushPayloadResult {
    for (key in PushPayload.FIELD_KEYS) {
        if (data.hasNonStringField(key)) {
            return PushPayloadResult.Malformed(key)
        }
    }
    val notificationId =
        data.stringField("notification_id") ?: return PushPayloadResult.Malformed(PushPayload.REASON_NOTIFICATION_ID)
    if (!PushPayload.NOTIFICATION_ID_REGEX.matches(notificationId)) {
        return PushPayloadResult.Malformed(PushPayload.REASON_NOTIFICATION_ID)
    }
    val title = data.stringField("title")
    val body = data.stringField("body")
    if ((title == null || title.isBlank()) && (body == null || body.isBlank())) {
        return PushPayloadResult.Malformed(PushPayload.REASON_TEXT)
    }
    if (title != null && (title.length > PushPayload.MAX_TITLE_CHARS || title.hasControlChars())) {
        return PushPayloadResult.Malformed(PushPayload.REASON_TITLE)
    }
    if (body != null && (body.length > PushPayload.MAX_BODY_CHARS || body.hasControlChars())) {
        return PushPayloadResult.Malformed(PushPayload.REASON_BODY)
    }
    val level = data.stringField("level") ?: PushPayload.LEVEL_INFO
    if (level !in PushPayload.LEVELS) {
        return PushPayloadResult.Malformed(PushPayload.REASON_LEVEL)
    }
    val chatId = data.stringField("chat_id")
    if (chatId != null && (chatId.length > PushPayload.MAX_CHAT_ID_CHARS || chatId.hasControlChars())) {
        return PushPayloadResult.Malformed(PushPayload.REASON_CHAT_ID)
    }
    return PushPayloadResult.Decoded(PushPayload(notificationId, title, body, level, chatId))
}

fun displayIdFor(notificationId: String): Int =
    ByteBuffer.wrap(MessageDigest.getInstance("SHA-256").digest(notificationId.toByteArray(Charsets.UTF_8))).getInt()

private fun String.hasControlChars(): Boolean = any { it.code < 0x20 || it.code == 0x7F }

private fun JsonObject.hasNonStringField(key: String): Boolean {
    val value = this[key] ?: return false
    if (value is JsonNull) return false
    val primitive = value as? JsonPrimitive ?: return true
    return !primitive.isString
}

private fun JsonObject.stringField(key: String): String? {
    val value = this[key] ?: return null
    if (value is JsonNull) return null
    val primitive = value as? JsonPrimitive ?: return null
    if (!primitive.isString) return null
    return primitive.content
}
