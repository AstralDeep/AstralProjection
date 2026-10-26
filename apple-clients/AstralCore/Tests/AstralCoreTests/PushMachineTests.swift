// Deterministic scenarios for the Apple push destination machine: enrollment and rotation,
// retryable and permanent failures, foreground suppression, duplicate and malformed payloads,
// permission revocation, unsupported availability, and bounded ledger recovery after dismissal.

import XCTest

@testable import AstralCore

final class PushMachineTests: XCTestCase {
    private let identity = PushIdentity(deviceId: "device-0001-aa", label: "Astral phone")

    private func grantedMachine(supported: Bool = true) -> PushDestinationMachine {
        let machine = PushDestinationMachine(identity: identity)
        _ = machine.onPermissionReport(granted: true, notificationsAuthorized: true)
        _ = machine.onAvailability(supported: supported)
        return machine
    }

    private func payload(_ id: String, level: String? = nil, chatId: String? = nil) -> [String: String] {
        var data = ["notification_id": id, "title": "Hello", "body": "Body text"]
        if let level { data["level"] = level }
        if let chatId { data["chat_id"] = chatId }
        return data
    }

    func testPayloadDecodeSuccessEdgeAndDenialVectors() {
        guard case .decoded(let payload) = decodePushPayload(payload("notif-0001")) else {
            return XCTFail("minimal payload must decode")
        }
        XCTAssertEqual(payload.notificationId, "notif-0001")
        XCTAssertEqual(payload.level, "info")
        XCTAssertNil(payload.chatId)

        guard case .malformed = decodePushPayload(payload("short")) else {
            return XCTFail("short identity must be malformed")
        }
        guard case .malformed = decodePushPayload(["title": "Hello", "body": "Body text"]) else {
            return XCTFail("missing identity must be malformed")
        }
        guard case .malformed = decodePushPayload(payload("notif-0001", level: "verbose")) else {
            return XCTFail("unknown level must be malformed")
        }
        let oversizedChatId = String(repeating: "c", count: 129)
        guard case .malformed = decodePushPayload(payload("notif-0001", chatId: oversizedChatId)) else {
            return XCTFail("oversized source id must be malformed")
        }
        var oversized = payload("notif-0001")
        oversized["title"] = String(repeating: "t", count: 129)
        guard case .malformed = decodePushPayload(oversized) else {
            return XCTFail("oversized title must be malformed")
        }
        var control = payload("notif-0001")
        control["body"] = "bad\u{07}text"
        guard case .malformed = decodePushPayload(control) else {
            return XCTFail("control characters must be malformed")
        }

        let sourced = payload("notif-0001", level: "error", chatId: "chat-1")
        guard case .decoded(let chatPayload) = decodePushPayload(sourced) else {
            return XCTFail("bounded source payload must decode")
        }
        XCTAssertEqual(chatPayload.chatId, "chat-1")
        XCTAssertEqual(chatPayload.level, "error")
    }

    func testGrantRequestsTokenAndEnrollmentCarriesContractFields() {
        let machine = PushDestinationMachine(identity: identity)
        XCTAssertTrue(machine.onPermissionReport(granted: true, notificationsAuthorized: true).isEmpty)
        let bootstrap = machine.onAvailability(supported: true)
        XCTAssertEqual(bootstrap, [.requestToken(reason: "bootstrap")])
        XCTAssertEqual(machine.registration, .requestingToken)

        let enroll = machine.onDeviceToken("aabbccdd")
        XCTAssertEqual(
            enroll,
            [.enrollDestination(
                deviceId: identity.deviceId, platform: "ios", token: "aabbccdd",
                label: identity.label, tokenGeneration: 1)])
        XCTAssertEqual(machine.registration, .enrolling)
        _ = machine.onEnrollmentAccepted()
        XCTAssertEqual(
            machine.registration,
            .registered(tokenFingerprint: pushTokenFingerprint("aabbccdd"), tokenGeneration: 1))
    }

    func testRepeatedTokenIsIdempotentAndRotationReenrolls() {
        let machine = grantedMachine()
        _ = machine.onDeviceToken("aabbccdd")
        _ = machine.onEnrollmentAccepted()
        let repeatEffects = machine.onDeviceToken("  aabbccdd  ")
        XCTAssertTrue(repeatEffects.isEmpty)
        XCTAssertEqual(
            machine.registration,
            .registered(tokenFingerprint: pushTokenFingerprint("aabbccdd"), tokenGeneration: 1))

        let rotated = machine.onDeviceToken("bbee0011")
        XCTAssertEqual(rotated.count, 1)
        XCTAssertEqual(machine.registration, .enrolling)
        _ = machine.onEnrollmentAccepted()
        XCTAssertEqual(
            machine.registration,
            .registered(tokenFingerprint: pushTokenFingerprint("bbee0011"), tokenGeneration: 2))
    }

    func testPermanentAndTransientEnrollmentFailuresRecoverThroughRetry() {
        let machine = grantedMachine()
        _ = machine.onDeviceToken("aabbccdd")
        _ = machine.onEnrollmentRejected(transient: false, code: "destination_invalid")
        XCTAssertEqual(machine.registration, .failedPermanent(code: "destination_invalid"))
        XCTAssertTrue(machine.retryRegistration().isEmpty)

        let recovering = grantedMachine()
        _ = recovering.onDeviceToken("aabbccdd")
        _ = recovering.onEnrollmentRejected(transient: true, code: "provider_unavailable")
        guard case .failedRetryable(let code, let attempts) = recovering.registration else {
            return XCTFail("transient rejection must stay retryable")
        }
        XCTAssertEqual(code, "provider_unavailable")
        XCTAssertEqual(attempts, 1)
        let retry = recovering.retryRegistration()
        XCTAssertEqual(retry.count, 1)
        XCTAssertEqual(recovering.registration, .enrolling)
        _ = recovering.onEnrollmentAccepted()
        XCTAssertEqual(
            recovering.registration,
            .registered(tokenFingerprint: pushTokenFingerprint("aabbccdd"), tokenGeneration: 1))
    }

    func testNilTokenMarksRetryableAndRecoversWithNewToken() {
        let machine = PushDestinationMachine(identity: identity)
        _ = machine.onPermissionReport(granted: true, notificationsAuthorized: true)
        _ = machine.onAvailability(supported: true)
        XCTAssertEqual(machine.registration, .requestingToken)
        XCTAssertTrue(machine.onDeviceToken(nil).isEmpty)
        guard case .failedRetryable(let code, _) = machine.registration else {
            return XCTFail("nil token must be retryable")
        }
        XCTAssertEqual(code, "token_unavailable")
        let retry = machine.retryRegistration()
        XCTAssertEqual(retry, [.requestToken(reason: "retry")])
        _ = machine.onDeviceToken("aabbccdd")
        _ = machine.onEnrollmentAccepted()
        XCTAssertEqual(
            machine.registration,
            .registered(tokenFingerprint: pushTokenFingerprint("aabbccdd"), tokenGeneration: 1))
    }

    func testForegroundDeliveryStaysInAppAndAcknowledges() {
        let machine = grantedMachine()
        machine.onLifecycle(.foreground)
        let delivery = machine.onForegroundDelivery(payload("notif-0001"))
        guard case .accepted(let payload, let effects, let presented) = delivery else {
            return XCTFail("foreground delivery must be accepted")
        }
        XCTAssertFalse(presented)
        XCTAssertEqual(payload.notificationId, "notif-0001")
        XCTAssertEqual(
            effects,
            [.acknowledge(deviceId: identity.deviceId, notificationId: "notif-0001")])
        guard case .duplicate = machine.onForegroundDelivery(payload("notif-0001")) else {
            return XCTFail("second delivery must be a duplicate")
        }
    }

    func testSystemDeliveryAcknowledgesAndTapSeedSuppressesRedelivery() {
        let machine = grantedMachine()
        machine.onLifecycle(.background)
        guard case .accepted(_, let effects, let presented) = machine.onSystemDelivery(payload("notif-0001")) else {
            return XCTFail("system delivery must be accepted while granted")
        }
        XCTAssertTrue(presented)
        XCTAssertEqual(effects.first, .acknowledge(deviceId: identity.deviceId, notificationId: "notif-0001"))
        machine.seedAccepted(["notif-0001"])
        guard case .duplicate = machine.onSystemDelivery(payload("notif-0001")) else {
            return XCTFail("seeded identity must not re-acknowledge")
        }
    }

    func testDeniedPermissionHoldsDeliveryWithoutLedger() {
        let machine = PushDestinationMachine(identity: identity)
        _ = machine.onPermissionReport(granted: false, notificationsAuthorized: false)
        _ = machine.onAvailability(supported: true)
        guard case .notPermitted = machine.onSystemDelivery(payload("notif-0001")) else {
            return XCTFail("denied permission must hold delivery")
        }
        XCTAssertTrue(machine.accepted.isEmpty)
        _ = machine.onPermissionReport(granted: true, notificationsAuthorized: true)
        guard case .accepted = machine.onSystemDelivery(payload("notif-0001")) else {
            return XCTFail("grant must release the held identity")
        }
    }

    func testRevocationClearsLedgerAndCancelsPresented() {
        let machine = grantedMachine()
        machine.onLifecycle(.background)
        _ = machine.onSystemDelivery(payload("notif-0001"))
        let effects = machine.onPermissionReport(granted: false, notificationsAuthorized: false)
        XCTAssertEqual(effects, [.cancelPresented(["notif-0001"])])
        XCTAssertEqual(machine.permission, .revoked)
        XCTAssertTrue(machine.accepted.isEmpty)
    }

    func testUnsupportedAvailabilitySuppressesRegistrationAndReceipts() {
        let machine = PushDestinationMachine(identity: identity)
        _ = machine.onPermissionReport(granted: true, notificationsAuthorized: true)
        _ = machine.onAvailability(supported: false, reason: "provider_bridge_absent")
        XCTAssertEqual(machine.unsupportedReason, "provider_bridge_absent")
        XCTAssertTrue(machine.onDeviceToken("aabbccdd").isEmpty)
        guard case .unsupported = machine.onSystemDelivery(payload("notif-0001")) else {
            return XCTFail("unsupported backend must refuse receipts")
        }
        _ = machine.onAvailability(supported: true)
        _ = machine.onDeviceToken("aabbccdd")
        _ = machine.onEnrollmentAccepted()
        let fingerprint = pushTokenFingerprint("aabbccdd")
        XCTAssertEqual(machine.registration, .registered(tokenFingerprint: fingerprint, tokenGeneration: 1))
    }

    func testMalformedPayloadsNeverPresentOrAcknowledge() {
        let machine = grantedMachine()
        machine.onLifecycle(.background)
        guard case .malformed = machine.onSystemDelivery(["notification_id": "short"]) else {
            return XCTFail("short identity must be malformed")
        }
        guard case .malformed = machine.onSystemDelivery(["title": "Hello"]) else {
            return XCTFail("missing identity must be malformed")
        }
        XCTAssertTrue(machine.accepted.isEmpty)
    }

    func testLedgerCapacityBoundsAndDismissalRecovery() {
        let machine = PushDestinationMachine(identity: identity, acceptedCapacity: 2)
        machine.onLifecycle(.background)
        _ = machine.onSystemDelivery(payload("notif-0001"))
        _ = machine.onSystemDelivery(payload("notif-0002"))
        _ = machine.onSystemDelivery(payload("notif-0003"))
        XCTAssertEqual(machine.accepted, ["notif-0002", "notif-0003"])
        XCTAssertTrue(machine.onDismissed("notif-0002"))
        _ = machine.onSystemDelivery(payload("notif-0002"))
        XCTAssertEqual(machine.accepted, ["notif-0003", "notif-0002"])
    }

    func testFingerprintMatchesAndroidAndServerConstruction() {
        XCTAssertEqual(pushTokenFingerprint("provider-token-01").count, 64)
        XCTAssertEqual(
            pushTokenFingerprint("provider-token-01"),
            pushTokenFingerprint("provider-token-01"))
    }
}
