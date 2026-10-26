// Minimal OS push payload decode for the notification adapter: validates the server-delivered
// notification identity and text against the same bounds the delivery pipeline enforces, so a
// malformed provider payload surfaces as a typed failure instead of a crash or silent drop.

package com.personalailabs.astraldeep.core.push

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.security.MessageDigest

data class PushPayload(
    val notificationId: String,
    val title: String?,
    val body: String?,
    val level: String = LEVEL_INFO,
    val chatId: String? = null,
) {
    init {
        require(NOTIFICATION_ID_REGEX.matches(notificationId)) { REASON_NOTIFICATION_ID }
        require(!title.isNullOrBlank() || !body.isNullOrBlank()) { REASON_TEXT }
        title?.let { require(it.length <= MAX_TITLE_CHARS && !it.hasControlChars()) { REASON_TITLE } }
        body?.let { require(it.length <= MAX_BODY_CHARS && !it.hasControlChars()) { REASON_BODY } }
        require(level in LEVELS) { REASON_LEVEL }
        chatId?.let { require(it.length <= MAX_CHAT_ID_CHARS && !it.hasControlChars()) { REASON_CHAT_ID } }
    }

    val displayId: Int by lazy { displayIdFor(notificationId) }

    companion object {
        const val LEVEL_INFO = "info"
        const val LEVEL_WARNING = "warning"
        const val LEVEL_ERROR = "error"
        val LEVELS = setOf(LEVEL_INFO, LEVEL_WARNING, LEVEL_ERROR)
        const val MAX_TITLE_CHARS = 128
        const val MAX_BODY_CHARS = 256
        const val MAX_CHAT_ID_CHARS = 128
        val NOTIFICATION_ID_REGEX = Regex("^[A-Za-z0-9._:-]{8,128}$")
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

fun decodePushPayload(data: JsonObject): PushPayloadResult =
    try {
        PushPayloadResult.Decoded(
            PushPayload(
                notificationId = requireNotNull(data.stringField("notification_id")) { PushPayload.REASON_NOTIFICATION_ID },
                title = data.stringField("title"),
                body = data.stringField("body"),
                level = data.stringField("level") ?: PushPayload.LEVEL_INFO,
                chatId = data.stringField("chat_id"),
            ),
        )
    } catch (error: IllegalArgumentException) {
        PushPayloadResult.Malformed(error.message ?: "payload")
    }

fun displayIdFor(notificationId: String): Int {
    val digest = MessageDigest.getInstance("SHA-256").digest(notificationId.toByteArray(Charsets.UTF_8))
    return ((digest[0].toInt() and 0xFF) shl 24) or
        ((digest[1].toInt() and 0xFF) shl 16) or
        ((digest[2].toInt() and 0xFF) shl 8) or
        (digest[3].toInt() and 0xFF)
}

private fun String.hasControlChars(): Boolean = any { it.code < 0x20 || it.code == 0x7F }

private fun JsonObject.stringField(key: String): String? {
    val value = this[key] ?: return null
    if (value is JsonNull) return null
    val primitive = value as? JsonPrimitive ?: throw IllegalArgumentException(key)
    if (!primitive.isString) throw IllegalArgumentException(key)
    return primitive.content
}
