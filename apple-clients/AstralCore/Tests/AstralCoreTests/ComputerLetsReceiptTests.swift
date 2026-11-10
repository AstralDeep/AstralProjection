// Exercises the LETS executor receipt verifier with runtime-generated Ed25519 material: policy and issuer
// denials, freshness windows, tampered payloads, evidence-digest signature coverage and durable claim-once.

#if os(macOS)
    import CryptoKit
    import Foundation
    import XCTest

    @testable import AstralCore

    final class ComputerLetsReceiptTests: XCTestCase {
        private final class MemoryClaimStore: ComputerLetsClaimStoring, @unchecked Sendable {
            private let lock = NSLock()
            private var claimed: Set<String> = []

            func claim(_ receipt: ComputerLetsReceipt, claimedAtNs: Int64) throws {
                let inserted = lock.withLock { claimed.insert(receipt.receiptId).inserted }
                guard inserted else {
                    throw ComputerHostError(
                        "receipt_replayed", "This receipt was already claimed on this Mac.")
                }
            }
        }

        private func mint(
            _ changes: (inout [String: ComputerLetsValue]) -> Void = { _ in }
        ) throws -> (json: String, privateKey: Curve25519.Signing.PrivateKey) {
            let privateKey = Curve25519.Signing.PrivateKey()
            var payload: [String: ComputerLetsValue] = [
                "type": .string(ComputerLetsReceipt.wireType),
                "tenant_id": .string("tenant"),
                "envelope_id": .string("envelope"),
                "config_epoch": .integer(1),
                "receipt_id": .string("receipt_unit0001"),
                "request_id": .string("request_unit01"),
                "warden_id": .string("warden-test"),
                "key_id": .string("warden-test/ed25519-test"),
                "policy_id": .string("policy-unit01"),
                "policy_version": .string("v1"),
                "policy_digest": .string("sha256:" + String(repeating: "1", count: 64)),
                "machine_digest": .string("sha256:" + String(repeating: "2", count: 64)),
                "lease_id": .string("lease_unit001"),
                "lineage_id": .string("lineage_unit1"),
                "subject_id": .string("subject-unit1"),
                "executor_audience": .string("mac-host"),
                "transition": .string("act"),
                "source_state": .string("ready"),
                "target_state": .string("ready"),
                "cost": .array([.integer(1)]),
                "resulting_sequence": .integer(1),
                "evidence_digest": .string("sha256:" + String(repeating: "3", count: 64)),
                "nonce": .string("nonce-unit-0001"),
                "issued_at_ns": .integer(1_000),
                "expires_at_ns": .integer(2_000),
            ]
            changes(&payload)
            let canonical = try ComputerLetsCanonical.canonicalString(.object(payload))
            let signature = try privateKey.signature(for: Data(canonical.utf8))
            payload["signature"] = .string(ComputerLetsCanonical.base64URLEncode(signature))
            return (try ComputerLetsCanonical.canonicalString(.object(payload)), privateKey)
        }

        private func trustedKey(_ privateKey: Curve25519.Signing.PrivateKey) throws -> ComputerLetsTrustedKey {
            try ComputerLetsTrustedKey(
                wardenId: "warden-test", keyId: "warden-test/ed25519-test",
                publicKey: privateKey.publicKey.rawRepresentation)
        }

        private func policy(
            audience: String = "mac-host", tenantId: String? = "tenant", envelopeId: String? = "envelope",
            configEpoch: Int64? = 1, allowedPolicyDigests: Set<String> = [], trustedWardens: Set<String> = [],
            maxClockUncertaintyNs: Int64 = 0
        ) -> ComputerLetsExecutorPolicy {
            ComputerLetsExecutorPolicy(
                audience: audience, tenantId: tenantId, envelopeId: envelopeId, configEpoch: configEpoch,
                allowedPolicyDigests: allowedPolicyDigests, trustedWardens: trustedWardens,
                maxClockUncertaintyNs: maxClockUncertaintyNs)
        }

        private func verifyCode(
            _ json: String, privateKey: Curve25519.Signing.PrivateKey, policy: ComputerLetsExecutorPolicy? = nil,
            keys: [ComputerLetsTrustedKey]? = nil, nowNs: Int64 = 1_500, uncertaintyNs: Int64? = nil
        ) -> String? {
            do {
                try ComputerLetsVerifier.verify(
                    try ComputerLetsReceipt(json: json),
                    policy: policy ?? self.policy(),
                    keys: keys ?? [try trustedKey(privateKey)],
                    nowNs: nowNs, uncertaintyNs: uncertaintyNs)
                return nil
            } catch {
                return (error as? ComputerHostError)?.code ?? String(describing: error)
            }
        }

        private func claimCode(
            _ json: String, privateKey: Curve25519.Signing.PrivateKey, store: ComputerLetsClaimStoring
        ) -> String? {
            do {
                try ComputerLetsVerifier.verifyAndClaim(
                    try ComputerLetsReceipt(json: json), policy: policy(), keys: [try trustedKey(privateKey)],
                    store: store, nowNs: 1_500)
                return nil
            } catch {
                return (error as? ComputerHostError)?.code ?? String(describing: error)
            }
        }

        func testValidReceiptVerifiesAndKeepsItsEvidenceDigest() throws {
            let (json, privateKey) = try mint()
            let receipt = try ComputerLetsReceipt(json: json)
            XCTAssertEqual(receipt.receiptId, "receipt_unit0001")
            XCTAssertEqual(receipt.executorAudience, "mac-host")
            XCTAssertEqual(receipt.evidenceDigest, "sha256:" + String(repeating: "3", count: 64))
            XCTAssertNil(verifyCode(json, privateKey: privateKey))
        }

        func testSignatureCoversEveryUnsignedFieldIncludingTheEvidenceDigest() throws {
            let privateKey = Curve25519.Signing.PrivateKey()
            let unrestricted = policy(tenantId: nil, envelopeId: nil, configEpoch: nil)
            for name in ComputerLetsReceipt.unsignedNames
            where name != "type" && name != "executor_audience" {
                let (json, _) = try mint { payload in
                    switch payload[name] {
                    case .string(let value): payload[name] = .string(value + "x")
                    case .integer(let value): payload[name] = .integer(value &+ 1)
                    case .array(let value): payload[name] = .array(value + [.integer(1)])
                    case .null: payload[name] = .string("sha256:" + String(repeating: "4", count: 64))
                    default: XCTFail("unexpected field shape for \(name)")
                    }
                }
                XCTAssertEqual(
                    verifyCode(json, privateKey: privateKey, policy: unrestricted), "receipt_invalid", name)
            }
            let (audience, _) = try mint { $0["executor_audience"] = .string("mac-hostx") }
            XCTAssertEqual(
                verifyCode(audience, privateKey: privateKey, policy: unrestricted), "receipt_refused")
        }

        func testPolicyDenialsForForeignAudienceTenantEnvelopeEpochDigestAndWarden() throws {
            let denials: [(String, (inout [String: ComputerLetsValue]) -> Void, ComputerLetsExecutorPolicy)] = [
                ("audience", { $0["executor_audience"] = .string("other-host") }, policy()),
                ("tenant", { $0["tenant_id"] = .string("other-tenant") }, policy()),
                ("envelope", { $0["envelope_id"] = .string("other-envelope") }, policy()),
                ("epoch", { $0["config_epoch"] = .integer(2) }, policy()),
                (
                    "policy digest",
                    { $0["policy_digest"] = .string("sha256:" + String(repeating: "9", count: 64)) },
                    policy(allowedPolicyDigests: ["sha256:" + String(repeating: "1", count: 64)])
                ),
                ("warden", { $0["warden_id"] = .string("warden-other") }, policy(trustedWardens: ["warden-test"])),
            ]
            for (name, changes, denied) in denials {
                let (json, signingKey) = try mint(changes)
                XCTAssertEqual(verifyCode(json, privateKey: signingKey, policy: denied), "receipt_refused", name)
            }
        }

        func testFreshnessDenialsAndClockUncertaintyWindows() throws {
            let (json, privateKey) = try mint()
            XCTAssertEqual(verifyCode(json, privateKey: privateKey, nowNs: 2_000), "receipt_refused")
            XCTAssertNil(verifyCode(json, privateKey: privateKey, nowNs: 1_999))
            XCTAssertEqual(
                verifyCode(
                    json, privateKey: privateKey, policy: policy(maxClockUncertaintyNs: 1_000), nowNs: 1_999,
                    uncertaintyNs: 1), "receipt_refused")
            XCTAssertNil(
                verifyCode(
                    json, privateKey: privateKey, policy: policy(maxClockUncertaintyNs: 1_000), nowNs: 1_500,
                    uncertaintyNs: 400))
            XCTAssertEqual(
                verifyCode(json, privateKey: privateKey, policy: policy(maxClockUncertaintyNs: 0), nowNs: 1_500,
                    uncertaintyNs: 1), "receipt_refused")
            let (future, futureKey) = try mint { payload in
                payload["issued_at_ns"] = .integer(2_000)
                payload["expires_at_ns"] = .integer(3_000)
            }
            XCTAssertEqual(verifyCode(future, privateKey: futureKey, nowNs: 1_500), "receipt_refused")
        }

        func testUntrustedStaleOrSubstitutedKeysAreRefused() throws {
            let (json, privateKey) = try mint()
            let substitute = Curve25519.Signing.PrivateKey()
            XCTAssertEqual(
                verifyCode(
                    json, privateKey: privateKey,
                    keys: [try trustedKey(substitute)]), "receipt_invalid")
            XCTAssertEqual(
                verifyCode(
                    json, privateKey: privateKey,
                    keys: [try ComputerLetsTrustedKey(
                        wardenId: "warden-test", keyId: "warden-test/ed25519-other",
                        publicKey: privateKey.publicKey.rawRepresentation)]), "receipt_invalid")
            XCTAssertEqual(
                verifyCode(
                    json, privateKey: privateKey,
                    keys: [try ComputerLetsTrustedKey(
                        wardenId: "warden-test", keyId: "warden-test/ed25519-test",
                        publicKey: privateKey.publicKey.rawRepresentation, notBeforeNs: 1_600)]),
                "receipt_invalid")
            XCTAssertEqual(
                verifyCode(
                    json, privateKey: privateKey,
                    keys: [try ComputerLetsTrustedKey(
                        wardenId: "warden-test", keyId: "warden-test/ed25519-test",
                        publicKey: privateKey.publicKey.rawRepresentation, notAfterNs: 1_400)]),
                "receipt_invalid")
            XCTAssertNil(
                verifyCode(
                    json, privateKey: privateKey,
                    keys: [try ComputerLetsTrustedKey(
                        wardenId: "warden-test", keyId: "warden-test/ed25519-test",
                        publicKey: privateKey.publicKey.rawRepresentation, notBeforeNs: 1_400,
                        notAfterNs: 1_600)]))
        }

        func testMalformedReceiptsAreRefusedWithoutVerification() {
            let bad: [(String, (inout [String: ComputerLetsValue]) -> Void)] = [
                ("unknown field", { $0["extra"] = .integer(1) }),
                ("missing field", { $0.removeValue(forKey: "nonce") }),
                ("wrong type field", { $0["type"] = .string("lets.receipt/v2") }),
                ("bad digest", { $0["policy_digest"] = .string("md5:zz") }),
                ("bad evidence digest", { $0["evidence_digest"] = .string("sha256:ZZ") }),
                ("empty cost", { $0["cost"] = .array([]) }),
                ("negative cost", { $0["cost"] = .array([.integer(-1)]) }),
                ("zero epoch", { $0["config_epoch"] = .integer(0) }),
                ("zero sequence", { $0["resulting_sequence"] = .integer(0) }),
                ("inverted window", { payload in
                    payload["expires_at_ns"] = .integer(1_000)
                    payload["issued_at_ns"] = .integer(2_000)
                }),
                ("control identifier", { $0["nonce"] = .string("nonce\u{1F}") }),
                ("padded identifier", { $0["subject_id"] = .string(" subject") }),
            ]
            for (name, changes) in bad {
                XCTAssertThrowsError(try ComputerLetsReceipt(json: try mint(changes).json), name)
            }
            for text in ["", "{", "[]", "null", "{\"signature\":1.5}", "{\"type\":1}"] {
                XCTAssertThrowsError(try ComputerLetsReceipt(json: text), text)
            }
            let floated = (try? mint().json)?.replacingOccurrences(
                of: "\"issued_at_ns\":1000", with: "\"issued_at_ns\":1.5")
            XCTAssertNotNil(floated)
            XCTAssertThrowsError(try ComputerLetsReceipt(json: floated!))
        }

        func testVerifyAndClaimClaimsEachReceiptExactlyOnce() throws {
            let (json, privateKey) = try mint()
            let store = MemoryClaimStore()
            XCTAssertEqual(claimCode(json, privateKey: privateKey, store: store), nil)
            XCTAssertEqual(claimCode(json, privateKey: privateKey, store: store), "receipt_replayed")
            let (second, secondKey) = try mint { $0["receipt_id"] = .string("receipt_unit0002") }
            XCTAssertEqual(claimCode(second, privateKey: secondKey, store: store), nil)
        }

        func testTrustedKeyConstructionRejectsBadMaterial() throws {
            let privateKey = Curve25519.Signing.PrivateKey()
            XCTAssertThrowsError(
                try ComputerLetsTrustedKey(
                    wardenId: "warden-test", keyId: "k", publicKey: privateKey.publicKey.rawRepresentation
                        .prefix(31)))
            XCTAssertThrowsError(
                try ComputerLetsTrustedKey(
                    wardenId: "warden-test", keyId: "k", publicKey: privateKey.publicKey.rawRepresentation,
                    notBeforeNs: 10, notAfterNs: 10))
            XCTAssertThrowsError(
                try ComputerLetsTrustedKey(
                    wardenId: "warden-test", keyId: "k", publicKey: privateKey.publicKey.rawRepresentation,
                    notBeforeNs: -1))
            XCTAssertThrowsError(
                try ComputerLetsTrustedKey(
                    wardenId: "", keyId: "k", publicKey: privateKey.publicKey.rawRepresentation))
        }
    }
#endif
