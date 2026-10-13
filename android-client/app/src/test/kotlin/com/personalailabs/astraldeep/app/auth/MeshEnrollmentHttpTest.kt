// Exercises the dedicated enrollment HTTP transport against a local deterministic peer.
// Cookie, redirect, malformed-body, and response-size refusals never enter owner transport.
package com.personalailabs.astraldeep.app.auth

import kotlinx.coroutines.runBlocking
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MeshEnrollmentHttpTest {
    @Test
    fun dedicated_transport_discards_inherited_cookie_and_interceptors() =
        runBlocking {
            val server = MockWebServer()
            server.start()
            try {
                val client =
                    OkHttpClient.Builder().cookieJar(
                        object : CookieJar {
                            override fun saveFromResponse(
                                url: HttpUrl,
                                cookies: List<Cookie>,
                            ) = Unit

                            override fun loadForRequest(url: HttpUrl): List<Cookie> =
                                listOf(Cookie.Builder().name("astral_session").value("owner-cookie").domain(url.host).build())
                        },
                    ).addInterceptor { chain -> chain.proceed(chain.request().newBuilder().header("Authorization", "Bearer owner").build()) }
                        .build()
                server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody("{\"nonce\":\"synthetic\"}"))
                val reply = MeshEnrollmentHttp(client).request(Request.Builder().url(server.url("/api/mesh/nonce")).build())
                assertEquals("synthetic", reply["nonce"].toString().trim('"'))
                val received = server.takeRequest()
                assertNull(received.getHeader("Cookie"))
                assertNull(received.getHeader("Authorization"))
                assertNull(received.getHeader("Origin"))
            } finally {
                server.shutdown()
            }
        }

    @Test
    fun failed_redirect_cookie_mime_and_bounded_body_are_refused() =
        runBlocking {
            val server = MockWebServer()
            server.start()
            try {
                val failures =
                    listOf(
                        MockResponse().setResponseCode(401),
                        MockResponse().setResponseCode(302).setHeader("Location", server.url("/foreign")),
                        MockResponse().setHeader("Content-Type", "application/json").setHeader("Set-Cookie", "astral_session=unexpected").setBody("{}"),
                        MockResponse().setHeader("Content-Type", "text/plain").setBody("{}"),
                        MockResponse().setHeader("Content-Type", "application/json").setBody("{broken}"),
                        MockResponse().setHeader("Content-Type", "application/json").setBody("[]"),
                        MockResponse().setHeader("Content-Type", "application/json").setBody("x".repeat(32769)),
                        MockResponse().setHeader("Content-Type", "application/json").setChunkedBody("x".repeat(32769), 512),
                    )
                for (failure in failures) {
                    server.enqueue(failure)
                    val result = runCatching { MeshEnrollmentHttp().request(Request.Builder().url(server.url("/api/mesh/me")).build()) }
                    assertTrue(result.isFailure)
                    server.takeRequest()
                }
                assertEquals(failures.size, server.requestCount)
            } finally {
                server.shutdown()
            }
        }
}
