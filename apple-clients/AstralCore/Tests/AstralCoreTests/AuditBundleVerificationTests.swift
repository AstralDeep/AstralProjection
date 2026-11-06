// Tests the audit export bundle verifier: a byte-identical bundle verifies against the server-reported
// digest, and truncation, edits, and malformed digests fail closed as unverified.

import CryptoKit
import XCTest

@testable import AstralCore

final class AuditBundleVerificationTests: XCTestCase {
    private let bundle = Data("{\"format\":\"astral.audit-export/v1\",\"records\":[]}".utf8)

    func testIntactBundleVerifiesWithLowercasedServerDigest() {
        let digest = SHA256Hex.of(bundle)
        XCTAssertEqual(
            AuditBundleVerifier.verify(bundle, expectedDigest: digest),
            .verified(digest: digest))
    }

    func testUppercaseAndPaddedServerDigestStillVerify() {
        let digest = SHA256Hex.of(bundle)
        XCTAssertEqual(
            AuditBundleVerifier.verify(bundle, expectedDigest: "  \(digest.uppercased())\n"),
            .verified(digest: digest))
    }

    func testEditedBundleShowsUnverified() {
        let digest = SHA256Hex.of(bundle)
        var edited = bundle
        edited[0] = 124
        XCTAssertEqual(
            AuditBundleVerifier.verify(edited, expectedDigest: digest),
            .unverified(.digestMismatch))
    }

    func testTruncatedBundleShowsUnverified() {
        let digest = SHA256Hex.of(bundle)
        XCTAssertEqual(
            AuditBundleVerifier.verify(Data(bundle.prefix(bundle.count - 1)), expectedDigest: digest),
            .unverified(.digestMismatch))
    }

    func testMalformedServerDigestsFailClosedWithoutGuessing() {
        for raw in ["", "deadbeef", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            XCTAssertEqual(
                AuditBundleVerifier.verify(bundle, expectedDigest: raw),
                .unverified(.malformedDigest))
        }
        XCTAssertNil(AuditBundleVerifier.serverDigest("deadbeef"))
        XCTAssertEqual(AuditBundleVerifier.serverDigest(String(repeating: "A", count: 64))?.count, 64)
    }

    func testEmptyBundleOnlyVerifiesAgainstTheEmptyDigest() {
        XCTAssertEqual(
            AuditBundleVerifier.verify(Data(), expectedDigest: SHA256Hex.of(Data())),
            .verified(digest: SHA256Hex.of(Data())))
        XCTAssertEqual(
            AuditBundleVerifier.verify(Data(), expectedDigest: SHA256Hex.of(bundle)),
            .unverified(.digestMismatch))
    }
}

private enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
