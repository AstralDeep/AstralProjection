package com.personalailabs.astraldeep.app.rest

import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CanvasPresentationRest088Test {
    private val capture = Json.parseToJsonElement("""{"version":"astral.canvas-export/v1","components":[],"display_state":[],"images":[],"viewport":{"width":296,"height":600,"window_width":320,"window_height":640},"theme":{}}""") as JsonObject
    private val response = JsonObject(capture.filterKeys { it in setOf("version", "viewport", "theme") } + ("html" to JsonPrimitive("<p>display</p>")))

    private fun response(value: String = response.toString()) = MockResponse().setHeader("Content-Type", "application/json").setHeader("X-Astral-Render-Revision", "2").setBody(value)

    @Test fun authorizationIsBeforeEphemeralPostAndBothUseExactRevision() =
        runBlocking {
            MockWebServer().use { server ->
                server.enqueue(MockResponse().setHeader("X-Astral-Render-Revision", "2").setBody("Discard this historical HTML"))
                server.enqueue(response())
                val rest = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                rest.authorizeCanvas("token", "chat", 2u)
                assertEquals(response, rest.canvasPresentation("token", "chat", 2u, capture))
                assertEquals("/api/export/canvas/chat.html?render_revision=2", server.takeRequest().path)
                val request = server.takeRequest()
                assertEquals("POST", request.method)
                assertEquals("/api/export/canvas/chat/presentation?render_revision=2", request.path)
                assertEquals("Bearer token", request.getHeader("Authorization"))
                assertEquals("no-store", request.getHeader("Cache-Control"))
                assertNull(request.getHeader("Cookie"))
                assertEquals(capture, Json.parseToJsonElement(request.body.readUtf8()))
            }
        }

    @Test fun staleMalformedAndRefusedPresentationNeverBecomeFallbackHtml() =
        runBlocking {
            MockWebServer().use { server ->
                val rest = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                val invalid =
                    listOf(
                        response().setHeader("X-Astral-Render-Revision", "3"),
                        response().addHeader("X-Astral-Render-Revision", "2"),
                        response().setHeader("Content-Type", "text/html"),
                        response(response.toString().replace("296", "295")),
                        response(response.toString().replace("<p>display</p>", "private").dropLast(1) + ",\"html\":\"other\"}"),
                        response("[]"),
                    ) +
                        listOf(401, 403, 404, 408, 409, 413, 415, 422, 429, 503).map {
                            response("{\"error\":\"private-server-content\"}").setResponseCode(it)
                        }
                for (failure in invalid) {
                    server.enqueue(failure)
                    val error = assertFailsWith<WorkspaceRequestException> { rest.canvasPresentation("token", "chat", 2u, capture) }
                    assertFalse(error.toString().contains("private"))
                }
                assertEquals(invalid.size, server.requestCount)
            }
        }

    @Test fun oversizedOrInvalidRevisionRequestNeverLeavesClient() =
        runBlocking {
            MockWebServer().use { server ->
                val rest = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                val huge = JsonObject(capture + ("components" to JsonPrimitive("x".repeat(8 * 1024 * 1024))))
                assertFailsWith<WorkspaceRequestException> { rest.canvasPresentation("token", "chat", 2u, huge) }
                assertFailsWith<WorkspaceRequestException> { rest.canvasPresentation("token", "chat", ULong.MAX_VALUE, capture) }
                assertEquals(0, server.requestCount)
            }
        }

    @Test fun uncertainPostAndCancelledHeadersNeverRetry() =
        runBlocking {
            MockWebServer().use { server ->
                val rest = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
                assertFailsWith<WorkspaceRequestException> { rest.canvasPresentation("token", "chat", 2u, capture) }
                assertEquals(1, server.requestCount)
                server.takeRequest()
                server.enqueue(response().setHeadersDelay(1, TimeUnit.SECONDS))
                val fresh = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                val pending = async { fresh.canvasPresentation("token", "chat", 2u, capture) }
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { server.takeRequest(5, TimeUnit.SECONDS) }
                pending.cancelAndJoin()
                assertEquals(2, server.requestCount)
            }
        }

    @Test
    fun totalDeadlineStopsSlowDripWithoutRetry() =
        runBlocking {
            MockWebServer().use { server ->
                val client = OkHttpClient.Builder().callTimeout(500, TimeUnit.MILLISECONDS).build()
                val rest = WorkspaceRest(server.url("/").toString(), client, allowLocalHttp = true)
                server.dispatcher =
                    object : okhttp3.mockwebserver.Dispatcher() {
                        override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse =
                            response().throttleBody(1, 75, TimeUnit.MILLISECONDS)
                    }
                val started = System.nanoTime()
                assertFailsWith<WorkspaceRequestException> { rest.canvasPresentation("token", "chat", 2u, capture) }
                assertTrue((System.nanoTime() - started) / 1_000_000 < 2000)
                assertEquals(1, server.requestCount)
            }
        }
}
