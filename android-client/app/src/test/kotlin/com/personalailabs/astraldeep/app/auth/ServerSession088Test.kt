// Tests for Android's WS session bootstrap over TLS: a per-run self-signed loopback certificate proves
// registration is refused on a retired connection ticket before the bearer token is written.

package com.personalailabs.astraldeep.app.auth

import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.net.InetAddress
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ServerSession088Test {
    private val now = Instant.parse("2026-09-13T00:00:00Z")
    private val issuer = "https://iam.example/realms/Astral"
    private val owner = "test-owner"
    private val token = jwt(owner)
    private val cookie = "astral_session=opaque.signed"
    private val cookieHeader = "$cookie; HttpOnly; Max-Age=3600; Path=/; SameSite=lax; Secure"

    private fun jwt(
        user: String,
        suffix: String = "signature",
    ): String {
        val payload =
            buildJsonObject {
                put("iss", issuer)
                put("sub", user)
                put("exp", 1900000000)
            }.toString()
        return "header.${Base64.getUrlEncoder().withoutPadding().encodeToString(payload.encodeToByteArray())}.$suffix"
    }

    private fun scope(backend: String = "https://localhost/"): ServerSessionScope =
        ServerSessionScope(backend, issuer, "astral-mobile", "com.personalailabs.astraldeep:/oauth2redirect")

    private fun issued(
        access: String = token,
        user: String = owner,
    ): String =
        buildJsonObject {
            put("authenticated", true)
            put("access_token", access)
            put("token_type", "Bearer")
            put("expires_in", 300)
            put("user_id", user)
            put("resumed", false)
        }.toString()

    private fun refreshed(
        access: String = token,
        user: String = owner,
    ): String =
        buildJsonObject {
            put("authenticated", true)
            put("access_token", access)
            put("user_id", user)
            put("resumed", true)
        }.toString()

    private fun json(body: String): MockResponse = MockResponse().setHeader("Content-Type", "application/json").setBody(body)

    @Test fun probe_requires_valid_anonymous_response_and_never_falls_back_on_failure() =
        runBlocking<Unit> {
            Fixture().use { f ->
                val transport = ServerSessionTransport(scope(f.origin), f.client) { now }
                val anonymous = "{\"authenticated\":false,\"access_token\":\"\",\"resumed\":false,\"reason\":\"no_session\"}"
                f.server.enqueue(json(anonymous).setHeader("X-Astral-Session-Custody", "server_v1"))
                assertTrue(transport.probe())
                f.server.enqueue(json(anonymous))
                assertFalse(transport.probe())
                f.server.enqueue(json(anonymous).setHeader("X-Astral-Session-Custody", "future_v2"))
                assertFalse(transport.probe())
                for (response in listOf(
                    json(anonymous).addHeader("X-Astral-Session-Custody", "server_v1").addHeader("X-Astral-Session-Custody", "server_v1"),
                    json(anonymous).setHeader("Set-Cookie", cookieHeader),
                    json(refreshed()),
                    json("{}"),
                    MockResponse().setResponseCode(503),
                    MockResponse().setResponseCode(302).setHeader("Location", f.server.url("/other")),
                )) {
                    f.server.enqueue(response)
                    assertFailsWith<ServerSessionException> { transport.probe() }
                }
                assertEquals(9, f.server.requestCount)
                repeat(9) {
                    val request = f.server.takeRequest()
                    assertEquals("/auth/session", request.path)
                    assertNull(request.getHeader("Cookie"))
                    assertNull(request.getHeader("Authorization"))
                    assertNull(request.getHeader("Origin"))
                }
            }
        }

    @Test fun publication_fence_refuses_old_probe_exchange_restore_and_consumed_callbacks() {
        val fence = AuthAttemptFence()
        val restore = fence.capture()
        val first = fence.begin()
        assertFailsWith<ServerSessionException> { fence.publish(restore) { error("stale restore") } }
        fence.select(first, AuthAttemptFence.Mode.SERVER)
        assertEquals(AuthAttemptFence.Mode.SERVER, fence.currentMode())
        fence.consume(first)
        assertFailsWith<ServerSessionException> { fence.consume(first) }
        assertFailsWith<ServerSessionException> { fence.select(first, AuthAttemptFence.Mode.LEGACY) }
        val next = fence.begin()
        assertFailsWith<ServerSessionException> { fence.guarded(first) { error("stale exchange") } }
        fence.select(next, AuthAttemptFence.Mode.SERVER)
        assertEquals("current", fence.publish(next) { "current" })
        fence.retire()
        assertFailsWith<ServerSessionException> { fence.publish(next) { error("late logout") } }
    }

    @Test fun lost_exchange_acknowledgement_has_one_send_and_storage_failure_never_publishes() =
        runBlocking<Unit> {
            Fixture().use { f ->
                val transport = ServerSessionTransport(scope(f.origin), f.client) { now }
                val memory = Memory()
                val controller = ServerSessionCoordinator(transport, memory) { now }
                val attempt = controller.begin()
                f.server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
                assertFailsWith<ServerSessionException> {
                    controller.exchange(attempt, ServerAuthorizationCode(transport.scope, "once", "v".repeat(43)))
                }
                assertFailsWith<ServerSessionException> {
                    controller.exchange(attempt, ServerAuthorizationCode(transport.scope, "once", "v".repeat(43)))
                }
                assertEquals(1, f.server.requestCount)
                assertNull(memory.value)
                val next = controller.begin()
                memory.fail = true
                f.server.enqueue(json(issued()).setHeader("Set-Cookie", cookieHeader))
                assertEquals(
                    ServerSessionException.Reason.STORAGE,
                    assertFailsWith<ServerSessionException> {
                        controller.exchange(next, ServerAuthorizationCode(transport.scope, "new-code", "v".repeat(43)))
                    }.reason,
                )
                assertFailsWith<ServerSessionException> { controller.withToken(token) { error("not durable") } }
                assertNull(memory.value)
            }
        }

    private class Memory : ServerSessionPersistence {
        var value: ServerSession? = null
        var saves = 0
        var fail = false

        override fun loadSession(
            scope: ServerSessionScope,
            now: Instant,
        ): ServerSession? = value

        override fun saveSession(session: ServerSession): Boolean {
            if (fail) return false
            saves++
            value = session
            return true
        }

        override fun clearSession(scope: ServerSessionScope): Boolean {
            value = null
            return !fail
        }
    }

    private class Fixture : AutoCloseable {
        val server = MockWebServer()
        val client: OkHttpClient

        // MockWebServer's own url() uses a reverse-DNS host, not loopback
        val origin: String get() = "https://localhost:${server.port}/"

        val socketOrigin: String get() = "wss://localhost:${server.port}/"

        init {
            val password = "test-only".toCharArray()
            val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
            val certificate = LoopbackCertificate.selfSigned(pair)
            val store = KeyStore.getInstance("PKCS12").apply { load(null, null) }
            store.setKeyEntry("custody-localhost", pair.private, password, arrayOf(certificate))
            val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, password) }
            val trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
            val ssl = SSLContext.getInstance("TLS").apply { init(keys.keyManagers, trust.trustManagers, null) }
            server.useHttps(ssl.socketFactory, false)
            server.start()
            client = OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory, trust.trustManagers.single() as X509TrustManager).build()
        }

        override fun close() {
            server.shutdown()
            client.dispatcher.executorService.shutdown()
            client.connectionPool.evictAll()
        }
    }

    private object LoopbackCertificate {
        private const val SHA256_WITH_RSA = "1.2.840.113549.1.1.11"
        private const val COMMON_NAME = "2.5.4.3"
        private const val SUBJECT_ALT_NAME = "2.5.29.17"

        fun selfSigned(pair: KeyPair): X509Certificate {
            val algorithm = sequence(oid(SHA256_WITH_RSA), byteArrayOf(0x05, 0x00))
            val name = sequence(tlv(0x31, sequence(oid(COMMON_NAME), tlv(0x0c, "localhost".encodeToByteArray()))))
            val notBefore = Instant.now().minusSeconds(3600)
            val altNames =
                sequence(
                    tlv(0x82, "localhost".encodeToByteArray()),
                    tlv(0x87, byteArrayOf(127, 0, 0, 1)),
                    tlv(0x87, ByteArray(16).also { it[15] = 1 }),
                )
            val extensions = sequence(sequence(oid(SUBJECT_ALT_NAME), tlv(0x04, altNames)))
            val tbs =
                sequence(
                    tlv(0xa0, integer(BigInteger.TWO)),
                    integer(BigInteger.ONE),
                    algorithm,
                    name,
                    sequence(utcTime(notBefore), utcTime(notBefore.plusSeconds(2 * 24 * 3600))),
                    name,
                    pair.public.encoded,
                    tlv(0xa3, extensions),
                )
            val signature =
                Signature.getInstance("SHA256withRSA").apply {
                    initSign(pair.private)
                    update(tbs)
                }.sign()
            val der = sequence(tbs, algorithm, tlv(0x03, byteArrayOf(0) + signature))
            return CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(der)) as X509Certificate
        }

        private fun sequence(vararg items: ByteArray): ByteArray = tlv(0x30, items.fold(ByteArray(0)) { acc, item -> acc + item })

        private fun integer(value: BigInteger): ByteArray = tlv(0x02, value.toByteArray())

        private fun utcTime(instant: Instant): ByteArray =
            tlv(0x17, DateTimeFormatter.ofPattern("yyMMddHHmmss'Z'").withZone(ZoneOffset.UTC).format(instant).encodeToByteArray())

        private fun oid(dotted: String): ByteArray {
            val arcs = dotted.split('.').map { it.toInt() }
            val out = ByteArrayOutputStream()

            fun base128(value: Int) {
                val bytes = ArrayDeque<Int>()
                var rest = value
                bytes.addFirst(rest and 0x7f)
                rest = rest shr 7
                while (rest > 0) {
                    bytes.addFirst((rest and 0x7f) or 0x80)
                    rest = rest shr 7
                }
                bytes.forEach(out::write)
            }
            base128(arcs[0] * 40 + arcs[1])
            arcs.drop(2).forEach(::base128)
            return tlv(0x06, out.toByteArray())
        }

        private fun tlv(
            tag: Int,
            body: ByteArray,
        ): ByteArray {
            val length =
                when {
                    body.size < 0x80 -> byteArrayOf(body.size.toByte())
                    body.size < 0x100 -> byteArrayOf(0x81.toByte(), body.size.toByte())
                    else -> byteArrayOf(0x82.toByte(), (body.size shr 8).toByte(), body.size.toByte())
                }
            return byteArrayOf(tag.toByte()) + length + body
        }
    }

    @Test fun retirement_during_actual_tls_connection_prevents_registration_on_the_opened_socket() =
        runBlocking<Unit> {
            Fixture().use { f ->
                val entered = CountDownLatch(1)
                val proceed = CountDownLatch(1)
                val held =
                    f.client.newBuilder().dns(
                        object : Dns {
                            override fun lookup(hostname: String): List<InetAddress> {
                                entered.countDown()
                                check(proceed.await(5, TimeUnit.SECONDS))
                                return Dns.SYSTEM.lookup(hostname)
                            }
                        },
                    ).build()
                val transport = ServerSessionTransport(scope(f.origin), held) { now }
                val memory = Memory().apply { value = ServerSession(transport.scope, owner, token, cookie, now.plusSeconds(3600)) }
                val controller = ServerSessionCoordinator(transport, memory) { now }
                controller.restore()
                val frames = CopyOnWriteArrayList<String>()
                val serverSide = CountDownLatch(1)
                f.server.enqueue(
                    MockResponse().withWebSocketUpgrade(
                        object : WebSocketListener() {
                            override fun onMessage(
                                webSocket: WebSocket,
                                text: String,
                            ) {
                                frames.add(text)
                            }

                            override fun onClosing(
                                webSocket: WebSocket,
                                code: Int,
                                reason: String,
                            ) {
                                serverSide.countDown()
                            }

                            override fun onFailure(
                                webSocket: WebSocket,
                                t: Throwable,
                                response: Response?,
                            ) {
                                serverSide.countDown()
                            }
                        },
                    ),
                )
                val client = OrchestratorClient(f.socketOrigin + "ws", held, serverSession = { controller })
                val collecting =
                    launch(Dispatchers.Default) {
                        client.stream(token, DeviceCapabilities(screenWidth = 400, screenHeight = 800)).collect { }
                    }
                try {
                    assertTrue(entered.await(5, TimeUnit.SECONDS), "socket creation passed the fence and OkHttp began connecting")
                    controller.retire()
                } finally {
                    proceed.countDown()
                }
                withTimeout(5000) { collecting.join() }
                val upgrade = assertNotNull(f.server.takeRequest(5, TimeUnit.SECONDS))
                assertEquals("/ws", upgrade.path)
                assertEquals(cookie, upgrade.getHeader("Cookie"), "the ticket was current when the socket was created")
                assertEquals(1, f.server.requestCount)
                assertTrue(serverSide.await(5, TimeUnit.SECONDS), "the client must cancel a socket whose ticket was retired before open")
                assertEquals(emptyList(), frames, "register_ui must never ride a socket whose ticket was retired")
                assertFalse(client.state.value == ConnectionState.Connected)
            }
        }

    @Test fun scopes_and_secret_representations_are_closed() {
        for (backend in listOf("http://localhost", "https://localhost/base", "https://u:p@localhost", "https://localhost/?x=1", "https://localhost/#x")) {
            assertFailsWith<ServerSessionException> { scope(backend) }
        }
        val value = ServerSession(scope(), owner, token, cookie, now.plusSeconds(3600))
        assertFalse(value.toString().contains(token))
        assertFalse(value.toString().contains(cookie))
        assertEquals("ServerSession(private)", value.toString())
        assertEquals(owner, ServerSession.decode(value.encoded(), scope(), now).userId)
        assertFailsWith<ServerSessionException> { ServerSession.decode(value.encoded(), scope("https://other.example/"), now) }
        assertFailsWith<ServerSessionException> { ServerSession.decode(value.encoded(), scope(), now.plusSeconds(3600)) }
        assertFailsWith<ServerSessionException> { ServerSession(scope(), "other", token, cookie, now) }
    }

    @Test fun strict_flat_json_refuses_duplicates_coercion_nesting_trailing_and_invalid_utf8_shapes() {
        for (raw in listOf(
            "{}x", "{\"x\":1,\"x\":2}", "{\"x\":1,\"\\u0078\":2}", "{\"x\":{}}", "{\"x\":[]}",
            "{\"x\":null}", "{\"x\":1e999}", "{\"x\":01}", "{\"x\":-1}", "{\"x\":true,}", "{\"x\":\"unterminated}", " ", "[]",
        )) {
            assertFailsWith<ServerSessionException>(raw) { sessionObject(raw) }
        }
        assertEquals("a\"b", sessionObject(" { \"x\" : \"a\\\"b\" } \n").string("x"))
        assertFailsWith<ServerSessionException> { sessionObject("{\"x\":\"${"a".repeat(32769)}\"}") }
        assertFailsWith<ServerSessionException> { sessionObject("{\"x\":\"true\"}").boolean("x") }
        assertFailsWith<ServerSessionException> { sessionObject("{\"x\":\"1\"}").number("x") }
    }

    @Test fun cookie_requires_exact_server_attributes_and_never_accepts_domain_or_duplicates() {
        val parsed = ServerSessionTransport.issuedCookie(listOf(cookieHeader), now)
        assertEquals(cookie, parsed.first)
        assertEquals(now.plusSeconds(3600), parsed.second)
        val bad =
            listOf(
                emptyList(), listOf(cookieHeader, cookieHeader), listOf(cookieHeader.replace("; Secure", "")),
                listOf(cookieHeader + "; Domain=localhost"), listOf(cookieHeader + "; Path=/"),
                listOf(cookieHeader.replace("lax", "none")), listOf(cookieHeader.replace("Max-Age=3600", "Max-Age=0")),
                listOf(cookieHeader.replace("Path=/", "Path=/auth")), listOf(cookieHeader.replace("astral_session", "other")),
                listOf(cookieHeader.replace("opaque.signed", "bad value")),
            )
        for (headers in bad) assertFailsWith<ServerSessionException> { ServerSessionTransport.issuedCookie(headers, now) }
    }

    @Test fun actual_tls_exchange_refresh_logout_use_fixed_wire_and_no_legacy_refresh_owner() =
        runBlocking<Unit> {
            Fixture().use { f ->
                val transport = ServerSessionTransport(scope(f.origin), f.client) { now }
                f.server.enqueue(json(issued()).setHeader("Set-Cookie", cookieHeader))
                val code = ServerAuthorizationCode(transport.scope, "original-code", "v".repeat(43))
                val session = transport.exchange(code)
                val req = f.server.takeRequest()
                assertEquals("/auth/token", req.path)
                assertEquals("server_v1", req.getHeader("X-Astral-Session-Custody"))
                assertNull(req.getHeader("Origin"))
                assertNull(req.getHeader("Cookie"))
                assertNull(req.getHeader("Authorization"))
                val form = req.body.readUtf8()
                assertTrue(form.contains("code=original-code"))
                assertTrue(form.contains("code_verifier=${"v".repeat(43)}"))
                assertTrue(form.contains("session_custody=server_v1"))
                assertFalse(form.contains("refresh_token"))
                assertFailsWith<ServerSessionException> { transport.exchange(code) }
                f.server.enqueue(json(refreshed(jwt(owner, "newsignature"))))
                val updated = transport.refresh(session)
                assertEquals(cookie, updated.cookie)
                assertEquals(jwt(owner, "newsignature"), updated.accessToken)
                val refresh = f.server.takeRequest()
                assertEquals("/auth/session", refresh.path)
                assertEquals("GET", refresh.method)
                assertEquals(cookie, refresh.getHeader("Cookie"))
                assertNull(refresh.getHeader("Authorization"))
                assertEquals(0, refresh.bodySize)
                f.server.enqueue(json("{\"outcome\":\"revoked\",\"revoked\":true,\"queued\":false}"))
                assertTrue(transport.logout(updated))
                val logout = f.server.takeRequest()
                assertEquals("/api/auth/logout", logout.path)
                assertEquals(cookie, logout.getHeader("Cookie"))
                assertEquals("Bearer ${updated.accessToken}", logout.getHeader("Authorization"))
                assertEquals("{\"session_custody\":\"server_v1\"}", logout.body.readUtf8())
            }
        }

    @Test fun malformed_issuance_never_persists_and_redirects_are_not_followed() =
        runBlocking<Unit> {
            Fixture().use { f ->
                val transport = ServerSessionTransport(scope(f.origin), f.client) { now }
                val memory = Memory()
                val controller = ServerSessionCoordinator(transport, memory) { now }
                val replies =
                    listOf(
                        json(issued()), json(issued().replace("\"Bearer\"", "\"bearer\"")).setHeader("Set-Cookie", cookieHeader),
                        json(issued().dropLast(1) + ",\"refresh_token\":\"forbidden\"}").setHeader("Set-Cookie", cookieHeader),
                        json(issued(jwt("other"), owner)).setHeader("Set-Cookie", cookieHeader),
                        MockResponse().setResponseCode(302).setHeader("Location", f.server.url("/other")),
                        json(issued()).setHeader("Set-Cookie", cookieHeader).setHeader("Content-Type", "text/plain"),
                        json("x".repeat(32769)), MockResponse().setResponseCode(500), MockResponse().setResponseCode(401),
                    )
                for (reply in replies) {
                    f.server.enqueue(reply)
                    val attempt = controller.begin()
                    assertFailsWith<ServerSessionException> { controller.exchange(attempt, ServerAuthorizationCode(transport.scope, "code", "v".repeat(43))) }
                    assertNull(memory.value)
                    assertFailsWith<ServerSessionException> { controller.exchange(attempt, ServerAuthorizationCode(transport.scope, "code", "v".repeat(43))) }
                }
                assertEquals(replies.size, f.server.requestCount)
                assertEquals(0, memory.saves)
            }
        }

    @Test fun refresh_refuses_replacement_cookie_owner_and_definitive_retirement() =
        runBlocking<Unit> {
            Fixture().use { f ->
                val transport = ServerSessionTransport(scope(f.origin), f.client) { now }
                val session = ServerSession(transport.scope, owner, token, cookie, now.plusSeconds(3600))
                for (reply in listOf(
                    json(refreshed()).setHeader("Set-Cookie", cookieHeader),
                    json(refreshed(jwt("other"), "other")),
                    json("{\"authenticated\":false,\"access_token\":\"\",\"resumed\":false,\"reason\":\"hard_cap\"}"),
                )) {
                    f.server.enqueue(reply)
                    assertFailsWith<ServerSessionException> { transport.refresh(session) }
                }
            }
        }

    @Test fun concurrent_refresh_coalesces_and_signout_or_cancel_cannot_restore_credentials() =
        runBlocking<Unit> {
            Fixture().use { f ->
                val transport = ServerSessionTransport(scope(f.origin), f.client) { now }
                val memory = Memory().apply { value = ServerSession(transport.scope, owner, token, cookie, now.plusSeconds(3600)) }
                val controller = ServerSessionCoordinator(transport, memory) { now }
                assertTrue(controller.restore())
                assertTrue(controller.restore())
                f.server.enqueue(json(refreshed(jwt(owner, "newsignature"))).setBodyDelay(250, TimeUnit.MILLISECONDS))
                val a = async(Dispatchers.Default) { controller.refresh() }
                assertNotNull(f.server.takeRequest(3, TimeUnit.SECONDS))
                val b = async(Dispatchers.Default) { controller.refresh() }
                assertEquals(a.await(), b.await())
                assertEquals(1, f.server.requestCount)
                assertEquals(1, memory.saves)
                val ticket = controller.socketTicket(f.socketOrigin + "ws", jwt(owner, "newsignature"))
                assertTrue(controller.isCurrent(ticket))
                f.server.enqueue(json(refreshed()).setBodyDelay(250, TimeUnit.MILLISECONDS))
                val late = async(Dispatchers.Default) { runCatching { controller.refresh() } }
                assertNotNull(f.server.takeRequest(3, TimeUnit.SECONDS))
                controller.retire()
                assertFalse(controller.isCurrent(ticket))
                assertTrue(late.await().exceptionOrNull() is ServerSessionException)
                assertNull(memory.value)
                val attempt = controller.begin()
                f.server.enqueue(json(issued()).setHeader("Set-Cookie", cookieHeader).setBodyDelay(1, TimeUnit.SECONDS))
                val cancelled = launch(Dispatchers.Default) { controller.exchange(attempt, ServerAuthorizationCode(transport.scope, "code", "v".repeat(43))) }
                assertNotNull(f.server.takeRequest(3, TimeUnit.SECONDS))
                cancelled.cancelAndJoin()
                assertNull(memory.value)
                assertEquals(1, memory.saves)
                assertFailsWith<ServerSessionException> { controller.exchange(attempt, ServerAuthorizationCode(transport.scope, "code", "v".repeat(43))) }
            }
        }

    @Test fun real_websocket_upgrade_carries_cookie_but_never_serializes_it_or_uses_global_jar() =
        runBlocking<Unit> {
            Fixture().use { f ->
                val jarReads = AtomicInteger()
                val supplied =
                    f.client.newBuilder().cookieJar(
                        object : CookieJar {
                            override fun saveFromResponse(
                                url: HttpUrl,
                                cookies: List<Cookie>,
                            ) = error("global jar used")

                            override fun loadForRequest(url: HttpUrl): List<Cookie> {
                                jarReads.incrementAndGet()
                                return emptyList()
                            }
                        },
                    ).build()
                val transport = ServerSessionTransport(scope(f.origin), supplied) { now }
                val memory = Memory().apply { value = ServerSession(transport.scope, owner, token, cookie, now.plusSeconds(3600)) }
                val controller = ServerSessionCoordinator(transport, memory) { now }
                controller.restore()
                f.server.enqueue(
                    MockResponse().withWebSocketUpgrade(
                        object : WebSocketListener() {
                            override fun onMessage(
                                webSocket: WebSocket,
                                text: String,
                            ) {
                                assertTrue(text.contains("register_ui"))
                                assertTrue(text.contains(token))
                                assertFalse(text.contains(cookie))
                                webSocket.send("{\"type\":\"auth_required\",\"reason\":\"fixture\"}")
                            }
                        },
                    ),
                )
                val url = f.socketOrigin + "ws"
                val client = OrchestratorClient(url, supplied, serverSession = { controller })
                withTimeout(5000) { client.stream(token, DeviceCapabilities(screenWidth = 400, screenHeight = 800)).first { it is Inbound.AuthRequired } }
                assertEquals(cookie, f.server.takeRequest().getHeader("Cookie"))
                assertEquals(0, jarReads.get())
                controller.retire()
                withTimeout(1000) { client.stream(token, DeviceCapabilities(screenWidth = 400, screenHeight = 800)).first { it is Inbound.AuthRequired } }
                assertEquals(1, f.server.requestCount)
                for (bad in listOf("ws://localhost/ws", url.replace("/ws", "/arbitrary"), url + "?token=x", url.replace("localhost", "example.com"))) {
                    assertFailsWith<ServerSessionException> { controller.socketTicket(bad, token) }
                }
            }
        }
}
