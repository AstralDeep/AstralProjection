// Fetches the Ed25519-signed minimum-build policy from the Downloads site and decides whether this Mac build may connect.
// Any fetch, parse, signature, expiry or rollback problem leaves the policy absent so the app connects normally.

#if os(macOS)
    import AstralCore
    import CryptoKit
    import Foundation
    import os

    nonisolated struct UpdatePolicy: Equatable, Sendable {
        let minimumBuild: Int
        let serial: Int
        let expires: Date
        let message: String
    }

    nonisolated enum UpdatePolicyFailure: String, Error, Equatable, Sendable {
        case unreachable, expired, signature, parse, rollback

        var reportable: Bool { self == .signature || self == .parse || self == .rollback }

        var summary: String {
            switch self {
            case .unreachable: return "The update policy could not be fetched."
            case .expired: return "The update policy has expired."
            case .signature: return "The update policy signature could not be verified."
            case .parse: return "The update policy could not be read."
            case .rollback: return "The update policy is older than one already seen."
            }
        }
    }

    nonisolated struct UpdateRequirement: Equatable, Sendable {
        let minimumBuild: Int
        let installedBuild: Int
        let message: String
    }

    nonisolated enum UpdatePolicyOutcome: Equatable, Sendable {
        case allowed
        case required(UpdateRequirement)
    }

    nonisolated protocol UpdatePolicyFetching: Sendable {
        func body(of url: URL) async throws -> Data
    }

    nonisolated struct UpdatePolicyHTTP: UpdatePolicyFetching {
        struct Rejected: Error {}
        let session: URLSession
        let timeout: TimeInterval

        init(session: URLSession = NoStoreHTTP.session, timeout: TimeInterval = 8) {
            self.session = session
            self.timeout = timeout
        }

        func body(of url: URL) async throws -> Data {
            guard url.scheme == "https" else { throw Rejected() }
            var request = URLRequest(
                url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Rejected() }
            return data
        }
    }

    @MainActor
    final class UpdatePolicyGate {
        static let policyURL = URL(string: "https://astraldeep.github.io/data/mac-update-policy.json")!
        static let cacheLifetime: TimeInterval = 24 * 60 * 60
        static let policyLimit = 16 * 1024
        static let signatureLimit = 512
        static let cacheKey = "update.policy.cache"
        static let serialKey = "update.policy.serial"
        static let distributionMarker = "direct-download"

        private struct Cached: Codable {
            let policy: Data
            let signature: String
            let fetchedAt: Double
        }

        private struct Wire: Decodable {
            let schemaVersion: Int
            let minimumBuild: Int
            let serial: Int
            let expires: String
            let message: String
        }

        private let policyURL: URL
        private let publicKey: Curve25519.Signing.PublicKey
        private let installedBuild: Int
        private let fetcher: any UpdatePolicyFetching
        private let defaults: UserDefaults
        private let now: @Sendable () -> Date
        private let log = Logger(subsystem: "com.personalailabs.astraldeep", category: "updates")

        private(set) var lastFailure: UpdatePolicyFailure?

        init?(
            policyURL: URL = UpdatePolicyGate.policyURL, publicKeyBase64: String, installedBuild: Int,
            fetcher: any UpdatePolicyFetching = UpdatePolicyHTTP(), defaults: UserDefaults = .standard,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            guard let raw = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
                let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw), installedBuild > 0
            else { return nil }
            self.policyURL = policyURL
            publicKey = key
            self.installedBuild = installedBuild
            self.fetcher = fetcher
            self.defaults = defaults
            self.now = now
        }

        convenience init?(bundle: Bundle = .main, fetcher: any UpdatePolicyFetching = UpdatePolicyHTTP()) {
            guard bundle.object(forInfoDictionaryKey: "ASTRALDistribution") as? String == Self.distributionMarker,
                let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
            else { return nil }
            self.init(publicKeyBase64: key, installedBuild: build, fetcher: fetcher)
        }

        func evaluate() async -> UpdatePolicyOutcome {
            lastFailure = nil
            switch await resolve() {
            case .failure(let failure):
                if failure.reportable { lastFailure = failure }
                log.notice("Update policy absent: \(failure.rawValue, privacy: .public)")
                return .allowed
            case .success(let policy):
                guard policy.minimumBuild > installedBuild else { return .allowed }
                return .required(
                    UpdateRequirement(
                        minimumBuild: policy.minimumBuild, installedBuild: installedBuild, message: policy.message))
            }
        }

        private func resolve() async -> Result<UpdatePolicy, UpdatePolicyFailure> {
            if let cached = cachedPolicy() { return .success(cached) }
            let bytes: Data
            do { bytes = try await fetcher.body(of: policyURL) } catch { return .failure(.unreachable) }
            let signatureBytes: Data
            do {
                signatureBytes = try await fetcher.body(of: policyURL.appendingPathExtension("sig"))
            } catch { return .failure(.signature) }
            guard bytes.count <= Self.policyLimit else { return .failure(.parse) }
            guard signatureBytes.count <= Self.signatureLimit,
                let signature = String(data: signatureBytes, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                verifies(bytes, signature: signature)
            else { return .failure(.signature) }
            guard let policy = parse(bytes) else { return .failure(.parse) }
            let seen = defaults.integer(forKey: Self.serialKey)
            guard policy.serial >= seen else { return .failure(.rollback) }
            defaults.set(policy.serial, forKey: Self.serialKey)
            guard policy.expires > now() else { return .failure(.expired) }
            store(Cached(policy: bytes, signature: signature, fetchedAt: now().timeIntervalSince1970))
            return .success(policy)
        }

        private func cachedPolicy() -> UpdatePolicy? {
            guard let data = defaults.data(forKey: Self.cacheKey),
                let cached = try? JSONDecoder().decode(Cached.self, from: data)
            else { return nil }
            let age = now().timeIntervalSince1970 - cached.fetchedAt
            guard age >= 0, age < Self.cacheLifetime, verifies(cached.policy, signature: cached.signature),
                let policy = parse(cached.policy), policy.serial >= defaults.integer(forKey: Self.serialKey),
                policy.expires > now()
            else { return nil }
            return policy
        }

        private func store(_ cached: Cached) {
            if let data = try? JSONEncoder().encode(cached) { defaults.set(data, forKey: Self.cacheKey) }
        }

        private func verifies(_ bytes: Data, signature: String) -> Bool {
            guard let raw = Data(base64Encoded: signature), raw.count == 64 else { return false }
            return publicKey.isValidSignature(raw, for: bytes)
        }

        private func parse(_ bytes: Data) -> UpdatePolicy? {
            guard let wire = try? JSONDecoder().decode(Wire.self, from: bytes), wire.schemaVersion == 1,
                wire.minimumBuild >= 1, wire.serial >= 0,
                let expires = ISO8601DateFormatter().date(from: wire.expires)
            else { return nil }
            let cleaned = String(
                wire.message.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 32 }
                    .map(Character.init).prefix(200))
            return UpdatePolicy(
                minimumBuild: wire.minimumBuild, serial: wire.serial, expires: expires,
                message: cleaned.isEmpty ? "Update required" : cleaned)
        }
    }
#endif
