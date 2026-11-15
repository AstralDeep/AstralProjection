// Verifies strict publisher registration responses, explicit HTTPS configuration and content-free, owner-authenticated request bounds.

@testable import AstralCore
import XCTest

final class MeshPushRestTests: XCTestCase {
    let mesh = "sha256:" + String(repeating: "a", count: 64)
    let device = "sha256:" + String(repeating: "b", count: 64)
    let now: Int64 = 1_800_000_000_000

    func body() -> [String: Any] {
        [
            "mesh_id": mesh, "device_id": device, "revision": 1,
            "route": [
                "publisher": "astral", "capability": String(repeating: "opaque_", count: 12) + "=",
                "expires_at_ms": now + 60_000,
            ],
        ]
    }

    func testRegistrationUsesExactTargetAndNoStoreRequest() async throws {
        let data = try JSONSerialization.data(withJSONObject: body())
        let rest = try XCTUnwrap(
            MeshPushRest(publisherURL: URL(string: "https://publisher.example")!, now: { self.now }) { request in
                XCTAssertEqual(request.url?.path, "/api/push/mesh/destinations")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer normal-owner-access")
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
                let body = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(Set(body.keys), ["mesh_id", "device_id", "token", "expected_revision"])
                XCTAssertEqual(body["mesh_id"] as? String, self.mesh)
                return (200, data)
            })
        let outcome = await rest.register(
            access: "normal-owner-access", meshId: mesh, deviceId: device, pushToken: "phone-token", expectedRevision: 0
        )
        guard case .registered(let value) = outcome else { return XCTFail("registration refused") }
        XCTAssertEqual(value.revision, 1)
        XCTAssertFalse(String(reflecting: value).contains("opaque_"))
        XCTAssertEqual(value.route.publisher, "astral")
    }

    func testInvalidResponsesNeverYieldAnAvailableRoute() async throws {
        for mutation in [
            "mesh", "device", "extra", "service", "expired", "future", "bool", "float", "capability",
            "trailing_newline", "revision",
        ] {
            var row = body()
            var route = try XCTUnwrap(row["route"] as? [String: Any])
            switch mutation {
            case "mesh": row["mesh_id"] = device
            case "device": row["device_id"] = mesh
            case "extra": row["token"] = "must-not-be-returned"
            case "service": route["publisher"] = "other"
            case "expired": route["expires_at_ms"] = now
            case "future": route["expires_at_ms"] = now + 86_400_001
            case "bool": route["expires_at_ms"] = true
            case "float": route["expires_at_ms"] = 1_800_000_060_000.5
            case "capability": route["capability"] = "invalid\ncapability"
            case "trailing_newline": route["capability"] = "opaque_capability\n"
            default: row["revision"] = 0
            }
            row["route"] = route
            let data = try JSONSerialization.data(withJSONObject: row)
            let rest = try XCTUnwrap(
                MeshPushRest(publisherURL: URL(string: "https://publisher.example")!, now: { self.now }) { _ in
                    (200, data)
                })
            let result = await rest.register(
                access: "access", meshId: mesh, deviceId: device, pushToken: "phone-token", expectedRevision: 0)
            XCTAssertEqual(result, .unavailable("publisher_response_invalid"), mutation)
        }
    }

    func testMissingCredentialAndInvalidInputNeverSend() async throws {
        let rest = try XCTUnwrap(
            MeshPushRest(publisherURL: URL(string: "https://publisher.example")!) { _ in
                XCTFail("unexpected request")
                return (500, Data())
            })
        let missing = await rest.register(
            access: nil, meshId: mesh, deviceId: device, pushToken: "token", expectedRevision: 0)
        XCTAssertEqual(missing, .signInRequired)
        let invalid = await rest.register(
            access: "access", meshId: "profile-id", deviceId: device, pushToken: "token", expectedRevision: 0)
        XCTAssertEqual(invalid, .unavailable("target_invalid"))
        for value in [
            "http://publisher.example", "https://u:p@publisher.example", "https://publisher.example/path",
            "https://publisher.example?q=x",
        ] {
            XCTAssertNil(MeshPushRest(publisherURL: URL(string: value)!))
        }
    }

    func testStatusAndRevokeAreRevisionFenced() async throws {
        let rest = try XCTUnwrap(
            MeshPushRest(publisherURL: URL(string: "https://publisher.example")!) { request in
                if request.httpMethod == "GET" { return (404, Data()) }
                let row = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(row["expected_revision"] as? Int, 8)
                return (409, Data())
            })
        let status = await rest.status(access: "access", meshId: mesh, deviceId: device)
        XCTAssertEqual(status, .absent)
        let revoked = await rest.revoke(access: "access", meshId: mesh, deviceId: device, revision: 8)
        XCTAssertEqual(revoked, .conflict)
    }
    func testCancelledHTTPCompletionStillReturnsRevisionForCompensatingRevocation() async throws {
        let data = try JSONSerialization.data(withJSONObject: body())
        let gate = MeshPushResponseGate()
        let rest = try XCTUnwrap(
            MeshPushRest(publisherURL: URL(string: "https://publisher.example")!, now: { self.now }) { _ in
                await gate.wait()
                return (200, data)
            })
        let task = Task {
            await rest.register(
                access: "access", meshId: self.mesh, deviceId: self.device, pushToken: "token", expectedRevision: 0)
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        let result = await task.value
        guard case .registered(let registration) = result else {
            return XCTFail("lost committed registration revision")
        }
        XCTAssertEqual(registration.revision, 1)
    }

}

private actor MeshPushResponseGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
