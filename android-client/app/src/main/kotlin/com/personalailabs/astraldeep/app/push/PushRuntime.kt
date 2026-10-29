// Owns authenticated Android push lifetimes, authorized delivery, conditional cleanup, opaque source navigation and registered UI presence.
package com.personalailabs.astraldeep.app.push

import android.content.Context
import android.content.Intent
import android.util.Log
import com.personalailabs.astraldeep.app.AppConfig
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.transport.voiceDeviceId
import com.personalailabs.astraldeep.core.push.PushBinding
import com.personalailabs.astraldeep.core.push.PushIdentity
import com.personalailabs.astraldeep.core.push.PushLifecycle
import com.personalailabs.astraldeep.core.push.PushPayload
import com.personalailabs.astraldeep.core.push.PushPermissionState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.security.MessageDigest

interface PushCustodyStorage {
    fun loadPushCustody(): String?

    fun savePushCustody(value: String): Boolean

    fun clearPushCustody(): Boolean
}

class PushRuntime(
    context: Context,
    private val identity: PushIdentity,
    private val rest: PushDestinationRest,
    private val provider: PushProviderBackend,
    private val storage: PushCustodyStorage,
    private val sessionIncarnation: (String) -> String?,
    private val currentCustodyAccess: (String) -> String?,
    private val restoreAccess: suspend (String) -> String?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences("astral_push_permission", Context.MODE_PRIVATE)
    private val destinationLock = Mutex()
    private var ownerScope: String? = null
    private var incarnation: String? = null
    private var bindingScope: String? = null
    private var providerRetired = false
    private var access: String? = null
    private var epoch = 0L
    private var foreground = false
    private var uiConnection: String? = null
    private var presenceSequence = 0L
    private var heartbeat: Job? = null
    private var pendingTap: Intent? = null
    private var enrollment = CompletableDeferred<PushBinding?>()
    var inAppListener: ((PushPayload) -> Unit)? = null
    var sourceListener: ((PushSource) -> Boolean)? = null
    var failure: String? = null
        private set
    var adapter: AndroidNotificationAdapter? = null
        private set

    fun start() {
        refreshPermission()
        scope.launch { restoreOwner() }
    }

    fun onAuthenticated(token: String) {
        val nextOwner = ownerScope(token) ?: return
        val nextIncarnation = sessionIncarnation(token)
        if (nextIncarnation == null || !nextIncarnation.matches(Regex("[a-f0-9]{64}"))) {
            failure = "push_session_custody_required"
            if (adapter != null) retire()
            return
        }
        if (ownerScope != nextOwner || incarnation != nextIncarnation) {
            if (ownerScope != null) pendingTap = null
            if (ownerScope != null || adapter != null) retire()
            epoch += 1
            failure = null
            providerRetired = false
            ownerScope = nextOwner
            incarnation = nextIncarnation
            bindingScope = tokenFingerprint(nextOwner + "\u0000" + nextIncarnation)
            access = token
            enrollment = CompletableDeferred()
            val capturedEpoch = epoch
            val capturedOwner = nextOwner
            val capturedIncarnation = nextIncarnation
            val capturedBindingScope = checkNotNull(bindingScope)
            var revokeAccess = token
            lateinit var current: AndroidNotificationAdapter
            current =
                AndroidNotificationAdapter(
                    appContext, provider, identity, capturedBindingScope,
                    inAppListener = { payload -> if (isCurrent(capturedEpoch, current.machine.binding)) inAppListener?.invoke(payload) },
                    acknowledgeListener = { binding, id ->
                        val credential = access.takeIf { isCurrent(capturedEpoch, binding) }
                        if (credential != null) {
                            scope.launch {
                                val result = rest.acknowledge(credential, binding.deviceId, id)
                                if (isCurrent(capturedEpoch, binding) && result != PushAckOutcome.Acknowledged) {
                                    failure = "push_ack_unconfirmed"
                                }
                            }
                        }
                    },
                    enrollListener = { effect ->
                        if (capturedEpoch == epoch && adapter === current) {
                            enrollment.complete(null)
                            enrollment = CompletableDeferred()
                        }
                        scope.launch {
                            val credential = currentAccess(capturedEpoch)
                            destinationLock.withLock {
                                if (capturedEpoch != epoch || adapter !== current) return@withLock
                                val snapshot = rest.destinationSnapshot(credential, effect.deviceId)
                                if (snapshot == null) {
                                    current.onEnrollmentRejected(effect, true, "push_destination_unavailable")
                                    enrollment.complete(null)
                                    return@withLock
                                }
                                val saved =
                                    runCatching {
                                        Json.parseToJsonElement(storage.loadPushCustody() ?: "{}").jsonObject
                                    }.getOrNull()
                                val fingerprint = tokenFingerprint(effect.token)
                                val reusable =
                                    snapshot.active && saved?.get("owner_scope")?.jsonPrimitive?.content == capturedOwner &&
                                        saved["device_id"]?.jsonPrimitive?.content == identity.deviceId &&
                                        saved["session_incarnation"]?.jsonPrimitive?.content == capturedIncarnation &&
                                        saved["server_token_generation"]?.jsonPrimitive?.longOrNull == snapshot.generation &&
                                        saved["destination_revision"]?.jsonPrimitive?.longOrNull == snapshot.revision &&
                                        saved["token_fingerprint"]?.jsonPrimitive?.content == fingerprint
                                val result =
                                    if (reusable) {
                                        PushEnrollOutcome.Accepted(snapshot.generation, snapshot.revision)
                                    } else {
                                        rest.enroll(
                                            credential,
                                            effect.deviceId,
                                            effect.platform,
                                            effect.token,
                                            effect.label, snapshot.revision,
                                        )
                                    }
                                when (result) {
                                    is PushEnrollOutcome.Accepted -> {
                                        if (credential != null) revokeAccess = credential
                                        current.onEnrollmentAccepted(effect, result.serverTokenGeneration, result.destinationRevision)
                                        val binding = current.machine.binding
                                        if (isCurrent(capturedEpoch, binding) && binding != null) {
                                            val saved =
                                                storage.savePushCustody(
                                                    buildJsonObject {
                                                        put("owner_scope", capturedOwner)
                                                        put("session_incarnation", capturedIncarnation)
                                                        put("device_id", binding.deviceId)
                                                        put("server_token_generation", result.serverTokenGeneration)
                                                        put("destination_revision", result.destinationRevision)
                                                        put("token_fingerprint", fingerprint)
                                                    }.toString(),
                                                )
                                            if (saved) {
                                                enrollment.complete(binding)
                                                resolvePendingTap()
                                            } else {
                                                failure = "push_storage_unavailable"
                                                retire()
                                            }
                                        }
                                    }
                                    is PushEnrollOutcome.Rejected -> {
                                        current.onEnrollmentRejected(effect, result.transient, result.code)
                                        if (capturedEpoch == epoch) {
                                            failure = result.code
                                            enrollment.complete(null)
                                        }
                                    }
                                    PushEnrollOutcome.Unauthenticated -> {
                                        current.onEnrollmentRejected(effect, true, "unauthenticated")
                                        if (capturedEpoch == epoch) {
                                            failure = "push_authentication_required"
                                            enrollment.complete(null)
                                        }
                                    }
                                }
                            }
                        }
                    },
                    revokeListener = { effect ->
                        val credential = access.takeIf { ownerScope == capturedOwner && incarnation == capturedIncarnation } ?: revokeAccess
                        val generation = effect.binding.serverTokenGeneration
                        val revision = effect.binding.serverDestinationRevision
                        if (generation != null && revision != null) {
                            scope.launch {
                                destinationLock.withLock {
                                    val currentBinding = adapter?.machine?.binding
                                    if (adapter !== current && currentBinding?.ownerSessionId == capturedBindingScope &&
                                        currentBinding.serverTokenGeneration == generation &&
                                        currentBinding.serverDestinationRevision == revision
                                    ) {
                                        return@withLock
                                    }
                                    val result = rest.revoke(credential, effect.binding.deviceId, generation, revision)
                                    if (result != PushRevokeOutcome.Revoked && result != PushRevokeOutcome.Conflict &&
                                        (capturedEpoch == epoch || ownerScope == null)
                                    ) {
                                        failure = "push_revoke_unconfirmed"
                                    }
                                }
                            }
                        }
                    },
                )
            adapter = current
            current.start()
            if (current.machine.deviceUnsupported) {
                failure = current.machine.unsupportedReason
                enrollment.complete(null)
            }
            current.machine.onLifecycle(if (foreground) PushLifecycle.Foreground else PushLifecycle.Background)
        } else {
            access = token
            adapter?.retryRegistration()
        }
        refreshPermission()
        restartHeartbeat()
        resolvePendingTap()
    }

    fun shouldRequestPermission(): Boolean = preferences.getBoolean("requested", false).not() && adapter?.shouldRequestPermission() == true

    fun shouldOfferPermissionRequest(): Boolean = shouldRequestPermission()

    fun onPermissionResult(granted: Boolean) {
        if (!preferences.edit().putBoolean("requested", true).commit()) failure = "push_storage_unavailable"
        if (!granted && !storage.clearPushCustody()) failure = "push_storage_unavailable"
        if (granted) providerRetired = false
        adapter?.onPermissionResult(granted)
        if (!granted) retireProvider()
    }

    fun refreshPermission() {
        adapter?.refreshPermission(preferences.getBoolean("requested", false))
        val current = adapter?.machine
        if (current?.permission == PushPermissionState.Granted) providerRetired = false
        if (current?.permission == PushPermissionState.Revoked || current?.permission == PushPermissionState.Denied ||
            current?.deviceUnsupported == true
        ) {
            retireSavedDestination()
            retireProvider()
            enrollment.complete(null)
        }
    }

    private fun retireSavedDestination() {
        val saved = storage.loadPushCustody() ?: return
        val row = readCustody()
        val generation = (row?.get("server_token_generation") as? kotlinx.serialization.json.JsonPrimitive)?.longOrNull
        val revision = (row?.get("destination_revision") as? kotlinx.serialization.json.JsonPrimitive)?.longOrNull
        val owner = row?.get("owner_scope")?.jsonPrimitive?.content
        val credential = access
        val captured = epoch
        if (!storage.clearPushCustody()) failure = "push_storage_unavailable"
        if (owner == ownerScope &&
            row?.get("session_incarnation")?.jsonPrimitive?.content == incarnation &&
            generation != null &&
            generation > 0 &&
            revision != null &&
            revision > 0
        ) {
            scope.launch {
                destinationLock.withLock {
                    val result = rest.revoke(credential, identity.deviceId, generation, revision)
                    if (captured == epoch && result != PushRevokeOutcome.Revoked && result != PushRevokeOutcome.Conflict) {
                        failure = "push_revoke_unconfirmed"
                    }
                }
            }
        }
    }

    fun onLifecycleActive() {
        foreground = true
        adapter?.machine?.onLifecycle(PushLifecycle.Foreground)
        refreshPermission()
        restartHeartbeat()
    }

    fun onLifecycleInactive() {
        foreground = false
        adapter?.machine?.onLifecycle(PushLifecycle.Background)
        heartbeat?.cancel()
        heartbeat = null
        publishPresence(false)
    }

    fun onUiConnection(
        generation: String?,
        connected: Boolean,
    ) {
        val next = generation.takeIf { connected }
        if (next != uiConnection) {
            publishPresence(false)
            uiConnection = next
            presenceSequence = 0
            restartHeartbeat()
        }
        resolvePendingTap()
    }

    fun onSignedOut() {
        retire()
        pendingTap = null
    }

    fun onAccountChanged() = onSignedOut()

    private fun retire() {
        if (!storage.clearPushCustody()) failure = "push_storage_unavailable"
        publishPresence(false)
        heartbeat?.cancel()
        heartbeat = null
        adapter?.close()
        adapter = null
        epoch += 1
        access = null
        ownerScope = null
        incarnation = null
        bindingScope = null
        uiConnection = null
        presenceSequence = 0
        enrollment.complete(null)
        retireProvider()
    }

    private fun retireProvider() {
        if (providerRetired) return
        providerRetired = true
        val captured = epoch
        provider.retireRegistration { confirmed ->
            scope.launch {
                if (!confirmed) {
                    Log.w("PushRuntime", "Provider registration cleanup unconfirmed")
                    if (captured == epoch) failure = "push_provider_cleanup_unconfirmed"
                }
            }
        }
    }

    suspend fun refreshProviderToken() {
        withTimeoutOrNull(9000) {
            if (!restoreOwner()) return@withTimeoutOrNull
            val captured = epoch
            val current = adapter ?: return@withTimeoutOrNull
            if (currentAccess(captured) == null) return@withTimeoutOrNull
            val received = CompletableDeferred<String?>()
            provider.requestToken { token -> received.complete(token) }
            val token = received.await()
            if (captured != epoch || adapter !== current || incarnation?.let { currentCustodyAccess(it) } == null) return@withTimeoutOrNull
            current.onProviderToken(token)
            enrollment.await()
        }
    }

    suspend fun receiveProviderMessage(data: Map<String, String>) {
        if (data.keys != setOf("notification_id")) {
            failure = "push_payload_invalid"
            return
        }
        val id = data["notification_id"] ?: return
        if (!PushPayload.NOTIFICATION_ID_REGEX.matches(id)) {
            failure = "push_payload_invalid"
            return
        }
        withTimeoutOrNull(9000) {
            if (!restoreOwner()) return@withTimeoutOrNull
            val capturedEpoch = epoch
            val current = adapter ?: return@withTimeoutOrNull
            if (current.machine.permission != PushPermissionState.Granted) return@withTimeoutOrNull
            val binding = current.machine.binding ?: enrollment.await() ?: return@withTimeoutOrNull
            val credential = currentAccess(capturedEpoch) ?: return@withTimeoutOrNull
            val source =
                rest.authorize(
                    credential,
                    binding.deviceId,
                    checkNotNull(binding.serverTokenGeneration),
                    checkNotNull(binding.serverDestinationRevision),
                    id,
                )
            if (source == null) {
                if (capturedEpoch == epoch) failure = "push_source_unavailable"
                return@withTimeoutOrNull
            }
            if (!isCurrent(capturedEpoch, binding)) return@withTimeoutOrNull
            provider.deliverAuthorized(buildJsonObject { put("notification_id", id) })
        }
    }

    private fun readCustody(): kotlinx.serialization.json.JsonObject? {
        return runCatching {
            val row = Json.parseToJsonElement(storage.loadPushCustody() ?: return null).jsonObject
            if (row.keys !=
                setOf(
                    "owner_scope", "device_id", "server_token_generation", "destination_revision", "token_fingerprint",
                    "session_incarnation",
                )
            ) {
                return null
            }
            for (key in listOf("owner_scope", "token_fingerprint", "session_incarnation")) {
                val value = row[key] as? kotlinx.serialization.json.JsonPrimitive ?: return null
                if (!value.isString || !value.content.matches(Regex("[a-f0-9]{64}"))) return null
            }
            val device = (row["device_id"] as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content
            if (device != identity.deviceId) return null
            for (key in listOf("server_token_generation", "destination_revision")) {
                val value = row[key] as? kotlinx.serialization.json.JsonPrimitive ?: return null
                if (value.isString || value.longOrNull?.let { it in 1..PushDestinationRest.MAX_SEQUENCE } != true) return null
            }
            row
        }.getOrNull()
    }

    private suspend fun restoreOwner(): Boolean {
        if (ownerScope != null && access != null) return true
        val saved = storage.loadPushCustody() ?: return false
        val row = readCustody() ?: return false
        val expected = row["owner_scope"]?.jsonPrimitive?.content ?: return false
        if (row["device_id"]?.jsonPrimitive?.content != identity.deviceId) return false
        val capturedEpoch = epoch
        val token = restoreAccess(expected) ?: return false
        if (epoch != capturedEpoch || storage.loadPushCustody() != saved || ownerScope(token) != expected ||
            sessionIncarnation(token) != row["session_incarnation"]?.jsonPrimitive?.content
        ) {
            return false
        }
        onAuthenticated(token)
        return ownerScope == expected
    }

    fun handleTap(intent: Intent?) {
        if (intent?.action != AndroidNotificationAdapter.ACTION_OPEN) return
        pendingTap = Intent(intent)
        resolvePendingTap()
    }

    private fun resolvePendingTap() {
        val intent = pendingTap ?: return
        val current = adapter ?: return
        val id = current.notificationIdFromTap(intent) ?: return
        if (!foreground || uiConnection == null || sourceListener == null) return
        pendingTap = null
        val capturedEpoch = epoch
        val binding = current.machine.binding ?: return
        val connection = uiConnection
        scope.launch {
            val fresh = currentAccess(capturedEpoch) ?: return@launch
            val source =
                rest.authorize(
                    fresh,
                    binding.deviceId,
                    checkNotNull(binding.serverTokenGeneration),
                    checkNotNull(binding.serverDestinationRevision),
                    id,
                )
            if (!isCurrent(capturedEpoch, binding)) return@launch
            if (source == null) {
                failure = "push_source_unavailable"
                return@launch
            }
            if (!foreground || uiConnection != connection || sourceListener?.invoke(source) != true) {
                pendingTap = intent
                return@launch
            }
            val acknowledged = rest.acknowledge(fresh, binding.deviceId, id)
            if (isCurrent(capturedEpoch, binding) && acknowledged != PushAckOutcome.Acknowledged) failure = "push_ack_unconfirmed"
        }
    }

    private suspend fun currentAccess(captured: Long): String? {
        if (captured != epoch) return null
        val expected = ownerScope ?: return null
        val currentIncarnation = incarnation ?: return null
        val token = currentCustodyAccess(currentIncarnation) ?: return null
        if (ownerScope(token) != expected || sessionIncarnation(token) != currentIncarnation) return null
        access = token
        val expiry =
            runCatching {
                val claims = java.util.Base64.getUrlDecoder().decode(token.split('.')[1]).decodeToString()
                Json.parseToJsonElement(claims).jsonObject["exp"]?.jsonPrimitive?.longOrNull
            }.getOrNull()
        if (expiry != null && expiry > System.currentTimeMillis() / 1000 + 60) return token
        val refreshed = restoreAccess(expected) ?: return null
        if (captured != epoch || ownerScope(refreshed) != expected) return null
        access = refreshed
        return refreshed
    }

    private fun isCurrent(
        capturedEpoch: Long,
        binding: PushBinding?,
    ): Boolean {
        val credential = incarnation?.let { currentCustodyAccess(it) } ?: return false
        return capturedEpoch == epoch && binding != null && binding == adapter?.machine?.binding &&
            binding.ownerSessionId == bindingScope && ownerScope(credential) == ownerScope
    }

    private fun restartHeartbeat() {
        heartbeat?.cancel()
        if (!foreground || uiConnection == null || access == null) return
        heartbeat =
            scope.launch {
                while (isActive && foreground && uiConnection != null) {
                    publishPresence(true)
                    delay(15000)
                }
            }
    }

    private fun publishPresence(active: Boolean) {
        val connection = uiConnection ?: return
        val credential = access ?: return
        if (presenceSequence == PushDestinationRest.MAX_SEQUENCE) {
            failure = "push_presence_sequence_exhausted"
            return
        }
        val sequence = ++presenceSequence
        val captured = epoch
        scope.launch {
            val fresh = if (active) currentAccess(captured) else credential
            val result = rest.presence(fresh, identity.deviceId, connection, sequence, active)
            if (captured == epoch && uiConnection == connection && result == null) failure = "push_presence_unconfirmed"
        }
    }

    companion object {
        private fun tokenFingerprint(token: String): String =
            MessageDigest.getInstance("SHA-256")
                .digest(token.encodeToByteArray()).joinToString("") { "%02x".format(it) }

        fun pushDeviceId(context: Context): String = voiceDeviceId(context)

        fun ownerScope(token: String): String? {
            val owner = ConversationResumeStore.accountFromAccessToken(token) ?: return null
            val claims =
                runCatching {
                    Json.parseToJsonElement(java.util.Base64.getUrlDecoder().decode(token.split('.')[1]).decodeToString()).jsonObject
                }.getOrNull() ?: return null
            val audiences =
                when (val value = claims["aud"]) {
                    is kotlinx.serialization.json.JsonArray ->
                        value.mapNotNull {
                            (it as? kotlinx.serialization.json.JsonPrimitive)?.takeIf {
                                    item ->
                                item.isString
                            }?.content
                        }.sorted()
                    is kotlinx.serialization.json.JsonPrimitive -> if (value.isString) listOf(value.content) else return null
                    null -> emptyList()
                    else -> return null
                }
            val authority = AppConfig.API_BASE.toHttpUrl().newBuilder().fragment(null).query(null).build().toString().trimEnd('/')
            return MessageDigest.getInstance("SHA-256")
                .digest(
                    "$authority\u0000${owner.issuer}\u0000${owner.subject}\u0000${audiences.joinToString("\u0000")}".encodeToByteArray(),
                )
                .joinToString("") { "%02x".format(it) }
        }
    }
}
