// REST boundary for the push destination runtime: enrolls the device push token with Deep,
// acknowledges delivered notification identities, and revokes the destination on sign-out
// or account change, reporting typed outcomes the runtime maps into the adapter machine.

package com.personalailabs.astraldeep.app.push

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

sealed interface PushEnrollOutcome {
    data object Accepted : PushEnrollOutcome

    data class Rejected(val transient: Boolean, val code: String) : PushEnrollOutcome

    data object Unauthenticated : PushEnrollOutcome
}

sealed interface PushAckOutcome {
    data object Acknowledged : PushAckOutcome

    data object Refused : PushAckOutcome

    data object DestinationRevoked : PushAckOutcome

    data object Unauthenticated : PushAckOutcome
}

sealed interface PushRevokeOutcome {
    data object Revoked : PushRevokeOutcome

    data object Unauthenticated : PushRevokeOutcome

    data object Failed : PushRevokeOutcome
}

class PushDestinationRest(
    private val baseUrl: String,
    private val client: OkHttpClient = OkHttpClient(),
) {
    suspend fun enroll(
        token: String?,
        deviceId: String,
        platform: String,
        pushToken: String,
        label: String?,
    ): PushEnrollOutcome =
        withContext(Dispatchers.IO) {
            if (token.isNullOrBlank()) return@withContext PushEnrollOutcome.Unauthenticated
            val body =
                buildJsonObject {
                    put("device_id", deviceId)
                    put("platform", platform)
                    put("token", pushToken)
                    if (!label.isNullOrBlank()) put("label", label.take(64))
                }
            val request =
                Request.Builder()
                    .url("${baseUrl.trimEnd('/')}/api/push/destinations")
                    .header("Authorization", "Bearer $token")
                    .post(
                        body.toString().toRequestBody("application/json".toMediaType()),
                    )
                    .build()
            runCatching { client.newCall(request).execute().use { classify(it.code) } }
                .getOrDefault(PushEnrollOutcome.Rejected(true, ENROLL_NETWORK))
        }

    suspend fun acknowledge(
        token: String?,
        deviceId: String,
        notificationId: String,
    ): PushAckOutcome =
        withContext(Dispatchers.IO) {
            if (token.isNullOrBlank()) return@withContext PushAckOutcome.Unauthenticated
            val body =
                buildJsonObject {
                    put("device_id", deviceId)
                    put("notification_id", notificationId)
                }
            val request =
                Request.Builder()
                    .url("${baseUrl.trimEnd('/')}/api/push/ack")
                    .header("Authorization", "Bearer $token")
                    .post(body.toString().toRequestBody("application/json".toMediaType()))
                    .build()
            runCatching {
                client.newCall(request).execute().use { response ->
                    when {
                        response.isSuccessful -> PushAckOutcome.Acknowledged
                        response.code == 410 -> PushAckOutcome.DestinationRevoked
                        else -> PushAckOutcome.Refused
                    }
                }
            }.getOrDefault(PushAckOutcome.Refused)
        }

    suspend fun revoke(
        token: String?,
        deviceId: String,
    ): PushRevokeOutcome =
        withContext(Dispatchers.IO) {
            if (token.isNullOrBlank()) return@withContext PushRevokeOutcome.Unauthenticated
            val url =
                baseUrl.trimEnd('/').toHttpUrl().newBuilder()
                    .addPathSegment("api")
                    .addPathSegment("push")
                    .addPathSegment("destinations")
                    .addPathSegment(deviceId)
                    .build()
            val request =
                Request.Builder().url(url).header("Authorization", "Bearer $token").delete().build()
            runCatching {
                client.newCall(request).execute().use { response ->
                    when {
                        response.isSuccessful || response.code == 404 -> PushRevokeOutcome.Revoked
                        else -> PushRevokeOutcome.Failed
                    }
                }
            }.getOrDefault(PushRevokeOutcome.Failed)
        }

    private fun classify(code: Int): PushEnrollOutcome =
        when (code) {
            in 200..299 -> PushEnrollOutcome.Accepted
            401 -> PushEnrollOutcome.Unauthenticated
            400 -> PushEnrollOutcome.Rejected(false, "destination_invalid")
            403 -> PushEnrollOutcome.Rejected(false, "destination_forbidden")
            409 -> PushEnrollOutcome.Rejected(false, "destination_capacity")
            429 -> PushEnrollOutcome.Rejected(true, "rate_limited")
            else -> PushEnrollOutcome.Rejected(true, ENROLL_PROVIDER_UNAVAILABLE)
        }

    companion object {
        const val ENROLL_NETWORK = "enroll_network"
        const val ENROLL_PROVIDER_UNAVAILABLE = "provider_unavailable"
    }
}
