// Exercises exact safety payloads and envelope correlation through the production Wire encoder.
package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SafetySurfaceRequestTest {
    private val request = "11111111-1111-4111-8111-111111111111"
    private val submission = "22222222-2222-4222-8222-222222222222"

    @Test
    fun safety_wire_preserves_exact_server_payload_and_envelope_identity() {
        val payloads =
            mapOf(
                "chrome_open" to
                    buildJsonObject {
                        put("surface", "safety")
                        putJsonObject("params") {}
                    },
                "chrome_safety_stop" to buildJsonObject { put("surface", "safety") },
                "chrome_safety_resume" to
                    buildJsonObject {
                        put("surface", "safety")
                        put("expected_revision", 9007199254740991L)
                    },
                "chrome_safety_verify" to buildJsonObject { put("surface", "safety") },
            )
        for ((action, payload) in payloads) {
            assertTrue(SafetySurfaceRequest.isEvent(action, payload))
            assertTrue(SafetySurfaceRequest.validPayload(action, payload))
            val frame = Json.parseToJsonElement(Wire.encodeUiEvent(action, null, payload, request, submission)).jsonObject
            assertEquals(payload, frame.getValue("payload"))
            assertEquals(request, frame.getValue("request_generation").jsonPrimitive.content)
            assertEquals(submission, frame.getValue("submission_id").jsonPrimitive.content)
            assertEquals("null", frame.getValue("session_id").toString())
            for ((generation, identifier) in listOf(null to submission, request to null, null to null)) {
                assertFailsWith<IllegalArgumentException> { Wire.encodeUiEvent(action, null, payload, generation, identifier) }
            }
        }
        assertFalse(SafetySurfaceRequest.isEvent("chrome_open", buildJsonObject { put("surface", "theme") }))
        assertFalse(SafetySurfaceRequest.isEvent("ordinary", JsonObject(emptyMap())))
    }

    @Test
    fun malformed_and_cross_surface_payloads_are_denied_before_encoding() {
        val malformed =
            listOf(
                "other" to buildJsonObject { put("surface", "safety") },
                "chrome_safety_stop" to JsonObject(emptyMap()),
                "chrome_safety_stop" to buildJsonObject { putJsonObject("surface") {} },
                "chrome_safety_stop" to buildJsonObject { put("surface", true) },
                "chrome_safety_stop" to buildJsonObject { put("surface", "theme") },
                "chrome_safety_stop" to
                    buildJsonObject {
                        put("surface", "safety")
                        put("owner_id", "forged")
                    },
                "chrome_safety_verify" to
                    buildJsonObject {
                        put("surface", "safety")
                        put("request_generation", request)
                    },
                "chrome_open" to
                    buildJsonObject {
                        put("surface", "safety")
                        put("params", "invalid")
                    },
                "chrome_open" to
                    buildJsonObject {
                        put("surface", "safety")
                        putJsonObject("params") { put("resume", true) }
                    },
                "chrome_safety_resume" to
                    buildJsonObject {
                        put("surface", "safety")
                        putJsonObject("expected_revision") {}
                    },
            )
        for ((action, payload) in malformed) {
            assertFalse(SafetySurfaceRequest.validPayload(action, payload))
            assertFailsWith<IllegalArgumentException> { Wire.encodeUiEvent(action, null, payload, request, submission) }
        }
    }

    @Test
    fun resume_revision_is_a_positive_portable_exact_json_integer() {
        for (value in listOf("true", "null", "0", "-1", "1.0", "1e0", "\"1\"", "9007199254740992", "99999999999999999999999999")) {
            val payload =
                buildJsonObject {
                    put("surface", "safety")
                    put("expected_revision", Json.parseToJsonElement(value))
                }
            assertFalse(SafetySurfaceRequest.validPayload("chrome_safety_resume", payload))
            assertFailsWith<IllegalArgumentException> { Wire.encodeUiEvent("chrome_safety_resume", null, payload, request, submission) }
        }
        val payload =
            buildJsonObject {
                put("surface", "safety")
                put("expected_revision", 1)
            }
        assertTrue(SafetySurfaceRequest.validPayload("chrome_safety_resume", payload))
        assertEquals(JsonPrimitive(1), Json.parseToJsonElement(Wire.encodeUiEvent("chrome_safety_resume", null, payload, request, submission)).jsonObject.getValue("payload").jsonObject["expected_revision"])
    }
}
