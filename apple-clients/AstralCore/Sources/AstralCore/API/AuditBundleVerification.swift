// Verifies a downloaded audit export bundle against the SHA-256 digest the server reported for that
// export, so a file edited or truncated after download is detectable before the owner relies on it.
// The bundle's contents stay server-owned redacted audit records; this type only checks integrity.

import CryptoKit
import Foundation

public enum AuditBundleVerificationFailure: Equatable, Sendable {
    case malformedDigest
    case digestMismatch
}

public enum AuditBundleVerification: Equatable, Sendable {
    case verified(digest: String)
    case unverified(AuditBundleVerificationFailure)
}

public enum AuditBundleVerifier {
    public static func verify(_ data: Data, expectedDigest: String) -> AuditBundleVerification {
        guard let expected = Self.serverDigest(expectedDigest) else { return .unverified(.malformedDigest) }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { return .unverified(.digestMismatch) }
        return .verified(digest: actual)
    }

    public static func serverDigest(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64, trimmed.allSatisfy({ Self.hex.contains($0) }) else { return nil }
        return trimmed
    }

    private static let hex = Set("0123456789abcdef")
}
