// Exercises actual push HTTP admission, authoritative generation parsing, bounded bodies, stale outcomes and strict registered presence against a local transport.
package com.personalailabs.astraldeep.app.push

import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PushAdmissionRestTest {
    @Test
    fun delivery_requires_current_destination_queued_generation_and_owned_inbox() =
        runTest {
            MockWebServer().use { server ->
                server.start()
                val rest = PushDestinationRest(server.url("/").toString())
                server.enqueue(ok("""{"device_id":"device-0001","status":"active","token_generation":42,"updated_at":99,"destination_revision":99}"""))
                server.enqueue(ok("""[{"action":"push.delivery.queued","device_id":"device-0001","token_generation":42,"updated_at":99,"destination_revision":99}]"""))
                server.enqueue(ok("""{"entry_id":"notification-01","revision":0,"deleted_at":null,"content":{"chat_id":"owned-chat"}}"""))
                assertEquals(PushSource("notification-01", "owned-chat"), rest.authorize("access", "device-0001", 42, 99, "notification-01"))
                assertEquals("/api/push/destinations/device-0001", server.takeRequest().path)
                assertEquals("/api/push/deliveries/notification-01", server.takeRequest().path)
                assertEquals("/api/notifications/inbox/notification-01", server.takeRequest().path)
            }
        }

    @Test
    fun stale_revoked_unknown_and_legacy_generations_cannot_authorize() =
        runTest {
            MockWebServer().use { server ->
                server.start()
                val rest = PushDestinationRest(server.url("/").toString())
                for (destination in listOf("{}", """{"device_id":"device-0001","status":"revoked","token_generation":42,"updated_at":99,"destination_revision":99}""", """{"device_id":"device-0001","status":"active","token_generation":41}""")) {
                    server.enqueue(ok(destination))
                    assertNull(rest.authorize("access", "device-0001", 42, 99, "notification-01"))
                }
                for (events in listOf("[]", "{}", """[{"action":"push.delivery.queued","device_id":"device-0001"}]""", """[{"action":"push.delivery.queued","device_id":"foreign-device","token_generation":42,"updated_at":99,"destination_revision":99}]""", """[{"action":"push.delivery.queued","device_id":"device-0001","token_generation":"42"}]""")) {
                    server.enqueue(ok("""{"device_id":"device-0001","status":"active","token_generation":42,"updated_at":99,"destination_revision":99}"""))
                    server.enqueue(ok(events))
                    assertNull(rest.authorize("access", "device-0001", 42, 99, "notification-01"))
                }
                assertNull(rest.authorize(null, "device-0001", 42, 99, "notification-01"))
                assertNull(rest.authorize("access", "device-0001", 0, 99, "notification-01"))
            }
        }

    @Test
    fun source_denials_malformed_foreign_and_deleted_records_fail_closed() =
        runTest {
            MockWebServer().use { server ->
                server.start()
                val rest = PushDestinationRest(server.url("/").toString())
                for (body in listOf("{}", "[]", "not-json", "x".repeat(65537), """{"entry_id":"foreign-id","revision":0,"deleted_at":null,"content":{}}""", """{"entry_id":"notification-01","revision":true,"deleted_at":null,"content":{}}""", """{"entry_id":"notification-01","revision":0,"deleted_at":1,"content":{}}""", """{"entry_id":"notification-01","revision":0,"deleted_at":null,"content":{"chat_id":""}}""")) {
                    server.enqueue(ok(body))
                    assertNull(rest.source("access", "notification-01"))
                }
                for (status in listOf(401, 404, 503)) {
                    server.enqueue(MockResponse().setResponseCode(status))
                    assertNull(rest.source("access", "notification-01"))
                }
                assertNull(rest.source(null, "notification-01"))
                assertNull(rest.source("access", "bad"))
            }
        }

    @Test
    fun missing_or_noninteger_enrollment_generation_is_never_success() =
        runTest {
            MockWebServer().use { server ->
                server.start()
                val rest = PushDestinationRest(server.url("/").toString())
                for (generation in listOf("null", "true", "\"42\"", "42.0", "0", "-1")) {
                    server.enqueue(ok("""{"device_id":"device-0001","platform":"android","status":"active","token_generation":$generation,"updated_at":99}"""))
                    assertEquals(PushEnrollOutcome.Rejected(false, "destination_response_invalid"), rest.enroll("access", "device-0001", "android", "provider-token", null, 0))
                }
                server.enqueue(MockResponse().setResponseCode(409))
                assertEquals(PushRevokeOutcome.Conflict, rest.revoke("access", "device-0001", 42, 99))
                assertTrue(server.takeRequest().getHeader("Authorization") == "Bearer access")
            }
        }

    @Test
    fun presence_preserves_bool_integer_and_captured_connection_identity() =
        runTest {
            MockWebServer().use { server ->
                server.start()
                val rest = PushDestinationRest(server.url("/").toString())
                server.enqueue(ok("""{"accepted_sequence":9,"expires_in_seconds":45}"""))
                assertEquals(PushPresenceOutcome(9, 45), rest.presence("access", "device-0001", "connection-A", 9, true))
                val sent = server.takeRequest()
                assertEquals("/api/notifications/presence", sent.path)
                val body = sent.body.readUtf8()
                assertTrue(body.contains("\"foreground\":true"))
                assertTrue(body.contains("\"sequence\":9"))
                assertTrue(body.contains("connection-A"))
                server.enqueue(ok("""{"accepted_sequence":10,"expires_in_seconds":0}"""))
                assertEquals(PushPresenceOutcome(10, 0), rest.presence("access", "device-0001", "connection-A", 10, false))
                for (status in listOf(401, 409, 422, 503)) {
                    server.enqueue(MockResponse().setResponseCode(status))
                    assertNull(rest.presence("access", "device-0001", "connection-A", 11, true))
                }
                assertNull(rest.presence("access", "device-0001", "connection-A", 0, true))
                assertNull(rest.presence("access", "device-0001", "connection-A", 9007199254740992, true))
            }
        }

    private fun ok(body: String) = MockResponse().setResponseCode(200).setBody(body)
}
