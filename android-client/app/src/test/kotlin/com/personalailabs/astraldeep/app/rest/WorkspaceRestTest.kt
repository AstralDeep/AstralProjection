package com.personalailabs.astraldeep.app.rest

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Authenticator
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WorkspaceRestTest {
    private val chat = "4e230273-3897-4d1e-bcb7-fd40447d79e0"
    private val opaque = "A_b-".repeat(11)

    @Test
    fun share_posts_fixed_owner_authenticated_body_and_returns_same_origin_link() =
        runBlocking {
            MockWebServer().use { server ->
                server.enqueue(shareResponse("/share/$opaque"))
                val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                assertEquals(server.url("/share/$opaque").toString(), api.shareCanvas("private-token", chat))
                val request = server.takeRequest()
                assertEquals("POST", request.method)
                assertEquals("/api/share", request.path)
                assertEquals("Bearer private-token", request.getHeader("Authorization"))
                assertEquals("no-store", request.getHeader("Cache-Control"))
                assertEquals("application/json; charset=utf-8", request.getHeader("Content-Type"))
                val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
                assertEquals(setOf("chat_id", "scope"), body.keys)
                assertEquals(chat, body.getValue("chat_id").jsonPrimitive.content)
                assertEquals("canvas", body.getValue("scope").jsonPrimitive.content)
            }
        }

    @Test
    fun malformed_or_foreign_share_references_are_refused_without_retrieval() =
        runBlocking {
            MockWebServer().use { server ->
                val base = server.url("/").toString().trimEnd('/')
                val api = WorkspaceRest(base, allowLocalHttp = true)
                val invalid =
                    listOf(
                        "https://elsewhere.example/share/$opaque", "//$opaque.example/share/$opaque",
                        "/share/short", "/share/${"a".repeat(257)}", "/share/$opaque?token=secret",
                        "/share/$opaque#part", "/share/$opaque/", "/share/%41$opaque",
                        "/share/../$opaque", "/share/$opaque\\tail", "share/$opaque",
                        "$base/share/$opaque ", "$base/share/$opaque\n", "$base/api/share/$opaque",
                        base.replace("://", "://user:password@") + "/share/$opaque",
                    )
                for (reference in invalid) {
                    server.enqueue(shareResponse(reference))
                    val error = assertFailsWith<WorkspaceRequestException>(reference) { api.shareCanvas("token", chat) }
                    assertFalse(error.userMessage.contains(reference))
                }
                assertEquals(invalid.size, server.requestCount)
                server.enqueue(shareResponse("$base/share/$opaque"))
                assertEquals("$base/share/$opaque", api.shareCanvas("token", chat))
            }
        }

    @Test
    fun share_json_is_bounded_strict_utf8_and_has_one_string_url() =
        runBlocking {
            MockWebServer().use { server ->
                val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                val invalid =
                    listOf(
                        "{}", "[]", "null", "{\"share_url\":4}", "{\"share_url\":null}",
                        "{\"share_url\":\"/share/$opaque\",\"share_url\":\"/share/$opaque\"}",
                        "{\"share_url\":\"/share/$opaque\",\"share_\\u0075rl\":\"/share/$opaque\"}",
                        "{\"share_url\":\"/share/$opaque\",}", "{share_url: '/share/$opaque'}",
                    )
                for (body in invalid) {
                    server.enqueue(MockResponse().setResponseCode(201).setBody(body))
                    assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", chat) }
                }
                server.enqueue(MockResponse().setResponseCode(201).setBody(Buffer().write(byteArrayOf(0xC3.toByte(), 0x28))))
                assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", chat) }
                for (response in listOf(
                    MockResponse().setBody("x".repeat(65537)),
                    MockResponse().setChunkedBody("x".repeat(65537), 1000),
                )) {
                    server.enqueue(response.setResponseCode(201))
                    assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", chat) }
                }
            }
        }

    @Test
    fun phi_refusal_is_explicit_and_other_server_text_is_never_exposed() =
        runBlocking {
            MockWebServer().use { server ->
                val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                server.enqueue(MockResponse().setResponseCode(403).setBody("{\"error\":\"phi_blocked\"}"))
                assertEquals(
                    "Sharing refused: the content matched the PHI gate.",
                    assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", chat) }.userMessage,
                )
                for (status in listOf(400, 401, 403, 404, 422, 500)) {
                    server.enqueue(MockResponse().setResponseCode(status).setBody("{\"detail\":\"private server token\"}"))
                    val error = assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", chat) }
                    assertFalse(error.userMessage.contains("private"))
                    assertFalse(error.toString().contains("private"))
                }
            }
        }

    @Test
    fun scoped_client_discards_inherited_cookies_interceptors_and_authenticators() =
        runBlocking {
            MockWebServer().use { server ->
                val sideEffects = AtomicInteger()
                val client =
                    OkHttpClient.Builder()
                        .cookieJar(
                            object : CookieJar {
                                override fun loadForRequest(url: HttpUrl): List<Cookie> {
                                    sideEffects.incrementAndGet()
                                    return listOf(Cookie.Builder().name("private").value("cookie").hostOnlyDomain(url.host).build())
                                }

                                override fun saveFromResponse(
                                    url: HttpUrl,
                                    cookies: List<Cookie>,
                                ) {
                                    sideEffects.incrementAndGet()
                                }
                            },
                        )
                        .authenticator(
                            Authenticator { _, response ->
                                sideEffects.incrementAndGet()
                                response.request.newBuilder().header("Authorization", "other-secret").build()
                            },
                        )
                        .addInterceptor { chain ->
                            sideEffects.incrementAndGet()
                            chain.proceed(chain.request())
                        }
                        .addNetworkInterceptor { chain ->
                            sideEffects.incrementAndGet()
                            chain.proceed(chain.request())
                        }.build()
                val api = WorkspaceRest(server.url("/").toString(), client, allowLocalHttp = true)
                server.enqueue(shareResponse("/share/$opaque").setHeader("Set-Cookie", "secret=value"))
                api.shareCanvas("token", chat)
                assertNull(server.takeRequest().getHeader("Cookie"))
                server.enqueue(MockResponse().setResponseCode(401))
                assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", chat) }
                assertEquals(0, sideEffects.get())
                assertEquals(2, server.requestCount)
            }
        }

    @Test
    fun redirects_and_uncertain_post_never_send_another_authenticated_request() =
        runBlocking {
            MockWebServer().use { server ->
                MockWebServer().use { other ->
                    val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                    for (code in listOf(301, 302, 303, 307, 308)) {
                        server.enqueue(MockResponse().setResponseCode(code).setHeader("Location", other.url("/capture")))
                        assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", chat) }
                    }
                    server.enqueue(MockResponse().setResponseCode(503).setHeader("Retry-After", "0"))
                    assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", chat) }
                    server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
                    assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", chat) }
                    assertEquals(7, server.requestCount)
                    assertEquals(0, other.requestCount)
                }
            }
        }

    @Test
    fun invalid_configuration_credentials_and_chat_do_not_send_requests() =
        runBlocking {
            MockWebServer().use { server ->
                val base = server.url("/").toString()
                for (invalidBase in listOf("garbage", "http://astral.example", "https://user:secret@astral.example", "https://astral.example/#frag")) {
                    assertFailsWith<WorkspaceRequestException> { WorkspaceRest(invalidBase).shareCanvas("token", chat) }
                }
                assertFailsWith<WorkspaceRequestException> { WorkspaceRest(base).shareCanvas("token", chat) }
                val api = WorkspaceRest(base, allowLocalHttp = true)
                for (token in listOf("", " ", "secret\nheader")) {
                    assertFailsWith<WorkspaceRequestException> { api.shareCanvas(token, chat) }
                }
                for (invalidChat in listOf("", "../chat", "chat/another", "chat?query", "chat#fragment", "x".repeat(129))) {
                    assertFailsWith<WorkspaceRequestException> { api.shareCanvas("token", invalidChat) }
                }
                assertEquals(0, server.requestCount)
            }
        }

    @Test
    fun export_requires_exact_revision_and_copies_bounded_bytes_without_cache() =
        runBlocking {
            withDestination { destination ->
                MockWebServer().use { server ->
                    server.enqueue(MockResponse().setHeader("X-Astral-Render-Revision", "0").setBody("canvas bytes"))
                    WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                        .exportCanvas("private-token", chat, 0UL, destination)
                    assertEquals("canvas bytes", destination.readText())
                    val request = server.takeRequest()
                    assertEquals("GET", request.method)
                    assertEquals("/api/export/canvas/$chat.html?render_revision=0", request.path)
                    assertEquals("Bearer private-token", request.getHeader("Authorization"))
                    assertEquals("no-store", request.getHeader("Cache-Control"))
                }
            }
        }

    @Test
    fun missing_malformed_duplicate_or_changed_export_revision_deletes_destination() =
        runBlocking {
            withDestination { destination ->
                MockWebServer().use { server ->
                    val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                    val responses =
                        listOf(
                            MockResponse(),
                            MockResponse().setHeader("X-Astral-Render-Revision", "9"),
                            MockResponse().setHeader("X-Astral-Render-Revision", "08"),
                            MockResponse().addHeader("X-Astral-Render-Revision", "8").addHeader("X-Astral-Render-Revision", "8"),
                            MockResponse().setResponseCode(409).setHeader("X-Astral-Render-Revision", "8"),
                        )
                    for (response in responses) {
                        destination.writeText("old private bytes")
                        server.enqueue(response.setBody("should not be published"))
                        assertFailsWith<WorkspaceRequestException> { api.exportCanvas("token", chat, 8UL, destination) }
                        assertFalse(destination.exists())
                    }
                }
            }
        }

    @Test
    fun oversized_truncated_and_redirected_export_streams_remove_partial_file() =
        runBlocking {
            withDestination { destination ->
                MockWebServer().use { server ->
                    val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true, maxExportBytes = 4)
                    for (response in listOf(
                        MockResponse().setBody("large body"),
                        MockResponse().setChunkedBody("large body", 2),
                        MockResponse().setBody("ok").setHeader("Content-Length", "4").setSocketPolicy(SocketPolicy.DISCONNECT_AT_END),
                        MockResponse().setResponseCode(302).setHeader("Location", server.url("/other")),
                    )) {
                        server.enqueue(response.setHeader("X-Astral-Render-Revision", "8"))
                        assertFailsWith<WorkspaceRequestException> { api.exportCanvas("token", chat, 8UL, destination) }
                        assertFalse(destination.exists())
                    }
                    assertEquals(4, server.requestCount)
                }
            }
        }

    @Test
    fun cancellation_during_response_body_stops_call_and_removes_private_file_before_return() =
        runBlocking {
            withDestination { destination ->
                MockWebServer().use { server ->
                    server.enqueue(
                        MockResponse().setHeader("X-Astral-Render-Revision", "8")
                            .setBody("x".repeat(100)).throttleBody(1, 1, TimeUnit.SECONDS),
                    )
                    val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                    val download = async(start = CoroutineStart.UNDISPATCHED) { api.exportCanvas("token", chat, 8UL, destination) }
                    assertNotNull(server.takeRequest(3, TimeUnit.SECONDS))
                    withTimeout(3000) { while (destination.length() == 0L) delay(10) }
                    withTimeout(3000) { download.cancelAndJoin() }
                    assertTrue(download.isCancelled)
                    assertFalse(destination.exists())
                }
            }
        }

    @Test
    fun cancellation_before_headers_stops_share_without_publishing_a_link() =
        runBlocking {
            MockWebServer().use { server ->
                server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
                val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                val share = async(start = CoroutineStart.UNDISPATCHED) { api.shareCanvas("token", chat) }
                assertNotNull(server.takeRequest(3, TimeUnit.SECONDS))
                withTimeout(3000) { share.cancelAndJoin() }
                assertTrue(share.isCancelled)
                assertEquals(1, server.requestCount)
            }
        }

    private fun shareResponse(reference: String): MockResponse =
        MockResponse().setResponseCode(201).setBody(
            "{\"id\":1,\"created_at\":\"2026-09-11T12:00:00Z\",\"share_url\":" +
                Json.encodeToString(kotlinx.serialization.serializer<String>(), reference) + "}",
        )

    private suspend fun withDestination(block: suspend (File) -> Unit) {
        val directory = Files.createTempDirectory("workspace-rest-test-").toFile()
        try {
            block(File(directory, "export.html"))
        } finally {
            directory.deleteRecursively()
        }
    }
}
