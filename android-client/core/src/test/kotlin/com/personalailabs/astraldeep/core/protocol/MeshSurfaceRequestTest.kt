// Exercises mesh management payloads, public-only key validation, and replay exclusions.
package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MeshSurfaceRequestTest {
    private val id = "a".repeat(32)
    private val key = """{"kty":"OKP","crv":"Ed25519","x":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"""

    private fun body(raw: String): JsonObject = Json.parseToJsonElement(raw) as JsonObject

    private fun create(raw: String = key): JsonObject =
        body(
            """{"surface":"mesh","fields":{"label":"Phone","device_key":${JsonPrimitive(raw)},"scopes":"tools:read","ttl_seconds":"3600"}}""",
        )

    @Test
    fun exact_payloads_use_current_owner_transport() {
        val cases =
            mapOf(
                "chrome_open" to body("""{"surface":"mesh","params":{}}"""),
                "chrome_close" to body("""{"surface":"mesh"}"""),
                "chrome_mesh_create" to create(),
                "chrome_mesh_confirm" to body("""{"surface":"mesh","invite_id":"$id"}"""),
                "chrome_mesh_reject" to body("""{"surface":"mesh","invite_id":"$id"}"""),
                "chrome_mesh_remove_invitation" to body("""{"surface":"mesh","invite_id":"$id"}"""),
                "chrome_mesh_revoke" to body("""{"surface":"mesh","member_id":"$id"}"""),
                "chrome_mesh_rename" to body("""{"surface":"mesh","member_id":"$id","fields":{"label":"Desktop"}}"""),
            )
        for ((action, payload) in cases) {
            assertTrue(MeshSurfaceRequest.isEvent(action, payload))
            assertTrue(MeshSurfaceRequest.validPayload(action, payload), action)
            assertFalse(MeshSurfaceRequest.validPayload(action, JsonObject(payload + ("unexpected" to JsonPrimitive(true)))))
            assertFalse(MeshSurfaceRequest.validPayload(action, JsonObject(payload + ("surface" to JsonPrimitive("other")))))
        }
        for (action in listOf("chrome_mesh_identity", "chrome_mesh_redeem", "chrome_mesh_unknown")) {
            assertTrue(MeshSurfaceRequest.isEvent(action, JsonObject(emptyMap())))
            assertFalse(MeshSurfaceRequest.validPayload(action, body("""{"surface":"mesh"}""")))
        }
        assertFalse(MeshSurfaceRequest.isEvent("ordinary", JsonObject(emptyMap())))
    }

    @Test
    fun malformed_fields_and_private_keys_are_denied() {
        val rawKeys =
            listOf(
                "", "{}", "[]", "broken", "x".repeat(2049), key.replace("OKP", "RSA"),
                key.replace("Ed25519", "X25519"), key.replace("AAA\"", "AA=\""), key.replace("AAA\"", "AAB\""),
                key.replace("AAA\"", "AA\""), key.replace("AAA\"", "AA+\""), key.replace("}", ",\"d\":\"secret\"}"),
                key.replace("\"x\":", "\"unknown\":"), key.replace("\"OKP\"", "true"), key.replace("\"AAAA", "0,\"extra\":\"AAAA"),
            )
        for (raw in rawKeys) assertFalse(MeshSurfaceRequest.validPayload("chrome_mesh_create", create(raw)), raw)
        for (field in listOf("label", "scopes", "ttl_seconds", "device_key")) {
            val fields = create()["fields"] as JsonObject
            for (value in listOf(JsonPrimitive(""), JsonPrimitive(true), JsonPrimitive("x".repeat(2050)))) {
                val payload = JsonObject(create() + ("fields" to JsonObject(fields + (field to value))))
                assertFalse(MeshSurfaceRequest.validPayload("chrome_mesh_create", payload))
            }
            assertFalse(
                MeshSurfaceRequest.validPayload(
                    "chrome_mesh_create",
                    JsonObject(
                        create() +
                            ("fields" to JsonObject(fields - field)),
                    ),
                ),
            )
        }
        for (action in listOf("chrome_mesh_revoke", "chrome_mesh_confirm")) {
            val field = if (action == "chrome_mesh_revoke") "member_id" else "invite_id"
            for (value in listOf("", "a".repeat(31), "A".repeat(32), "../forged")) {
                assertFalse(MeshSurfaceRequest.validPayload(action, body("""{"surface":"mesh","$field":"$value"}""")))
            }
        }
        assertFalse(MeshSurfaceRequest.validPayload("chrome_mesh_rename", body("""{"surface":"mesh","member_id":"$id","fields":{"label":true}}""")))
        assertFalse(MeshSurfaceRequest.validPayload("chrome_open", body("""{"surface":"mesh","params":{"foreign":true}}""")))
        assertFalse(MeshSurfaceRequest.validPayload("chrome_close", JsonObject(emptyMap())))
        assertFalse(MeshSurfaceRequest.validPayload("chrome_close", body("""{"surface":true}""")))
    }
}
