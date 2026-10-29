// Verifies closed Work continuity requests and current-connection wire identities without replay authority.
package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkContinuityTest {
    private val operation = "180cd30b-cc38-432d-8349-1851b0d3ad7e"
    private val submission = "fc5c2124-ce23-48d9-927b-9c004d950c10"
    private val generation = "48873d61-2e9b-4f38-bc36-bbfa81d78580"

    private fun payload() = JsonObject(mapOf("version" to JsonPrimitive(1), "operation_id" to JsonPrimitive(operation), "expected_revision" to JsonPrimitive(3), "submission_id" to JsonPrimitive(submission)))

    @Test fun exactSafePayloadIsAccepted() {
        assertTrue(WorkContinuity.validPayload(payload()))
        assertTrue(WorkContinuity.validPayload(JsonObject(payload() + ("expected_revision" to JsonPrimitive(9007199254740991L)))))
    }

    @Test fun malformedOrExtraAuthorityIsDenied() {
        for ((key, value) in listOf("version" to JsonPrimitive(true), "version" to JsonPrimitive("1"), "version" to JsonPrimitive(2), "operation_id" to JsonPrimitive("foreign"), "expected_revision" to JsonPrimitive(0), "expected_revision" to JsonPrimitive(true), "expected_revision" to JsonPrimitive("3"), "expected_revision" to JsonPrimitive(3.0), "expected_revision" to JsonPrimitive(9007199254740992L), "submission_id" to JsonPrimitive(submission.uppercase()), "token" to JsonPrimitive("private"))) {
            assertFalse(WorkContinuity.validPayload(JsonObject(payload() + (key to value))))
        }
        assertFalse(WorkContinuity.validPayload(JsonObject(emptyMap())))
    }

    @Test fun wireKeepsExactPayloadAndCorrelatesCapturedSubmission() {
        val frame = Json.parseToJsonElement(Wire.encodeUiEvent(WorkContinuity.ACTION, null, payload(), generation, submission)).jsonObject
        assertEquals(payload(), frame["payload"])
        assertEquals(JsonPrimitive(submission), frame["submission_id"])
        assertEquals(JsonPrimitive(generation), frame["request_generation"])
    }

    @Test(expected = IllegalArgumentException::class)
    fun wireRefusesMissingCurrentRequestIdentity() {
        Wire.encodeUiEvent(WorkContinuity.ACTION, null, payload())
    }

    @Test(expected = IllegalArgumentException::class)
    fun wireRefusesReplacingTheCapturedSubmission() {
        Wire.encodeUiEvent(WorkContinuity.ACTION, null, payload(), generation, generation)
    }
}
