// Validates the compiled deployment profile before exposing endpoints to the app.
// Gradle retains the shipped defaults and permits only explicit secure deployment overrides.

package com.personalailabs.astraldeep.app

import com.personalailabs.astraldeep.core.deployment.ClientDeploymentProfile

object AppConfig {
    private val deployment =
        ClientDeploymentProfile(
            BuildConfig.ASTRAL_API_BASE,
            BuildConfig.ASTRAL_WS_URL,
            allowShippedDebug = BuildConfig.DEBUG && !BuildConfig.ASTRAL_EXPLICIT_DEPLOYMENT,
        )

    val WS_URL: String = deployment.websocketUrl
    val API_BASE: String = deployment.apiBase
}
