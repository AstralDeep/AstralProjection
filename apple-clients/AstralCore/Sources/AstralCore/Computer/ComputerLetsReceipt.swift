// Decodes and verifies warden-signed LETS executor receipts for Mac host effects, binding each receipt to
// the resolved effect plan it authorizes and claiming it durably before the effect runs.

#if os(macOS)
    import CryptoKit
    import Foundation

    public struct ComputerLetsReceipt: Sendable, Equatable {
        public static let wireType = "lets.receipt/v1"
        static let maximumIdentifier = 512
        static let maximumResource = Int64.max
        public let tenantId: String
        public let envelopeId: String
        public let configEpoch: Int64
        public let receiptId: String
        public let requestId: String
        public let wardenId: String
        public let keyId: String
        public let policyId: String
        public let policyVersion: String
        public let policyDigest: String
        public let machineDigest: String
        public let leaseId: String
        public let lineageId: String
        public let subjectId: String
        public let executorAudience: String
        public let transition: String
        public let sourceState: String
        public let targetState: String
        public let cost: [Int64]
        public let resultingSequence: Int64
        public let evidenceDigest: String?
        public let nonce: String
        public let issuedAtNs: Int64
        public let expiresAtNs: Int64
        public let signature: String

        static let unsignedNames: Set<String> = [
            "type", "tenant_id", "envelope_id", "config_epoch", "receipt_id", "request_id", "warden_id", "key_id",
            "policy_id", "policy_version", "policy_digest", "machine_digest", "lease_id", "lineage_id", "subject_id",
            "executor_audience", "transition", "source_state", "target_state", "cost", "resulting_sequence",
            "evidence_digest", "nonce", "issued_at_ns", "expires_at_ns",
        ]

        public init(json: String) throws {
            guard case .object(let items) = try ComputerLetsCanonical.parse(json) else {
                throw ComputerHostError("receipt_invalid", "The receipt payload is not an object.")
            }
            var names = Self.unsignedNames
            names.insert("signature")
            guard Set(items.keys) == names else {
                throw ComputerHostError("receipt_invalid", "The receipt fields do not match lets.receipt/v1.")
            }
            guard items["type"] == .string(Self.wireType) else {
                throw ComputerHostError("receipt_invalid", "The receipt type is not lets.receipt/v1.")
            }
            func text(_ name: String) throws -> String {
                guard case .string(let value) = items[name], Self.validIdentifier(value) else {
                    throw ComputerHostError("receipt_invalid", "The receipt field \(name) is invalid.")
                }
                return value
            }
            func integer(_ name: String) throws -> Int64 {
                guard case .integer(let value) = items[name] else {
                    throw ComputerHostError("receipt_invalid", "The receipt field \(name) must be an integer.")
                }
                return value
            }
            tenantId = try text("tenant_id")
            envelopeId = try text("envelope_id")
            receiptId = try text("receipt_id")
            requestId = try text("request_id")
            policyId = try text("policy_id")
            policyVersion = try text("policy_version")
            leaseId = try text("lease_id")
            lineageId = try text("lineage_id")
            subjectId = try text("subject_id")
            executorAudience = try text("executor_audience")
            transition = try text("transition")
            sourceState = try text("source_state")
            targetState = try text("target_state")
            nonce = try text("nonce")
            wardenId = try text("warden_id")
            keyId = try text("key_id")
            policyDigest = try text("policy_digest")
            machineDigest = try text("machine_digest")
            guard Self.validDigest(policyDigest), Self.validDigest(machineDigest),
                computerFullMatch(wardenId, "^[A-Za-z0-9][A-Za-z0-9._~-]{0,127}$"),
                computerFullMatch(keyId, "^[A-Za-z0-9][A-Za-z0-9._~:/+-]{0,511}$")
            else {
                throw ComputerHostError("receipt_invalid", "The receipt digests or issuer identity are invalid.")
            }
            configEpoch = try integer("config_epoch")
            resultingSequence = try integer("resulting_sequence")
            issuedAtNs = try integer("issued_at_ns")
            expiresAtNs = try integer("expires_at_ns")
            guard configEpoch > 0, resultingSequence > 0, issuedAtNs >= 0, expiresAtNs > 0, expiresAtNs > issuedAtNs
            else {
                throw ComputerHostError("receipt_invalid", "The receipt counters or validity window are invalid.")
            }
            guard case .array(let dimensions) = items["cost"], !dimensions.isEmpty else {
                throw ComputerHostError("receipt_invalid", "The receipt cost vector is invalid.")
            }
            var parsedCost: [Int64] = []
            parsedCost.reserveCapacity(dimensions.count)
            for dimension in dimensions {
                guard case .integer(let value) = dimension, value >= 0, value <= Self.maximumResource else {
                    throw ComputerHostError("receipt_invalid", "The receipt cost vector is invalid.")
                }
                parsedCost.append(value)
            }
            cost = parsedCost
            if case .string(let evidence) = items["evidence_digest"] {
                guard Self.validDigest(evidence) else {
                    throw ComputerHostError("receipt_invalid", "The receipt evidence digest is invalid.")
                }
                evidenceDigest = evidence
            } else if items["evidence_digest"] == .null {
                evidenceDigest = nil
            } else {
                throw ComputerHostError("receipt_invalid", "The receipt evidence digest is invalid.")
            }
            guard case .string(let encoded) = items["signature"] else {
                throw ComputerHostError("receipt_invalid", "The receipt signature is missing.")
            }
            signature = encoded
        }

        public func unsignedPayload() -> ComputerLetsValue {
            .object([
                "type": .string(Self.wireType),
                "tenant_id": .string(tenantId),
                "envelope_id": .string(envelopeId),
                "config_epoch": .integer(configEpoch),
                "receipt_id": .string(receiptId),
                "request_id": .string(requestId),
                "warden_id": .string(wardenId),
                "key_id": .string(keyId),
                "policy_id": .string(policyId),
                "policy_version": .string(policyVersion),
                "policy_digest": .string(policyDigest),
                "machine_digest": .string(machineDigest),
                "lease_id": .string(leaseId),
                "lineage_id": .string(lineageId),
                "subject_id": .string(subjectId),
                "executor_audience": .string(executorAudience),
                "transition": .string(transition),
                "source_state": .string(sourceState),
                "target_state": .string(targetState),
                "cost": .array(cost.map { .integer($0) }),
                "resulting_sequence": .integer(resultingSequence),
                "evidence_digest": evidenceDigest.map { .string($0) } ?? .null,
                "nonce": .string(nonce),
                "issued_at_ns": .integer(issuedAtNs),
                "expires_at_ns": .integer(expiresAtNs),
            ])
        }

        public static func validIdentifier(_ value: String) -> Bool {
            guard !value.isEmpty, value.unicodeScalars.count <= maximumIdentifier else { return false }
            let scalars = Array(value.unicodeScalars)
            guard let first = scalars.first, let last = scalars.last,
                !first.properties.isWhitespace, !last.properties.isWhitespace
            else { return false }
            return !scalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }

        public static func validDigest(_ value: String) -> Bool {
            computerFullMatch(value, "^sha256:[0-9a-f]{64}$")
        }
    }

    public struct ComputerLetsTrustedKey: Sendable, Equatable {
        public let wardenId: String
        public let keyId: String
        public let publicKey: Data
        public let notBeforeNs: Int64?
        public let notAfterNs: Int64?

        public init(
            wardenId: String, keyId: String, publicKey: Data, notBeforeNs: Int64? = nil, notAfterNs: Int64? = nil
        ) throws {
            guard publicKey.count == 32,
                computerFullMatch(wardenId, "^[A-Za-z0-9][A-Za-z0-9._~-]{0,127}$"),
                computerFullMatch(keyId, "^[A-Za-z0-9][A-Za-z0-9._~:/+-]{0,511}$"),
                (notBeforeNs ?? 0) >= 0, (notAfterNs ?? 0) >= 0,
                notBeforeNs == nil || notAfterNs == nil || notAfterNs! > notBeforeNs!
            else {
                throw ComputerHostError("receipt_invalid", "The trusted warden key is invalid.")
            }
            self.wardenId = wardenId
            self.keyId = keyId
            self.publicKey = publicKey
            self.notBeforeNs = notBeforeNs
            self.notAfterNs = notAfterNs
        }
    }

    public struct ComputerLetsExecutorPolicy: Sendable, Equatable {
        public var audience: String
        public var tenantId: String?
        public var envelopeId: String?
        public var configEpoch: Int64?
        public var allowedPolicyDigests: Set<String>
        public var allowedMachineDigests: Set<String>
        public var trustedWardens: Set<String>
        public var maxClockUncertaintyNs: Int64

        public init(
            audience: String, tenantId: String? = nil, envelopeId: String? = nil, configEpoch: Int64? = nil,
            allowedPolicyDigests: Set<String> = [], allowedMachineDigests: Set<String> = [],
            trustedWardens: Set<String> = [], maxClockUncertaintyNs: Int64 = 0
        ) {
            self.audience = audience
            self.tenantId = tenantId
            self.envelopeId = envelopeId
            self.configEpoch = configEpoch
            self.allowedPolicyDigests = allowedPolicyDigests
            self.allowedMachineDigests = allowedMachineDigests
            self.trustedWardens = trustedWardens
            self.maxClockUncertaintyNs = maxClockUncertaintyNs
        }
    }

    public protocol ComputerLetsClaimStoring: Sendable {
        func claim(_ receipt: ComputerLetsReceipt, claimedAtNs: Int64) throws
    }

    public enum ComputerLetsVerifier {
        public static func verify(
            _ receipt: ComputerLetsReceipt, policy: ComputerLetsExecutorPolicy, keys: [ComputerLetsTrustedKey],
            nowNs: Int64, uncertaintyNs: Int64? = nil
        ) throws {
            let uncertainty = uncertaintyNs ?? 0
            guard uncertainty >= 0, uncertainty <= policy.maxClockUncertaintyNs, nowNs >= 0,
                nowNs <= ComputerLetsReceipt.maximumResource - uncertainty
            else {
                throw ComputerHostError(
                    "receipt_refused", "This Mac's clock uncertainty exceeds the receipt policy.")
            }
            func refuse(_ why: String) -> ComputerHostError {
                ComputerHostError("receipt_refused", why)
            }
            if receipt.executorAudience != policy.audience {
                throw refuse("The receipt was issued for another executor audience.")
            }
            if let tenant = policy.tenantId, receipt.tenantId != tenant {
                throw refuse("The receipt tenant is not accepted by this Mac.")
            }
            if let envelope = policy.envelopeId, receipt.envelopeId != envelope {
                throw refuse("The receipt envelope is not accepted by this Mac.")
            }
            if let epoch = policy.configEpoch, receipt.configEpoch != epoch {
                throw refuse("The receipt configuration epoch is not accepted.")
            }
            if !policy.allowedPolicyDigests.isEmpty, !policy.allowedPolicyDigests.contains(receipt.policyDigest) {
                throw refuse("The receipt policy digest is not accepted.")
            }
            if !policy.allowedMachineDigests.isEmpty, !policy.allowedMachineDigests.contains(receipt.machineDigest) {
                throw refuse("The receipt machine digest is not accepted.")
            }
            if !policy.trustedWardens.isEmpty, !policy.trustedWardens.contains(receipt.wardenId) {
                throw refuse("The receipt issuer is not a trusted warden.")
            }
            if receipt.issuedAtNs > nowNs + uncertainty {
                throw refuse("The receipt issuance time is in the future.")
            }
            if nowNs + uncertainty >= receipt.expiresAtNs {
                throw refuse("The receipt has expired or cannot be proven fresh.")
            }
            guard let entry = keys.first(where: { $0.wardenId == receipt.wardenId && $0.keyId == receipt.keyId }) else {
                throw ComputerHostError("receipt_invalid", "The receipt issuer key is not trusted.")
            }
            if let notBefore = entry.notBeforeNs, nowNs - uncertainty < notBefore {
                throw ComputerHostError("receipt_invalid", "The trusted warden key is outside its validity window.")
            }
            if let notAfter = entry.notAfterNs, nowNs + uncertainty >= notAfter {
                throw ComputerHostError("receipt_invalid", "The trusted warden key is outside its validity window.")
            }
            let signature: Data
            do {
                signature = try ComputerLetsCanonical.base64URLDecode(receipt.signature)
            } catch {
                throw ComputerHostError("receipt_invalid", "The receipt signature is malformed.")
            }
            guard signature.count == 64 else {
                throw ComputerHostError("receipt_invalid", "The receipt signature is malformed.")
            }
            let payload: Data
            do {
                payload = try ComputerLetsCanonical.canonical(receipt.unsignedPayload())
            } catch {
                throw ComputerHostError("receipt_invalid", "The receipt payload cannot be canonicalized.")
            }
            guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: entry.publicKey),
                publicKey.isValidSignature(signature, for: payload)
            else {
                throw ComputerHostError("receipt_invalid", "The receipt signature is invalid or untrusted.")
            }
        }

        public static func verifyAndClaim(
            _ receipt: ComputerLetsReceipt, policy: ComputerLetsExecutorPolicy, keys: [ComputerLetsTrustedKey],
            store: any ComputerLetsClaimStoring, nowNs: Int64, uncertaintyNs: Int64? = nil
        ) throws {
            try verify(receipt, policy: policy, keys: keys, nowNs: nowNs, uncertaintyNs: uncertaintyNs)
            do {
                try store.claim(receipt, claimedAtNs: nowNs)
            } catch let error as ComputerHostError {
                throw error
            } catch {
                throw ComputerHostError(
                    "receipt_store_failed",
                    "The local receipt claim store is unavailable, so the effect cannot start.")
            }
        }
    }
#endif
