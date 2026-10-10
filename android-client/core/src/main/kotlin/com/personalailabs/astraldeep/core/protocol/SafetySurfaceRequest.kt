// Validates the server-owned safety control payload before current-connection transport.
// Wire keeps correlation in the envelope and OrchestratorClient prevents queued replay.
package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

object SafetySurfaceRequest {
    fun isEvent(
        action: String,
        payload: JsonObject,
    ): Boolean =
        action in setOf("chrome_safety_stop", "chrome_safety_resume", "chrome_safety_verify") ||
            (payload["surface"] as? JsonPrimitive)?.contentOrNull == "safety"

    fun validPayload(
        action: String,
        payload: JsonObject,
    ): Boolean {
        val fields =
            when (action) {
                "chrome_open" -> setOf("surface", "params")
                "chrome_safety_stop", "chrome_safety_verify" -> setOf("surface")
                "chrome_safety_resume" -> setOf("surface", "expected_revision")
                else -> return false
            }
        val surface = payload["surface"] as? JsonPrimitive ?: return false
        if (!surface.isString || surface.content != "safety" || payload.keys != fields) return false
        if (action == "chrome_open") return (payload["params"] as? JsonObject)?.isEmpty() == true
        if (action == "chrome_safety_resume") {
            val revision = payload["expected_revision"] as? JsonPrimitive ?: return false
            if (revision.isString || !Regex("[1-9][0-9]*").matches(revision.content)) return false
            return revision.content.toLongOrNull()?.let { it <= 9007199254740991L } == true
        }
        return true
    }
}
