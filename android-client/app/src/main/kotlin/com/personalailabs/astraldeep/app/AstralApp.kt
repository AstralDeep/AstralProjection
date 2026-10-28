// Owns application-scoped session custody and the Firebase-backed push runtime so background OS callbacks use the same owner fences as the Activity.
package com.personalailabs.astraldeep.app

import android.app.Application
import com.personalailabs.astraldeep.app.auth.ServerSessionCoordinator
import com.personalailabs.astraldeep.app.auth.ServerSessionScope
import com.personalailabs.astraldeep.app.auth.ServerSessionTransport
import com.personalailabs.astraldeep.app.auth.TokenStore
import com.personalailabs.astraldeep.app.push.FcmPushProvider
import com.personalailabs.astraldeep.app.push.PushDestinationRest
import com.personalailabs.astraldeep.app.push.PushRuntime
import com.personalailabs.astraldeep.core.push.PushIdentity
import kotlinx.coroutines.CancellationException

class AstralApp : Application() {
    val tokenStore by lazy { TokenStore(this) }
    val serverScope by lazy {
        if (AppConfig.API_BASE.startsWith("https://")) {
            ServerSessionScope(
                AppConfig.API_BASE,
                AppConfig.KEYCLOAK_AUTHORITY,
                AppConfig.OIDC_CLIENT_ID,
                AppConfig.OIDC_REDIRECT_URI,
            )
        } else {
            null
        }
    }
    val serverSession by lazy { serverScope?.let { ServerSessionCoordinator(ServerSessionTransport(it), tokenStore) } }
    val pushRuntime by lazy {
        PushRuntime(
            this,
            PushIdentity(PushRuntime.pushDeviceId(this)),
            PushDestinationRest(AppConfig.API_BASE, sessionHeaders = { token -> serverSession?.pushRequestHeaders(token).orEmpty() }),
            FcmPushProvider(this),
            tokenStore,
            sessionIncarnation = { token -> serverSession?.pushSessionIncarnation(token) },
            currentCustodyAccess = { incarnation -> serverSession?.pushCurrentAccess(incarnation) },
            restoreAccess = { expected ->
                try {
                    val custody = serverSession
                    if (custody?.restore() == true) custody.refresh().takeIf { PushRuntime.ownerScope(it) == expected } else null
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    null
                }
            },
        )
    }
}
