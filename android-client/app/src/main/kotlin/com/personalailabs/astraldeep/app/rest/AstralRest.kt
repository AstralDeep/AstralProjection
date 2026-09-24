// Thin REST client for surfaces the SDUI WebSocket doesn't carry: audit log reads (tolerant of a few response
// shapes), attachment upload, logout, and per-tool permission toggles.

package com.personalailabs.astraldeep.app.rest

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

data class AuditEvent(
    val id: String?,
    val eventClass: String?,
    val action: String?,
    val outcome: String?,
    val recordedAt: String?,
    val outcomeDetail: String? = null,
    val detail: String? = null,
)

private val auditJson =
    Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

fun parseAudit(raw: String): List<AuditEvent> {
    val root = runCatching { auditJson.parseToJsonElement(raw) }.getOrNull() ?: return emptyList()
    val arr: JsonArray =
        when (root) {
            is JsonArray -> root
            is JsonObject -> (root["events"] ?: root["items"] ?: root["data"]) as? JsonArray ?: JsonArray(emptyList())
            else -> JsonArray(emptyList())
        }
    return arr.mapNotNull { it as? JsonObject }.map { o ->
        fun pick(vararg keys: String): String? = keys.firstNotNullOfOrNull { (o[it] as? JsonPrimitive)?.contentOrNull }
        AuditEvent(
            id = pick("id", "event_id"),
            eventClass = pick("event_class", "class"),
            action = pick("action_type", "action"),
            outcome = pick("outcome", "result"),
            recordedAt = pick("recorded_at", "created_at", "timestamp"),
            outcomeDetail = pick("outcome_detail"),
            detail = metaSummary(o),
        )
    }
}

private fun metaSummary(o: JsonObject): String? {
    val parts = mutableListOf<String>()
    (o["inputs_meta"] as? JsonObject)?.let { if (it.isNotEmpty()) parts.add("inputs: $it") }
    (o["outputs_meta"] as? JsonObject)?.let { if (it.isNotEmpty()) parts.add("outputs: $it") }
    return parts.joinToString("\n").ifBlank { null }
}

data class AttachmentUpload(
    val attachmentId: String,
    val filename: String,
    val category: String,
    val parserStatus: String?,
)

class AstralRest(
    private val baseUrl: String,
    private val client: OkHttpClient = OkHttpClient(),
) {
    suspend fun uploadAttachment(
        token: String,
        filename: String,
        mimeType: String?,
        bytes: ByteArray,
    ): AttachmentUpload? =
        withContext(Dispatchers.IO) {
            val media = (mimeType ?: "application/octet-stream").toMediaTypeOrNull()
            val body =
                MultipartBody.Builder()
                    .setType(MultipartBody.FORM)
                    .addFormDataPart("file", filename, bytes.toRequestBody(media))
                    .build()
            val request =
                Request.Builder()
                    .url("${baseUrl.trimEnd('/')}/api/upload")
                    .header("Authorization", "Bearer $token")
                    .post(body)
                    .build()
            runCatching {
                client.newCall(request).execute().use { resp ->
                    val raw = resp.body?.string().orEmpty()
                    if (!resp.isSuccessful) return@use null
                    val o = auditJson.parseToJsonElement(raw) as? JsonObject ?: return@use null
                    val id = (o["attachment_id"] as? JsonPrimitive)?.contentOrNull ?: return@use null
                    AttachmentUpload(
                        attachmentId = id,
                        filename = (o["filename"] as? JsonPrimitive)?.contentOrNull ?: filename,
                        category = (o["category"] as? JsonPrimitive)?.contentOrNull ?: "file",
                        parserStatus = (o["parser_status"] as? JsonPrimitive)?.contentOrNull,
                    )
                }
            }.getOrNull()
        }

    suspend fun audit(token: String): List<AuditEvent> =
        withContext(Dispatchers.IO) {
            val request =
                Request.Builder()
                    .url("${baseUrl.trimEnd('/')}/api/audit")
                    .header("Authorization", "Bearer $token")
                    .build()
            client.newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) emptyList() else parseAudit(resp.body?.string().orEmpty())
            }
        }

    suspend fun logout(
        token: String,
        refreshToken: String,
        clientId: String,
    ): Boolean =
        withContext(Dispatchers.IO) {
            val body =
                buildJsonObject {
                    put("refresh_token", refreshToken)
                    put("client_id", clientId)
                }.toString()
            val request =
                Request.Builder()
                    .url("${baseUrl.trimEnd('/')}/api/auth/logout")
                    .header("Authorization", "Bearer $token")
                    .post(body.toRequestBody("application/json".toMediaType()))
                    .build()
            runCatching { client.newCall(request).execute().use { it.isSuccessful } }.getOrDefault(false)
        }

    suspend fun setToolPermission(
        token: String,
        agentId: String,
        tool: String,
        kind: String,
        enabled: Boolean,
    ): Boolean =
        withContext(Dispatchers.IO) {
            val body =
                buildJsonObject {
                    putJsonObject("per_tool_permissions") {
                        putJsonObject(tool) { put(kind, enabled) }
                    }
                }.toString()
            val request =
                Request.Builder()
                    .url("${baseUrl.trimEnd('/')}/api/agents/$agentId/permissions")
                    .header("Authorization", "Bearer $token")
                    .put(body.toRequestBody("application/json".toMediaType()))
                    .build()
            client.newCall(request).execute().use { it.isSuccessful }
        }
}
