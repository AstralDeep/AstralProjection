// Validates mesh owner-management payloads before current-connection transport.
// Client-local identity and redemption controls never enter the replay queue.
package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.util.Base64

object MeshSurfaceRequest {
    fun isEvent(
        action: String,
        payload: JsonObject,
    ): Boolean = action.startsWith("chrome_mesh_") || (payload["surface"] as? JsonPrimitive)?.contentOrNull == "mesh"

    fun validPayload(
        action: String,
        payload: JsonObject,
    ): Boolean {
        if (text(payload["surface"]) != "mesh") return false
        val fields = payload["fields"] as? JsonObject
        return when (action) {
            "chrome_open" -> payload.keys == setOf("surface", "params") && (payload["params"] as? JsonObject)?.isEmpty() == true
            "chrome_close" -> payload.keys == setOf("surface")
            "chrome_mesh_confirm", "chrome_mesh_reject", "chrome_mesh_remove_invitation" ->
                payload.keys == setOf("surface", "invite_id") && identity(payload["invite_id"])
            "chrome_mesh_revoke" -> payload.keys == setOf("surface", "member_id") && identity(payload["member_id"])
            "chrome_mesh_rename" ->
                payload.keys == setOf("surface", "member_id", "fields") && identity(payload["member_id"]) &&
                    fields?.keys == setOf("label") && bounded(fields["label"], 256)
            "chrome_mesh_create" ->
                payload.keys == setOf("surface", "fields") &&
                    fields?.keys == setOf("label", "device_key", "scopes", "ttl_seconds") && bounded(fields["label"], 256) &&
                    bounded(fields["scopes"], 256) && bounded(fields["ttl_seconds"], 16) && publicKey(text(fields["device_key"]))
            else -> false
        }
    }

    private fun identity(value: kotlinx.serialization.json.JsonElement?): Boolean = text(value)?.matches(Regex("[a-f0-9]{32}")) == true

    private fun text(value: kotlinx.serialization.json.JsonElement?): String? = (value as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun bounded(
        value: kotlinx.serialization.json.JsonElement?,
        maximum: Int,
    ): Boolean = text(value)?.let { it.isNotEmpty() && it.encodeToByteArray().size <= maximum } == true

    private fun publicKey(raw: String?): Boolean {
        if (raw == null || raw.encodeToByteArray().size > 2048) return false
        val key = runCatching { Json.parseToJsonElement(raw) as? JsonObject }.getOrNull() ?: return false
        if (key.keys != setOf("kty", "crv", "x") || text(key["kty"]) != "OKP" || text(key["crv"]) != "Ed25519") return false
        val x = text(key["x"]) ?: return false
        if (!x.matches(Regex("[A-Za-z0-9_-]{43}"))) return false
        val bytes = runCatching { Base64.getUrlDecoder().decode(x) }.getOrNull() ?: return false
        return bytes.size == 32 && Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) == x
    }
}
