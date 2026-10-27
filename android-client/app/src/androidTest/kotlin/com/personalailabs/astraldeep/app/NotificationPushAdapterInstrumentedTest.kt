// Exercises the Android notification adapter against the real OS notification manager on an
// emulator: permission grant and revoke, provider token and enrollment seams, presentation,
// dismissal, duplicate and malformed payloads, and unsupported-device behavior.

package com.personalailabs.astraldeep.app

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.push.AndroidNotificationAdapter
import com.personalailabs.astraldeep.app.push.PushProvider
import com.personalailabs.astraldeep.core.push.NotificationPushAdapter
import com.personalailabs.astraldeep.core.push.ProviderAvailability
import com.personalailabs.astraldeep.core.push.PushIdentity
import com.personalailabs.astraldeep.core.push.PushLifecycle
import com.personalailabs.astraldeep.core.push.PushPayload
import com.personalailabs.astraldeep.core.push.PushPermissionState
import com.personalailabs.astraldeep.core.push.RegistrationState
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

class NotificationPushAdapterInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val notificationManager = context.getSystemService(NotificationManager::class.java)
    private val inAppPayloads = CopyOnWriteArrayList<PushPayload>()
    private val acknowledged = CopyOnWriteArrayList<String>()
    private val enrolled = CopyOnWriteArrayList<String>()

    @Before
    fun grantPermissionAndClearState() {
        runShell("pm grant ${context.packageName} ${Manifest.permission.POST_NOTIFICATIONS}")
        notificationManager.cancelAll()
    }

    @Test
    fun unsupportedDeviceNeverRegistersOrPresents() {
        val provider = FakePushProvider(supported = false)
        val adapter = startAdapter(provider)
        assertEquals(ProviderAvailability.Unsupported, adapter.machine.availability)
        assertTrue(enrolled.isEmpty())
        adapter.onMessage(payloadJson(NOTIFICATION_ID))
        assertTrue(postedTags().isEmpty())
        assertTrue(acknowledged.isEmpty())
    }

    @Test
    fun grantedPermissionRequestsTokenAndPresentsBackgroundMessage() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(adapter)
        val posted = checkNotNull(notificationManager.activeNotifications.firstOrNull { it.tag == NOTIFICATION_ID })
        assertEquals("astral_push", posted.notification.channelId)
        assertEquals("Hello", posted.notification.extras.getString(Notification.EXTRA_TITLE))
        assertEquals("Body text", posted.notification.extras.getString(Notification.EXTRA_TEXT))
        assertEquals(listOf(NOTIFICATION_ID), acknowledged.toList())
        assertEquals(RegistrationState.Registered::class, adapter.machine.registration::class)
    }

    @Test
    fun foregroundMessageStaysInApp() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(adapter)
        adapter.machine.onLifecycle(PushLifecycle.Foreground)
        adapter.onMessage(payloadJson("foreground-notif-01"))
        assertNull(notificationManager.activeNotifications.firstOrNull { it.tag == "foreground-notif-01" })
        assertEquals("foreground-notif-01", inAppPayloads.single().notificationId)
    }

    @Test
    fun duplicatePayloadPresentsOnce() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(adapter)
        adapter.onMessage(payloadJson(NOTIFICATION_ID))
        assertEquals(1, postedTags().count { it == NOTIFICATION_ID })
        assertEquals(listOf(NOTIFICATION_ID), acknowledged.toList())
    }

    @Test
    fun malformedPayloadIsIgnoredWithoutPresentation() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        adapter.onProviderToken("provider-token-01")
        adapter.onMessage(buildJsonObject { put("notification_id", 5) })
        adapter.onMessage(payloadJson("bad id!"))
        assertTrue(postedTags().isEmpty())
        assertTrue(acknowledged.isEmpty())
    }

    @Test
    fun revokedPermissionCancelsPresentedNotifications() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(adapter)
        assertNotNull(notificationManager.activeNotifications.firstOrNull { it.tag == NOTIFICATION_ID })
        runShell("pm revoke ${context.packageName} ${Manifest.permission.POST_NOTIFICATIONS}")
        adapter.refreshPermission()
        assertEquals(PushPermissionState.Revoked, adapter.machine.permission)
        assertNull(notificationManager.activeNotifications.firstOrNull { it.tag == NOTIFICATION_ID })
    }

    @Test
    fun deleteIntentDismissalReopensRedelivery() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(adapter)
        context.sendBroadcast(
            Intent("com.personalailabs.astraldeep.push.DISMISSED")
                .setPackage(context.packageName)
                .putExtra("notification_id", NOTIFICATION_ID),
        )
        instrumentation.waitForIdleSync()
        assertTrue(adapter.machine.accepted.isEmpty())
        adapter.onMessage(payloadJson(NOTIFICATION_ID))
        assertNotNull(notificationManager.activeNotifications.firstOrNull { it.tag == NOTIFICATION_ID })
        assertEquals(listOf(NOTIFICATION_ID, NOTIFICATION_ID), acknowledged.toList())
    }

    @Test
    fun coldStartSeedsPresentedNotificationsAndSuppressesDuplicates() {
        val first = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(first)
        val replacementMachine = NotificationPushAdapter(IDENTITY)
        val replacementAcks = CopyOnWriteArrayList<String>()
        val second =
            AndroidNotificationAdapter(
                context,
                FakePushProvider(supported = true),
                IDENTITY,
                replacementMachine,
                acknowledgeListener = { _, id -> replacementAcks.add(id) },
            )
        second.start()
        assertEquals(listOf(NOTIFICATION_ID), replacementMachine.accepted)
        second.onMessage(payloadJson(NOTIFICATION_ID))
        assertEquals(1, postedTags().count { it == NOTIFICATION_ID })
        assertTrue(replacementAcks.isEmpty())
    }

    @Test
    fun tokenRotationReenrolls() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(adapter)
        adapter.onProviderToken("rotated-token-02")
        assertEquals("rotated-token-02", enrolled.last())
        adapter.machine.onEnrollmentAccepted()
        assertEquals(2, (adapter.machine.registration as RegistrationState.Registered).tokenGeneration)
    }

    @Test
    fun transientTokenFailureRecoversThroughRetry() {
        val provider = FakePushProvider(supported = true, token = null)
        val adapter = startAdapter(provider)
        provider.deliverPendingToken()
        assertEquals(RegistrationState.FailedRetryable::class, adapter.machine.registration::class)
        adapter.retryRegistration()
        provider.token = "recovered-token-01"
        provider.deliverPendingToken()
        adapter.machine.onEnrollmentAccepted()
        assertEquals(RegistrationState.Registered::class, adapter.machine.registration::class)
        assertEquals("recovered-token-01", enrolled.last())
    }

    private fun startAdapter(provider: PushProvider): AndroidNotificationAdapter {
        val machine = NotificationPushAdapter(IDENTITY)
        val adapter =
            AndroidNotificationAdapter(
                context,
                provider,
                IDENTITY,
                machine,
                inAppListener = { payload -> inAppPayloads.add(payload) },
                acknowledgeListener = { _, id -> acknowledged.add(id) },
                enrollListener = { effect ->
                    enrolled.add(effect.token)
                    machine.onEnrollmentAccepted()
                },
            )
        adapter.start()
        return adapter
    }

    private fun deliverAndAccept(adapter: AndroidNotificationAdapter) {
        adapter.onProviderToken("provider-token-01")
        assertEquals(listOf("provider-token-01"), enrolled.toList())
        adapter.onMessage(payloadJson(NOTIFICATION_ID))
    }

    private fun postedTags(): List<String?> = notificationManager.activeNotifications.map { it.tag }

    private fun runShell(command: String) {
        instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).readBytes()
        }
    }

    private fun payloadJson(id: String): JsonObject =
        buildJsonObject {
            put("notification_id", id)
            put("title", "Hello")
            put("body", "Body text")
        }

    private class FakePushProvider(
        private val supported: Boolean,
        var token: String? = "provider-token-01",
    ) : PushProvider {
        private var listener: ((JsonObject) -> Unit)? = null
        private var pendingTokenResult: ((String?) -> Unit)? = null

        override fun isSupported(): Boolean = supported

        override fun requestToken(onResult: (String?) -> Unit) {
            pendingTokenResult = onResult
        }

        override fun setMessageListener(onMessage: (JsonObject) -> Unit) {
            listener = onMessage
        }

        fun deliverPendingToken() {
            val result = pendingTokenResult
            pendingTokenResult = null
            result?.invoke(token)
        }
    }

    private companion object {
        val IDENTITY = PushIdentity("device-0001-aa", "instrumented owner phone")
        const val NOTIFICATION_ID = "notif-0001"
    }
}
