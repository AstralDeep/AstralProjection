// Tests for the client-local readiness ladder and the strict v2 backend-selection parse: typed
// fallback reasons for permission denial, missing language and synthesis gaps, and the frozen
// requirement envelope that routes activation between remote and client-local speech.

package com.personalailabs.astraldeep.app.voice

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LocalSpeechReadiness075Test {
    @Test
    fun supportedFactsAdvertiseReadyWithTheExactClientCapabilityBody() {
        val verdict = LocalSpeechReadiness.evaluate(readyFacts())
        assertTrue(verdict.eligible)
        assertEquals(null, verdict.reason)
        val capability = requireNotNull(verdict.capability)
        assertEquals(
            buildJsonObject {
                put("contract", "client_local/v1")
                put("transport", "client_local")
                put("configured_locale", "en-US")
                put("full_duplex", false)
                put("has_microphone", true)
                put("has_audio_output", true)
                put("microphone_permission", "authorized")
                put("recognition_permission", "authorized")
                put("recognition_processing", "guaranteed_local")
                put("recognition_locale", "ready")
                put("recognition_installation", "ready")
                put("synthesis_processing", "guaranteed_local")
                put("synthesis_locale", "ready")
            },
            capability.toJson(),
        )
    }

    @Test
    fun permissionDenialAndUndeterminedKeepTypedFallback() {
        val denied = LocalSpeechReadiness.evaluate(readyFacts(microphonePermission = "denied"))
        assertEquals("microphone_permission_denied", denied.reason)
        assertEquals(null, denied.capability)

        val undetermined = LocalSpeechReadiness.evaluate(readyFacts(microphonePermission = "not_determined"))
        assertEquals("microphone_permission_not_determined", undetermined.reason)

        val restricted = LocalSpeechReadiness.evaluate(readyFacts(microphonePermission = "restricted"))
        assertEquals("microphone_permission_denied", restricted.reason)
    }

    @Test
    fun missingRecognitionLanguageAndInstallationStatesKeepTypedFallback() {
        assertEquals(
            "local_recognition_unavailable",
            LocalSpeechReadiness.evaluate(readyFacts(recognitionServiceAvailable = false)).reason,
        )
        assertEquals(
            "local_processing_not_guaranteed",
            LocalSpeechReadiness.evaluate(readyFacts(recognitionOnDevice = false)).reason,
        )
        assertEquals(
            "local_language_download_required",
            LocalSpeechReadiness.evaluate(readyFacts(recognitionInstallation = "downloadable")).reason,
        )
        val installable = LocalSpeechReadiness.evaluate(readyFacts(recognitionInstallation = "downloadable"))
        assertTrue(installable.installable)
        assertEquals(
            "local_language_installing",
            LocalSpeechReadiness.evaluate(readyFacts(recognitionInstallation = "installing")).reason,
        )
        assertEquals(
            "local_language_install_failed",
            LocalSpeechReadiness.evaluate(readyFacts(recognitionInstallation = "failed")).reason,
        )
        assertEquals(
            "local_recognition_locale_unavailable",
            LocalSpeechReadiness.evaluate(readyFacts(recognitionLocaleState = "unknown")).reason,
        )
    }

    @Test
    fun unprovedInstallationNeverAdvertisesReadiness() {
        for (state in listOf("unknown", "", "unexpected")) {
            assertNull(LocalSpeechReadiness.evaluate(readyFacts(recognitionInstallation = state)).capability)
        }
    }

    @Test
    fun missingSynthesisAndAudioHardwareKeepTypedFallback() {
        assertEquals(
            "local_synthesis_unavailable",
            LocalSpeechReadiness.evaluate(readyFacts(synthesisEngineReady = false)).reason,
        )
        assertEquals(
            "local_synthesis_locale_unavailable",
            LocalSpeechReadiness.evaluate(readyFacts(synthesisLocaleState = "unknown")).reason,
        )
        assertEquals("no_microphone", LocalSpeechReadiness.evaluate(readyFacts(hasMicrophone = false)).reason)
        assertEquals("no_audio_output", LocalSpeechReadiness.evaluate(readyFacts(hasAudioOutput = false)).reason)
    }

    @Test
    fun backendSelectionParsesTheClosedClientLocalEnvelope() {
        val selection = VoiceBackendSelection.fromJson(unavailableSelection())
        assertIs<VoiceBackendSelection.Local>(selection)
        assertEquals("unavailable", selection.status)
        assertEquals("local_recognition_unavailable", selection.reason)
        assertEquals(10, selection.requirements.announcementTtlSeconds)
        assertEquals(500L, selection.requirements.echoSuppressionMilliseconds)
        assertEquals(8000, selection.requirements.maxFinalUnicodeScalars)
        assertEquals("en-US", selection.requirements.configuredLocale)

        val readiness =
            VoiceBackendSelection.fromJson(
                JsonObject(
                    unavailableSelection() +
                        ("status" to JsonPrimitive("requires_client_readiness")) +
                        ("reason" to JsonPrimitive("client_readiness_required")),
                ),
            )
        assertIs<VoiceBackendSelection.Local>(readiness)
        assertEquals("requires_client_readiness", readiness.status)

        val remote =
            VoiceBackendSelection.fromJson(
                buildJsonObject {
                    put("schema_version", "2")
                    put("speech_backend", "llm_factory")
                    put("status", "ready")
                    put("reason", "ready")
                    put("checked_at", "2026-08-28T12:00:00Z")
                    put("expires_at", "2026-08-28T12:00:10Z")
                    put(
                        "supported_transports",
                        kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive("livekit"))),
                    )
                    put(
                        "requirements",
                        buildJsonObject {
                            put("announcement_ttl_seconds", 10)
                            put("configured_locale", "en-US")
                            put("echo_suppression_milliseconds", 500)
                            put("installation_policy", "explicit_user_action_only")
                            put("local_frame_contract", JsonNull)
                            put("max_announcement_utf8_bytes", 600)
                            put("max_final_unicode_scalars", 8000)
                            put("recognition_must_be_local", false)
                            put("requirement_revision", 1)
                            put("session_contract", "voice-rest/v1")
                            put("synthesis_must_be_local", false)
                        },
                    )
                },
            )
        assertIs<VoiceBackendSelection.Remote>(remote)
        assertEquals("ready", remote.status)
    }

    @Test
    fun backendSelectionRejectsMalformedEnvelopes() {
        assertNull(VoiceBackendSelection.fromJson(buildJsonObject { put("schema_version", "1") }))
        assertNull(VoiceBackendSelection.fromJson(JsonObject(unavailableSelection() + ("unexpected" to JsonPrimitive(true)))))
        assertNull(VoiceBackendSelection.fromJson(JsonObject(unavailableSelection() + ("reason" to JsonPrimitive("not a reason")))))
        assertNull(
            VoiceBackendSelection.fromJson(
                JsonObject(unavailableSelection() + ("expires_at" to JsonPrimitive("2026-08-27T12:00:00Z"))),
            ),
        )
        assertNull(
            VoiceBackendSelection.fromJson(
                JsonObject(
                    unavailableSelection() +
                        ("supported_transports" to kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive("livekit")))),
                ),
            ),
        )
        assertNull(
            VoiceBackendSelection.fromJson(
                JsonObject(unavailableSelection() + ("retry_after_seconds" to JsonPrimitive(301))),
            ),
        )
        assertNull(
            VoiceBackendSelection.fromJson(
                JsonObject(
                    unavailableSelection() +
                        (
                            "requirements" to
                                JsonObject(
                                    requireNotNull(unavailableSelection()["requirements"] as? JsonObject) +
                                        ("engine" to JsonPrimitive("forbidden")),
                                )
                        ),
                ),
            ),
        )
    }

    private fun readyFacts(
        hasMicrophone: Boolean = true,
        hasAudioOutput: Boolean = true,
        microphonePermission: String = "authorized",
        recognitionServiceAvailable: Boolean = true,
        recognitionOnDevice: Boolean = true,
        recognitionLocaleState: String = "ready",
        recognitionInstallation: String = "ready",
        synthesisEngineReady: Boolean = true,
        synthesisLocaleState: String = "ready",
    ) = LocalSpeechFacts(
        hasMicrophone = hasMicrophone,
        hasAudioOutput = hasAudioOutput,
        microphonePermission = microphonePermission,
        recognitionServiceAvailable = recognitionServiceAvailable,
        recognitionOnDevice = recognitionOnDevice,
        recognitionLocaleState = recognitionLocaleState,
        recognitionInstallation = recognitionInstallation,
        synthesisEngineReady = synthesisEngineReady,
        synthesisLocaleState = synthesisLocaleState,
    )

    private fun unavailableSelection() =
        Json
            .parseToJsonElement(
                """
                {
                  "schema_version": "2",
                  "speech_backend": "client_local",
                  "status": "unavailable",
                  "reason": "local_recognition_unavailable",
                  "checked_at": "2026-08-28T12:00:00Z",
                  "expires_at": "2026-08-28T12:00:10Z",
                  "supported_transports": ["client_local"],
                  "requirements": {
                    "session_contract": "voice-rest/v2-client-local",
                    "local_frame_contract": "client_local/v1",
                    "configured_locale": "en-US",
                    "recognition_must_be_local": true,
                    "synthesis_must_be_local": true,
                    "installation_policy": "explicit_user_action_only",
                    "requirement_revision": 1,
                    "max_final_unicode_scalars": 8000,
                    "max_announcement_utf8_bytes": 600,
                    "announcement_ttl_seconds": 10,
                    "echo_suppression_milliseconds": 500
                  }
                }
                """.trimIndent(),
            ).let { value -> assertIs<JsonObject>(value) }
}
