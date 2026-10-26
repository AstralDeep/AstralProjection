// Pure decision machine for the Android notification adapter: permission and availability gates,
// provider token enrollment with rotation generation and fingerprints, minimal payload receipt
// with bounded duplicate suppression, and lifecycle-dependent presentation decisions.
// AndroidNotificationAdapter binds these decisions to the OS; a push provider bridge supplies
// token callbacks and message delivery during coordinated app integration.

package com.personalailabs.astraldeep.core.push

import kotlinx.serialization.json.JsonObject
import java.security.MessageDigest

enum class PushLifecycle { Foreground, Background, Terminated }

enum class PushPermissionState { NotDetermined, Granted, Denied, Revoked }

enum class ProviderAvailability { Unknown, Supported, Unsupported }

data class PushIdentity(
    val deviceId: String,
    val label: String? = null,
) {
    init {
        require(DEVICE_ID_REGEX.matches(deviceId)) { REASON_DEVICE_ID }
        require(label == null || label.length <= MAX_LABEL_CHARS) { REASON_LABEL }
    }

    companion object {
        const val MAX_LABEL_CHARS = 64
        val DEVICE_ID_REGEX = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$")
        const val REASON_DEVICE_ID = "device_id"
        const val REASON_LABEL = "label"
    }
}

data class OsNotificationSpec(
    val notificationId: String,
    val displayId: Int,
    val channelId: String,
    val title: String?,
    val body: String?,
    val level: String,
    val chatId: String?,
    val autoCancel: Boolean,
)

sealed interface PushEffect {
    data class RequestToken(val reason: String) : PushEffect

    data class EnrollDestination(
        val deviceId: String,
        val platform: String,
        val token: String,
        val label: String?,
        val tokenGeneration: Int,
    ) : PushEffect

    data class PresentOs(val spec: OsNotificationSpec) : PushEffect

    data class ShowInApp(val payload: PushPayload) : PushEffect

    data class Acknowledge(val deviceId: String, val notificationId: String) : PushEffect

    data class CancelPresented(val notificationIds: List<String>) : PushEffect
}

sealed interface RegistrationState {
    data object Idle : RegistrationState

    data object RequestingToken : RegistrationState

    data object Enrolling : RegistrationState

    data class Registered(val tokenFingerprint: String, val tokenGeneration: Int) : RegistrationState

    data class FailedRetryable(val code: String, val attempts: Int) : RegistrationState

    data class FailedPermanent(val code: String) : RegistrationState
}

sealed interface MessageReceipt {
    data class Accepted(
        val payload: PushPayload,
        val effects: List<PushEffect>,
        val presentedAsOsNotification: Boolean,
    ) : MessageReceipt

    data class Duplicate(val notificationId: String) : MessageReceipt

    data class Malformed(val reason: String) : MessageReceipt

    data object NotPermitted : MessageReceipt

    data object Unsupported : MessageReceipt
}

class NotificationPushAdapter(
    private val identity: PushIdentity,
    private val acceptedCapacity: Int = DEFAULT_ACCEPTED_CAPACITY,
) {
    init {
        require(acceptedCapacity > 0) { "accepted_capacity" }
    }

    var lifecycle: PushLifecycle = PushLifecycle.Terminated
        private set

    var permission: PushPermissionState = PushPermissionState.NotDetermined
        private set

    var availability: ProviderAvailability = ProviderAvailability.Unknown
        private set

    var registration: RegistrationState = RegistrationState.Idle
        private set

    var unsupportedReason: String? = null
        private set

    private val acceptedIds = ArrayDeque<String>()
    private var currentToken: String? = null
    private var currentFingerprint: String? = null
    private var currentGeneration: Int = 0
    private var retryableAttempts: Int = 0

    val platform: String get() = PLATFORM

    val accepted: List<String> get() = acceptedIds.toList()

    val deviceUnsupported: Boolean get() = availability == ProviderAvailability.Unsupported

    fun seedAccepted(ids: Collection<String>) {
        for (id in ids) {
            if (id.isNotBlank() && id !in acceptedIds) remember(id)
        }
    }

    fun onLifecycle(phase: PushLifecycle) {
        lifecycle = phase
    }

    fun onPermissionReport(granted: Boolean, notificationsEnabled: Boolean): List<PushEffect> {
        val previous = permission
        permission =
            when {
                granted && notificationsEnabled -> PushPermissionState.Granted
                granted && !notificationsEnabled -> PushPermissionState.Revoked
                previous == PushPermissionState.Granted || previous == PushPermissionState.Revoked ->
                    PushPermissionState.Revoked
                else -> PushPermissionState.Denied
            }
        return when {
            previous == PushPermissionState.Granted && permission == PushPermissionState.Revoked -> {
                val cancelled = acceptedIds.toList()
                acceptedIds.clear()
                listOf(PushEffect.CancelPresented(cancelled))
            }
            permission == PushPermissionState.Granted -> bootstrapEffects()
            else -> emptyList()
        }
    }

    fun onAvailability(supported: Boolean, reason: String? = null): List<PushEffect> {
        availability = if (supported) ProviderAvailability.Supported else ProviderAvailability.Unsupported
        if (!supported) {
            registration = RegistrationState.Idle
            unsupportedReason = reason ?: REASON_PROVIDER_UNAVAILABLE
            currentToken = null
            currentFingerprint = null
            currentGeneration = 0
            return emptyList()
        }
        unsupportedReason = null
        return bootstrapEffects()
    }

    fun onToken(token: String?): List<PushEffect> {
        if (deviceUnsupported || permission != PushPermissionState.Granted) return emptyList()
        if (token == null) {
            if (registration == RegistrationState.RequestingToken ||
                registration == RegistrationState.Enrolling ||
                registration is RegistrationState.Registered
            ) {
                registration = RegistrationState.FailedRetryable(CODE_TOKEN_UNAVAILABLE, ++retryableAttempts)
                currentToken = null
                currentFingerprint = null
                currentGeneration = 0
            }
            return emptyList()
        }
        val normalized = token.trim()
        if (normalized.isEmpty() || normalized.length > MAX_TOKEN_CHARS || normalized.hasControlChars()) {
            registration = RegistrationState.FailedPermanent(CODE_TOKEN_INVALID)
            return emptyList()
        }
        val fingerprint = tokenFingerprint(normalized)
        if (fingerprint == currentFingerprint) {
            registration = RegistrationState.Registered(fingerprint, currentGeneration)
            retryableAttempts = 0
            return emptyList()
        }
        currentToken = normalized
        currentFingerprint = fingerprint
        currentGeneration += 1
        registration = RegistrationState.Enrolling
        return listOf(enrollEffect(normalized))
    }

    fun onTokenRequestFailed(transient: Boolean, code: String): List<PushEffect> {
        if (registration != RegistrationState.RequestingToken) return emptyList()
        registration =
            if (transient) {
                RegistrationState.FailedRetryable(code, ++retryableAttempts)
            } else {
                RegistrationState.FailedPermanent(code)
            }
        return emptyList()
    }

    fun onEnrollmentAccepted(): List<PushEffect> {
        val fingerprint = currentFingerprint
        if (registration != RegistrationState.Enrolling || fingerprint == null) return emptyList()
        registration = RegistrationState.Registered(fingerprint, currentGeneration)
        retryableAttempts = 0
        return emptyList()
    }

    fun onEnrollmentRejected(transient: Boolean, code: String): List<PushEffect> {
        if (registration != RegistrationState.Enrolling) return emptyList()
        registration =
            if (transient) {
                RegistrationState.FailedRetryable(code, ++retryableAttempts)
            } else {
                RegistrationState.FailedPermanent(code)
            }
        return emptyList()
    }

    fun retryRegistration(): List<PushEffect> {
        if (deviceUnsupported || permission != PushPermissionState.Granted) return emptyList()
        return when (registration) {
            is RegistrationState.FailedRetryable -> {
                val token = currentToken
                if (token != null) {
                    registration = RegistrationState.Enrolling
                    listOf(enrollEffect(token))
                } else {
                    registration = RegistrationState.RequestingToken
                    listOf(PushEffect.RequestToken(REASON_RETRY))
                }
            }
            RegistrationState.Idle -> bootstrapEffects()
            else -> emptyList()
        }
    }

    fun onMessage(data: JsonObject): MessageReceipt {
        if (deviceUnsupported) return MessageReceipt.Unsupported
        val decoded = decodePushPayload(data)
        val payload =
            when (decoded) {
                is PushPayloadResult.Decoded -> decoded.payload
                is PushPayloadResult.Malformed -> return MessageReceipt.Malformed(decoded.reason)
            }
        if (payload.notificationId in acceptedIds) return MessageReceipt.Duplicate(payload.notificationId)
        return when {
            lifecycle == PushLifecycle.Foreground -> {
                remember(payload.notificationId)
                MessageReceipt.Accepted(
                    payload,
                    listOf(
                        PushEffect.ShowInApp(payload),
                        PushEffect.Acknowledge(identity.deviceId, payload.notificationId),
                    ),
                    presentedAsOsNotification = false,
                )
            }
            permission == PushPermissionState.Granted -> {
                remember(payload.notificationId)
                MessageReceipt.Accepted(
                    payload,
                    listOf(
                        PushEffect.PresentOs(specFor(payload)),
                        PushEffect.Acknowledge(identity.deviceId, payload.notificationId),
                    ),
                    presentedAsOsNotification = true,
                )
            }
            else -> MessageReceipt.NotPermitted
        }
    }

    fun onDismissed(notificationId: String): Boolean = acceptedIds.removeAll { it == notificationId }

    private fun enrollEffect(token: String): PushEffect =
        PushEffect.EnrollDestination(identity.deviceId, PLATFORM, token, identity.label, currentGeneration)

    private fun specFor(payload: PushPayload): OsNotificationSpec =
        OsNotificationSpec(
            notificationId = payload.notificationId,
            displayId = payload.displayId,
            channelId = if (payload.level == PushPayload.LEVEL_ERROR) PushChannels.ALERTS else PushChannels.DEFAULT,
            title = payload.title,
            body = payload.body,
            level = payload.level,
            chatId = payload.chatId,
            autoCancel = true,
        )

    private fun bootstrapEffects(): List<PushEffect> {
        if (permission != PushPermissionState.Granted ||
            availability != ProviderAvailability.Supported ||
            registration != RegistrationState.Idle
        ) {
            return emptyList()
        }
        registration = RegistrationState.RequestingToken
        return listOf(PushEffect.RequestToken(REASON_BOOTSTRAP))
    }

    private fun remember(notificationId: String) {
        if (notificationId !in acceptedIds) acceptedIds.addLast(notificationId)
        while (acceptedIds.size > acceptedCapacity) acceptedIds.removeFirst()
    }

    private companion object {
        const val PLATFORM = "android"
        const val DEFAULT_ACCEPTED_CAPACITY = 64
        const val MAX_TOKEN_CHARS = 4096
        const val CODE_TOKEN_UNAVAILABLE = "provider_token_unavailable"
        const val CODE_TOKEN_INVALID = "token_invalid"
        const val REASON_BOOTSTRAP = "bootstrap"
        const val REASON_RETRY = "retry"
        const val REASON_PROVIDER_UNAVAILABLE = "provider_unavailable"
    }
}

object PushChannels {
    const val DEFAULT = "astral_push"
    const val ALERTS = "astral_push_alerts"
}

private fun String.hasControlChars(): Boolean = any { it.code < 0x20 || it.code == 0x7F }

private fun tokenFingerprint(token: String): String =
    MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
