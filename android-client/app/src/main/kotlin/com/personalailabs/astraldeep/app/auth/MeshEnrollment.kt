// Protected account/server-scoped Ed25519 identity and possession-bound mesh enrollment.
// AppViewModel supplies current owner/navigation fences; host IAM approves the member session.

package com.personalailabs.astraldeep.app.auth

import com.google.crypto.tink.subtle.Ed25519Sign
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.Callback
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit

class MeshEnrollmentException : Exception("Device enrollment was not completed")

interface MeshKeyStorage {
    fun loadMesh(key: String): String?

    fun saveMesh(
        key: String,
        value: String,
    ): Boolean

    fun removeMesh(key: String): Boolean

    fun retainOnlyMesh(key: String?): Boolean
}

class MeshEnrollmentScope(server: String, val issuer: String, val owner: String) {
    val origin: HttpUrl = server.toHttpUrlOrNull() ?: meshInvalid()
    val storageKey: String

    init {
        if (origin.scheme != "https" || origin.encodedPath != "/" || origin.query != null || origin.fragment != null ||
            origin.username.isNotEmpty() || origin.password.isNotEmpty() || issuer.isBlank() || owner.isBlank() || owner.length > 256
        ) {
            meshInvalid()
        }
        storageKey =
            digest(listOf(origin.toString(), issuer, owner).joinToString("\u0000").encodeToByteArray())
                .joinToString("") { "%02x".format(it) }
    }

    fun same(other: MeshEnrollmentScope): Boolean = origin == other.origin && issuer == other.issuer && owner == other.owner

    override fun toString(): String = "MeshEnrollmentScope"
}

internal fun meshInvalid(): Nothing = throw MeshEnrollmentException()

private fun digest(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

class MeshEnrollmentCustody(val scope: MeshEnrollmentScope, private val storage: MeshKeyStorage) {
    private class Record(val seed: ByteArray, val memberId: String)

    private fun record(
        create: Boolean,
        current: () -> Boolean,
    ): Record {
        if (!current()) meshInvalid()
        if (!storage.retainOnlyMesh(scope.storageKey)) meshInvalid()
        val raw = storage.loadMesh(scope.storageKey)
        if (raw != null) {
            val body = sessionObject(raw)
            if (body.keys != setOf("seed", "member_id")) meshInvalid()
            val seed = decode(body.string("seed"))
            if (seed.size != 32) meshInvalid()
            return Record(seed, body.string("member_id"))
        }
        if (!create) meshInvalid()
        val value = Record(Ed25519Sign.KeyPair.newKeyPair().privateKey, "")
        if (!current() || !storage.saveMesh(scope.storageKey, encoded(value))) meshInvalid()
        return value
    }

    private fun encoded(record: Record): String =
        buildJsonObject {
            put("seed", encode(record.seed))
            put("member_id", record.memberId)
        }.toString()

    private fun identity(record: Record): JsonObject =
        buildJsonObject {
            put("kty", "OKP")
            put("crv", "Ed25519")
            put("x", encode(Ed25519Sign.KeyPair.newKeyPairFromSeed(record.seed).publicKey))
        }

    fun publicIdentity(current: () -> Boolean): JsonObject = identity(record(true, current))

    fun retire(): Boolean = storage.removeMesh(scope.storageKey)

    suspend fun redeem(
        link: String,
        current: () -> Boolean,
        transport: suspend (Request) -> JsonObject = MeshEnrollmentHttp()::request,
    ): String {
        val record = record(false, current)
        val publicKey = identity(record)
        val url = link.toHttpUrlOrNull() ?: meshInvalid()
        if (link.length > 8192 || url.scheme != scope.origin.scheme || url.host != scope.origin.host || url.port != scope.origin.port ||
            url.encodedPath != "/enroll" || url.query != null || url.username.isNotEmpty() || url.password.isNotEmpty() ||
            url.encodedFragment != url.fragment
        ) {
            meshInvalid()
        }
        val payload = url.fragment ?: meshInvalid()
        val fields = sessionObject(decode(payload).decodeToString(throwOnInvalidSequence = true))
        if (fields.keys != setOf("v", "o", "i", "t", "c") || fields.number("v") != 1L || fields.string("o") != scope.owner ||
            !Regex("[a-f0-9]{32}").matches(fields.string("i")) || decode(fields.string("t")).size != 32 ||
            decode(fields.string("c")).size != 32
        ) {
            meshInvalid()
        }
        val body =
            buildJsonObject {
                put("payload", payload)
                put("signature", encode(Ed25519Sign(record.seed).sign(decode(fields.string("c")))))
            }
        if (!current()) meshInvalid()
        val reply = transport(request("/api/mesh/enrollment/redeem", body))
        if (!current() || reply.string("token_type") != "DPoP" || reply.number("expires_in") <= 0) meshInvalid()
        val access = reply.string("access_token")
        if (access.isEmpty() || access.length > 16384) meshInvalid()
        val memberId = member(reply["member"] as? JsonObject, publicKey)
        val nonceReply =
            transport(
                request(
                    "/api/mesh/nonce",
                    buildJsonObject {
                        put("owner_id", scope.owner)
                        put("member_id", memberId)
                    },
                ),
            )
        if (!current()) meshInvalid()
        val nonce = nonceReply.string("nonce")
        if (nonce.length !in 1..256) meshInvalid()
        val target = scope.origin.newBuilder().encodedPath("/api/mesh/me").build()
        val header =
            buildJsonObject {
                put("typ", "dpop+jwt")
                put("alg", "EdDSA")
                put("jwk", publicKey)
            }
        val claims =
            buildJsonObject {
                put("jti", UUID.randomUUID().toString().replace("-", ""))
                put("htm", "GET")
                put("htu", target.toString())
                put("iat", Instant.now().epochSecond)
                put("nonce", nonce)
                put("ath", encode(digest(access.encodeToByteArray())))
            }
        val signing = encode(header.toString().encodeToByteArray()) + "." + encode(claims.toString().encodeToByteArray())
        val proof = signing + "." + encode(Ed25519Sign(record.seed).sign(signing.encodeToByteArray()))
        val verify =
            request("/api/mesh/me", null).newBuilder()
                .header("Authorization", "DPoP $access").header("DPoP", proof).header("DPoP-Nonce", nonce).build()
        if (!current()) meshInvalid()
        val verified = transport(verify)
        if (!current() || member(verified["member"] as? JsonObject, publicKey) != memberId ||
            !storage.saveMesh(scope.storageKey, encoded(Record(record.seed, memberId)))
        ) {
            meshInvalid()
        }
        return memberId
    }

    private fun member(
        value: JsonObject?,
        key: JsonObject,
    ): String {
        val member = value ?: meshInvalid()
        if (member.string("owner_id") != scope.owner || member["device_key"] != key || member.string("status") != "active") meshInvalid()
        return member.string("member_id").also { if (!Regex("[a-f0-9]{32}").matches(it)) meshInvalid() }
    }

    private fun request(
        path: String,
        body: JsonObject?,
    ): Request =
        Request.Builder().url(scope.origin.newBuilder().encodedPath(path).build())
            .header("Cache-Control", "no-store").header("Pragma", "no-cache")
            .apply { if (body != null) post(body.toString().toRequestBody("application/json".toMediaType())) else get() }.build()

    companion object {
        fun validatePublicIdentity(value: String): JsonObject {
            val key = sessionObject(value)
            if (key.keys != setOf("kty", "crv", "x") || key.string("kty") != "OKP" || key.string("crv") != "Ed25519" ||
                decode(key.string("x")).size != 32
            ) {
                meshInvalid()
            }
            return key
        }

        private fun encode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

        private fun decode(value: String): ByteArray {
            if (value.isEmpty() || value.length > 8192 || !Regex("[A-Za-z0-9_-]+").matches(value)) meshInvalid()
            return runCatching { Base64.getUrlDecoder().decode(value) }.getOrElse { meshInvalid() }
                .also { if (encode(it) != value) meshInvalid() }
        }
    }
}

class MeshEnrollmentHttp(client: OkHttpClient = OkHttpClient()) {
    private val http =
        client.newBuilder().cache(null).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
            .callTimeout(30, TimeUnit.SECONDS).apply {
                interceptors().clear()
                networkInterceptors().clear()
            }.build()

    suspend fun request(request: Request): JsonObject =
        suspendCancellableCoroutine { continuation ->
            val call = http.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(
                object : Callback {
                    override fun onFailure(
                        call: Call,
                        e: IOException,
                    ) {
                        continuation.resumeWith(Result.failure(MeshEnrollmentException()))
                    }

                    override fun onResponse(
                        call: Call,
                        response: Response,
                    ) {
                        val result =
                            runCatching {
                                response.use {
                                    if (it.code != 200 || it.request.url != request.url || it.headers("Set-Cookie").isNotEmpty()) {
                                        meshInvalid()
                                    }
                                    val body = it.body ?: meshInvalid()
                                    if (body.contentType()?.let {
                                                type ->
                                            type.type == "application" && type.subtype == "json"
                                        } != true || body.contentLength() > 32768
                                    ) {
                                        meshInvalid()
                                    }
                                    val source = body.source()
                                    if (source.request(32769)) meshInvalid()
                                    val bytes = source.buffer.readByteArray()
                                    Json.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence = true)).jsonObject
                                }
                            }
                        continuation.resumeWith(result)
                    }
                },
            )
        }
}
