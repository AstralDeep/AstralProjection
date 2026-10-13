// Validates the immutable native deployment endpoints and registered OIDC identity.
// AppConfig checks generated BuildConfig values here before transports or sign-in use them.
package com.personalailabs.astraldeep.core.deployment

import java.net.URI

class ClientDeploymentProfile(
    val apiBase: String,
    val websocketUrl: String,
    val keycloakAuthority: String,
    val clientId: String,
    val redirectUri: String,
    allowShippedDebug: Boolean = false,
) {
    init {
        require(clientId == "astral-mobile" && redirectUri == "com.personalailabs.astraldeep:/oauth2redirect") {
            "Registered Android OIDC identity cannot change"
        }
        val shippedDebug =
            allowShippedDebug && apiBase == "http://10.0.2.2:8001" &&
                websocketUrl == "ws://10.0.2.2:8001/ws" && keycloakAuthority == "https://iam.ai.uky.edu/realms/Astral"
        if (!shippedDebug) {
            val api = endpoint(apiBase, "https")
            val websocket = endpoint(websocketUrl, "wss")
            val authority = endpoint(keycloakAuthority, "https")
            require(api.path in setOf("", "/") && websocket.path == "/ws") { "Invalid backend deployment path" }
            require(
                api.host.equals(websocket.host, ignoreCase = true) && effectivePort(api) == effectivePort(websocket),
            ) { "REST and WebSocket deployment origins differ" }
            require(Regex("/(?:[A-Za-z0-9._~-]+/)*realms/[A-Za-z0-9._~-]+").matches(authority.path)) {
                "Invalid Keycloak realm authority"
            }
        }
    }

    private fun endpoint(
        value: String,
        scheme: String,
    ): URI {
        require(value.length in 1..2048 && value.all { it.code in 33..126 }) { "Invalid deployment URI" }
        val uri = runCatching { URI(value) }.getOrElse { throw IllegalArgumentException("Invalid deployment URI") }
        require(
            uri.scheme == scheme && uri.host != null && uri.rawUserInfo == null && uri.rawQuery == null &&
                uri.rawFragment == null && uri.port in -1..65535 && uri.port != 0 && uri.rawPath == uri.path && uri.normalize() == uri,
        ) { "Invalid deployment URI" }
        return uri
    }

    private fun effectivePort(uri: URI): Int = if (uri.port == -1) 443 else uri.port
}
