// Deterministic scenarios for content-free local mesh notices: permission grant, denial, revocation and regrant;
// strict opaque payloads; bounded duplicate suppression; redacted token rotation; and capped registration retry.

import Foundation
import XCTest

@testable import AstralCore

final class LocalNoticeCoreTests: XCTestCase {

    func testPermissionGrantDenialRevocationAndRegrant() {
        var state = LocalNoticePermission.next(previous: nil, reported: .notDetermined)
        XCTAssertEqual(state, .notDetermined)
        XCTAssertTrue(state.canRequest)
        XCTAssertFalse(state.allowsPosting)

        state = LocalNoticePermission.next(previous: state, reported: .authorized)
        XCTAssertEqual(state, .authorized)
        XCTAssertTrue(state.allowsPosting)
        XCTAssertFalse(state.canRequest)

        state = LocalNoticePermission.next(previous: state, reported: .denied)
        XCTAssertEqual(state, .revoked, "a denial after a grant is a revocation")
        XCTAssertFalse(state.allowsPosting)
        XCTAssertFalse(state.canRequest, "the OS will not prompt again; Settings must be used")

        state = LocalNoticePermission.next(previous: state, reported: .denied)
        XCTAssertEqual(state, .revoked, "repeated denial reports keep the revocation")

        state = LocalNoticePermission.next(previous: state, reported: .authorized)
        XCTAssertEqual(state, .authorized, "re-enabling in Settings recovers")
    }

    func testFirstDenialIsNotARevocationAndProvisionalOrEphemeralAllowPosting() {
        XCTAssertEqual(LocalNoticePermission.next(previous: nil, reported: .denied), .denied)
        XCTAssertEqual(LocalNoticePermission.next(previous: .notDetermined, reported: .denied), .denied)
        XCTAssertEqual(LocalNoticePermission.next(previous: .denied, reported: .denied), .denied)
        XCTAssertEqual(LocalNoticePermission.next(previous: .provisional, reported: .denied), .revoked)

        let provisional = LocalNoticePermission.next(previous: nil, reported: .provisional)
        XCTAssertEqual(provisional, .provisional)
        XCTAssertTrue(provisional.allowsPosting)
        XCTAssertEqual(LocalNoticePermission.next(previous: nil, reported: .ephemeral), .authorized)
        XCTAssertFalse(LocalNoticePermission.denied.allowsPosting)
        XCTAssertFalse(LocalNoticePermission.denied.canRequest)
    }

    func testReferenceValidationAndOpaqueDerivation() {
        XCTAssertNotNil(LocalNoticeRef("abcdefgh"))
        XCTAssertNotNil(LocalNoticeRef("A.b_c:d-e" + String(repeating: "x", count: 100)))
        XCTAssertNil(LocalNoticeRef("short"))
        XCTAssertNil(LocalNoticeRef(String(repeating: "a", count: 129)))
        XCTAssertNil(LocalNoticeRef("has space in it"))
        XCTAssertNil(LocalNoticeRef("chat/../secret"))
        XCTAssertNil(LocalNoticeRef("émoji-reference"))

        let first = LocalNoticeRef.derive(namespace: "mesh-1", change: "rev-1")
        XCTAssertEqual(first, LocalNoticeRef.derive(namespace: "mesh-1", change: "rev-1"), "derivation is stable")
        XCTAssertNotEqual(first, LocalNoticeRef.derive(namespace: "mesh-1", change: "rev-2"))
        XCTAssertNotEqual(first, LocalNoticeRef.derive(namespace: "mesh-2", change: "rev-1"))
        XCTAssertTrue(first.value.hasPrefix("mn-"))
        XCTAssertEqual(first.value.count, 35)
        XCTAssertFalse(first.value.contains("mesh-1"), "inputs never appear in the reference")
        XCTAssertEqual(first.description, first.value)
    }

    func testPayloadRoundTripsAndRejectsMalformedOrForeignPayloads() {
        let ref = LocalNoticeRef("ref-00000001")!
        let info: [AnyHashable: Any] = LocalNoticePayload.userInfo(ref)
        XCTAssertEqual(try LocalNoticePayload.decode(info).get(), ref)
        XCTAssertEqual(LocalNoticePayload.identifier(ref), "astral-mesh-ref-00000001")
        XCTAssertTrue(LocalNoticePayload.claims(info))

        let foreign: [AnyHashable: Any] = ["notification_id": "server-0001"]
        XCTAssertFalse(LocalNoticePayload.claims(foreign))
        XCTAssertEqual(decodeFailure(foreign), .notLocalNotice)
        XCTAssertEqual(decodeFailure([:]), .notLocalNotice)

        XCTAssertEqual(
            decodeFailure(["astral_local_ref": "ref-00000001", "body": "patient result"]),
            .malformed("unexpected_fields"), "content beside the reference is rejected")
        XCTAssertEqual(decodeFailure(["astral_local_ref": 12_345_678]), .malformed("reference_type"))
        XCTAssertEqual(decodeFailure(["astral_local_ref": "bad ref"]), .malformed("reference_format"))
        XCTAssertEqual(
            decodeFailure([AnyHashable(7): "x", "astral_local_ref": "ref-00000001"]), .malformed("unexpected_fields"))
    }

    private func decodeFailure(_ info: [AnyHashable: Any]) -> LocalNoticeRejection? {
        if case .failure(let rejection) = LocalNoticePayload.decode(info) { return rejection }
        return nil
    }

    func testLedgerSuppressesDuplicatesAndStaysBounded() {
        var ledger = LocalNoticeLedger(capacity: 2)
        let a = LocalNoticeRef("ref-aaaaaaaa")!
        let b = LocalNoticeRef("ref-bbbbbbbb")!
        let c = LocalNoticeRef("ref-cccccccc")!
        XCTAssertTrue(ledger.insert(a))
        XCTAssertFalse(ledger.insert(a), "duplicate")
        XCTAssertTrue(ledger.insert(b))
        XCTAssertTrue(ledger.insert(c))
        XCTAssertEqual(ledger.count, 2)
        XCTAssertFalse(ledger.contains(a), "oldest evicted at capacity")
        XCTAssertTrue(ledger.contains(b) && ledger.contains(c))

        ledger.remove(b)
        XCTAssertFalse(ledger.contains(b))
        ledger.remove(b)
        XCTAssertEqual(ledger.count, 1)
        XCTAssertTrue(ledger.insert(b))
        ledger.removeAll()
        XCTAssertEqual(ledger.count, 0)
        XCTAssertEqual(LocalNoticeLedger().capacity, 256)
    }

    func testTokenFirstUnchangedRotatedInvalidAndRedaction() {
        var tracker = LocalNoticeTokenTracker()
        XCTAssertNil(tracker.fingerprint)
        XCTAssertEqual(LocalNoticeTokenTracker.redacted(nil), "none")

        let tokenA = Data([0xde, 0xad, 0xbe, 0xef])
        let tokenB = Data([0xca, 0xfe, 0xba, 0xbe])
        XCTAssertEqual(LocalNoticeTokenTracker.hex(tokenA), "deadbeef")

        guard case .first(let fpA) = tracker.receive(tokenA) else { return XCTFail("expected first") }
        XCTAssertEqual(fpA, pushTokenFingerprint("deadbeef"))
        XCTAssertEqual(tracker.receive(tokenA), .unchanged)
        guard case .rotated(let previous, let current) = tracker.receive(tokenB) else {
            return XCTFail("expected rotation")
        }
        XCTAssertEqual(previous, fpA)
        XCTAssertEqual(current, pushTokenFingerprint("cafebabe"))
        XCTAssertEqual(tracker.fingerprint, current)

        XCTAssertEqual(tracker.receive(Data()), .invalid)
        XCTAssertEqual(tracker.receive(Data(repeating: 1, count: 257)), .invalid)
        XCTAssertEqual(tracker.fingerprint, current, "invalid tokens do not replace the current one")

        let redacted = LocalNoticeTokenTracker.redacted(current)
        XCTAssertTrue(redacted.hasPrefix("sha256:"))
        XCTAssertFalse(redacted.contains("cafebabe"))
        XCTAssertEqual(redacted.count, "sha256:".count + 8 + 1)

        tracker.reset()
        guard case .first = tracker.receive(tokenB) else { return XCTFail("reset forgets the token") }
    }

    func testRetryBackoffIsCappedAndExhausts() {
        let policy = LocalNoticeRetryPolicy(baseSeconds: 5, maxSeconds: 60, maxAttempts: 6)
        XCTAssertEqual((1...6).map { policy.delay(afterFailure: $0) }, [5, 10, 20, 40, 60, 60])
        XCTAssertNil(policy.delay(afterFailure: 7))
        XCTAssertNil(policy.delay(afterFailure: 0))
        XCTAssertEqual(
            LocalNoticeRetryPolicy(), LocalNoticeRetryPolicy(baseSeconds: 5, maxSeconds: 300, maxAttempts: 6))

        let huge = LocalNoticeRetryPolicy(baseSeconds: Int.max / 2, maxSeconds: Int.max, maxAttempts: 64)
        XCTAssertEqual(huge.delay(afterFailure: 64), Int.max, "overflow saturates at the cap")
    }
}
