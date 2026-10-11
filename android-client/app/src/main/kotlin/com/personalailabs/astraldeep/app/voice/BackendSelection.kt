// Strict parse of the server's v2 voice backend selection: the capability envelope that routes a
// session activation between the remote LiveKit path and the client-local runtime, carrying the
// frozen client-local requirements. OkHttpVoiceControlApi produces it and VoiceSessionController
// branches on the parsed variant.

package com.personalailabs.astraldeep.app.voice

import com.personalailabs.astraldeep.core.protocol.LocalVoiceFrame
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import java.time.Instant

data class LocalVoiceRequirements(
    val configuredLocale: String,
    val maxFinalUnicodeScalars: Int,
    val maxAnnouncementUtf8Bytes: Int,
    val announcementTtlSeconds: Int,
    val echoSuppressionMilliseconds: Long,
) {
    companion object {
        private val FIELDS =
            setOf(
                "announcement_ttl_seconds",
                "configured_locale",
                "echo_suppression_milliseconds",
                "installation_policy",
                "local_frame_contract",
                "max_announcement_utf8_bytes",
                "max_final_unicode_scalars",
                "recognition_must_be_local",
                "requirement_revision",
                "session_contract",
                "synthesis_must_be_local",
            )

        fun fromJson(root: JsonObject): LocalVoiceRequirements? {
            if (root.keys != FIELDS) return null
            val locale = root.string("configured_locale")
            val sessionContract = root.string("session_contract")
            val frameContract = root.string("local_frame_contract")
            val installation = root.string("installation_policy")
            val recognitionLocal = root.bool("recognition_must_be_local")
            val synthesisLocal = root.bool("synthesis_must_be_local")
            val revision = root.int("requirement_revision")
            val maxScalars = root.int("max_final_unicode_scalars")
            val maxAnnouncement = root.int("max_announcement_utf8_bytes")
            val ttl = root.int("announcement_ttl_seconds")
            val echo = root.long("echo_suppression_milliseconds")
            val local = sessionContract == "voice-rest/v2-client-local"
            if (!local && sessionContract != "voice-rest/v1") return null
            val expectedFrameContract = if (local) "client_local/v1" else null
            if (frameContract != expectedFrameContract) return null
            if (recognitionLocal != local || synthesisLocal != local) return null
            if (locale != "en-US" || installation != "explicit_user_action_only") return null
            if (revision != 1 || maxScalars != 8000 || maxAnnouncement != 600 || ttl != 10 || echo != 500L) return null
            return LocalVoiceRequirements(
                configuredLocale = locale,
                maxFinalUnicodeScalars = maxScalars,
                maxAnnouncementUtf8Bytes = maxAnnouncement,
                announcementTtlSeconds = ttl,
                echoSuppressionMilliseconds = echo,
            )
        }
    }
}

sealed interface VoiceBackendSelection {
    data object Legacy : VoiceBackendSelection

    data class Remote(
        val status: String,
        val reason: String,
    ) : VoiceBackendSelection

    data class Local(
        val status: String,
        val reason: String,
        val expiresAt: String,
        val requirements: LocalVoiceRequirements,
    ) : VoiceBackendSelection

    companion object {
        private val FIELDS =
            setOf(
                "checked_at",
                "expires_at",
                "reason",
                "requirements",
                "schema_version",
                "speech_backend",
                "status",
                "supported_transports",
            )
        private val OPTIONAL_FIELDS = FIELDS + "retry_after_seconds"
        private val REASON_PATTERN = Regex("^[a-z][a-z0-9_]*$")

        fun fromJson(root: JsonObject): VoiceBackendSelection? {
            if (root.keys !in setOf(FIELDS, OPTIONAL_FIELDS)) return null
            if (root.string("schema_version") != "2") return null
            val backend = root.string("speech_backend") ?: return null
            val status = root.string("status") ?: return null
            val reason = root.string("reason")?.takeIf(REASON_PATTERN::matches) ?: return null
            val checkedAt = root.timestamp("checked_at") ?: return null
            val expiresAtValue = root.string("expires_at") ?: return null
            val expiresAt = root.timestamp("expires_at") ?: return null
            if (!expiresAt.isAfter(checkedAt)) return null
            root.int("retry_after_seconds")?.takeIf { it !in 1..300 }?.let { return null }
            val transports = root.transports() ?: return null
            val requirements = root.obj("requirements") ?: return null
            return when (backend) {
                "client_local" ->
                    if (status !in setOf("ready", "unavailable", "requires_client_readiness") ||
                        transports != listOf("client_local") ||
                        reason !in LocalVoiceFrame.reasons
                    ) {
                        null
                    } else {
                        val parsed = LocalVoiceRequirements.fromJson(requirements) ?: return null
                        Local(status, reason, expiresAtValue, parsed)
                    }
                "llm_factory" ->
                    if (status !in setOf("ready", "unavailable") ||
                        transports.isEmpty() ||
                        transports.size > 2 ||
                        "livekit" !in transports ||
                        transports.any { it !in setOf("livekit", "watch_pcm_websocket") }
                    ) {
                        null
                    } else {
                        val parsed = LocalVoiceRequirements.fromJson(requirements) ?: return null
                        Remote(status, reason)
                    }
                else -> null
            }
        }
    }
}

internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

internal fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

internal fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull

internal fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull

internal fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

private fun JsonObject.timestamp(key: String): Instant? = string(key)?.let { runCatching { Instant.parse(it) }.getOrNull() }

private fun JsonObject.transports(): List<String>? {
    val array = this["supported_transports"] as? kotlinx.serialization.json.JsonArray ?: return null
    val values =
        array.map { element ->
            (element as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull ?: return null
        }
    return values.takeIf { it.size == it.toSet().size }
}
