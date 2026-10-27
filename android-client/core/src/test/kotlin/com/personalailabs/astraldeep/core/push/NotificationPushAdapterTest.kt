// Tests the notification adapter decision machine: permission denial and revocation, provider
// token enrollment and rotation, malformed and duplicate payloads, transient and permanent
// provider failures, and foreground, background and terminated lifecycle presentation decisions.

package com.personalailabs.astraldeep.core.push

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NotificationPushAdapterTest {
    @Test
    fun starts_deterministic_and_undetermined() {
        val adapter = NotificationPushAdapter(IDENTITY)
        assertEquals(PushLifecycle.Terminated, adapter.lifecycle)
        assertEquals(PushPermissionState.NotDetermined, adapter.permission)
        assertEquals(ProviderAvailability.Unknown, adapter.availability)
        assertEquals(RegistrationState.Idle, adapter.registration)
        assertEquals("android", adapter.platform)
        assertTrue(adapter.accepted.isEmpty())
        assertFalse(adapter.deviceUnsupported)
    }

    @Test
    fun rejects_invalid_identity() {
        assertFailsWith<IllegalArgumentException> { PushIdentity("short") }
        assertFailsWith<IllegalArgumentException> { PushIdentity("-leads-with-separator") }
        assertFailsWith<IllegalArgumentException> { PushIdentity("bad id with space-123456") }
        assertFailsWith<IllegalArgumentException> { PushIdentity(VALID_DEVICE_ID, "x".repeat(65)) }
        PushIdentity(VALID_DEVICE_ID, "x".repeat(64))
    }

    @Test
    fun rejects_invalid_capacity() {
        assertFailsWith<IllegalArgumentException> { NotificationPushAdapter(IDENTITY, acceptedCapacity = 0) }
    }

    @Test
    fun unsupported_device_is_explicit_and_ignores_all_traffic() {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        assertTrue(adapter.onAvailability(false, "no_provider_backend").isEmpty())
        assertTrue(adapter.deviceUnsupported)
        assertEquals(ProviderAvailability.Unsupported, adapter.availability)
        assertEquals("no_provider_backend", adapter.unsupportedReason)
        assertEquals(MessageReceipt.Unsupported, adapter.onMessage(payloadJson()))
        assertTrue(adapter.onToken("provider-token-A").isEmpty())
        assertTrue(adapter.retryRegistration().isEmpty())
        assertEquals(listOf<PushEffect>(PushEffect.RequestToken("bootstrap")), adapter.onAvailability(true))
        assertNull(adapter.unsupportedReason)
    }

    @Test
    fun availability_reset_clears_prior_registration_state() {
        val adapter = registeredAdapter()
        adapter.onAvailability(false)
        assertTrue(adapter.retryRegistration().isEmpty())
        assertEquals(listOf<PushEffect>(PushEffect.RequestToken("bootstrap")), adapter.onAvailability(true))
    }

    @Test
    fun denied_permission_blocks_bootstrap_and_registration() {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onAvailability(true)
        assertTrue(adapter.onPermissionReport(granted = false, notificationsEnabled = false).isEmpty())
        assertEquals(PushPermissionState.Denied, adapter.permission)
        assertTrue(adapter.onToken("provider-token-A").isEmpty())
        assertTrue(adapter.retryRegistration().isEmpty())
        assertEquals(MessageReceipt.NotPermitted, adapter.onMessage(payloadJson()))
        assertTrue(adapter.accepted.isEmpty())
    }

    @Test
    fun granted_permission_bootstraps_token_request_when_supported() {
        val adapter = NotificationPushAdapter(IDENTITY)
        assertTrue(adapter.onPermissionReport(granted = true, notificationsEnabled = true).isEmpty())
        adapter.onAvailability(true)
        assertEquals(RegistrationState.RequestingToken, adapter.registration)
    }

    @Test
    fun permission_report_completes_bootstrap_when_availability_was_ready_first() {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onAvailability(true)
        assertTrue(adapter.onPermissionReport(granted = false, notificationsEnabled = false).isEmpty())
        val granted = adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        assertEquals(listOf<PushEffect>(PushEffect.RequestToken("bootstrap")), granted)
        assertEquals(RegistrationState.RequestingToken, adapter.registration)
    }

    @Test
    fun granted_then_disabled_notifications_revoke() {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        adapter.onAvailability(true)
        deliverToken(adapter, "provider-token-A")
        adapter.onEnrollmentAccepted()
        adapter.onMessage(payloadJson(id = "notif-0001"))
        assertEquals(listOf("notif-0001"), adapter.accepted)
        assertIs<PushEffect.CancelPresented>(adapter.onPermissionReport(granted = true, notificationsEnabled = false).single())
        assertEquals(PushPermissionState.Revoked, adapter.permission)
        assertTrue(adapter.accepted.isEmpty())
    }

    @Test
    fun revoked_permission_cancels_presented_notifications() {
        val adapter = registeredAdapter()
        adapter.onMessage(payloadJson(id = "notif-0001"))
        adapter.onMessage(payloadJson(id = "notif-0002"))
        val effects = adapter.onPermissionReport(granted = false, notificationsEnabled = false)
        val cancel = assertIs<PushEffect.CancelPresented>(effects.single())
        assertEquals(listOf("notif-0001", "notif-0002"), cancel.notificationIds)
        assertTrue(adapter.accepted.isEmpty())
        assertEquals(PushPermissionState.Revoked, adapter.permission)
        assertEquals(RegistrationState.Registered(FINGERPRINT_A, 1), adapter.registration)
    }

    @Test
    fun revocation_persists_until_regranted_without_cancelling_again() {
        val adapter = registeredAdapter()
        adapter.onMessage(payloadJson(id = "notif-0001"))
        assertIs<PushEffect.CancelPresented>(adapter.onPermissionReport(granted = false, notificationsEnabled = false).single())
        assertTrue(adapter.onPermissionReport(granted = false, notificationsEnabled = false).isEmpty())
        assertTrue(adapter.onPermissionReport(granted = true, notificationsEnabled = true).isEmpty())
        assertEquals(PushPermissionState.Granted, adapter.permission)
    }

    @Test
    fun token_enrollment_uses_destination_contract() {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        adapter.onAvailability(true)
        val effect = assertIs<PushEffect.EnrollDestination>(deliverToken(adapter, "provider-token-A").single())
        assertEquals(VALID_DEVICE_ID, effect.deviceId)
        assertEquals("android", effect.platform)
        assertEquals("provider-token-A", effect.token)
        assertEquals("owner phone", effect.label)
        assertEquals(1, effect.tokenGeneration)
        assertEquals(RegistrationState.Enrolling, adapter.registration)
        assertTrue(adapter.onEnrollmentAccepted().isEmpty())
        assertEquals(RegistrationState.Registered(FINGERPRINT_A, 1), adapter.registration)
    }

    @Test
    fun repeated_same_token_is_idempotent() {
        val adapter = registeredAdapter()
        assertTrue(deliverToken(adapter, "provider-token-A").isEmpty())
        assertEquals(RegistrationState.Registered(FINGERPRINT_A, 1), adapter.registration)
    }

    @Test
    fun token_rotation_enrolls_with_incremented_generation() {
        val adapter = registeredAdapter()
        val effect = assertIs<PushEffect.EnrollDestination>(deliverToken(adapter, "provider-token-B").single())
        assertEquals("provider-token-B", effect.token)
        assertEquals(2, effect.tokenGeneration)
        assertTrue(adapter.onEnrollmentAccepted().isEmpty())
        assertEquals(RegistrationState.Registered(FINGERPRINT_B, 2), adapter.registration)
    }

    @Test
    fun invalid_tokens_fail_permanently() {
        for (token in listOf("", "   ", "x".repeat(4097), "token\u0007")) {
            val adapter = NotificationPushAdapter(IDENTITY)
            adapter.onPermissionReport(granted = true, notificationsEnabled = true)
            adapter.onAvailability(true)
            assertTrue(deliverToken(adapter, token).isEmpty())
            assertEquals(RegistrationState.FailedPermanent("token_invalid"), adapter.registration)
        }
    }

    @Test
    fun token_unavailable_is_retryable_and_retry_requests_a_token() {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        adapter.onAvailability(true)
        assertTrue(adapter.onToken(null).isEmpty())
        assertEquals(RegistrationState.FailedRetryable("token_unavailable", 1), adapter.registration)
        assertEquals(listOf<PushEffect>(PushEffect.RequestToken("retry")), adapter.retryRegistration())
        assertEquals(RegistrationState.RequestingToken, adapter.registration)
        deliverToken(adapter, "provider-token-A")
        adapter.onEnrollmentAccepted()
        assertEquals(RegistrationState.Registered(FINGERPRINT_A, 1), adapter.registration)
    }

    @Test
    fun token_unavailable_outside_active_request_is_ignored() {
        val adapter = NotificationPushAdapter(IDENTITY)
        assertTrue(adapter.onToken(null).isEmpty())
        assertEquals(RegistrationState.Idle, adapter.registration)
    }

    @Test
    fun token_request_failure_classification() {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        adapter.onAvailability(true)
        assertTrue(adapter.onTokenRequestFailed(transient = true, code = "provider_timeout").isEmpty())
        assertEquals(RegistrationState.FailedRetryable("provider_timeout", 1), adapter.registration)
        assertEquals(listOf<PushEffect>(PushEffect.RequestToken("retry")), adapter.retryRegistration())
        assertTrue(adapter.onTokenRequestFailed(transient = false, code = "provider_blocked").isEmpty())
        assertEquals(RegistrationState.FailedPermanent("provider_blocked"), adapter.registration)
        assertTrue(adapter.retryRegistration().isEmpty())
    }

    @Test
    fun token_request_failure_outside_active_request_is_ignored() {
        val adapter = registeredAdapter()
        assertTrue(adapter.onTokenRequestFailed(transient = true, code = "provider_timeout").isEmpty())
        assertEquals(RegistrationState.Registered(FINGERPRINT_A, 1), adapter.registration)
    }

    @Test
    fun enrollment_rejection_classification_and_retry() {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        adapter.onAvailability(true)
        deliverToken(adapter, "provider-token-A")
        assertTrue(adapter.onEnrollmentRejected(transient = true, code = "destination_store_unavailable").isEmpty())
        assertEquals(RegistrationState.FailedRetryable("destination_store_unavailable", 1), adapter.registration)
        val retry = assertIs<PushEffect.EnrollDestination>(adapter.retryRegistration().single())
        assertEquals("provider-token-A", retry.token)
        assertEquals(1, retry.tokenGeneration)
        assertTrue(adapter.onEnrollmentAccepted().isEmpty())
        assertEquals(RegistrationState.Registered(FINGERPRINT_A, 1), adapter.registration)
    }

    @Test
    fun permanent_enrollment_rejection_needs_a_fresh_token() {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        adapter.onAvailability(true)
        deliverToken(adapter, "provider-token-A")
        assertTrue(adapter.onEnrollmentRejected(transient = false, code = "token_sender_mismatch").isEmpty())
        assertEquals(RegistrationState.FailedPermanent("token_sender_mismatch"), adapter.registration)
        assertTrue(adapter.retryRegistration().isEmpty())
        val effect = assertIs<PushEffect.EnrollDestination>(deliverToken(adapter, "provider-token-B").single())
        assertEquals(2, effect.tokenGeneration)
    }

    @Test
    fun enrollment_decisions_outside_enrolling_are_ignored() {
        val adapter = registeredAdapter()
        assertTrue(adapter.onEnrollmentAccepted().isEmpty())
        assertTrue(adapter.onEnrollmentRejected(transient = true, code = "destination_store_unavailable").isEmpty())
        assertEquals(RegistrationState.Registered(FINGERPRINT_A, 1), adapter.registration)
    }

    @Test
    fun background_message_presents_os_notification_and_acknowledges() {
        val adapter = registeredAdapter()
        adapter.onLifecycle(PushLifecycle.Background)
        val receipt = adapter.onMessage(payloadJson(id = "notif-0001")) as MessageReceipt.Accepted
        assertTrue(receipt.presentedAsOsNotification)
        val present = assertIs<PushEffect.PresentOs>(receipt.effects[0])
        val acknowledge = assertIs<PushEffect.Acknowledge>(receipt.effects[1])
        assertEquals(VALID_DEVICE_ID, acknowledge.deviceId)
        assertEquals("notif-0001", acknowledge.notificationId)
        assertEquals("notif-0001", present.spec.notificationId)
        assertEquals(displayIdFor("notif-0001"), present.spec.displayId)
        assertEquals(PushChannels.DEFAULT, present.spec.channelId)
        assertEquals("Hello", present.spec.title)
        assertEquals("Body text", present.spec.body)
        assertEquals("info", present.spec.level)
        assertTrue(present.spec.autoCancel)
        assertEquals(listOf("notif-0001"), adapter.accepted)
    }

    @Test
    fun terminated_lifecycle_presents_like_background() {
        val adapter = registeredAdapter()
        assertEquals(PushLifecycle.Terminated, adapter.lifecycle)
        val receipt = adapter.onMessage(payloadJson(id = "notif-0001")) as MessageReceipt.Accepted
        assertTrue(receipt.presentedAsOsNotification)
        assertIs<PushEffect.PresentOs>(receipt.effects[0])
    }

    @Test
    fun error_level_message_targets_the_alert_channel() {
        val adapter = registeredAdapter()
        val receipt =
            adapter.onMessage(payloadJson(id = "notif-0001", level = "error")) as MessageReceipt.Accepted
        val present = assertIs<PushEffect.PresentOs>(receipt.effects[0])
        assertEquals(PushChannels.ALERTS, present.spec.channelId)
        assertEquals("error", present.spec.level)
    }

    @Test
    fun foreground_message_becomes_in_app_only() {
        val adapter = registeredAdapter()
        adapter.onLifecycle(PushLifecycle.Foreground)
        val receipt = adapter.onMessage(payloadJson(id = "notif-0001")) as MessageReceipt.Accepted
        assertFalse(receipt.presentedAsOsNotification)
        assertIs<PushEffect.ShowInApp>(receipt.effects[0])
        assertIs<PushEffect.Acknowledge>(receipt.effects[1])
        assertEquals(listOf("notif-0001"), adapter.accepted)
    }

    @Test
    fun duplicate_payloads_are_suppressed_on_every_surface() {
        val adapter = registeredAdapter()
        adapter.onLifecycle(PushLifecycle.Foreground)
        assertIs<MessageReceipt.Accepted>(adapter.onMessage(payloadJson(id = "notif-0001")))
        assertEquals(MessageReceipt.Duplicate("notif-0001"), adapter.onMessage(payloadJson(id = "notif-0001")))
        adapter.onLifecycle(PushLifecycle.Background)
        assertEquals(MessageReceipt.Duplicate("notif-0001"), adapter.onMessage(payloadJson(id = "notif-0001")))
    }

    @Test
    fun malformed_payloads_are_explicit_and_ignored() {
        val adapter = registeredAdapter()
        val receipt = adapter.onMessage(buildJsonObject { put("notification_id", 5) })
        assertEquals(MessageReceipt.Malformed("notification_id"), receipt)
        assertTrue(adapter.accepted.isEmpty())
    }

    @Test
    fun background_delivery_without_permission_is_not_permitted_and_not_remembered() {
        val adapter = registeredAdapter()
        adapter.onPermissionReport(granted = false, notificationsEnabled = false)
        assertEquals(MessageReceipt.NotPermitted, adapter.onMessage(payloadJson(id = "notif-0001")))
        assertTrue(adapter.accepted.isEmpty())
    }

    @Test
    fun accepted_ledger_is_bounded_and_evicts_oldest() {
        val adapter = NotificationPushAdapter(IDENTITY, acceptedCapacity = 2)
        adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        adapter.onAvailability(true)
        deliverToken(adapter, "provider-token-A")
        adapter.onEnrollmentAccepted()
        for (id in listOf("notif-0001", "notif-0002", "notif-0003")) {
            assertIs<MessageReceipt.Accepted>(adapter.onMessage(payloadJson(id = id)))
        }
        assertEquals(listOf("notif-0002", "notif-0003"), adapter.accepted)
        assertIs<MessageReceipt.Accepted>(adapter.onMessage(payloadJson(id = "notif-0001")))
        assertEquals(MessageReceipt.Duplicate("notif-0003"), adapter.onMessage(payloadJson(id = "notif-0003")))
    }

    @Test
    fun dismissal_reopens_redelivery() {
        val adapter = registeredAdapter()
        adapter.onMessage(payloadJson(id = "notif-0001"))
        assertTrue(adapter.onDismissed("notif-0001"))
        assertTrue(adapter.accepted.isEmpty())
        assertIs<MessageReceipt.Accepted>(adapter.onMessage(payloadJson(id = "notif-0001")))
        assertTrue(adapter.onDismissed("notif-0001"))
        assertFalse(adapter.onDismissed("unknown-id-01"))
    }

    @Test
    fun seeding_from_the_os_prevents_duplicate_presentation_after_restart() {
        val adapter = registeredAdapter()
        adapter.seedAccepted(listOf("notif-0001", "", "notif-0001", "notif-0002"))
        assertEquals(listOf("notif-0001", "notif-0002"), adapter.accepted)
        assertEquals(MessageReceipt.Duplicate("notif-0001"), adapter.onMessage(payloadJson(id = "notif-0001")))
    }

    @Test
    fun display_ids_differ_for_distinct_notifications() {
        assertNotEquals(displayIdFor("notif-0001"), displayIdFor("notif-0002"))
    }

    private fun deliverToken(
        adapter: NotificationPushAdapter,
        token: String?,
    ): List<PushEffect> = adapter.onToken(token)

    private fun registeredAdapter(): NotificationPushAdapter {
        val adapter = NotificationPushAdapter(IDENTITY)
        adapter.onPermissionReport(granted = true, notificationsEnabled = true)
        adapter.onAvailability(true)
        deliverToken(adapter, "provider-token-A")
        adapter.onEnrollmentAccepted()
        return adapter
    }

    private fun payloadJson(
        id: String = "notif-0001",
        title: String? = "Hello",
        body: String? = "Body text",
        level: String? = null,
        chatId: String? = null,
    ): JsonObject =
        buildJsonObject {
            put("notification_id", id)
            title?.let { put("title", it) }
            body?.let { put("body", it) }
            level?.let { put("level", it) }
            chatId?.let { put("chat_id", it) }
        }

    private companion object {
        const val VALID_DEVICE_ID = "device-0001-aa"
        const val FINGERPRINT_A = "7f8e385a0063a58631b876333391650f287a2c09dbf5c1de83ed6c0dea982dd5"
        const val FINGERPRINT_B = "3a42720a890a43e41f4fddac9239a843f00f254450415bf4073c3519e77c1290"
        val IDENTITY = PushIdentity(VALID_DEVICE_ID, "owner phone")
    }
}
