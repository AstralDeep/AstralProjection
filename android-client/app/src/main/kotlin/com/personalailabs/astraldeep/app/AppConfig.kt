// Validates the compiled deployment profile before exposing endpoints to MainActivity and OidcAuth.
// Gradle retains the shipped defaults and permits only explicit secure deployment overrides.

package com.personalailabs.astraldeep.app

import com.personalailabs.astraldeep.core.deployment.ClientDeploymentProfile

object AppConfig {
    private val deployment =
        ClientDeploymentProfile(
            BuildConfig.ASTRAL_API_BASE,
            BuildConfig.ASTRAL_WS_URL,
            BuildConfig.ASTRAL_KEYCLOAK_AUTHORITY,
            BuildConfig.ASTRAL_OIDC_CLIENT_ID,
            BuildConfig.ASTRAL_OIDC_REDIRECT_URI,
            allowShippedDebug = BuildConfig.DEBUG && !BuildConfig.ASTRAL_EXPLICIT_DEPLOYMENT,
        )

    val WS_URL: String = deployment.websocketUrl
    val API_BASE: String = deployment.apiBase
    val KEYCLOAK_AUTHORITY: String = deployment.keycloakAuthority
    val OIDC_CLIENT_ID: String = deployment.clientId
    val OIDC_REDIRECT_URI: String = deployment.redirectUri
}
