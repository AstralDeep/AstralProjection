// Central app configuration: orchestrator WS/REST endpoints (debug via the emulator's 10.0.2.2 alias, release
// via TLS) and Keycloak OIDC constants used by OidcAuth and MainActivity.

package com.personalailabs.astraldeep.app

object AppConfig {
    // Emulator loopback is 10.0.2.2, not localhost
    val WS_URL: String = if (BuildConfig.DEBUG) "ws://10.0.2.2:8001/ws" else "wss://sandbox.ai.uky.edu/ws"

    val API_BASE: String = if (BuildConfig.DEBUG) "http://10.0.2.2:8001" else "https://sandbox.ai.uky.edu"

    const val KEYCLOAK_AUTHORITY: String = "https://iam.ai.uky.edu/realms/Astral"

    const val OIDC_CLIENT_ID: String = "astral-mobile"

    const val OIDC_REDIRECT_URI: String = "com.personalailabs.astraldeep:/oauth2redirect"
}
