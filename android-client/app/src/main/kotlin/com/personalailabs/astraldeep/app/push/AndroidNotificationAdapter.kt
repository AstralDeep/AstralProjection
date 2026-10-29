// Binds the owner-session notification machine to Android permission, provider callbacks, OS notices and opaque tap intents.

package com.personalailabs.astraldeep.app.push

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.personalailabs.astraldeep.app.MainActivity
import com.personalailabs.astraldeep.app.R
import com.personalailabs.astraldeep.core.push.MessageReceipt
import com.personalailabs.astraldeep.core.push.NotificationPushAdapter
import com.personalailabs.astraldeep.core.push.OsNotificationSpec
import com.personalailabs.astraldeep.core.push.PushBinding
import com.personalailabs.astraldeep.core.push.PushChannels
import com.personalailabs.astraldeep.core.push.PushEffect
import com.personalailabs.astraldeep.core.push.PushIdentity
import com.personalailabs.astraldeep.core.push.PushPayload
import com.personalailabs.astraldeep.core.push.RegistrationState
import com.personalailabs.astraldeep.core.push.displayIdFor
import kotlinx.serialization.json.JsonObject
import java.security.MessageDigest

interface PushProvider {
    fun isSupported(): Boolean

    fun requestToken(onResult: (String?) -> Unit)

    fun setMessageListener(onMessage: (JsonObject) -> Unit)
}

class AndroidNotificationAdapter(
    context: Context,
    private val provider: PushProvider,
    private val identity: PushIdentity,
    ownerSessionId: String,
    val machine: NotificationPushAdapter = NotificationPushAdapter(identity, ownerSessionId),
    private val inAppListener: ((PushPayload) -> Unit)? = null,
    private val acknowledgeListener: ((PushBinding, String) -> Unit)? = null,
    private val enrollListener: ((PushEffect.EnrollDestination) -> Unit)? = null,
    private val revokeListener: ((PushEffect.RevokeDestination) -> Unit)? = null,
) {
    private val appContext: Context = context.applicationContext
    private val notifications = NotificationManagerCompat.from(appContext)
    private var started = false
    private var closed = false
    private var tokenRequest = 0L
    private var dismissReceiver: BroadcastReceiver? = null
    private val scopeTag =
        MessageDigest.getInstance("SHA-256")
            .digest("${machine.ownerSessionId}:${identity.deviceId}".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) } + ":"

    init {
        require(machine.ownerSessionId == ownerSessionId) { "owner_session" }
    }

    @Synchronized
    fun start() {
        if (closed || started) return
        started = true
        createChannels()
        registerDismissReceiver()
        refreshPermission()
        machine.seedAccepted(activeNotificationIds())
        val supported =
            try {
                provider.isSupported()
            } catch (_: RuntimeException) {
                false
            }
        execute(machine.onAvailability(supported))
    }

    @Synchronized
    fun refreshPermission(requestCompleted: Boolean = false) {
        if (!started) return
        val granted =
            Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        execute(machine.onPermissionReport(granted, notifications.areNotificationsEnabled(), requestCompleted))
    }

    @Synchronized
    fun onPermissionResult(granted: Boolean) {
        if (!started || closed) return
        execute(machine.onPermissionReport(granted, notifications.areNotificationsEnabled(), requestCompleted = true))
    }

    fun shouldRequestPermission(): Boolean =
        !closed && Build.VERSION.SDK_INT >= 33 &&
            machine.permission == com.personalailabs.astraldeep.core.push.PushPermissionState.NotDetermined &&
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED

    @Synchronized
    fun onMessage(
        data: JsonObject,
        binding: PushBinding,
    ): MessageReceipt {
        if (!started || closed) return MessageReceipt.NotPermitted
        refreshPermission()
        val receipt = machine.onMessage(data, binding)
        if (receipt is MessageReceipt.Accepted) execute(receipt.effects)
        return receipt
    }

    @Synchronized
    fun onProviderToken(token: String?) {
        if (!started || closed) return
        tokenRequest += 1
        execute(machine.onToken(token))
    }

    @Synchronized
    fun onEnrollmentAccepted(
        effect: PushEffect.EnrollDestination,
        serverTokenGeneration: Long,
        serverDestinationRevision: Long? = null,
    ) {
        if (effect.ownerSessionId != machine.ownerSessionId || effect.deviceId != identity.deviceId) return
        require(serverTokenGeneration > 0) { "server_token_generation" }
        if (!started || closed || effect.tokenGeneration != machine.tokenGeneration ||
            machine.permission != com.personalailabs.astraldeep.core.push.PushPermissionState.Granted ||
            machine.registration != RegistrationState.Enrolling
        ) {
            if (machine.binding ==
                effect.binding.copy(
                    serverTokenGeneration = serverTokenGeneration,
                    serverDestinationRevision = serverDestinationRevision,
                )
            ) {
                return
            }
            revokeListener?.invoke(
                PushEffect.RevokeDestination(
                    effect.binding.copy(
                        serverTokenGeneration = serverTokenGeneration,
                        serverDestinationRevision = serverDestinationRevision,
                    ),
                ),
            )
            return
        }
        execute(machine.onEnrollmentAccepted(effect.tokenGeneration, serverTokenGeneration, serverDestinationRevision))
        val binding = machine.binding ?: return
        try {
            provider.setMessageListener { data -> onMessage(data, binding) }
        } catch (_: RuntimeException) {
            execute(machine.onAvailability(false, "provider_listener_failed"))
        }
    }

    @Synchronized
    fun onEnrollmentRejected(
        effect: PushEffect.EnrollDestination,
        transient: Boolean,
        code: String,
    ) {
        if (!started || closed || effect.ownerSessionId != machine.ownerSessionId || effect.deviceId != identity.deviceId) return
        execute(machine.onEnrollmentRejected(transient, code, effect.tokenGeneration))
    }

    @Synchronized
    fun close() {
        if (closed) return
        closed = true
        started = false
        tokenRequest += 1
        val effects = machine.endSession()
        activeNotificationIds().forEach { cancel(it) }
        try {
            execute(effects)
            provider.setMessageListener { _ -> }
        } finally {
            dismissReceiver?.let { appContext.unregisterReceiver(it) }
            dismissReceiver = null
        }
    }

    @Synchronized
    fun notificationIdFromTap(intent: Intent?): String? {
        if (!started || closed) return null
        val binding = machine.binding ?: return null
        val id = intent?.getStringExtra(EXTRA_NOTIFICATION_ID) ?: return null
        if (intent.action != ACTION_OPEN || !PushPayload.NOTIFICATION_ID_REGEX.matches(id) || intent.data != tapUri(id)) return null
        if (intent.getLongExtra(EXTRA_GENERATION, -1) != binding.serverTokenGeneration) return null
        if (intent.getLongExtra(EXTRA_REVISION, -1L) != (binding.serverDestinationRevision ?: -1L)) return null
        return id
    }

    @Synchronized
    fun retryRegistration() {
        if (!started || closed) return
        execute(machine.retryRegistration())
    }

    fun dismissPresented(notificationId: String) {
        machine.onDismissed(notificationId)
        cancel(notificationId)
    }

    private fun execute(effects: List<PushEffect>) {
        for (effect in effects) {
            when (effect) {
                is PushEffect.RequestToken -> requestToken()
                is PushEffect.EnrollDestination -> enrollListener?.invoke(effect)
                is PushEffect.PresentOs -> if (!present(effect.spec)) return
                is PushEffect.ShowInApp -> inAppListener?.invoke(effect.payload)
                is PushEffect.Acknowledge -> machine.binding?.let { acknowledgeListener?.invoke(it, effect.notificationId) }
                is PushEffect.CancelPresented -> effect.notificationIds.forEach { cancel(it) }
                is PushEffect.RevokeDestination -> {
                    tokenRequest += 1
                    revokeListener?.invoke(effect)
                }
            }
        }
    }

    private fun requestToken() {
        val request = ++tokenRequest
        var callbackStarted = false
        try {
            provider.requestToken { token ->
                synchronized(this) {
                    if (started && !closed && request == tokenRequest) {
                        callbackStarted = true
                        onProviderToken(token)
                    }
                }
            }
        } catch (failure: RuntimeException) {
            if (callbackStarted) throw failure
            execute(machine.onTokenRequestFailed(true, "provider_request_failed"))
        }
    }

    @SuppressLint("MissingPermission")
    private fun present(spec: OsNotificationSpec): Boolean {
        val notification =
            NotificationCompat.Builder(appContext, spec.channelId)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(appContext.getString(R.string.app_name))
                .setContentText(appContext.getString(R.string.push_notification_body))
                .setAutoCancel(spec.autoCancel)
                .setContentIntent(contentIntent(spec))
                .setDeleteIntent(deleteIntent(spec.displayId, spec.notificationId))
                .build()
        return try {
            notifications.notify(scopeTag + spec.notificationId, spec.displayId, notification)
            true
        } catch (_: SecurityException) {
            machine.onDismissed(spec.notificationId)
            refreshPermission()
            false
        }
    }

    private fun cancel(notificationId: String) {
        notifications.cancel(scopeTag + notificationId, displayIdFor(notificationId))
    }

    private fun contentIntent(spec: OsNotificationSpec): PendingIntent =
        PendingIntent.getActivity(
            appContext,
            spec.displayId,
            Intent(appContext, MainActivity::class.java)
                .setAction(ACTION_OPEN)
                .setData(tapUri(spec.notificationId))
                .putExtra(EXTRA_NOTIFICATION_ID, spec.notificationId)
                .putExtra(EXTRA_GENERATION, checkNotNull(machine.binding?.serverTokenGeneration))
                .putExtra(EXTRA_REVISION, machine.binding?.serverDestinationRevision ?: -1L)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun deleteIntent(
        requestCode: Int,
        notificationId: String,
    ): PendingIntent =
        PendingIntent.getBroadcast(
            appContext,
            requestCode,
            Intent(ACTION_DISMISSED).setPackage(appContext.packageName)
                .setData(tapUri(notificationId))
                .putExtra(EXTRA_NOTIFICATION_ID, notificationId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun createChannels() {
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                PushChannels.DEFAULT,
                appContext.getString(R.string.push_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
        manager.createNotificationChannel(
            NotificationChannel(
                PushChannels.ALERTS,
                appContext.getString(R.string.push_alert_channel_name),
                NotificationManager.IMPORTANCE_HIGH,
            ),
        )
    }

    private fun registerDismissReceiver() {
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(
                    receiverContext: Context,
                    intent: Intent,
                ) {
                    val notificationId = intent.getStringExtra(EXTRA_NOTIFICATION_ID) ?: return
                    synchronized(this@AndroidNotificationAdapter) {
                        if (started && !closed && intent.data == tapUri(notificationId)) machine.onDismissed(notificationId)
                    }
                }
            }
        dismissReceiver = receiver
        ContextCompat.registerReceiver(
            appContext,
            receiver,
            IntentFilter(ACTION_DISMISSED).apply {
                addDataScheme("astral-push")
                addDataAuthority(appContext.packageName, null)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    private fun activeNotificationIds(): List<String> {
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return emptyList()
        return manager.activeNotifications.mapNotNull { it.tag?.takeIf { tag -> tag.startsWith(scopeTag) }?.removePrefix(scopeTag) }
    }

    private fun tapUri(notificationId: String): Uri =
        Uri.Builder().scheme("astral-push").authority(appContext.packageName)
            .appendPath(scopeTag).appendPath(notificationId).build()

    companion object {
        const val ACTION_OPEN = "com.personalailabs.astraldeep.push.OPEN"
        const val EXTRA_REVISION = "push_destination_revision"
        const val EXTRA_GENERATION = "push_token_generation"
        const val ACTION_DISMISSED = "com.personalailabs.astraldeep.push.DISMISSED"
        const val EXTRA_NOTIFICATION_ID = "notification_id"
    }
}
