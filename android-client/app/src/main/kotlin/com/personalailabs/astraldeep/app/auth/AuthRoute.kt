// Pure decision for where auth routes after a silent-refresh attempt: a definitive OAuth rejection signs out
// with an explanation, a transient failure keeps the cached session. Used by MainActivity.

package com.personalailabs.astraldeep.app.auth

import net.openid.appauth.AuthorizationException
import java.io.IOException

data class AuthRoute(val token: String?, val error: String?)

// Only a definitive OAuth rejection signs out; transient errors don't
fun routeAfterRefresh(
    result: Result<String>,
    cachedToken: String? = null,
): AuthRoute =
    result.fold(
        onSuccess = { AuthRoute(token = it, error = null) },
        onFailure = { e ->
            if (cachedToken != null && isTransientRefreshFailure(e)) {
                AuthRoute(token = cachedToken, error = null)
            } else {
                AuthRoute(token = null, error = "Session expired — sign in again")
            }
        },
    )

private fun isTransientRefreshFailure(e: Throwable): Boolean =
    when (e) {
        is AuthorizationException -> e.type != AuthorizationException.TYPE_OAUTH_TOKEN_ERROR
        is IOException -> true
        else -> false
    }
