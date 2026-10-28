// Exercises notification permission, provider races, scoped OS notices and tap identity through the Android binding.

package com.personalailabs.astraldeep.app

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.push.AndroidNotificationAdapter
import com.personalailabs.astraldeep.app.push.PushProvider
import com.personalailabs.astraldeep.core.push.MessageReceipt
import com.personalailabs.astraldeep.core.push.NotificationPushAdapter
import com.personalailabs.astraldeep.core.push.ProviderAvailability
import com.personalailabs.astraldeep.core.push.PushEffect
import com.personalailabs.astraldeep.core.push.PushIdentity
import com.personalailabs.astraldeep.core.push.PushLifecycle
import com.personalailabs.astraldeep.core.push.PushPayload
import com.personalailabs.astraldeep.core.push.PushPermissionState
import com.personalailabs.astraldeep.core.push.RegistrationState
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class NotificationPushAdapterInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val notificationManager = context.getSystemService(NotificationManager::class.java)
    private val inAppPayloads = CopyOnWriteArrayList<PushPayload>()
    private val acknowledged = CopyOnWriteArrayList<String>()
    private val enrolled = CopyOnWriteArrayList<String>()
    private val adapters = mutableListOf<AndroidNotificationAdapter>()
    private val revocations = mutableListOf<PushEffect.RevokeDestination>()

    @After
    fun closeAdapters() {
        adapters.forEach { it.close() }
        notificationManager.cancelAll()
        runShell("appops set ${context.packageName} POST_NOTIFICATION allow")
        runShell("pm grant ${context.packageName} ${Manifest.permission.POST_NOTIFICATIONS}")
    }

    @Before
    fun grantPermissionAndClearState() {
        if (InstrumentationRegistry.getArguments().getString("pushPermissionDenied") == "true") {
            notificationManager.cancelAll()
            return
        }
        runShell("appops set ${context.packageName} POST_NOTIFICATION allow")
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
        val posted = checkNotNull(notificationManager.activeNotifications.firstOrNull { it.tag?.endsWith(NOTIFICATION_ID) == true })
        assertEquals("astral_push", posted.notification.channelId)
        assertEquals(context.getString(R.string.app_name), posted.notification.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(context.getString(R.string.push_notification_body), posted.notification.extras.getString(Notification.EXTRA_TEXT))
        assertEquals(listOf(NOTIFICATION_ID), acknowledged.toList())
        assertEquals(RegistrationState.Registered::class, adapter.machine.registration::class)
    }

    @Test
    fun foregroundMessageStaysInApp() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(adapter)
        adapter.machine.onLifecycle(PushLifecycle.Foreground)
        adapter.onMessage(payloadJson("foreground-notif-01"))
        assertNull(notificationManager.activeNotifications.firstOrNull { it.tag?.endsWith("foreground-notif-01") == true })
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
    fun revokedPermissionCallbackCancelsPresentedNotifications() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(adapter)
        assertNotNull(notificationManager.activeNotifications.firstOrNull { it.tag?.endsWith(NOTIFICATION_ID) == true })
        adapter.onPermissionResult(false)
        assertEquals(PushPermissionState.Revoked, adapter.machine.permission)
        awaitCondition { notificationManager.activeNotifications.none { it.tag?.endsWith(NOTIFICATION_ID) == true } }
        assertEquals(1, revocations.size)
    }

    @Test
    fun deleteIntentDismissalReopensRedelivery() {
        val adapter = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(adapter)
        notificationManager.activeNotifications.single().notification.deleteIntent.send()
        instrumentation.waitForIdleSync()
        awaitCondition { adapter.machine.accepted.isEmpty() }
        adapter.onMessage(payloadJson(NOTIFICATION_ID))
        assertNotNull(notificationManager.activeNotifications.firstOrNull { it.tag?.endsWith(NOTIFICATION_ID) == true })
        assertEquals(listOf(NOTIFICATION_ID, NOTIFICATION_ID), acknowledged.toList())
    }

    @Test
    fun coldStartSeedsPresentedNotificationsAndSuppressesDuplicates() {
        val first = startAdapter(FakePushProvider(supported = true))
        deliverAndAccept(first)
        val replacementMachine = NotificationPushAdapter(IDENTITY, OWNER)
        val replacementAcks = CopyOnWriteArrayList<String>()
        val second =
            AndroidNotificationAdapter(
                context,
                FakePushProvider(supported = true),
                IDENTITY,
                OWNER,
                replacementMachine,
                acknowledgeListener = { _, id -> replacementAcks.add(id) },
            )
        adapters.add(second)
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
        adapter.machine.onEnrollmentAccepted(adapter.machine.tokenGeneration, (adapter.machine.tokenGeneration).toLong())
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
        adapter.machine.onEnrollmentAccepted(adapter.machine.tokenGeneration, (adapter.machine.tokenGeneration).toLong())
        assertEquals(RegistrationState.Registered::class, adapter.machine.registration::class)
        assertEquals("recovered-token-01", enrolled.last())
    }

    @Test
    fun processStartPermissionTracksTheActualOsDecision() {
        val adapter = startAdapter(FakePushProvider(true))
        if (InstrumentationRegistry.getArguments().getString("pushPermissionDenied") != "true") {
            assertEquals(PushPermissionState.Granted, adapter.machine.permission)
            assertTrue(!adapter.shouldRequestPermission())
            return
        }
        assertEquals(PushPermissionState.NotDetermined, adapter.machine.permission)
        assertTrue(adapter.shouldRequestPermission())
        adapter.refreshPermission(requestCompleted = true)
        assertEquals(PushPermissionState.Denied, adapter.machine.permission)
        assertTrue(!adapter.shouldRequestPermission())
        adapter.onProviderToken("late-token-01")
        adapter.onMessage(payloadJson(NOTIFICATION_ID))
        assertTrue(postedTags().isEmpty())
    }

    @Test
    fun lateProviderCallbacksCannotRestoreAClosedOwnerSession() {
        val provider = FakePushProvider(true)
        val adapter = startAdapter(provider)
        adapter.onProviderToken("provider-token-01")
        val oldListener = checkNotNull(provider.listener)
        adapter.onMessage(payloadJson(NOTIFICATION_ID))
        adapter.close()
        provider.deliverPendingToken()
        oldListener(payloadJson("notification-late-01"))
        adapter.onProviderToken("rotation-after-close")
        adapter.start()
        awaitCondition { postedTags().isEmpty() }
        assertEquals(1, revocations.size)
        assertEquals(RegistrationState.Idle, adapter.machine.registration)
    }

    @Test
    fun twoConcurrentNotificationsKeepDistinctPendingIntents() {
        val adapter = startAdapter(FakePushProvider(true))
        deliverAndAccept(adapter)
        adapter.onMessage(payloadJson("notif-0002"))
        awaitCondition { notificationManager.activeNotifications.size == 2 }
        val notices = notificationManager.activeNotifications.map { it.notification }
        assertEquals(2, notices.size)
        assertTrue(notices[0].contentIntent != notices[1].contentIntent)
        assertTrue(notices[0].deleteIntent != notices[1].deleteIntent)
        val tappedIds =
            notices.map { notification ->
                val received = AtomicReference<Intent>()
                val latch = CountDownLatch(1)
                notification.contentIntent.send(context, 0, null, { _, intent, _, _, _ ->
                    received.set(intent)
                    latch.countDown()
                }, null)
                assertTrue(latch.await(5, TimeUnit.SECONDS))
                adapter.notificationIdFromTap(received.get())
            }
        assertEquals(setOf(NOTIFICATION_ID, "notif-0002"), tappedIds.toSet())
        adapter.close()
        awaitCondition { postedTags().isEmpty() }
    }

    @Test
    fun lateSuccessfulEnrollmentRevokesOnlyItsReturnedServerGeneration() {
        val effects = mutableListOf<PushEffect.EnrollDestination>()
        val adapter =
            AndroidNotificationAdapter(
                context,
                FakePushProvider(true),
                IDENTITY,
                OWNER,
                enrollListener = { effects.add(it) },
                revokeListener = { revocations.add(it) },
            )
        adapters.add(adapter)
        adapter.start()
        adapter.onProviderToken("provider-token-01")
        val effect = effects.single()
        adapter.close()
        adapter.onEnrollmentAccepted(effect, 99L)
        assertEquals(99L, revocations.single().binding.serverTokenGeneration)
        assertEquals(RegistrationState.Idle, adapter.machine.registration)
    }

    @Test
    fun rotatedProviderListenerCannotDeliverIntoCurrentGeneration() {
        val provider = FakePushProvider(true)
        val adapter = startAdapter(provider)
        adapter.onProviderToken("provider-token-01")
        val previous = checkNotNull(provider.listener)
        adapter.onProviderToken("provider-token-02")
        previous(payloadJson(NOTIFICATION_ID))
        assertTrue(postedTags().isEmpty())
        checkNotNull(provider.listener)(payloadJson(NOTIFICATION_ID))
        awaitCondition { postedTags() == listOf(NOTIFICATION_ID) }
    }

    @Test
    fun providerRequestFailureIsRetryableAndRecovers() {
        val provider = FakePushProvider(true).also { it.throwOnRequest = true }
        val adapter = startAdapter(provider)
        assertEquals(RegistrationState.FailedRetryable::class, adapter.machine.registration::class)
        provider.throwOnRequest = false
        adapter.retryRegistration()
        provider.deliverPendingToken()
        assertEquals(RegistrationState.Registered::class, adapter.machine.registration::class)
    }

    @Test
    fun accountSwitchRejectsTheRetiredOwnersProviderListener() {
        val previousProvider = FakePushProvider(true)
        val first = startAdapter(previousProvider)
        first.onProviderToken("provider-token-01")
        val previous = checkNotNull(previousProvider.listener)
        first.close()
        val currentProvider = FakePushProvider(true)
        val second = startAdapter(currentProvider, "owner-session-B")
        second.onProviderToken("provider-token-01")
        previous(payloadJson(NOTIFICATION_ID))
        assertTrue(postedTags().isEmpty())
        checkNotNull(currentProvider.listener)(payloadJson(NOTIFICATION_ID))
        awaitCondition { postedTags() == listOf(NOTIFICATION_ID) }
        first.close()
        assertEquals(listOf(NOTIFICATION_ID), postedTags())
    }

    @Test
    fun synchronousEnrollmentFailureCannotMasqueradeAsAProviderRetry() {
        val provider =
            object : PushProvider {
                override fun isSupported(): Boolean = true

                override fun requestToken(onResult: (String?) -> Unit) {
                    onResult("provider-token-01")
                }

                override fun setMessageListener(onMessage: (JsonObject) -> Unit) = Unit
            }
        val adapter =
            AndroidNotificationAdapter(
                context,
                provider,
                IDENTITY,
                OWNER,
                enrollListener = { throw IllegalStateException("enrollment_failure") },
            )
        adapters.add(adapter)
        val error = assertThrows(IllegalStateException::class.java) { adapter.start() }
        assertEquals("enrollment_failure", error.message)
    }

    private fun startAdapter(
        provider: PushProvider,
        owner: String = OWNER,
    ): AndroidNotificationAdapter {
        val machine = NotificationPushAdapter(IDENTITY, owner)
        lateinit var adapter: AndroidNotificationAdapter
        adapter =
            AndroidNotificationAdapter(
                context,
                provider,
                IDENTITY,
                owner,
                machine,
                inAppListener = { payload -> inAppPayloads.add(payload) },
                acknowledgeListener = { _, id -> acknowledged.add(id) },
                enrollListener = { effect ->
                    enrolled.add(effect.token)
                    adapter.onEnrollmentAccepted(effect, effect.tokenGeneration.toLong())
                },
                revokeListener = { revocations.add(it) },
            )
        adapters.add(adapter)
        adapter.start()
        return adapter
    }

    private fun deliverAndAccept(adapter: AndroidNotificationAdapter) {
        adapter.onProviderToken("provider-token-01")
        assertEquals(listOf("provider-token-01"), enrolled.toList())
        adapter.onMessage(payloadJson(NOTIFICATION_ID))
        awaitCondition { postedTags() == listOf(NOTIFICATION_ID) }
    }

    private fun postedTags(): List<String?> = notificationManager.activeNotifications.map { it.tag?.substringAfterLast(':') }

    private fun AndroidNotificationAdapter.onMessage(data: JsonObject): MessageReceipt =
        onMessage(data, machine.binding ?: com.personalailabs.astraldeep.core.push.PushBinding(OWNER, IDENTITY.deviceId, machine.tokenGeneration))

    private fun awaitCondition(condition: () -> Boolean) {
        for (attempt in 0 until 100) {
            if (condition()) return
            Thread.sleep(20)
        }
        assertTrue(condition())
    }

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
        var listener: ((JsonObject) -> Unit)? = null
        var throwOnRequest = false
        private var pendingTokenResult: ((String?) -> Unit)? = null

        override fun isSupported(): Boolean = supported

        override fun requestToken(onResult: (String?) -> Unit) {
            if (throwOnRequest) throw IllegalStateException("provider_unavailable")
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
        const val OWNER = "owner-session-A"
        val IDENTITY = PushIdentity("device-0001-aa", "instrumented owner phone")
        const val NOTIFICATION_ID = "notif-0001"
    }
}
