// Android OS binding for the notification adapter: creates the notification channels, maps runtime
// permission and presentation facts into the pure decision machine, and executes presentation,
// dismissal, cancellation, token and enrollment effects. PushProvider is the seam a provider
// bridge (for example FCM) implements during coordinated app integration.

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
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.personalailabs.astraldeep.app.MainActivity
import com.personalailabs.astraldeep.app.R
import com.personalailabs.astraldeep.core.push.NotificationPushAdapter
import com.personalailabs.astraldeep.core.push.OsNotificationSpec
import com.personalailabs.astraldeep.core.push.PushChannels
import com.personalailabs.astraldeep.core.push.PushEffect
import com.personalailabs.astraldeep.core.push.PushIdentity
import com.personalailabs.astraldeep.core.push.PushPayload
import com.personalailabs.astraldeep.core.push.displayIdFor
import kotlinx.serialization.json.JsonObject

interface PushProvider {
    fun isSupported(): Boolean

    fun requestToken(onResult: (String?) -> Unit)

    fun setMessageListener(onMessage: (JsonObject) -> Unit)
}

class AndroidNotificationAdapter(
    context: Context,
    private val provider: PushProvider,
    private val identity: PushIdentity,
    val machine: NotificationPushAdapter = NotificationPushAdapter(identity),
    private val inAppListener: ((PushPayload) -> Unit)? = null,
    private val acknowledgeListener: ((PushIdentity, String) -> Unit)? = null,
    private val enrollListener: ((PushEffect.EnrollDestination) -> Unit)? = null,
) {
    private val appContext: Context = context.applicationContext
    private val notifications = NotificationManagerCompat.from(appContext)
    private var started = false

    fun start() {
        if (started) return
        started = true
        createChannels()
        registerDismissReceiver()
        refreshPermission()
        machine.seedAccepted(activeNotificationIds())
        provider.setMessageListener { data -> onMessage(data) }
        execute(machine.onAvailability(provider.isSupported()))
    }

    fun refreshPermission() {
        if (!started) return
        val granted =
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        execute(machine.onPermissionReport(granted, notifications.areNotificationsEnabled()))
    }

    fun shouldRequestPermission(): Boolean =
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED

    fun onMessage(data: JsonObject) {
        execute(machine.onMessage(data))
    }

    fun onProviderToken(token: String?) {
        execute(machine.onToken(token))
    }

    fun retryRegistration() {
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
                is PushEffect.PresentOs -> present(effect.spec)
                is PushEffect.ShowInApp -> inAppListener?.invoke(effect.payload)
                is PushEffect.Acknowledge -> acknowledgeListener?.invoke(identity, effect.notificationId)
                is PushEffect.CancelPresented -> effect.notificationIds.forEach { cancel(it) }
            }
        }
    }

    private fun requestToken() {
        provider.requestToken { token -> onProviderToken(token) }
    }

    @SuppressLint("MissingPermission")
    private fun present(spec: OsNotificationSpec) {
        // The decision machine emits PresentOs only with POST_NOTIFICATIONS granted; lint cannot see that guard.
        val notification =
            NotificationCompat.Builder(appContext, spec.channelId)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(spec.title ?: appContext.getString(R.string.app_name))
                .setContentText(spec.body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(spec.body))
                .setAutoCancel(spec.autoCancel)
                .setContentIntent(contentIntent())
                .setDeleteIntent(deleteIntent(spec.displayId, spec.notificationId))
                .build()
        notifications.notify(spec.notificationId, spec.displayId, notification)
    }

    private fun cancel(notificationId: String) {
        notifications.cancel(notificationId, displayIdFor(notificationId))
    }

    private fun contentIntent(): PendingIntent =
        PendingIntent.getActivity(
            appContext,
            0,
            Intent(appContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun deleteIntent(
        requestCode: Int,
        notificationId: String,
    ): PendingIntent =
        PendingIntent.getBroadcast(
            appContext,
            requestCode,
            Intent(ACTION_DISMISSED).setPackage(appContext.packageName).putExtra(EXTRA_NOTIFICATION_ID, notificationId),
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
                override fun onReceive(receiverContext: Context, intent: Intent) {
                    val notificationId = intent.getStringExtra(EXTRA_NOTIFICATION_ID) ?: return
                    machine.onDismissed(notificationId)
                }
            }
        ContextCompat.registerReceiver(
            appContext,
            receiver,
            IntentFilter(ACTION_DISMISSED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    private fun activeNotificationIds(): List<String> {
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return emptyList()
        return manager.activeNotifications.mapNotNull { it.tag }
    }

    private companion object {
        const val ACTION_DISMISSED = "com.personalailabs.astraldeep.push.DISMISSED"
        const val EXTRA_NOTIFICATION_ID = "notification_id"
    }
}
