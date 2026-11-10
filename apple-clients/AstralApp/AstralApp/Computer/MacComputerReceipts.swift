// Loads the owner's receipt verification configuration, verifies and durably claims warden receipts in the
// app's protected container, and refuses a receipt that approves a different resolved effect plan.

#if os(macOS)
    import AstralCore
    import CryptoKit
    import Foundation

    struct MacComputerReceiptGate: Sendable {
        let policy: ComputerLetsExecutorPolicy
        let keys: [ComputerLetsTrustedKey]
        let store: MacComputerReceiptClaimStore
        let clock: @Sendable () -> Int64
        let uncertaintyNs: Int64

        func verify(_ receiptText: String, evidence: String) throws -> ComputerLetsReceipt {
            let receipt = try ComputerLetsReceipt(json: receiptText)
            try ComputerLetsVerifier.verify(
                receipt, policy: policy, keys: keys, nowNs: clock(), uncertaintyNs: uncertaintyNs)
            guard receipt.evidenceDigest == evidence else {
                throw ComputerHostError(
                    "plan_drift",
                    "The receipt approves a different resolved plan than this Mac is about to run, so nothing "
                        + "runs.")
            }
            return receipt
        }

        func claim(_ receipt: ComputerLetsReceipt) throws {
            try store.claim(receipt, claimedAtNs: clock())
        }
    }

    struct MacComputerReceiptClaimStore: Sendable {
        static let claimLimit = 8192
        let directory: URL
        let identity: String

        init(directory: URL, identity: String) throws {
            self.directory = directory
            self.identity = identity
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                (info.st_mode & 0o777) == 0o700
            else {
                throw ComputerHostError(
                    "receipt_store_failed", "The receipt claim store directory is not privately owned.")
            }
            let manifest = directory.appendingPathComponent("store.json")
            let payload = try JSONSerialization.data(
                withJSONObject: ["identity": identity, "version": 1], options: [.sortedKeys])
            let descriptor = open(manifest.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
            if descriptor >= 0 {
                defer { close(descriptor) }
                guard Self.write(descriptor, payload), Self.syncDirectory(directory) else {
                    throw ComputerHostError(
                        "receipt_store_failed", "The receipt claim store could not be initialized.")
                }
            } else if errno == EEXIST {
                guard let stored = FileManager.default.contents(atPath: manifest.path),
                    let document = try? JSONSerialization.jsonObject(with: stored) as? [String: Any],
                    document["identity"] as? String == identity, document["version"] as? Int == 1
                else {
                    throw ComputerHostError(
                        "receipt_store_failed",
                        "The receipt claim store belongs to a different executor identity.")
                }
            } else {
                throw ComputerHostError(
                    "receipt_store_failed", "The receipt claim store could not be opened (errno \(errno)).")
            }
        }

        func claim(_ receipt: ComputerLetsReceipt, claimedAtNs: Int64) throws {
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            guard existing.count < Self.claimLimit else {
                throw ComputerHostError(
                    "receipt_store_failed", "The receipt claim store is full, so the effect cannot start.")
            }
            let name = "claim-" + Self.digest(receipt.receiptId) + ".json"
            let payload = try JSONSerialization.data(
                withJSONObject: [
                    "claimed_at_ns": claimedAtNs, "receipt_id": receipt.receiptId, "request_id": receipt.requestId,
                ], options: [.sortedKeys])
            let descriptor = open(
                directory.appendingPathComponent(name).path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
            guard descriptor >= 0 else {
                if errno == EEXIST {
                    throw ComputerHostError(
                        "receipt_replayed",
                        "This receipt was already claimed on this Mac, so the effect will not run again.")
                }
                throw ComputerHostError(
                    "receipt_store_failed", "The receipt claim store refused the claim (errno \(errno)).")
            }
            defer { close(descriptor) }
            guard Self.write(descriptor, payload), fsync(descriptor) == 0,
                Self.syncDirectory(directory)
            else {
                throw ComputerHostError(
                    "receipt_store_failed", "The receipt claim could not be made durable.")
            }
        }

        static func digest(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        private static func write(_ descriptor: Int32, _ payload: Data) -> Bool {
            var sent = 0
            let bytes = [UInt8](payload)
            while sent < bytes.count {
                let written = bytes.withUnsafeBufferPointer { buffer in
                    write(descriptor, buffer.baseAddress!.advanced(by: sent), bytes.count - sent)
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                sent += written
            }
            return true
        }

        private static func syncDirectory(_ directory: URL) -> Bool {
            let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            return fsync(descriptor) == 0
        }
    }

    struct MacComputerReceiptConfigurationReader: @unchecked Sendable {
        static let configurationKey = "computer.receipt.configuration"
        let defaults: UserDefaults

        func read() -> MacComputerReceiptGate? {
            guard let raw = defaults.string(forKey: Self.configurationKey),
                let document = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            else { return nil }
            guard let audience = document["audience"] as? String,
                ComputerLetsReceipt.validIdentifier(audience),
                let keys = Self.keys(document["wardens"])
            else { return nil }
            guard let uncertainty = Self.integer(document["uncertainty_ns"], minimum: 0),
                let maximum = Self.integer(document["max_clock_uncertainty_ns"], minimum: 0),
                uncertainty <= maximum
            else { return nil }
            var policy = ComputerLetsExecutorPolicy(
                audience: audience, maxClockUncertaintyNs: maximum)
            if let tenant = Self.text(document["tenant_id"]) { policy.tenantId = tenant }
            if let envelope = Self.text(document["envelope_id"]) { policy.envelopeId = envelope }
            if let epoch = Self.integer(document["config_epoch"], minimum: 1) { policy.configEpoch = epoch }
            if document["policy_digests"] != nil {
                let digests = Self.digests(document["policy_digests"])
                guard !digests.isEmpty else { return nil }
                policy.allowedPolicyDigests = digests
            }
            if document["machine_digests"] != nil {
                let digests = Self.digests(document["machine_digests"])
                guard !digests.isEmpty else { return nil }
                policy.allowedMachineDigests = digests
            }
            policy.trustedWardens = Set(keys.map(\.wardenId))
            let fingerprints = keys.map { Self.digest($0.wardenId + "/" + $0.keyId + "/" + Self.hex($0.publicKey)) }
                .sorted()
            let identity = Self.digest(audience + "|" + fingerprints.joined(separator: ","))
            let support =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let directory =
                support
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "AstralDeep", isDirectory: true)
                .appendingPathComponent("ComputerReceipts", isDirectory: true)
            guard let store = try? MacComputerReceiptClaimStore(directory: directory, identity: identity) else {
                return nil
            }
            return MacComputerReceiptGate(
                policy: policy, keys: keys, store: store,
                clock: { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }, uncertaintyNs: uncertainty)
        }

        private static func digests(_ value: Any?) -> Set<String> {
            guard let names = value as? [String] else { return [] }
            return Set(names.filter { ComputerLetsReceipt.validDigest($0) })
        }

        private static func text(_ value: Any?) -> String? {
            guard let text = value as? String, ComputerLetsReceipt.validIdentifier(text) else { return nil }
            return text
        }

        private static func integer(_ value: Any?, minimum: Int64) -> Int64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            let integer = number.int64Value
            guard integer >= minimum else { return nil }
            return integer
        }

        private static func keys(_ value: Any?) -> [ComputerLetsTrustedKey]? {
            guard let entries = value as? [[String: Any]], !entries.isEmpty else { return nil }
            var keys: [ComputerLetsTrustedKey] = []
            for entry in entries {
                guard let wardenId = entry["warden_id"] as? String, let keyId = entry["key_id"] as? String,
                    let encoded = entry["public_key"] as? String,
                    let material = try? ComputerLetsCanonical.base64URLDecode(encoded)
                else { return nil }
                var notBefore: Int64?
                if entry["not_before_ns"] != nil {
                    guard let bounded = Self.integer(entry["not_before_ns"], minimum: 0) else { return nil }
                    notBefore = bounded
                }
                var notAfter: Int64?
                if entry["not_after_ns"] != nil {
                    guard let bounded = Self.integer(entry["not_after_ns"], minimum: 0) else { return nil }
                    notAfter = bounded
                }
                guard let key = try? ComputerLetsTrustedKey(
                    wardenId: wardenId, keyId: keyId, publicKey: material, notBeforeNs: notBefore,
                    notAfterNs: notAfter)
                else { return nil }
                keys.append(key)
            }
            return keys
        }

        private static func hex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
