// Exercises compiled deployment endpoint boundaries without Android, network access or credentials.
// These denials complement the Gradle profile gate and AppConfig's production validation.
package com.personalailabs.astraldeep.core.deployment

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ClientDeploymentProfileTest {
    private val valid =
        listOf(
            "https://example.invalid",
            "wss://example.invalid/ws",
            "https://iam.example.invalid/realms/Astral",
            "astral-mobile",
            "com.personalailabs.astraldeep:/oauth2redirect",
        )

    private fun profile(
        values: List<String> = valid,
        allowDebug: Boolean = false,
    ) =
        ClientDeploymentProfile(values[0], values[1], values[2], values[3], values[4], allowDebug)

    @Test
    fun secure_profile_retains_exact_compiled_values() {
        val deployment = profile()
        assertEquals(valid, listOf(deployment.apiBase, deployment.websocketUrl, deployment.keycloakAuthority, deployment.clientId, deployment.redirectUri))
        profile(valid.toMutableList().apply { this[0] = "https://example.invalid:443/" })
        profile(valid.toMutableList().apply { this[1] = "wss://example.invalid:443/ws" })
        profile(valid.toMutableList().apply { this[0] = "https://EXAMPLE.invalid" })
        profile(listOf("https://[::1]:9443", "wss://[::1]:9443/ws", valid[2], valid[3], valid[4]))
        profile(listOf("https://ad-bwq-web:9443", "wss://ad-bwq-web:9443/ws", "https://ad-bwq-keycloak:8443/realms/astral-bwq-synthetic", valid[3], valid[4]))
    }

    @Test
    fun unsafe_or_malformed_endpoints_are_denied_before_any_transport() {
        val invalid =
            listOf(
                0 to "", 0 to " https://example.invalid", 0 to "https://example.invalid\n", 0 to "https://éxample.invalid",
                0 to "http://example.invalid", 0 to "https://owner:secret@example.invalid", 0 to "https://example.invalid/api",
                0 to "https://example.invalid?key=value", 0 to "https://example.invalid#fragment", 0 to "https://example.invalid:0",
                0 to "https://example.invalid:65536", 0 to "https://example.invalid:-1", 0 to "https://[invalid",
                0 to "https://example.invalid/../", 0 to "x".repeat(2049), 0 to "https:///missing-host",
                1 to "ws://example.invalid/ws", 1 to "wss://foreign.invalid/ws", 1 to "wss://example.invalid:9443/ws",
                1 to "wss://example.invalid/other", 1 to "wss://example.invalid/ws?token=value", 1 to "wss://example.invalid/ws#fragment",
                2 to "http://iam.example.invalid/realms/Astral", 2 to "https://iam.example.invalid", 2 to "https://iam.example.invalid/realms/Astral/",
                2 to "https://iam.example.invalid/realms/%41stral", 2 to "https://owner:secret@iam.example.invalid/realms/Astral",
                2 to "https://iam.example.invalid/realms/Astral?key=value", 2 to "https://iam.example.invalid/realms/Astral#fragment",
                3 to "other-client", 3 to "", 4 to "other:/oauth2redirect", 4 to "com.personalailabs.astraldeep:/oauth2redirect?code=value",
            )
        for ((position, value) in invalid) {
            assertFailsWith<IllegalArgumentException> { profile(valid.toMutableList().apply { this[position] = value }) }
        }
    }

    @Test
    fun debug_compatibility_is_limited_to_the_exact_existing_compiled_defaults() {
        val debug =
            valid.toMutableList().apply {
                this[0] = "http://10.0.2.2:8001"
                this[1] = "ws://10.0.2.2:8001/ws"
                this[2] = "https://iam.ai.uky.edu/realms/Astral"
            }
        profile(debug, allowDebug = true)
        profile(allowDebug = true)
        assertFailsWith<IllegalArgumentException> { profile(debug) }
        for ((position, value) in listOf(0 to "http://foreign.invalid:8001", 1 to "ws://10.0.2.2:8002/ws", 2 to valid[2])) {
            assertFailsWith<IllegalArgumentException> { profile(debug.toMutableList().apply { this[position] = value }, allowDebug = true) }
        }
    }
}
