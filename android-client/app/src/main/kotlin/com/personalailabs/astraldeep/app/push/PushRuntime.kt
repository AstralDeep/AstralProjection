// App-side owner of the push destination runtime: binds the pure adapter machine to the
// PushDestinationRest boundary and the provider availability seam, acknowledges
// authentication-gated notification taps, and resets the destination on sign-out or account
// change. MainActivity owns the instance; the adapter machine owns every other decision.

package com.personalailabs.astraldeep.app.push

import android.content.Context
import android.content.Intent
import android.util.Log
import com.personalailabs.astraldeep.core.push.PushEffect
import com.personalailabs.astraldeep.core.push.PushIdentity
import com.personalailabs.astraldeep.core.push.PushLifecycle
import com.personalailabs.astraldeep.core.push.PushPermissionState
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

interface PushProviderBackend : PushProvider {
    fun availabilityReason(): String?
}

class AbsentPushProviderBackend : PushProviderBackend {
    override fun isSupported(): Boolean = false

    override fun requestToken(onResult: (String?) -> Unit) {
        onResult(null)
    }

    override fun setMessageListener(onMessage: (JsonObject) -> Unit) {}

    override fun availabilityReason(): String? = "provider_bridge_absent"
}

class PushRuntime(
    context: Context,
    private val identity: PushIdentity,
    private val rest: PushDestinationRest,
    private val tokenProvider: () -> String?,
    private val providerBackend: PushProviderBackend = AbsentPushProviderBackend(),
    private val inAppListener: ((PushPayload) -> Unit)? = null,
) {
    private val appContext: Context = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var pendingTapId: String? = null
    private var started = false

    var adapter: AndroidNotificationAdapter = buildAdapter()
        private set

    fun start() {
        if (started) return
        started = true
        adapter.start()
    }

    fun onLifecycleActive() {
        machine().onLifecycle(PushLifecycle.Foreground)
        adapter.refreshPermission()
    }

    fun onLifecycleInactive() {
        machine().onLifecycle(PushLifecycle.Background)
    }

    fun refreshPermission() {
        adapter.refreshPermission()
    }

    fun shouldRequestPermission(): Boolean = adapter.shouldRequestPermission()

    fun shouldOfferPermissionRequest(): Boolean = machine().permission == PushPermissionState.NotDetermined

    fun handleTap(intent: Intent?) {
        val tapped = intent?.getStringExtra(EXTRA_TAP_NOTIFICATION_ID)
            ?: intent?.getStringExtra(EXTRA_PROVIDER_NOTIFICATION_ID)
            ?: return
        pendingTapId = tapped
        resolvePendingTap()
    }

    fun onAuthenticated() {
        resolvePendingTap()
        adapter.retryRegistration()
    }

    fun onSignedOut(access: String?) {
        pendingTapId = null
        scope.launch {
            val outcome = rest.revoke(access, identity.deviceId)
            Log.i(TAG, "push destination revoke on sign-out: $outcome")
            rebuild()
        }
    }

    fun onAccountChanged(access: String?) {
        onSignedOut(access)
    }

    private fun resolvePendingTap() {
        val tapped = pendingTapId ?: return
        if (tokenProvider().isNullOrBlank()) return
        pendingTapId = null
        machine().seedAccepted(listOf(tapped))
        scope.launch {
            val outcome = rest.acknowledge(tokenProvider(), identity.deviceId, tapped)
            Log.i(TAG, "push tap acknowledge: $outcome")
        }
    }

    private fun machine() = adapter.machine

    private fun buildAdapter(): AndroidNotificationAdapter =
        AndroidNotificationAdapter(
            appContext,
            providerBackend,
            identity,
            inAppListener = { payload -> inAppListener?.invoke(payload) },
            acknowledgeListener = { pushIdentity, notificationId ->
                scope.launch {
                    val outcome =
                        rest.acknowledge(tokenProvider(), pushIdentity.deviceId, notificationId)
                    Log.i(TAG, "push delivery acknowledge: $outcome")
                }
            },
            enrollListener = { effect -> enroll(effect) },
        )

    private fun rebuild() {
        for (notificationId in machine().accepted) {
            adapter.dismissPresented(notificationId)
        }
        adapter = buildAdapter()
        adapter.start()
        adapter.refreshPermission()
    }

    private fun enroll(effect: PushEffect.EnrollDestination) {
        scope.launch {
            when (val outcome =
                rest.enroll(tokenProvider(), effect.deviceId, effect.platform, effect.token, effect.label)) {
                is PushEnrollOutcome.Accepted -> machine().onEnrollmentAccepted()
                is PushEnrollOutcome.Rejected -> {
                    Log.w(TAG, "push enrollment rejected: ${outcome.code}")
                    machine().onEnrollmentRejected(outcome.transient, outcome.code)
                }
                is PushEnrollOutcome.Unauthenticated ->
                    machine().onEnrollmentRejected(true, "unauthenticated")
            }
        }
    }

    companion object {
        private const val TAG = "PushRuntime"
        const val EXTRA_TAP_NOTIFICATION_ID = "push_tap_notification_id"
        const val EXTRA_PROVIDER_NOTIFICATION_ID = "notification_id"

        fun pushDeviceId(context: Context): String {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val existing = preferences.getString(DEVICE_ID, null)
            if (existing != null && identityMatches(existing)) return existing
            val generated = UUID.randomUUID().toString()
            preferences.edit().putString(DEVICE_ID, generated).apply()
            return generated
        }

        private fun identityMatches(candidate: String): Boolean =
            candidate.length in 8..128 &&
                candidate[0].isLetterOrDigit() &&
                candidate.all { it.isLetterOrDigit() || it == '.' || it == '_' || it == '-' }

        private const val PREFERENCES = "astral_push"
        private const val DEVICE_ID = "push_device_id"
    }
}
