// Direct RFC-style Keycloak logout (public client, no secret needed) used as the fallback when the backend's
// own logout endpoint is unreachable; injected endpoint lets tests target a local server.

package com.personalailabs.astraldeep.app.auth

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request

class KeycloakLogout(
    private val logoutEndpoint: String,
    private val client: OkHttpClient = OkHttpClient(),
) {
    suspend fun revoke(
        clientId: String,
        refreshToken: String,
    ): Boolean =
        withContext(Dispatchers.IO) {
            val body =
                FormBody.Builder()
                    .add("client_id", clientId)
                    .add("refresh_token", refreshToken)
                    .build()
            val request = Request.Builder().url(logoutEndpoint).post(body).build()
            runCatching { client.newCall(request).execute().use { it.isSuccessful } }.getOrDefault(false)
        }
}
