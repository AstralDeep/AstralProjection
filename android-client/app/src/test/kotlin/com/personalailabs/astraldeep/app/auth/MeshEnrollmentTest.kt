// Verifies mesh key persistence, actual Ed25519 challenge/DPoP signatures, and failed enrollment fences.
// Uses MeshEnrollmentCustody with in-memory protected-storage and deterministic HTTP boundaries.

package com.personalailabs.astraldeep.app.auth

import com.google.crypto.tink.subtle.Ed25519Verify
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest
import java.util.Base64

class MeshEnrollmentTest {
    class Storage : MeshKeyStorage {
        val values = mutableMapOf<String, String>()
        var fail = false

        override fun loadMesh(key: String): String? = values[key]

        override fun saveMesh(
            key: String,
            value: String,
        ): Boolean {
            if (fail) return false
            values[key] = value
            return true
        }

        override fun removeMesh(key: String): Boolean {
            values.remove(key)
            return true
        }

        override fun retainOnlyMesh(key: String?): Boolean {
            if (fail) return false
            values.keys.toList().filter { it != key }.forEach(values::remove)
            return true
        }
    }

    private val memberId = "b".repeat(32)

    private fun custody(
        storage: Storage,
        server: String = "https://app.invalid",
        owner: String = "owner",
    ) =
        MeshEnrollmentCustody(MeshEnrollmentScope(server, "https://iam.invalid/realms/Astral", owner), storage)

    private fun encode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    private fun decode(value: String): ByteArray = Base64.getUrlDecoder().decode(value)

    private fun link(
        owner: String = "owner",
        challenge: ByteArray = ByteArray(32) { 3 },
    ): String {
        val body =
            buildJsonObject {
                put("v", 1)
                put("o", owner)
                put("i", "a".repeat(32))
                put("t", encode(ByteArray(32) { 4 }))
                put("c", encode(challenge))
            }
        return "https://app.invalid/enroll#" + encode(body.toString().encodeToByteArray())
    }

    private fun member(
        key: JsonObject,
        owner: String = "owner",
        status: String = "active",
    ) =
        buildJsonObject {
            put("owner_id", owner)
            put("member_id", memberId)
            put("device_key", key)
            put("status", status)
        }

    private fun session(
        member: JsonObject,
        type: String = "DPoP",
        expires: Int = 300,
    ) =
        buildJsonObject {
            put("access_token", "test-dpop-session")
            put("token_type", type)
            put("expires_in", expires)
            put("member", member)
        }

    private fun body(request: Request): JsonObject {
        val buffer = okio.Buffer()
        request.body!!.writeTo(buffer)
        return Json.parseToJsonElement(buffer.readUtf8()).jsonObject
    }

    private inline fun refuses(action: () -> Unit) {
        val result = runCatching(action)
        assertTrue("expected refusal", result.isFailure)
    }

    @Test
    fun identity_survives_restart_and_other_account_or_server_purges_old_key() {
        val storage = Storage()
        val first = custody(storage).publicIdentity { true }
        assertEquals(first, custody(storage).publicIdentity { true })
        assertEquals(1, storage.values.size)
        val other = custody(storage, owner = "other")
        assertFalse(first == other.publicIdentity { true })
        assertEquals(1, storage.values.size)
        assertTrue(other.retire())
        assertTrue(storage.values.isEmpty())
        custody(storage, server = "https://other.invalid").publicIdentity { true }
        assertTrue(storage.retainOnlyMesh(null))
        assertTrue(storage.values.isEmpty())
    }

    @Test
    fun unsafe_origin_private_jwk_corrupt_storage_and_retired_generation_refuse() {
        for (server in listOf("http://app.invalid", "https://u:p@app.invalid", "https://app.invalid/path", "https://app.invalid?x=1", "https://app.invalid#x")) {
            refuses { custody(Storage(), server) }
        }
        val storage = Storage()
        val client = custody(storage)
        val key = client.publicIdentity { true }
        assertEquals(key, MeshEnrollmentCustody.validatePublicIdentity(key.toString()))
        for (field in listOf("d", "alg", "private_key")) {
            refuses { MeshEnrollmentCustody.validatePublicIdentity(JsonObject(key + (field to JsonPrimitive("secret"))).toString()) }
        }
        refuses { MeshEnrollmentCustody.validatePublicIdentity("{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"AQ\"}") }
        storage.values[client.scope.storageKey] = "{}"
        refuses { client.publicIdentity { true } }
        storage.fail = true
        refuses { client.publicIdentity { true } }
        refuses { custody(Storage()).publicIdentity { false } }
    }

    @Test
    fun challenge_and_dpop_me_acceptance_precede_safe_identity_storage() =
        runBlocking {
            val storage = Storage()
            val client = custody(storage)
            val key = client.publicIdentity { true }
            val verify = Ed25519Verify(decode(key.string("x")))
            var calls = 0
            val id =
                client.redeem(link(), { true }) { request ->
                    calls++
                    assertEquals(null, request.header("Cookie"))
                    when (request.url.encodedPath) {
                        "/api/mesh/enrollment/redeem" -> {
                            assertEquals(null, request.header("Authorization"))
                            val body = body(request)
                            assertEquals(setOf("payload", "signature"), body.keys)
                            verify.verify(decode(body.string("signature")), ByteArray(32) { 3 })
                            session(member(key))
                        }
                        "/api/mesh/nonce" -> {
                            assertEquals(null, request.header("Authorization"))
                            buildJsonObject { put("nonce", "11111111111111111111111111111111.AwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwA") }
                        }
                        "/api/mesh/me" -> {
                            assertEquals("DPoP test-dpop-session", request.header("Authorization"))
                            val parts = request.header("DPoP")!!.split('.')
                            val claims = sessionObject(decode(parts[1]).decodeToString())
                            assertEquals("GET", claims.string("htm"))
                            assertEquals("https://app.invalid/api/mesh/me", claims.string("htu"))
                            assertEquals("11111111111111111111111111111111.AwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwA", claims.string("nonce"))
                            assertEquals("11111111111111111111111111111111.AwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwA", request.header("DPoP-Nonce"))
                            assertEquals(encode(MessageDigest.getInstance("SHA-256").digest("test-dpop-session".encodeToByteArray())), claims.string("ath"))
                            verify.verify(decode(parts[2]), (parts[0] + "." + parts[1]).encodeToByteArray())
                            assertFalse(storage.values.values.single().contains(memberId))
                            buildJsonObject { put("member", member(key)) }
                        }
                        else -> error("unexpected endpoint")
                    }
                }
            assertEquals(memberId, id)
            assertEquals(3, calls)
            assertTrue(storage.values.values.single().contains(memberId))
            assertFalse(storage.values.values.single().contains("test-dpop-session"))
        }

    @Test
    fun missing_key_foreign_owner_or_url_and_bad_challenge_never_send() =
        runBlocking {
            val storage = Storage()
            val client = custody(storage)
            var calls = 0
            val transport: suspend (Request) -> JsonObject = {
                calls++
                error("must not send")
            }
            refuses { client.redeem(link(), { true }, transport) }
            assertTrue(storage.values.isEmpty())
            client.publicIdentity { true }
            val valid = link()
            for (bad in listOf(
                valid.replace("app.invalid", "foreign.invalid"),
                valid.replace("/enroll#", "/enroll?x=1#"),
                valid.replace("/enroll#", "/%65nroll#"),
                link(owner = "other"),
                link(challenge = ByteArray(31)),
                valid + "=",
                valid + "%41",
            )) {
                refuses { client.redeem(bad, { true }, transport) }
            }
            assertEquals(0, calls)
        }

    @Test
    fun foreign_reply_retirement_denial_and_persistence_failure_never_report_success() =
        runBlocking {
            for (failure in listOf("owner", "key", "token", "state", "expired", "me", "retired", "network", "storage")) {
                val storage = Storage()
                val client = custody(storage)
                val key = client.publicIdentity { true }
                var current = true
                val expected =
                    member(
                        if (failure == "key") JsonObject(emptyMap()) else key,
                        owner = if (failure == "owner") "foreign" else "owner",
                        status = if (failure == "state") "revoked" else "active",
                    )
                refuses {
                    client.redeem(link(), { current }) { request ->
                        if (failure == "network") error("denied")
                        when {
                            request.url.encodedPath.endsWith("redeem") -> {
                                if (failure == "retired") current = false
                                session(expected, type = if (failure == "token") "Bearer" else "DPoP", expires = if (failure == "expired") 0 else 300)
                            }
                            request.url.encodedPath.endsWith("nonce") -> buildJsonObject { put("nonce", "11111111111111111111111111111111.AwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwAwA") }
                            else -> {
                                if (failure == "storage") storage.fail = true
                                buildJsonObject { put("member", if (failure == "me") member(key, owner = "foreign") else expected) }
                            }
                        }
                    }
                }
                assertFalse(storage.values.values.single().contains(memberId))
                refuses { client.redeem(link(), { true }) { error("replay refused by host") } }
            }
        }
}
