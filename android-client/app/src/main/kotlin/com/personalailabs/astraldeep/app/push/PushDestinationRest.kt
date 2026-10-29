// Performs bounded, cancellable owner-authenticated push enrollment, delivery admission, receipts, conditional revocation and UI-presence requests.
package com.personalailabs.astraldeep.app.push

import com.personalailabs.astraldeep.core.push.PushPayload
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume

sealed interface PushEnrollOutcome {
    data class Accepted(val serverTokenGeneration: Long, val destinationRevision: Long) : PushEnrollOutcome

    data class Rejected(val transient: Boolean, val code: String) : PushEnrollOutcome

    data object Unauthenticated : PushEnrollOutcome
}

enum class PushAckOutcome { Acknowledged, Refused, DestinationRevoked, Unauthenticated }

enum class PushRevokeOutcome { Revoked, Conflict, Unauthenticated, Failed }

data class PushSource(val notificationId: String, val chatId: String?)

data class PushPresenceOutcome(val acceptedSequence: Long, val expiresInSeconds: Int)

data class PushDestinationSnapshot(val generation: Long, val revision: Long, val active: Boolean)

class PushDestinationRest(
    private val baseUrl: String,
    private val sessionHeaders: (String) -> Map<String, String> = { emptyMap() },
    private val client: OkHttpClient = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build(),
) {
    suspend fun enroll(
        token: String?,
        deviceId: String,
        platform: String,
        pushToken: String,
        label: String?,
        expectedDestinationRevision: Long,
    ): PushEnrollOutcome {
        require(expectedDestinationRevision in 0..MAX_SEQUENCE)
        if (token.isNullOrBlank()) return PushEnrollOutcome.Unauthenticated
        val body =
            buildJsonObject {
                put("device_id", deviceId)
                put("expected_destination_revision", expectedDestinationRevision)
                put("platform", platform)
                put("token", pushToken)
                if (!label.isNullOrBlank()) put("label", label.take(64))
            }
        val result =
            exchange(request(token, "push", "destinations").post(jsonBody(body)).build())
                ?: return PushEnrollOutcome.Rejected(true, ENROLL_NETWORK)
        if (result.code in 200..299) {
            val row = result.data as? JsonObject
            val generation = row?.get("token_generation").strictLong()
            val revision = row?.get("updated_at").strictLong()
            if (row != null && row["device_id"].text() == deviceId && row["platform"].text() == platform &&
                row["status"].text() == "active" &&
                generation != null &&
                generation in 1..MAX_SEQUENCE &&
                revision != null &&
                revision in 1..MAX_SEQUENCE && revision > expectedDestinationRevision
            ) {
                return PushEnrollOutcome.Accepted(generation, revision)
            }
            return PushEnrollOutcome.Rejected(false, "destination_response_invalid")
        }
        return when (result.code) {
            401 -> PushEnrollOutcome.Unauthenticated
            400, 422 -> PushEnrollOutcome.Rejected(false, "destination_invalid")
            403 -> PushEnrollOutcome.Rejected(false, "destination_forbidden")
            409 -> PushEnrollOutcome.Rejected(true, "destination_conflict")
            429 -> PushEnrollOutcome.Rejected(true, "rate_limited")
            else -> PushEnrollOutcome.Rejected(true, ENROLL_PROVIDER_UNAVAILABLE)
        }
    }

    suspend fun destinationSnapshot(
        token: String?,
        deviceId: String,
    ): PushDestinationSnapshot? {
        if (token.isNullOrBlank()) return null
        val result = exchange(request(token, "push", "destinations", deviceId).get().build()) ?: return null
        if (result.code == 404) return PushDestinationSnapshot(0, 0, false)
        val row = result.data as? JsonObject ?: return null
        if (result.code != 200 || row["device_id"].text() != deviceId) return null
        val revision = row["updated_at"].strictLong()?.takeIf { it in 1..MAX_SEQUENCE } ?: return null
        val generation = row["token_generation"].strictLong()?.takeIf { it in 1..MAX_SEQUENCE } ?: return null
        return PushDestinationSnapshot(generation, revision, row["status"].text() == "active")
    }

    suspend fun acknowledge(
        token: String?,
        deviceId: String,
        notificationId: String,
    ): PushAckOutcome {
        if (token.isNullOrBlank()) return PushAckOutcome.Unauthenticated
        val body =
            buildJsonObject {
                put("device_id", deviceId)
                put("notification_id", notificationId)
            }
        return when (exchange(request(token, "push", "ack").post(jsonBody(body)).build())?.code) {
            in 200..299 -> PushAckOutcome.Acknowledged
            410 -> PushAckOutcome.DestinationRevoked
            else -> PushAckOutcome.Refused
        }
    }

    suspend fun revoke(
        token: String?,
        deviceId: String,
        expectedTokenGeneration: Long,
        expectedDestinationRevision: Long,
    ): PushRevokeOutcome {
        require(expectedTokenGeneration in 1..MAX_SEQUENCE && expectedDestinationRevision in 1..MAX_SEQUENCE)
        if (token.isNullOrBlank()) return PushRevokeOutcome.Unauthenticated
        val url =
            url("push", "destinations", deviceId).newBuilder()
                .addQueryParameter("expected_token_generation", expectedTokenGeneration.toString())
                .addQueryParameter("expected_destination_revision", expectedDestinationRevision.toString()).build()
        val request = Request.Builder().url(url).header("Authorization", "Bearer $token").delete().build()
        return when (exchange(request)?.code) {
            in 200..299, 404 -> PushRevokeOutcome.Revoked
            409 -> PushRevokeOutcome.Conflict
            401 -> PushRevokeOutcome.Unauthenticated
            else -> PushRevokeOutcome.Failed
        }
    }

    suspend fun authorize(
        token: String?,
        deviceId: String,
        generation: Long,
        destinationRevision: Long,
        notificationId: String,
    ): PushSource? {
        if (token.isNullOrBlank() ||
            generation !in 1..MAX_SEQUENCE ||
            destinationRevision !in 1..MAX_SEQUENCE ||
            !PushPayload.NOTIFICATION_ID_REGEX.matches(notificationId)
        ) {
            return null
        }
        val destination = exchange(request(token, "push", "destinations", deviceId).get().build())
        val row = destination?.data as? JsonObject ?: return null
        if (destination.code != 200 || row["device_id"].text() != deviceId || row["status"].text() != "active" ||
            row["token_generation"].strictLong() != generation || row["updated_at"].strictLong() != destinationRevision
        ) {
            return null
        }
        val outcomes = exchange(request(token, "push", "deliveries", notificationId).get().build())
        val queued = outcomes?.data as? JsonArray ?: return null
        if (outcomes.code != 200 ||
            queued.none {
                val event = it as? JsonObject
                event != null && event["action"].text() == "push.delivery.queued" && event["device_id"].text() == deviceId &&
                    event["token_generation"].strictLong() == generation &&
                    event["destination_revision"].strictLong() == destinationRevision
            }
        ) {
            return null
        }
        return source(token, notificationId)
    }

    suspend fun source(
        token: String?,
        notificationId: String,
    ): PushSource? {
        if (token.isNullOrBlank() || !PushPayload.NOTIFICATION_ID_REGEX.matches(notificationId)) return null
        val result = exchange(request(token, "notifications", "inbox", notificationId).get().build())
        val entry = result?.data as? JsonObject ?: return null
        if (result.code != 200 || entry["entry_id"].text() != notificationId || entry["deleted_at"] != JsonNull ||
            entry["revision"].strictLong()?.let { it >= 0 } != true
        ) {
            return null
        }
        val content = entry["content"] as? JsonObject ?: return null
        val chat = content["chat_id"].text()
        if (chat != null && (chat.isBlank() || chat.length > 128 || chat.any { it.code < 32 || it.code == 127 })) return null
        return PushSource(notificationId, chat)
    }

    suspend fun presence(
        token: String?,
        deviceId: String,
        connectionGeneration: String,
        sequence: Long,
        foreground: Boolean,
    ): PushPresenceOutcome? {
        if (token.isNullOrBlank() || connectionGeneration.isBlank() || sequence !in 1..MAX_SEQUENCE) return null
        val body =
            buildJsonObject {
                put("device_id", deviceId)
                put("connection_generation", connectionGeneration)
                put("sequence", sequence)
                put("foreground", foreground)
            }
        val result = exchange(request(token, "notifications", "presence").post(jsonBody(body)).build())
        val data = result?.data as? JsonObject ?: return null
        val expiry = data["expires_in_seconds"].strictLong()
        if (result.code != 200 || data["accepted_sequence"].strictLong() != sequence || expiry != if (foreground) 45L else 0L) return null
        return PushPresenceOutcome(sequence, expiry.toInt())
    }

    private fun request(
        token: String,
        vararg segments: String,
    ): Request.Builder = Request.Builder().url(url(*segments)).header("Authorization", "Bearer $token").header("Cache-Control", "no-store")

    private fun url(vararg segments: String): HttpUrl =
        baseUrl.toHttpUrl().newBuilder()
            .apply {
                addPathSegment("api")
                segments.forEach { addPathSegment(it) }
            }.build()

    private fun jsonBody(data: JsonObject) = data.toString().toRequestBody("application/json".toMediaType())

    private data class Result(val code: Int, val data: JsonElement?)

    private suspend fun exchange(request: Request): Result? =
        suspendCancellableCoroutine { continuation ->
            val token = request.header("Authorization")?.removePrefix("Bearer ")
            val authenticated = request.newBuilder()
            if (token != null) {
                sessionHeaders(token).filterKeys { it == "Cookie" || it == "Origin" }.forEach {
                        (name, value) ->
                    authenticated.header(name, value)
                }
            }
            val call = client.newCall(authenticated.build())
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(
                object : Callback {
                    override fun onFailure(
                        call: Call,
                        e: IOException,
                    ) {
                        if (continuation.isActive) continuation.resume(null)
                    }

                    override fun onResponse(
                        call: Call,
                        response: Response,
                    ) {
                        val result =
                            response.use {
                                try {
                                    val source = it.body?.source()
                                    val data =
                                        if (source != null && !source.request(MAX_BODY + 1L)) {
                                            runCatching { Json.parseToJsonElement(source.readUtf8()) }.getOrNull()
                                        } else {
                                            null
                                        }
                                    Result(it.code, data)
                                } catch (_: IOException) {
                                    null
                                }
                            }
                        if (continuation.isActive) continuation.resume(result)
                    }
                },
            )
        }

    companion object {
        const val MAX_SEQUENCE = 9007199254740991L
        const val ENROLL_NETWORK = "enroll_network"
        const val ENROLL_PROVIDER_UNAVAILABLE = "provider_unavailable"
        private const val MAX_BODY = 65536L
    }
}

private fun JsonElement?.text(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

private fun JsonElement?.strictLong(): Long? =
    (this as? JsonPrimitive)?.takeIf {
        !it.isString && it.content.matches(Regex("-?[0-9]+"))
    }?.longOrNull
