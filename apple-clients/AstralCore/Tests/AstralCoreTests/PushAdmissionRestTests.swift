// Verifies actual Apple REST admission requires owned inbox and immutable queued/current destination generation proofs, with strict presence and revoke identities.
import XCTest

@testable import AstralCore

final class PushAdmissionRestTests: XCTestCase {
    func testAdmissionRequiresEveryOwnerAndGenerationProof() async {
        let client = PushRest(serverBase: URL(string: "https://example.test")!) { request in
            let body: String
            switch request.url!.path {
            case "/api/push/destinations/device-0001":
                body =
                    #"{"device_id":"device-0001","status":"active","token_generation":42,"updated_at":99,"destination_revision":99}"#
            case "/api/push/deliveries/notification-01":
                body =
                    #"[{"action":"push.delivery.queued","device_id":"device-0001","token_generation":42,"updated_at":99,"destination_revision":99}]"#
            default:
                body =
                    #"{"entry_id":"notification-01","revision":0,"deleted_at":null,"content":{"chat_id":"owned-chat"}}"#
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owned-access")
            return (200, Data(body.utf8))
        }
        let admitted = await client.authorize(
            token: "owned-access", deviceId: "device-0001", generation: 42, destinationRevision: 99,
            notificationId: "notification-01")
        XCTAssertEqual(admitted?.chatId, "owned-chat")
        let stale = await client.authorize(
            token: "owned-access", deviceId: "device-0001", generation: 41, destinationRevision: 99,
            notificationId: "notification-01")
        XCTAssertNil(stale)
    }

    func testStaleForeignAndLegacyProofsFailClosed() async {
        for body in [
            "[]", "{}", #"[{"action":"push.delivery.queued","device_id":"device-0001"}]"#,
            #"[{"action":"push.delivery.queued","device_id":"foreign-device","token_generation":42,"updated_at":99,"destination_revision":99}]"#,
            #"[{"action":"push.delivery.queued","device_id":"device-0001","token_generation":"42"}]"#,
        ] {
            let client = PushRest(serverBase: URL(string: "https://example.test")!) { request in
                if request.url!.path.contains("destinations") {
                    return (
                        200,
                        Data(
                            #"{"device_id":"device-0001","status":"active","token_generation":42,"updated_at":99,"destination_revision":99}"#
                                .utf8)
                    )
                }
                return (200, Data(body.utf8))
            }
            let result = await client.authorize(
                token: "owned-access", deviceId: "device-0001", generation: 42, destinationRevision: 99,
                notificationId: "notification-01")
            XCTAssertNil(result)
        }
    }

    func testEnrollmentRefusesMissingBooleanStringAndZeroGenerations() async {
        for raw in ["null", "true", #""42""#, "42.0", "0", "-1"] {
            let client = PushRest(serverBase: URL(string: "https://example.test")!) { _ in
                (
                    200,
                    Data(
                        "{\"device_id\":\"device-0001\",\"platform\":\"ios\",\"status\":\"active\",\"token_generation\":\(raw)}"
                            .utf8)
                )
            }
            let result = await client.enroll(
                token: "owned-access", deviceId: "device-0001", platform: "ios", pushToken: "provider-token",
                label: nil, expectedDestinationRevision: 0
            )
            XCTAssertEqual(result, .rejected(transient: false, code: "destination_response_invalid"))
        }
    }

    func testSourceRefusesMalformedForeignDeletedAndUnavailableEntries() async {
        for body in [
            "{}", "[]", "not-json", #"{"entry_id":"foreign-id","revision":0,"deleted_at":null,"content":{}}"#,
            #"{"entry_id":"notification-01","revision":true,"deleted_at":null,"content":{}}"#,
            #"{"entry_id":"notification-01","revision":0,"deleted_at":1,"content":{}}"#,
            #"{"entry_id":"notification-01","revision":0,"deleted_at":null,"content":{"chat_id":""}}"#,
            String(repeating: "x", count: 16385),
        ] {
            let client = PushRest(serverBase: URL(string: "https://example.test")!) { _ in (200, Data(body.utf8)) }
            let result = await client.source(token: "owned-access", notificationId: "notification-01")
            XCTAssertNil(result)
        }
    }

    func testConditionalRevokeAndPresenceUseCapturedIntegerAndBooleanValues() async {
        let client = PushRest(serverBase: URL(string: "https://example.test")!) { request in
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "42")
                return (409, Data())
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["connection_generation"] as? String, "connection-A")
            XCTAssertEqual(body["foreground"] as? Bool, true)
            XCTAssertEqual(body["sequence"] as? Int, 9)
            return (200, Data(#"{"accepted_sequence":9,"expires_in_seconds":45}"#.utf8))
        }
        let revoked = await client.revoke(
            token: "owned-access", deviceId: "device-0001", expectedTokenGeneration: 42, expectedDestinationRevision: 99
        )
        XCTAssertEqual(revoked, .conflict)
        let presence = await client.presence(
            token: "owned-access", deviceId: "device-0001", connectionGeneration: "connection-A", sequence: 9,
            foreground: true)
        XCTAssertEqual(presence?.expiresInSeconds, 45)
        let invalid = await client.presence(
            token: "owned-access", deviceId: "device-0001", connectionGeneration: "connection-A", sequence: 0,
            foreground: true)
        XCTAssertNil(invalid)
    }
    func testOpaqueRevisionRemainsAnExactIntegerAndNormalCustodyHeadersAreForwarded() async {
        let expected: Int64 = 9_007_199_254_740_990
        let client = PushRest(
            serverBase: URL(string: "https://example.test")!,
            sessionHeaders: { _ in
                ["Cookie": "astral_session=synthetic", "Origin": "https://example.test"]
            },
            transport: { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual((body["expected_destination_revision"] as? NSNumber)?.int64Value, expected)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "astral_session=synthetic")
                let response: [String: Any] = [
                    "device_id": "device-0001", "platform": "ios", "status": "active", "token_generation": 42,
                    "updated_at": expected + 1,
                ]
                return (200, try JSONSerialization.data(withJSONObject: response))
            })
        let result = await client.enroll(
            token: "owned", deviceId: "device-0001", platform: "ios", pushToken: "provider-token", label: nil,
            expectedDestinationRevision: expected)
        XCTAssertEqual(result, .accepted(serverTokenGeneration: 42, destinationRevision: expected + 1))
    }

}
