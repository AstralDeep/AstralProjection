// Verifies Apple push owner retirement and local/authoritative generation separation independently of the OS service.
import XCTest

@testable import AstralCore

final class PushOwnerFenceTests: XCTestCase {
    func testInitialPermissionAndRotationRetirement() {
        let machine = PushDestinationMachine(identity: .init(deviceId: "device-0001-aa"), ownerSessionId: "owner-A")
        _ = machine.onPermissionReport(granted: false, notificationsAuthorized: false, requestCompleted: false)
        XCTAssertEqual(machine.permission, .notDetermined)
        _ = machine.onPermissionReport(granted: true, notificationsAuthorized: true)
        _ = machine.onAvailability(supported: true)
        _ = machine.onDeviceToken("token-A")
        _ = machine.onDeviceToken("token-A")
        XCTAssertEqual(machine.registration, .enrolling)
        _ = machine.onEnrollmentAccepted(tokenGeneration: 1, serverTokenGeneration: 42)
        let old = machine.binding!
        XCTAssertEqual(old.serverTokenGeneration, 42)
        _ = machine.onDeviceToken("token-B")
        _ = machine.onEnrollmentAccepted(tokenGeneration: 1, serverTokenGeneration: 42)
        XCTAssertEqual(machine.registration, .enrolling)
        _ = machine.onEnrollmentAccepted(tokenGeneration: 2, serverTokenGeneration: 43)
        XCTAssertEqual(
            machine.onForegroundDelivery(["notification_id": "notification-01"], binding: old), .notPermitted)
        let revoked = machine.onPermissionReport(granted: false, notificationsAuthorized: false)
        XCTAssertTrue(
            revoked.contains(
                .revokeDestination(
                    machine.binding
                        ?? PushBinding(
                            ownerSessionId: "owner-A", deviceId: "device-0001-aa", tokenGeneration: 2,
                            serverTokenGeneration: 43))))
        XCTAssertEqual(machine.registration, .idle)
        XCTAssertNil(machine.binding)
        _ = machine.endSession()
        XCTAssertTrue(machine.onDeviceToken("late-token").isEmpty)
        XCTAssertTrue(machine.onPermissionReport(granted: true, notificationsAuthorized: true).isEmpty)
    }
}

extension PushOwnerFenceTests {
    func testFailureRecoveryAndTerminalOwnerFences() {
        let identity = PushIdentity(deviceId: "device-0001-aa")
        let machine = PushDestinationMachine(identity: identity, ownerSessionId: "owner-A")
        XCTAssertTrue(machine.onDeviceToken(nil).isEmpty)
        _ = machine.onAvailability(supported: true)
        _ = machine.onPermissionReport(granted: true, notificationsAuthorized: true)
        _ = machine.onTokenRequestFailed(transient: true, code: "provider_timeout")
        XCTAssertEqual(machine.retryRegistration(), [.requestToken(reason: "retry")])
        _ = machine.onTokenRequestFailed(transient: false, code: "unsupported")
        XCTAssertTrue(machine.retryRegistration().isEmpty)
        _ = machine.onDeviceToken("invalid\u{07}")
        XCTAssertEqual(machine.registration, .failedPermanent(code: "token_invalid"))
        _ = machine.onDeviceToken("provider-token-A")
        _ = machine.onEnrollmentRejected(transient: true, code: "storage_unavailable", tokenGeneration: 0)
        XCTAssertEqual(machine.registration, .enrolling)
        _ = machine.onEnrollmentAccepted(tokenGeneration: 1, serverTokenGeneration: 99)
        let binding = machine.binding!
        let other = PushDestinationMachine(identity: identity, ownerSessionId: "owner-B")
        _ = other.onAvailability(supported: true)
        _ = other.onPermissionReport(granted: true, notificationsAuthorized: true)
        _ = other.onDeviceToken("provider-token-A")
        _ = other.onEnrollmentAccepted(tokenGeneration: 1, serverTokenGeneration: 99)
        XCTAssertEqual(other.onSystemDelivery(["notification_id": "notification-01"], binding: binding), .notPermitted)
        _ = machine.endSession()
        XCTAssertNil(machine.binding)
        XCTAssertTrue(machine.endSession().isEmpty)
        XCTAssertTrue(machine.onAvailability(supported: true).isEmpty)
        XCTAssertTrue(machine.retryRegistration().isEmpty)
        XCTAssertEqual(
            machine.onSystemDelivery(["notification_id": "notification-01"], binding: binding), .notPermitted)
    }
}

extension PushOwnerFenceTests {
    func testOwnerScopeBindsCanonicalServerIssuerSubjectAndAudience() throws {
        func token(_ subject: String = "owner", audience: Any = ["b", "a"]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "iss": "https://issuer.test/realm", "sub": subject, "aud": audience,
            ])
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
                of: "/", with: "_"
            ).replacingOccurrences(of: "=", with: "")
            return "e30.\(encoded).test"
        }
        let first = pushOwnerScope(serverBase: URL(string: "https://EXAMPLE.test:443/")!, accessToken: try token())
        XCTAssertEqual(
            first,
            pushOwnerScope(
                serverBase: URL(string: "https://example.test")!, accessToken: try token(audience: ["a", "b"])))
        XCTAssertNotEqual(
            first, pushOwnerScope(serverBase: URL(string: "https://other.test")!, accessToken: try token()))
        XCTAssertNotEqual(
            first, pushOwnerScope(serverBase: URL(string: "https://example.test")!, accessToken: try token("other")))
        XCTAssertNotEqual(
            first,
            pushOwnerScope(serverBase: URL(string: "https://example.test")!, accessToken: try token(audience: "other")))
        XCTAssertNil(
            pushOwnerScope(serverBase: URL(string: "https://example.test")!, accessToken: try token(audience: 42)))
        XCTAssertNil(pushOwnerScope(serverBase: URL(string: "https://example.test")!, accessToken: "invalid"))
    }
}
