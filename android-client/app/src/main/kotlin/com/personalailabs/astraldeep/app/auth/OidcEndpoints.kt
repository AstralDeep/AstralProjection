// Derives Keycloak's well-known OIDC endpoint paths from a realm authority string, purely (no discovery
// round-trip); used by OidcAuth and KeycloakLogout.

package com.personalailabs.astraldeep.app.auth

data class OidcEndpoints(
    val authorizationEndpoint: String,
    val tokenEndpoint: String,
    val endSessionEndpoint: String,
)

fun keycloakEndpoints(authority: String): OidcEndpoints {
    val base = authority.trimEnd('/')
    return OidcEndpoints(
        authorizationEndpoint = "$base/protocol/openid-connect/auth",
        tokenEndpoint = "$base/protocol/openid-connect/token",
        endSessionEndpoint = "$base/protocol/openid-connect/logout",
    )
}
