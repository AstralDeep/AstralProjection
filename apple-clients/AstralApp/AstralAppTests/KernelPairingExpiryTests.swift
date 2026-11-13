// Verifies absolute pairing deadlines from generated Kernel records remain fixed when the host remaps them.

@testable import AstralDeep
import AstralKernel
import XCTest

final class KernelPairingExpiryTests: XCTestCase {
    private let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let deadline = Date(timeIntervalSince1970: 1_800_000_600)

    private func mappedDeadlines(at now: Date) throws -> [Date] {
        let offer = PairingOffer(
            code: "12345678", payload: "offer", expiresMs: 1_800_000_600_000, expiresS: 1_800_000_600)
        let preview = PairingPreview(
            code: "12345678", label: "Phone", kind: "iphone", deviceId: "device",
            expiresMs: 1_800_000_600_000, expiresS: 1_800_000_600)
        let invitation = Invitation(payload: "invitation", code: "12345678", expiresS: 1_800_000_600)
        let accepted = InvitationAccepted(
            code: "12345678", invitationCode: "12345678", inviterDeviceId: "inviter", expiresS: 1_800_000_600)
        let changes = KernelMapping.changes(
            .pairing(
                progress: .joinRequested(
                    code: "12345678", label: "Phone", kind: "iphone", deviceId: "device", expiresS: 1_800_000_600)))
        guard case .joinRequested(let request) = try XCTUnwrap(changes.first) else {
            XCTFail("The pairing request must reach the host")
            return []
        }
        return [
            try XCTUnwrap(KernelMapping.pairingOffer(offer, now: now).expiresAt),
            try XCTUnwrap(KernelMapping.pairingPreview(preview, now: now).expiresAt),
            KernelMapping.invitation(invitation, now: now).expiresAt,
            KernelMapping.accepted(accepted, now: now).expiresAt,
            request.expiresAt,
        ]
    }

    func testAllPairingPathsPreserveTheAbsoluteKernelDeadline() throws {
        let deadlines = try mappedDeadlines(at: issuedAt)
        XCTAssertEqual(deadlines.count, 5)
        for value in deadlines {
            XCTAssertEqual(value, deadline)
            XCTAssertEqual(MeshPresentation.countdown(until: value, now: issuedAt), "10:00")
        }
    }

    func testRemappingCannotExtendAnInvitationOrReviveAnExpiredCountdown() throws {
        let later = Date(timeIntervalSince1970: 1_800_000_300)
        let original = try mappedDeadlines(at: issuedAt)
        let remapped = try mappedDeadlines(at: later)
        XCTAssertEqual(remapped, original)
        for value in remapped {
            XCTAssertEqual(MeshPresentation.countdown(until: value, now: later), "5:00")
            XCTAssertNil(MeshPresentation.countdown(until: value, now: deadline))
            XCTAssertNil(MeshPresentation.countdown(until: value, now: Date(timeIntervalSince1970: 1_800_000_601)))
        }
    }
}
