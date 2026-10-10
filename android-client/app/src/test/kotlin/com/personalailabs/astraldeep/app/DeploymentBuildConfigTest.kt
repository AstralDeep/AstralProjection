// Verifies AppConfig consumes the exact generated Gradle constants and preserves the registered identity.
// The same test runs for shipped defaults and explicitly configured secure deployment builds.
package com.personalailabs.astraldeep.app

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DeploymentBuildConfigTest {
    @Test
    fun app_configuration_matches_generated_build_identity() {
        assertEquals(BuildConfig.ASTRAL_API_BASE, AppConfig.API_BASE)
        assertEquals(BuildConfig.ASTRAL_WS_URL, AppConfig.WS_URL)
        assertEquals(BuildConfig.ASTRAL_KEYCLOAK_AUTHORITY, AppConfig.KEYCLOAK_AUTHORITY)
        assertEquals("astral-mobile", AppConfig.OIDC_CLIENT_ID)
        assertEquals("com.personalailabs.astraldeep:/oauth2redirect", AppConfig.OIDC_REDIRECT_URI)
        if (BuildConfig.ASTRAL_EXPLICIT_DEPLOYMENT) {
            assertTrue(AppConfig.API_BASE.startsWith("https://"))
            assertTrue(AppConfig.WS_URL.startsWith("wss://"))
        } else if (BuildConfig.DEBUG) {
            assertEquals("http://10.0.2.2:8001", AppConfig.API_BASE)
            assertEquals("ws://10.0.2.2:8001/ws", AppConfig.WS_URL)
            assertEquals("https://iam.ai.uky.edu/realms/Astral", AppConfig.KEYCLOAK_AUTHORITY)
        } else {
            assertEquals("https://sandbox.ai.uky.edu", AppConfig.API_BASE)
            assertEquals("wss://sandbox.ai.uky.edu/ws", AppConfig.WS_URL)
            assertEquals("https://iam.ai.uky.edu/realms/Astral", AppConfig.KEYCLOAK_AUTHORITY)
        }
    }
}
