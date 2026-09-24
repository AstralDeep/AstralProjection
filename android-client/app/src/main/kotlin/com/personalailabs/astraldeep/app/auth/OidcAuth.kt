// Keycloak OIDC Authorization-Code+PKCE sign-in via AppAuth's system-browser flow for the public
// astral-mobile client; MainActivity launches authorizeIntent and calls exchange/freshToken to complete and
// refresh sessions.

package com.personalailabs.astraldeep.app.auth

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.personalailabs.astraldeep.app.AppConfig
import kotlinx.coroutines.suspendCancellableCoroutine
import net.openid.appauth.AuthState
import net.openid.appauth.AuthorizationException
import net.openid.appauth.AuthorizationRequest
import net.openid.appauth.AuthorizationResponse
import net.openid.appauth.AuthorizationService
import net.openid.appauth.AuthorizationServiceConfiguration
import net.openid.appauth.ResponseTypeValues
import net.openid.appauth.TokenResponse

class OidcAuth(context: Context) {
    val service = AuthorizationService(context)
    private var pendingServerRequest: AuthorizationRequest? = null

    private val config: AuthorizationServiceConfiguration by lazy {
        val e = keycloakEndpoints(AppConfig.KEYCLOAK_AUTHORITY)
        AuthorizationServiceConfiguration(
            Uri.parse(e.authorizationEndpoint),
            Uri.parse(e.tokenEndpoint),
            null,
            Uri.parse(e.endSessionEndpoint),
        )
    }

    fun authorizeIntent(): Intent {
        return service.getAuthorizationRequestIntent(newRequest())
    }

    private fun newRequest(): AuthorizationRequest =
        AuthorizationRequest.Builder(
            config,
            AppConfig.OIDC_CLIENT_ID,
            ResponseTypeValues.CODE,
            Uri.parse(AppConfig.OIDC_REDIRECT_URI),
        )
            // offline_access enables year-long sessions, not just SSO timeout
            .setScope("openid profile email offline_access")
            .build()

    @Synchronized
    fun authorizeServerIntent(scope: ServerSessionScope): Intent {
        checkScope(scope)
        return newRequest().let { request ->
            pendingServerRequest = request
            service.getAuthorizationRequestIntent(request)
        }
    }

    @Synchronized
    fun serverCode(
        intent: Intent,
        scope: ServerSessionScope,
    ): ServerAuthorizationCode {
        val original = pendingServerRequest
        pendingServerRequest = null
        checkScope(scope)
        val response = AuthorizationResponse.fromIntent(intent)
        if (original == null || response == null || AuthorizationException.fromIntent(intent) != null ||
            response.request.jsonSerializeString() != original.jsonSerializeString() || original.state.isNullOrBlank() ||
            response.state != original.state || original.codeVerifierChallengeMethod != "S256"
        ) {
            sessionInvalid()
        }
        return ServerAuthorizationCode(scope, response.authorizationCode ?: sessionInvalid(), original.codeVerifier ?: sessionInvalid())
    }

    private fun checkScope(scope: ServerSessionScope) {
        if (scope.issuer != AppConfig.KEYCLOAK_AUTHORITY || scope.clientId != AppConfig.OIDC_CLIENT_ID ||
            scope.redirectUri != AppConfig.OIDC_REDIRECT_URI
        ) {
            sessionInvalid()
        }
    }

    suspend fun exchange(intent: Intent): AuthState {
        val response = AuthorizationResponse.fromIntent(intent)
        val authEx = AuthorizationException.fromIntent(intent)
        requireNotNull(response) { authEx?.message ?: "no authorization response" }
        val state = AuthState(response, authEx)
        val tokenResponse =
            suspendCancellableCoroutine { cont ->
                service.performTokenRequest(response.createTokenExchangeRequest()) { tr: TokenResponse?, e ->
                    if (tr != null) {
                        cont.resumeWith(Result.success(tr))
                    } else {
                        cont.resumeWith(Result.failure(e ?: IllegalStateException("token exchange failed")))
                    }
                }
            }
        state.update(tokenResponse, null)
        return state
    }

    suspend fun freshToken(state: AuthState): String =
        suspendCancellableCoroutine { cont ->
            state.performActionWithFreshTokens(service) { accessToken, _, e ->
                if (accessToken != null) {
                    cont.resumeWith(Result.success(accessToken))
                } else {
                    cont.resumeWith(Result.failure(e ?: IllegalStateException("token refresh failed")))
                }
            }
        }

    fun dispose() {
        pendingServerRequest = null
        service.dispose()
    }
}
