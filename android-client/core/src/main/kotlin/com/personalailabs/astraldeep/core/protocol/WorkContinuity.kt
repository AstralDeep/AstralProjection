// Validates exact server-issued Work continuity requests for the Android surface and current transport.
package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import java.util.UUID

object WorkContinuity {
    const val ACTION = "chrome_work_continuity"

    fun validPayload(payload: JsonObject): Boolean {
        if (payload.keys != setOf("version", "operation_id", "expected_revision", "submission_id")) return false
        val version = payload["version"] as? JsonPrimitive ?: return false
        val revision = payload["expected_revision"] as? JsonPrimitive ?: return false
        if (version.isString || version.longOrNull != 1L || revision.isString ||
            revision.longOrNull?.let { it in 1..9007199254740991L } != true
        ) {
            return false
        }
        return listOf("operation_id", "submission_id").all { key ->
            val value = (payload[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            val identity = value?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            identity?.version() == 4 && identity.toString() == value
        }
    }
}
