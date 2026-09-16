package com.personalailabs.astraldeep.app.auth

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.time.Instant
import java.util.Base64

/** Closed errors intentionally contain no HTTP body, token, cookie, or provider exception. */
class ServerSessionException(val reason: Reason) : Exception("Server session ${reason.name.lowercase()}") {
    enum class Reason { INVALID, UNAVAILABLE, RETIRED, STORAGE }
}

internal fun sessionInvalid(): Nothing = throw ServerSessionException(ServerSessionException.Reason.INVALID)

/** Code-owned backend/client binding. HTTP and non-root backend URLs are never eligible. */
class ServerSessionScope(val backend: String, val issuer: String, val clientId: String, val redirectUri: String) {
    val origin: HttpUrl = backend.toHttpUrlOrNull() ?: sessionInvalid()

    init {
        if (origin.scheme != "https" || origin.encodedPath != "/" || origin.query != null ||
            origin.fragment != null || origin.username.isNotEmpty() || origin.password.isNotEmpty() ||
            issuer.toHttpUrlOrNull()?.scheme != "https" || clientId.isBlank() || redirectUri.isBlank()
        ) {
            sessionInvalid()
        }
    }

    internal fun matches(other: ServerSessionScope): Boolean =
        origin == other.origin && issuer == other.issuer && clientId == other.clientId && redirectUri == other.redirectUri

    internal fun endpoint(path: String): HttpUrl = origin.newBuilder().encodedPath(path).build()

    override fun toString(): String = "ServerSessionScope"
}

/** One AppAuth-validated original code and verifier; no refresh grant is representable. */
class ServerAuthorizationCode internal constructor(
    internal val scope: ServerSessionScope,
    internal val code: String,
    internal val verifier: String,
) {
    private var consumed = false

    init {
        if (code.isEmpty() || code.length > 4096 || code.any { it.code < 33 || it.code > 126 } ||
            !Regex("[A-Za-z0-9._~-]{43,128}").matches(verifier)
        ) {
            sessionInvalid()
        }
    }

    @Synchronized internal fun consume(expected: ServerSessionScope) {
        if (consumed || !scope.matches(expected)) sessionInvalid()
        consumed = true
    }

    override fun toString(): String = "ServerAuthorizationCode(private)"
}

/** A server-issued cookie is retained verbatim; this is never an AppAuth refresh owner. */
class ServerSession internal constructor(
    val scope: ServerSessionScope,
    val userId: String,
    internal val accessToken: String,
    internal val cookie: String,
    internal val cookieExpiresAt: Instant,
) {
    init {
        validateSessionToken(scope, userId, accessToken)
        if (!Regex("astral_session=[A-Za-z0-9._~=-]{1,4096}").matches(cookie)) sessionInvalid()
    }

    internal fun encoded(): String =
        buildJsonObject {
            put("version", 1)
            put("backend", scope.origin.toString())
            put("issuer", scope.issuer)
            put("client_id", scope.clientId)
            put("redirect_uri", scope.redirectUri)
            put("user_id", userId)
            put("access_token", accessToken)
            put("cookie", cookie)
            put("cookie_expires_at", cookieExpiresAt.epochSecond)
        }.toString()

    override fun toString(): String = "ServerSession(private)"

    companion object {
        internal fun decode(
            raw: String,
            scope: ServerSessionScope,
            now: Instant,
        ): ServerSession {
            val obj = sessionObject(raw)
            if (obj.keys !=
                setOf(
                    "version", "backend", "issuer", "client_id", "redirect_uri", "user_id",
                    "access_token", "cookie", "cookie_expires_at",
                ) || obj.number("version") != 1L ||
                obj.string("backend") != scope.origin.toString() || obj.string("issuer") != scope.issuer ||
                obj.string("client_id") != scope.clientId || obj.string("redirect_uri") != scope.redirectUri
            ) {
                sessionInvalid()
            }
            val expiry =
                try {
                    Instant.ofEpochSecond(obj.number("cookie_expires_at"))
                } catch (_: Exception) {
                    sessionInvalid()
                }
            if (!expiry.isAfter(now)) throw ServerSessionException(ServerSessionException.Reason.RETIRED)
            return ServerSession(scope, obj.string("user_id"), obj.string("access_token"), obj.string("cookie"), expiry)
        }
    }
}

/** Token claims are compared for local account binding only; the backend authenticates them. */
internal fun validateSessionToken(
    scope: ServerSessionScope,
    owner: String,
    token: String,
) {
    if (owner.isBlank() || owner.length > 256 || token.length > 16384 ||
        !Regex("[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+").matches(token)
    ) {
        sessionInvalid()
    }
    val claims =
        try {
            Json.parseToJsonElement(Base64.getUrlDecoder().decode(token.split('.')[1]).decodeToString(throwOnInvalidSequence = true)) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: sessionInvalid()
    if (claims.string("iss") != scope.issuer || claims.string("sub") != owner || claims.number("exp") <= 0) sessionInvalid()
}

internal fun JsonObject.string(key: String): String = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: sessionInvalid()

internal fun JsonObject.number(key: String): Long =
    (this[key] as? JsonPrimitive)?.takeIf { !it.isString && Regex("0|[1-9][0-9]*").matches(it.content) }?.longOrNull ?: sessionInvalid()

internal fun JsonObject.boolean(key: String): Boolean =
    when ((this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content) {
        "true" -> true
        "false" -> false
        else -> sessionInvalid()
    }

/** Bounded flat JSON objects only; duplicate fields and nested values are refused. */
internal fun sessionObject(raw: String): JsonObject {
    if (raw.encodeToByteArray().size > 32768) sessionInvalid()
    val keys = mutableSetOf<String>()
    var at = 0

    fun space() {
        while (at < raw.length && raw[at] in " \r\n\t") at++
    }

    fun quoted(): String {
        if (raw.getOrNull(at) != '"') sessionInvalid()
        val start = at++
        while (at < raw.length) {
            when (raw[at++]) {
                '\\' -> {
                    if (at == raw.length) sessionInvalid()
                    at++
                }
                '"' -> return raw.substring(start, at)
            }
        }
        sessionInvalid()
    }
    space()
    if (raw.getOrNull(at++) != '{') sessionInvalid()
    space()
    if (raw.getOrNull(at) != '}') {
        while (true) {
            val key =
                try {
                    (Json.parseToJsonElement(quoted()) as JsonPrimitive).content
                } catch (_: Exception) {
                    sessionInvalid()
                }
            if (!keys.add(key)) sessionInvalid()
            space()
            if (raw.getOrNull(at++) != ':') sessionInvalid()
            space()
            if (raw.getOrNull(at) == '"') {
                quoted()
            } else {
                val start = at
                while (at < raw.length && raw[at] !in ",} \r\n\t") at++
                if (!Regex("true|false|0|[1-9][0-9]*").matches(raw.substring(start, at))) sessionInvalid()
            }
            space()
            if (raw.getOrNull(at) != ',') break
            at++
            space()
        }
    }
    if (raw.getOrNull(at++) != '}') sessionInvalid()
    space()
    if (at != raw.length) sessionInvalid()
    return try {
        Json.parseToJsonElement(raw) as JsonObject
    } catch (_: Exception) {
        sessionInvalid()
    }
}
