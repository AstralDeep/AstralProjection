package com.personalailabs.astraldeep.app.auth

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.Callback
import okhttp3.CookieJar
import okhttp3.FormBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.time.Instant
import java.util.concurrent.TimeUnit

/** Dedicated transport: fixed HTTPS endpoints, no redirects, cookie jar, retry or token authenticator. */
class ServerSessionTransport(
    val scope: ServerSessionScope,
    client: OkHttpClient = OkHttpClient(),
    private val clock: () -> Instant = { Instant.now() },
) {
    private val http =
        client.newBuilder()
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
            .callTimeout(30, TimeUnit.SECONDS).connectTimeout(10, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
            .apply {
                interceptors().clear()
                networkInterceptors().clear()
            }.build()

    /** Protocol support only; a failed probe never authorizes a fallback exchange. */
    suspend fun probe(): Boolean {
        val result = request(Request.Builder().url(scope.endpoint("/auth/session")).get().build())
        val body = sessionObject(result.body)
        if (result.cookies.isNotEmpty() || body.keys != setOf("authenticated", "access_token", "resumed", "reason") ||
            body.boolean("authenticated") || body.string("access_token").isNotEmpty() || body.boolean("resumed") ||
            body.string("reason").length > 128 || result.capability.size > 1 ||
            result.capability.any { it.length > 128 }
        ) {
            sessionInvalid()
        }
        return result.capability.singleOrNull() == "server_v1"
    }

    suspend fun exchange(code: ServerAuthorizationCode): ServerSession {
        code.consume(scope)
        val form =
            FormBody.Builder().add("session_custody", "server_v1")
                .add("grant_type", "authorization_code").add("client_id", scope.clientId)
                .add("code", code.code).add("code_verifier", code.verifier).add("redirect_uri", scope.redirectUri).build()
        val result =
            request(
                Request.Builder().url(scope.endpoint("/auth/token"))
                    .header(CUSTODY_HEADER, "server_v1").post(form).build(),
            )
        val body = sessionObject(result.body)
        if (body.keys != setOf("authenticated", "access_token", "token_type", "expires_in", "user_id", "resumed") ||
            !body.boolean("authenticated") || body.boolean("resumed") || body.string("token_type") != "Bearer" ||
            body.number("expires_in") <= 0
        ) {
            sessionInvalid()
        }
        val (cookie, expiry) = issuedCookie(result.cookies, clock())
        return ServerSession(scope, body.string("user_id"), body.string("access_token"), cookie, expiry)
    }

    suspend fun refresh(session: ServerSession): ServerSession {
        eligible(session)
        val result =
            request(
                Request.Builder().url(scope.endpoint("/auth/session"))
                    .header("Cookie", session.cookie).get().build(),
            )
        // The qualified server refreshes credentials under the same SID. There is no cookie adoption path.
        if (result.cookies.isNotEmpty()) sessionInvalid()
        val body = sessionObject(result.body)
        if (!body.boolean("authenticated")) {
            if (body.keys != setOf("authenticated", "access_token", "resumed", "reason") ||
                body.string("access_token").isNotEmpty() || body.boolean("resumed") ||
                body.string("reason").length > 128
            ) {
                sessionInvalid()
            }
            throw ServerSessionException(ServerSessionException.Reason.RETIRED)
        }
        if (body.keys != setOf("authenticated", "access_token", "resumed", "user_id") ||
            body.string("user_id") != session.userId
        ) {
            sessionInvalid()
        }
        body.boolean("resumed")
        eligible(session)
        return ServerSession(scope, session.userId, body.string("access_token"), session.cookie, session.cookieExpiresAt)
    }

    suspend fun logout(session: ServerSession): Boolean {
        eligible(session)
        val result =
            request(
                Request.Builder().url(scope.endpoint("/api/auth/logout"))
                    .header(CUSTODY_HEADER, "server_v1").header("Cookie", session.cookie)
                    .header("Authorization", "Bearer ${session.accessToken}")
                    .post("{\"session_custody\":\"server_v1\"}".toRequestBody("application/json".toMediaType())).build(),
            )
        val body = sessionObject(result.body)
        if (body.keys != setOf("outcome", "revoked", "queued")) sessionInvalid()
        return when (body.string("outcome")) {
            "revoked" -> body.boolean("revoked") && !body.boolean("queued")
            "queued" -> !body.boolean("revoked") && body.boolean("queued")
            "unconfirmed" -> {
                if (body.boolean("revoked") || body.boolean("queued")) sessionInvalid()
                false
            }
            else -> sessionInvalid()
        }
    }

    private fun eligible(session: ServerSession) {
        if (!scope.matches(session.scope)) sessionInvalid()
        if (!session.cookieExpiresAt.isAfter(clock())) throw ServerSessionException(ServerSessionException.Reason.RETIRED)
    }

    private class Reply(val body: String, val cookies: List<String>, val capability: List<String>)

    private suspend fun request(request: Request): Reply =
        suspendCancellableCoroutine { continuation ->
            val call = http.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(
                object : Callback {
                    override fun onFailure(
                        call: Call,
                        e: IOException,
                    ) {
                        continuation.resumeWith(Result.failure(ServerSessionException(ServerSessionException.Reason.UNAVAILABLE)))
                    }

                    override fun onResponse(
                        call: Call,
                        response: Response,
                    ) {
                        val result =
                            runCatching {
                                response.use {
                                    if (it.code == 401 || it.code == 403) {
                                        throw ServerSessionException(
                                            ServerSessionException.Reason.RETIRED,
                                        )
                                    }
                                    if (it.code != 200) throw ServerSessionException(ServerSessionException.Reason.UNAVAILABLE)
                                    val body = it.body ?: sessionInvalid()
                                    if (body.contentType()?.let { type -> type.type == "application" && type.subtype == "json" } != true ||
                                        body.contentLength() > 32768
                                    ) {
                                        sessionInvalid()
                                    }
                                    val source = body.source()
                                    if (source.request(32769)) sessionInvalid()
                                    val bytes = source.readByteArray()
                                    Reply(
                                        bytes.decodeToString(throwOnInvalidSequence = true),
                                        it.headers.values("Set-Cookie"),
                                        it.headers.values(CUSTODY_HEADER),
                                    )
                                }
                            }.recoverCatching { error ->
                                throw if (error is ServerSessionException) {
                                    error
                                } else {
                                    ServerSessionException(
                                        ServerSessionException.Reason.INVALID,
                                    )
                                }
                            }
                        continuation.resumeWith(result)
                    }
                },
            )
        }

    companion object {
        private const val CUSTODY_HEADER = "X-Astral-Session-Custody"

        internal fun issuedCookie(
            headers: List<String>,
            now: Instant,
        ): Pair<String, Instant> {
            if (headers.size != 1 || headers.single().length > 4608) sessionInvalid()
            val parts = headers.single().split(';').map(String::trim)
            val cookie = parts.first()
            if (!Regex("astral_session=[A-Za-z0-9._~=-]{1,4096}").matches(cookie)) sessionInvalid()
            val attrs = linkedMapOf<String, String>()
            for (part in parts.drop(1)) {
                val pair = part.split('=', limit = 2)
                if (attrs.put(pair[0].lowercase(), pair.getOrElse(1) { "" }) != null) sessionInvalid()
            }
            if (attrs.keys != setOf("path", "httponly", "secure", "samesite", "max-age") ||
                attrs["path"] != "/" || attrs["httponly"] != "" || attrs["secure"] != "" ||
                attrs["samesite"]?.lowercase() != "lax"
            ) {
                sessionInvalid()
            }
            val seconds = attrs["max-age"]?.takeIf { Regex("[1-9][0-9]*").matches(it) }?.toLongOrNull() ?: sessionInvalid()
            val expiry =
                try {
                    now.plusSeconds(seconds)
                } catch (_: Exception) {
                    sessionInvalid()
                }
            return cookie to expiry
        }
    }
}
