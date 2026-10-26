// JVM classification tests for the push destination REST boundary: enrollment outcomes map to
// the adapter machine's transient and permanent rejection vocabulary, acknowledgments surface
// destination revocation, and revocation treats an unknown destination as already revoked.

package com.personalailabs.astraldeep.app.push

import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PushDestinationRestTest {
    private lateinit var server: MockWebServer
    private lateinit var rest: PushDestinationRest

    @Before
    fun start() {
        server = MockWebServer()
        server.start()
        rest = PushDestinationRest(server.url("/").toString())
    }

    @After
    fun stop() {
        server.shutdown()
    }

    @Test
    fun enrollAcceptedSendsDestinationContract() = runTest {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"status":"active"}"""))
        val outcome = rest.enroll("token-1", "device-0001-aa", "android", "push-token-01", "Phone")
        assertEquals(PushEnrollOutcome.Accepted, outcome)
        val recorded = server.takeRequest()
        assertEquals("/api/push/destinations", recorded.path)
        assertEquals("Bearer token-1", recorded.getHeader("Authorization"))
        val body = recorded.body.readUtf8()
        assertTrue(body.contains("\"device_id\":\"device-0001-aa\""))
        assertTrue(body.contains("\"platform\":\"android\""))
        assertTrue(body.contains("\"token\":\"push-token-01\""))
        assertTrue(body.contains("\"label\":\"Phone\""))
    }

    @Test
    fun enrollClassifiesPermanentAndTransientRejections() = runTest {
        server.enqueue(MockResponse().setResponseCode(400))
        assertEquals(
            PushEnrollOutcome.Rejected(false, "destination_invalid"),
            rest.enroll("token-1", "device-0001-aa", "android", "push-token-01", null),
        )
        server.enqueue(MockResponse().setResponseCode(403))
        assertEquals(
            PushEnrollOutcome.Rejected(false, "destination_forbidden"),
            rest.enroll("token-1", "device-0001-aa", "android", "push-token-01", null),
        )
        server.enqueue(MockResponse().setResponseCode(409))
        assertEquals(
            PushEnrollOutcome.Rejected(false, "destination_capacity"),
            rest.enroll("token-1", "device-0001-aa", "android", "push-token-01", null),
        )
        server.enqueue(MockResponse().setResponseCode(429))
        assertEquals(
            PushEnrollOutcome.Rejected(true, "rate_limited"),
            rest.enroll("token-1", "device-0001-aa", "android", "push-token-01", null),
        )
        server.enqueue(MockResponse().setResponseCode(503))
        assertEquals(
            PushEnrollOutcome.Rejected(true, PushDestinationRest.ENROLL_PROVIDER_UNAVAILABLE),
            rest.enroll("token-1", "device-0001-aa", "android", "push-token-01", null),
        )
    }

    @Test
    fun enrollWithoutAccessTokenStaysUnauthenticated() = runTest {
        assertEquals(PushEnrollOutcome.Unauthenticated, rest.enroll(null, "device-0001-aa", "android", "push-token-01", null))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun acknowledgeReportsAcknowledgedAndRevoked() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        assertEquals(PushAckOutcome.Acknowledged, rest.acknowledge("token-1", "device-0001-aa", NOTIFICATION_ID))
        val recorded = server.takeRequest()
        assertEquals("/api/push/ack", recorded.path)
        assertTrue(recorded.body.readUtf8().contains("\"notification_id\":\"$NOTIFICATION_ID\""))
        server.enqueue(MockResponse().setResponseCode(410))
        assertEquals(PushAckOutcome.DestinationRevoked, rest.acknowledge("token-1", "device-0001-aa", NOTIFICATION_ID))
        server.enqueue(MockResponse().setResponseCode(404))
        assertEquals(PushAckOutcome.Refused, rest.acknowledge("token-1", "device-0001-aa", NOTIFICATION_ID))
        assertEquals(PushAckOutcome.Unauthenticated, rest.acknowledge(null, "device-0001-aa", NOTIFICATION_ID))
    }

    @Test
    fun revokeTreatsUnknownDestinationAsRevoked() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        assertEquals(PushRevokeOutcome.Revoked, rest.revoke("token-1", "device-0001-aa"))
        assertEquals("/api/push/destinations/device-0001-aa", server.takeRequest().path)
        server.enqueue(MockResponse().setResponseCode(404))
        assertEquals(PushRevokeOutcome.Revoked, rest.revoke("token-1", "device-0001-aa"))
        server.enqueue(MockResponse().setResponseCode(500))
        assertEquals(PushRevokeOutcome.Failed, rest.revoke("token-1", "device-0001-aa"))
        assertEquals(PushRevokeOutcome.Unauthenticated, rest.revoke(null, "device-0001-aa"))
    }

    private companion object {
        const val NOTIFICATION_ID = "notif-0001"
    }
}
