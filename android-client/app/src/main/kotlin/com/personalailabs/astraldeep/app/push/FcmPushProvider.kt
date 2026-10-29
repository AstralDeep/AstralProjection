// Connects the configured Firebase SDK token/task callbacks and data-only OS service to the owner-bound application push runtime.
package com.personalailabs.astraldeep.app.push

import android.content.Context
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailabilityLight
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.personalailabs.astraldeep.app.AstralApp
import com.personalailabs.astraldeep.app.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlin.coroutines.resume

interface PushProviderBackend : PushProvider {
    fun deliverAuthorized(data: JsonObject)

    fun retireRegistration(onComplete: (Boolean) -> Unit)
}

class FcmPushProvider(private val context: Context) : PushProviderBackend {
    private var listener: ((JsonObject) -> Unit)? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val tokenOperations = Mutex()

    private fun messaging(): FirebaseMessaging? {
        if (BuildConfig.ASTRAL_FIREBASE_APP_ID.isBlank()) return null
        return try {
            if (FirebaseApp.getApps(context).none { it.name == FirebaseApp.DEFAULT_APP_NAME }) {
                FirebaseApp.initializeApp(
                    context,
                    FirebaseOptions.Builder()
                        .setApplicationId(BuildConfig.ASTRAL_FIREBASE_APP_ID)
                        .setProjectId(BuildConfig.ASTRAL_FIREBASE_PROJECT_ID)
                        .setGcmSenderId(BuildConfig.ASTRAL_FIREBASE_SENDER_ID)
                        .setApiKey(BuildConfig.ASTRAL_FIREBASE_API_KEY).build(),
                )
            }
            FirebaseMessaging.getInstance()
        } catch (_: IllegalStateException) {
            null
        }
    }

    override fun isSupported(): Boolean =
        GoogleApiAvailabilityLight.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS && messaging() != null

    override fun requestToken(onResult: (String?) -> Unit) {
        scope.launch {
            val token =
                tokenOperations.withLock {
                    val sdk = messaging() ?: return@withLock null
                    sdk.isAutoInitEnabled = true
                    suspendCancellableCoroutine<String?> { continuation ->
                        sdk.token.addOnCompleteListener { task ->
                            if (continuation.isActive) continuation.resume(if (task.isSuccessful) task.result else null)
                        }
                    }
                }
            onResult(token)
        }
    }

    override fun retireRegistration(onComplete: (Boolean) -> Unit) {
        messaging()?.isAutoInitEnabled = false
        scope.launch {
            val retired =
                tokenOperations.withLock {
                    val sdk = messaging() ?: return@withLock false
                    sdk.isAutoInitEnabled = false
                    suspendCancellableCoroutine<Boolean> { continuation ->
                        sdk.unregister().addOnCompleteListener { task ->
                            if (continuation.isActive) continuation.resume(task.isSuccessful)
                        }
                    }
                }
            onComplete(retired)
        }
    }

    override fun setMessageListener(onMessage: (JsonObject) -> Unit) {
        listener = onMessage
    }

    override fun deliverAuthorized(data: JsonObject) {
        listener?.invoke(data)
    }
}

class AstralFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (message.notification != null) return
        runBlocking {
            withContext(Dispatchers.Main) {
                (application as AstralApp).pushRuntime.receiveProviderMessage(message.data)
            }
        }
    }

    override fun onRegistered(token: String) {
        runBlocking { withContext(Dispatchers.Main) { (application as AstralApp).pushRuntime.refreshProviderToken() } }
    }

    override fun onNewToken(token: String) {
        runBlocking { withContext(Dispatchers.Main) { (application as AstralApp).pushRuntime.refreshProviderToken() } }
    }
}
