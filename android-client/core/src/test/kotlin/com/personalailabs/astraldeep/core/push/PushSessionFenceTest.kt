// Verifies owner-session and token-generation retirement in the pure notification machine used by the Android OS adapter.
package com.personalailabs.astraldeep.core.push

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class PushSessionFenceTest {
    @Test
    fun refresh_preserves_not_determined_until_a_permission_decision() {
        val machine = machine()
        machine.onPermissionReport(false, false, requestCompleted = false)
        assertEquals(PushPermissionState.NotDetermined, machine.permission)
        machine.onPermissionReport(false, false, requestCompleted = true)
        assertEquals(PushPermissionState.Denied, machine.permission)
    }

    @Test
    fun repeated_token_does_not_accept_an_outstanding_enrollment() {
        val machine = ready()
        machine.onToken("provider-token-A")
        assertEquals(RegistrationState.Enrolling, machine.registration)
        machine.onEnrollmentAccepted(1, 1L)
        assertIs<RegistrationState.Registered>(machine.registration)
    }

    @Test
    fun rotation_ignores_the_previous_generation_completion_and_delivery() {
        val machine = ready()
        machine.onEnrollmentAccepted(1, 1L)
        val old = checkNotNull(machine.binding)
        machine.onToken("provider-token-B")
        machine.onEnrollmentAccepted(1, 1L)
        assertEquals(RegistrationState.Enrolling, machine.registration)
        machine.onEnrollmentRejected(true, "late", 1)
        assertEquals(RegistrationState.Enrolling, machine.registration)
        machine.onEnrollmentAccepted(2, 2L)
        assertEquals(MessageReceipt.NotPermitted, machine.onMessage(payload(), old))
        assertIs<MessageReceipt.Accepted>(machine.onMessage(payload(), checkNotNull(machine.binding)))
    }

    @Test
    fun revocation_retires_registration_and_restoration_requests_a_fresh_token() {
        val machine = ready()
        machine.onEnrollmentAccepted(1, 1L)
        val old = checkNotNull(machine.binding)
        machine.onMessage(payload(), old)
        val effects = machine.onPermissionReport(false, false)
        assertIs<PushEffect.CancelPresented>(effects[0])
        assertIs<PushEffect.RevokeDestination>(effects[1])
        assertEquals(RegistrationState.Idle, machine.registration)
        assertEquals(MessageReceipt.NotPermitted, machine.onMessage(payload(), old))
        machine.onEnrollmentAccepted(1, 1L)
        assertEquals(RegistrationState.Idle, machine.registration)
        assertIs<PushEffect.RequestToken>(machine.onPermissionReport(true, true).single())
        val effect = assertIs<PushEffect.EnrollDestination>(machine.onToken("provider-token-A").single())
        assertTrue(effect.tokenGeneration > old.tokenGeneration)
    }

    @Test
    fun owner_session_end_is_synchronous_terminal_and_owner_bound() {
        val first = ready()
        first.onEnrollmentAccepted(1, 1L)
        val previous = checkNotNull(first.binding)
        first.onMessage(payload(), previous)
        assertEquals(2, first.endSession().size)
        assertTrue(first.accepted.isEmpty())
        assertTrue(first.endSession().isEmpty())
        assertTrue(first.onToken("provider-token-late").isEmpty())
        assertTrue(first.onAvailability(true).isEmpty())
        assertTrue(first.onPermissionReport(true, true).isEmpty())
        assertTrue(first.retryRegistration().isEmpty())
        assertEquals(MessageReceipt.NotPermitted, first.onMessage(payload(), previous))
        val second = ready("owner-session-B")
        second.onEnrollmentAccepted(1, 1L)
        assertEquals(MessageReceipt.NotPermitted, second.onMessage(payload(), previous))
    }

    @Test
    fun token_loss_and_unsupported_provider_retire_the_destination() {
        for (unavailable in listOf(false, true)) {
            val machine = ready()
            machine.onEnrollmentAccepted(1, 1L)
            val effects = if (unavailable) machine.onAvailability(false) else machine.onToken(null)
            assertIs<PushEffect.CancelPresented>(effects[0])
            assertIs<PushEffect.RevokeDestination>(effects[1])
            assertEquals(null, machine.binding)
        }
    }

    @Test
    fun authoritative_generation_is_distinct_from_local_rotation_counter() {
        val machine = ready()
        machine.onEnrollmentAccepted(1, 777L)
        val binding = checkNotNull(machine.binding)
        assertEquals(1, binding.tokenGeneration)
        assertEquals(777L, binding.serverTokenGeneration)
        val revoke = assertIs<PushEffect.RevokeDestination>(machine.endSession().last())
        assertEquals(binding, revoke.binding)
    }

    private fun machine(owner: String = "owner-session-A") =
        NotificationPushAdapter(PushIdentity("device-0001-aa"), ownerSessionId = owner)

    private fun ready(owner: String = "owner-session-A"): NotificationPushAdapter =
        machine(owner).also {
            it.onPermissionReport(true, true)
            it.onAvailability(true)
            it.onToken("provider-token-A")
        }

    private fun payload() =
        buildJsonObject {
            put("notification_id", "notification-01")
            put("title", "Update")
        }
}
