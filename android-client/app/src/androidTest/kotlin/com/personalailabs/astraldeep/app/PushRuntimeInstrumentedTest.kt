// Exercises owner-fenced application push integration through real Android notifications and local HTTP responses, including late callbacks and persisted permission decisions.
package com.personalailabs.astraldeep.app

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.push.PushCustodyStorage
import com.personalailabs.astraldeep.app.push.PushDestinationRest
import com.personalailabs.astraldeep.app.push.PushProviderBackend
import com.personalailabs.astraldeep.app.push.PushRuntime
import com.personalailabs.astraldeep.app.push.PushSource
import com.personalailabs.astraldeep.core.push.PushIdentity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class PushRuntimeInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val notices = context.getSystemService(NotificationManager::class.java)
    private val requests = CopyOnWriteArrayList<RecordedRequest>()
    private val runtimes = mutableListOf<PushRuntime>()
    private val scopes = mutableListOf<CoroutineScope>()
    private lateinit var server: MockWebServer
    private var inboxGate: CountDownLatch? = null
    private val inboxArrived = CountDownLatch(1)
    private var enrollGate: CountDownLatch? = null
    private val enrollArrived = CountDownLatch(1)
    private val enrollCount = AtomicInteger()
    private var allowSource = true

    @Before
    fun prepare() {
        val args = InstrumentationRegistry.getArguments()
        if (args.getString("pushPreservePermission") != "true") {
            context.getSharedPreferences("astral_push_permission", 0).edit().clear().commit()
        }
        if (args.getString("pushPermissionDenied") != "true") shell("pm grant ${context.packageName} ${Manifest.permission.POST_NOTIFICATIONS}")
        notices.cancelAll()
        server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    requests.add(request)
                    val path = request.path.orEmpty()
                    if (request.method == "DELETE") return MockResponse().setResponseCode(204)
                    if (path == "/api/push/destinations") {
                        val count = enrollCount.incrementAndGet()
                        if (count == 1) {
                            enrollArrived.countDown()
                            enrollGate?.await(10, TimeUnit.SECONDS)
                        }
                        return ok("""{"device_id":"device-0001-aa","platform":"android","status":"active","token_generation":42,"updated_at":${98 + enrollCount.get()},"destination_revision":${98 + enrollCount.get()}}""")
                    }
                    if (path == "/api/push/destinations/device-0001-aa") return ok("""{"device_id":"device-0001-aa","status":"active","token_generation":42,"updated_at":${98 + enrollCount.get()},"destination_revision":${98 + enrollCount.get()}}""")
                    if (path.startsWith("/api/push/deliveries/")) return ok("""[{"action":"push.delivery.queued","device_id":"device-0001-aa","token_generation":42,"updated_at":${98 + enrollCount.get()},"destination_revision":${98 + enrollCount.get()}}]""")
                    if (path.startsWith("/api/notifications/inbox/")) {
                        inboxArrived.countDown()
                        inboxGate?.await(10, TimeUnit.SECONDS)
                        if (!allowSource) return MockResponse().setResponseCode(404)
                        val id = path.substringAfterLast('/')
                        return ok("""{"entry_id":"$id","revision":0,"deleted_at":null,"content":{"chat_id":"$CHAT"}}""")
                    }
                    if (path == "/api/push/ack") return MockResponse().setResponseCode(204)
                    if (path == "/api/notifications/presence") {
                        val body = request.body.clone().readUtf8()
                        val sequence = Regex("\"sequence\":([0-9]+)").find(body)!!.groupValues[1]
                        val expiry = if (body.contains("\"foreground\":true")) 45 else 0
                        return ok("""{"accepted_sequence":$sequence,"expires_in_seconds":$expiry}""")
                    }
                    return MockResponse().setResponseCode(404)
                }
            }
        server.start()
        if (args.getString("pushPreservePermission") == "true") {
            assertTrue(context.getSharedPreferences("astral_push_permission", 0).getBoolean("requested", false))
            assertFalse(notices.areNotificationsEnabled())
        }
    }

    @After
    fun cleanup() {
        inboxGate?.countDown()
        enrollGate?.countDown()
        onMain { runtimes.forEach { it.onSignedOut() } }
        scopes.forEach { it.cancel() }
        notices.cancelAll()
        server.shutdown()
    }

    @Test
    fun provider_receipt_waits_for_owned_source_before_generic_notice_and_ack() {
        inboxGate = CountDownLatch(1)
        val runtime = runtime()
        authenticate(runtime)
        val job = scopes.last().launch { runtime.receiveProviderMessage(mapOf("notification_id" to ENTRY)) }
        assertTrue(inboxArrived.await(5, TimeUnit.SECONDS))
        assertTrue(notices.activeNotifications.isEmpty())
        assertFalse(requests.any { it.path == "/api/push/ack" })
        inboxGate!!.countDown()
        runBlocking { job.join() }
        await { notices.activeNotifications.size == 1 && requests.any { it.path == "/api/push/ack" } }
        assertTrue(notices.activeNotifications.single().notification.extras.getString("android.text")!!.contains("Open AstralDeep"))
        assertEquals(4, requests.count { it.method == "GET" })
    }

    @Test
    fun unavailable_source_and_nonopaque_provider_payload_never_present_or_ack() {
        allowSource = false
        val runtime = runtime()
        authenticate(runtime)
        runBlocking {
            withContext(Dispatchers.Main) {
                runtime.receiveProviderMessage(mapOf("notification_id" to ENTRY))
                runtime.receiveProviderMessage(mapOf("notification_id" to ENTRY, "title" to "forged"))
            }
        }
        assertTrue(notices.activeNotifications.isEmpty())
        assertFalse(requests.any { it.path == "/api/push/ack" })
        assertEquals("push_payload_invalid", runtime.failure)
    }

    @Test
    fun logout_retires_local_state_before_inflight_source_response_and_conditional_revoke() {
        inboxGate = CountDownLatch(1)
        val runtime = runtime()
        authenticate(runtime)
        val old = runtime.adapter!!
        val job = scopes.last().launch { runtime.receiveProviderMessage(mapOf("notification_id" to ENTRY)) }
        assertTrue(inboxArrived.await(5, TimeUnit.SECONDS))
        onMain { runtime.onSignedOut() }
        assertNull(runtime.adapter)
        assertTrue(old.machine.accepted.isEmpty())
        inboxGate!!.countDown()
        runBlocking { job.join() }
        await { requests.any { it.method == "DELETE" } }
        assertTrue(requests.first { it.method == "DELETE" }.path!!.endsWith("expected_token_generation=42&expected_destination_revision=99"))
        assertTrue(notices.activeNotifications.isEmpty())
        assertFalse(requests.any { it.path == "/api/push/ack" })
    }

    @Test
    fun late_same_owner_enrollment_cleanup_only_carries_its_captured_revision() {
        enrollGate = CountDownLatch(1)
        val runtime = runtime()
        onMain { runtime.onAuthenticated(token("owner-A")) }
        assertTrue(enrollArrived.await(5, TimeUnit.SECONDS))
        onMain {
            runtime.onSignedOut()
            runtime.onAuthenticated(token("owner-A"))
        }
        enrollGate!!.countDown()
        await { enrollCount.get() == 2 && runtime.adapter?.machine?.binding?.serverTokenGeneration == 42L }
        onMain { assertTrue(requests.filter { it.method == "DELETE" }.all { it.path!!.endsWith("expected_destination_revision=99") }) }
        assertEquals(42L, runtime.adapter!!.machine.binding!!.serverTokenGeneration)
        assertEquals(100L, runtime.adapter!!.machine.binding!!.serverDestinationRevision)
    }

    @Test
    fun real_tap_opens_server_source_only_after_current_registration_and_connection() {
        val runtime = runtime()
        authenticate(runtime)
        runBlocking { withContext(Dispatchers.Main) { runtime.receiveProviderMessage(mapOf("notification_id" to ENTRY)) } }
        await { notices.activeNotifications.size == 1 }
        val tap = AtomicReference<Intent>()
        val sent = CountDownLatch(1)
        notices.activeNotifications.single().notification.contentIntent.send(context, 0, null, { _, intent, _, _, _ ->
            tap.set(intent)
            sent.countDown()
        }, null)
        assertTrue(sent.await(5, TimeUnit.SECONDS))
        val opened = CopyOnWriteArrayList<PushSource>()
        onMain {
            runtime.sourceListener = {
                opened.add(it)
                true
            }
            runtime.handleTap(tap.get())
        }
        assertTrue(opened.isEmpty())
        onMain {
            runtime.onLifecycleActive()
            runtime.onUiConnection("connection-A", true)
        }
        await { opened.isNotEmpty() }
        assertEquals(CHAT, opened.single().chatId)
        assertEquals(ENTRY, opened.single().notificationId)
        val foreground = requests.first { it.path == "/api/notifications/presence" }.body.clone().readUtf8()
        assertTrue(foreground.contains("\"foreground\":true"))
        onMain { runtime.onLifecycleInactive() }
        await { requests.count { it.path == "/api/notifications/presence" } >= 2 }
        val background = requests.last { it.path == "/api/notifications/presence" }.body.clone().readUtf8()
        assertTrue(background.contains("\"foreground\":false"))
    }

    @Test
    fun malformed_or_legacy_custody_cannot_restore_an_owner_or_present() {
        val owner = PushRuntime.ownerScope(token("owner-A"))!!
        for (raw in listOf(
            "not-json",
            "[]",
            "{}",
            """{"owner_scope":{},"device_id":"device-0001-aa"}""",
            """{"owner_scope":"$owner","device_id":"device-0001-aa","server_token_generation":42,"destination_revision":true,"token_fingerprint":"${"a".repeat(64)}"}""",
            """{"owner_scope":"$owner","device_id":"device-0001-aa","server_token_generation":"42","destination_revision":99,"token_fingerprint":"${"a".repeat(64)}"}""",
        )) {
            val storage = MemoryStorage()
            storage.savePushCustody(raw)
            val runtime = runtime(storage)
            onMain { runtime.start() }
            assertNull(runtime.adapter)
        }
        assertTrue(requests.isEmpty())
        assertTrue(notices.activeNotifications.isEmpty())
    }

    @Test
    fun cold_owner_reattachment_preserves_two_distinct_taps_without_a_new_claim() {
        val storage = MemoryStorage()
        val first = runtime(storage)
        authenticate(first)
        val secondId = "58873d61-2e9b-4f38-bc36-bbfa81d78580"
        runBlocking {
            withContext(Dispatchers.Main) {
                first.receiveProviderMessage(mapOf("notification_id" to ENTRY))
                first.receiveProviderMessage(mapOf("notification_id" to secondId))
            }
        }
        await { notices.activeNotifications.size == 2 }
        val intents =
            notices.activeNotifications.map { note ->
                val result = AtomicReference<Intent>()
                val latch = CountDownLatch(1)
                note.notification.contentIntent.send(context, 0, null, { _, intent, _, _, _ ->
                    result.set(intent)
                    latch.countDown()
                }, null)
                assertTrue(latch.await(5, TimeUnit.SECONDS))
                result.get()
            }
        val replacement = runtime(storage)
        val opened = CopyOnWriteArrayList<String>()
        onMain {
            replacement.start()
            replacement.sourceListener = {
                opened.add(it.notificationId)
                true
            }
            replacement.onLifecycleActive()
            replacement.onUiConnection("cold-connection", true)
        }
        await { replacement.adapter?.machine?.binding?.serverDestinationRevision == 99L }
        for (intent in intents) {
            onMain { replacement.handleTap(intent) }
            await { opened.size > intents.indexOf(intent) }
        }
        assertEquals(setOf(ENTRY, secondId), opened.toSet())
        assertEquals(1, enrollCount.get())
    }

    @Test
    fun fresh_same_owner_session_cannot_reattach_old_custody_and_legacy_cannot_enroll() {
        val storage = MemoryStorage()
        val first = runtime(storage)
        authenticate(first)
        val old = first.adapter!!.machine.binding!!
        val replacement = runtime(storage, "d".repeat(64))
        onMain { replacement.start() }
        assertNull(replacement.adapter)
        onMain { replacement.onAuthenticated(token("owner-A")) }
        await { replacement.adapter?.machine?.binding?.serverDestinationRevision == 100L }
        assertTrue(old.ownerSessionId != replacement.adapter!!.machine.binding!!.ownerSessionId)
        assertEquals(2, enrollCount.get())
        val legacy = runtime(MemoryStorage(), null)
        onMain { legacy.onAuthenticated(token("owner-A")) }
        assertNull(legacy.adapter)
        assertEquals("push_session_custody_required", legacy.failure)
        assertTrue(requests.filter { it.method == "POST" && it.path == "/api/push/destinations" }.all { it.getHeader("Cookie") == "astral_session=synthetic" })
    }

    @Test
    fun provider_refresh_signal_reads_current_sdk_state_and_logout_retires_it() {
        val provider = Provider()
        val runtime = runtime(provider = provider)
        authenticate(runtime)
        provider.nextToken = "provider-token-02"
        runBlocking { withContext(Dispatchers.Main) { runtime.refreshProviderToken() } }
        await { runtime.adapter?.machine?.binding?.serverDestinationRevision == 100L }
        assertEquals(2, enrollCount.get())
        val queries = provider.tokenRequests
        onMain { runtime.onSignedOut() }
        assertTrue(provider.retireRequests > 0)
        provider.nextToken = "late-token-03"
        runBlocking { withContext(Dispatchers.Main) { runtime.refreshProviderToken() } }
        assertEquals(queries, provider.tokenRequests)
        assertNull(runtime.adapter)
    }

    @Test
    fun permission_decision_is_persisted_and_reloaded_for_denied_startup() {
        val runtime = runtime()
        onMain {
            runtime.onAuthenticated(token("owner-A"))
            runtime.onPermissionResult(false)
            runtime.onSignedOut()
        }
        val replacement = runtime()
        onMain { replacement.onAuthenticated(token("owner-A")) }
        assertFalse(replacement.shouldOfferPermissionRequest())
        assertTrue(context.getSharedPreferences("astral_push_permission", 0).getBoolean("requested", false))
        if (InstrumentationRegistry.getArguments().getString("pushPermissionDenied") == "true") {
            assertEquals(com.personalailabs.astraldeep.core.push.PushPermissionState.Denied, replacement.adapter!!.machine.permission)
            runBlocking { withContext(Dispatchers.Main) { replacement.receiveProviderMessage(mapOf("notification_id" to ENTRY)) } }
            assertTrue(notices.activeNotifications.isEmpty())
            assertFalse(requests.any { it.path == "/api/push/ack" })
        }
    }

    private fun runtime(
        storage: MemoryStorage = MemoryStorage(),
        incarnation: String? = "c".repeat(64),
        provider: Provider = Provider(),
    ): PushRuntime {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        scopes.add(scope)
        val runtime =
            PushRuntime(
                context,
                PushIdentity("device-0001-aa"),
                PushDestinationRest(server.url("/").toString(), sessionHeaders = { mapOf("Cookie" to "astral_session=synthetic", "Origin" to server.url("/").toString()) }),
                provider,
                storage,
                sessionIncarnation = { incarnation },
                currentCustodyAccess = { expected -> token("owner-A").takeIf { expected == incarnation } },
                restoreAccess = { expected -> token("owner-A").takeIf { PushRuntime.ownerScope(it) == expected } },
                scope = scope,
            )
        runtimes.add(runtime)
        return runtime
    }

    private fun authenticate(runtime: PushRuntime) {
        onMain { runtime.onAuthenticated(token("owner-A")) }
        await { runtime.adapter?.machine?.binding?.serverTokenGeneration == 42L }
    }

    private fun onMain(action: () -> Unit) = instrumentation.runOnMainSync(action)

    private fun await(condition: () -> Boolean) {
        for (i in 0 until 250) {
            if (condition())return
            Thread.sleep(20)
        }
        assertTrue(condition())
    }

    private fun shell(command: String) {
        instrumentation.uiAutomation.executeShellCommand(command).use { ParcelFileDescriptor.AutoCloseInputStream(it).readBytes() }
    }

    private fun ok(body: String) = MockResponse().setResponseCode(200).setBody(body)

    private fun token(owner: String): String {
        val claims = """{"iss":"https://issuer.example.test/realms/Astral","sub":"$owner","exp":4102444800}"""
        return "header." + Base64.getUrlEncoder().withoutPadding().encodeToString(claims.encodeToByteArray()) + ".signature"
    }

    private class MemoryStorage : PushCustodyStorage {
        var value: String? = null

        override fun loadPushCustody() = value

        override fun savePushCustody(value: String): Boolean {
            this.value = value
            return true
        }

        override fun clearPushCustody(): Boolean {
            value = null
            return true
        }
    }

    private class Provider : PushProviderBackend {
        private var listener: ((JsonObject) -> Unit)? = null
        var nextToken: String? = "provider-token-A"
        var tokenRequests = 0
        var retireRequests = 0

        override fun isSupported() = true

        override fun requestToken(onResult: (String?) -> Unit) {
            tokenRequests += 1
            onResult(nextToken)
        }

        override fun setMessageListener(onMessage: (JsonObject) -> Unit) {
            listener = onMessage
        }

        override fun retireRegistration(onComplete: (Boolean) -> Unit) {
            retireRequests += 1
            onComplete(true)
        }

        override fun deliverAuthorized(data: JsonObject) {
            listener?.invoke(data)
        }
    }

    companion object {
        const val ENTRY = "48873d61-2e9b-4f38-bc36-bbfa81d78580"
        const val CHAT = "180cd30b-cc38-432d-8349-1851b0d3ad7e"
    }
}
