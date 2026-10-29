// Transport-seamed tests for the push destination REST boundary: enrollment classification into
// the machine's transient and permanent vocabulary, acknowledgment revocation outcomes, and
// revocation treating an unknown destination as already revoked.

import XCTest

@testable import AstralCore

final class PushRestTests: XCTestCase {
    private let deviceId = "device-0001-aa"

    private func rest(
        status: Int,
        recording: @escaping @Sendable (URLRequest) -> Void
    ) -> PushRest {
        return PushRest(serverBase: URL(string: "https://backend.example.test")!) { request in
            recording(request)
            return (
                status,
                Data(
                    """
                    {"device_id":"device-0001-aa","platform":"ios","status":"active","token_generation":42,"updated_at":99,"destination_revision":99}
                    """.utf8)
            )
        }
    }

    func testEnrollAcceptedCarriesDestinationContract() async throws {
        var captured: URLRequest?
        let client = rest(status: 200) { captured = $0 }
        let outcome = await client.enroll(
            token: "token-1", deviceId: deviceId, platform: "ios", pushToken: "aabbccdd", label: "Astral phone",
            expectedDestinationRevision: 0)
        XCTAssertEqual(outcome, .accepted(serverTokenGeneration: 42, destinationRevision: 99))
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.path, "/api/push/destinations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"device_id\":\"device-0001-aa\""))
        XCTAssertTrue(body.contains("\"platform\":\"ios\""))
        XCTAssertTrue(body.contains("\"token\":\"aabbccdd\""))
        XCTAssertTrue(body.contains("\"label\":\"Astral phone\""))
    }

    func testEnrollClassifiesDenialsLikeTheMachineVocabulary() async {
        let permanent = await rest(status: 400) { _ in }.enroll(
            token: "token-1", deviceId: deviceId, platform: "ios", pushToken: "aabbccdd", label: nil,
            expectedDestinationRevision: 0)
        XCTAssertEqual(permanent, .rejected(transient: false, code: "destination_invalid"))
        let forbidden = await rest(status: 403) { _ in }.enroll(
            token: "token-1", deviceId: deviceId, platform: "ios", pushToken: "aabbccdd", label: nil,
            expectedDestinationRevision: 0)
        XCTAssertEqual(forbidden, .rejected(transient: false, code: "destination_forbidden"))
        let capacity = await rest(status: 409) { _ in }.enroll(
            token: "token-1", deviceId: deviceId, platform: "ios", pushToken: "aabbccdd", label: nil,
            expectedDestinationRevision: 0)
        XCTAssertEqual(capacity, .rejected(transient: true, code: "destination_conflict"))
        let throttled = await rest(status: 429) { _ in }.enroll(
            token: "token-1", deviceId: deviceId, platform: "ios", pushToken: "aabbccdd", label: nil,
            expectedDestinationRevision: 0)
        XCTAssertEqual(throttled, .rejected(transient: true, code: "rate_limited"))
        let unavailable = await rest(status: 503) { _ in }.enroll(
            token: "token-1", deviceId: deviceId, platform: "ios", pushToken: "aabbccdd", label: nil,
            expectedDestinationRevision: 0)
        XCTAssertEqual(unavailable, .rejected(transient: true, code: "provider_unavailable"))
    }

    func testEnrollWithoutTokenStaysUnauthenticatedWithoutTransport() async {
        var called = false
        let outcome = await rest(status: 200) { _ in called = true }.enroll(
            token: nil, deviceId: deviceId, platform: "ios", pushToken: "aabbccdd", label: nil,
            expectedDestinationRevision: 0)
        XCTAssertEqual(outcome, .unauthenticated)
        XCTAssertFalse(called)
    }

    func testAcknowledgeSurfacesAcknowledgedRefusedAndRevoked() async {
        let acknowledged = await rest(status: 204) { _ in }.acknowledge(
            token: "token-1", deviceId: deviceId, notificationId: "notif-0001")
        XCTAssertEqual(acknowledged, .acknowledged)
        let revoked = await rest(status: 410) { _ in }.acknowledge(
            token: "token-1", deviceId: deviceId, notificationId: "notif-0001")
        XCTAssertEqual(revoked, .destinationRevoked)
        let refused = await rest(status: 404) { _ in }.acknowledge(
            token: "token-1", deviceId: deviceId, notificationId: "notif-0001")
        XCTAssertEqual(refused, .refused)
        let unauthenticated = await rest(status: 204) { _ in }.acknowledge(
            token: nil, deviceId: deviceId, notificationId: "notif-0001")
        XCTAssertEqual(unauthenticated, .unauthenticated)
    }

    func testRevokeTreatsUnknownDestinationAsRevoked() async {
        var path: String?
        let gone = await rest(status: 404) { path = $0.url?.path }.revoke(
            token: "token-1", deviceId: deviceId, expectedTokenGeneration: 42, expectedDestinationRevision: 99)
        XCTAssertEqual(gone, .revoked)
        XCTAssertEqual(path, "/api/push/destinations/device-0001-aa")
        let revoked = await rest(status: 204) { _ in }.revoke(
            token: "token-1", deviceId: deviceId, expectedTokenGeneration: 42, expectedDestinationRevision: 99)
        XCTAssertEqual(revoked, .revoked)
        let failed = await rest(status: 500) { _ in }.revoke(
            token: "token-1", deviceId: deviceId, expectedTokenGeneration: 42, expectedDestinationRevision: 99)
        XCTAssertEqual(failed, .failed)
        let unauthenticated = await rest(status: 204) { _ in }.revoke(
            token: nil, deviceId: deviceId, expectedTokenGeneration: 42, expectedDestinationRevision: 99)
        XCTAssertEqual(unauthenticated, .unauthenticated)
    }

    func testTransportFailureClassifiesAsTransientProviderUnavailable() async {
        let client = PushRest(serverBase: URL(string: "https://backend.example.test")!) { _ in
            throw URLError(.notConnectedToInternet)
        }
        let outcome = await client.enroll(
            token: "token-1", deviceId: deviceId, platform: "ios", pushToken: "aabbccdd", label: nil,
            expectedDestinationRevision: 0)
        XCTAssertEqual(outcome, .rejected(transient: true, code: "enroll_network"))
    }
}
