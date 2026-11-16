// Platform-neutral decisions for content-free local mesh notices: permission transitions, opaque reference payloads,
// bounded duplicate suppression, redacted APNs token rotation and capped registration retry.

import CryptoKit
import Foundation

/// The OS alert permission as the local notice adapter understands it.
/// `revoked` means a previously granted permission is now denied (for example turned off in Settings).
public enum LocalNoticePermission: Equatable, Sendable {
    case notDetermined
    case provisional
    case authorized
    case denied
    case revoked

    /// Whether a local notice may be posted.
    public var allowsPosting: Bool { self == .authorized || self == .provisional }

    /// Whether the adapter may still ask the user (only before any decision).
    public var canRequest: Bool { self == .notDetermined }

    /// Raw OS states, decoupled from `UNAuthorizationStatus` so the decision is testable on every platform.
    public enum Reported: Equatable, Sendable {
        case notDetermined, provisional, authorized, ephemeral, denied
    }

    /// Folds a fresh OS report into the previous state. A denial that follows any grant is a revocation;
    /// a revocation stays a revocation until the OS reports a grant again.
    public static func next(previous: LocalNoticePermission?, reported: Reported) -> LocalNoticePermission {
        switch reported {
        case .notDetermined: return .notDetermined
        case .provisional: return .provisional
        case .authorized, .ephemeral: return .authorized
        case .denied:
            switch previous {
            case .authorized?, .provisional?, .revoked?: return .revoked
            default: return .denied
            }
        }
    }
}

/// An opaque, content-free reference to a synced mesh change. It names nothing and carries no user content.
public struct LocalNoticeRef: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    static let pattern = "^[A-Za-z0-9._:-]{8,128}$"

    public init?(_ value: String) {
        guard value.range(of: Self.pattern, options: .regularExpression) != nil else { return nil }
        self.value = value
    }

    /// Derives a stable opaque reference from a namespace and a change token without exposing either.
    public static func derive(namespace: String, change: String) -> LocalNoticeRef {
        let digest = SHA256.hash(data: Data((namespace + "\u{0}" + change).utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return LocalNoticeRef("mn-" + hex)!
    }

    public var description: String { value }
}

public enum LocalNoticeRejection: Error, Equatable, Sendable {
    case notLocalNotice
    case malformed(String)
}

/// The minimal local notice payload: exactly one opaque reference under `astral_local_ref`.
public enum LocalNoticePayload {
    public static let referenceKey = "astral_local_ref"
    public static let identifierPrefix = "astral-mesh-"

    public static func userInfo(_ ref: LocalNoticeRef) -> [String: String] { [referenceKey: ref.value] }

    public static func identifier(_ ref: LocalNoticeRef) -> String { identifierPrefix + ref.value }

    /// Whether this payload belongs to the local notice path at all (so other notification owners keep theirs).
    public static func claims(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo.keys.contains { ($0 as? String) == referenceKey }
    }

    /// Strictly validates a received payload: one string key, a valid opaque reference, nothing else.
    public static func decode(_ userInfo: [AnyHashable: Any]) -> Result<LocalNoticeRef, LocalNoticeRejection> {
        guard claims(userInfo) else { return .failure(.notLocalNotice) }
        guard userInfo.count == 1 else { return .failure(.malformed("unexpected_fields")) }
        guard let raw = userInfo[referenceKey] as? String else { return .failure(.malformed("reference_type")) }
        guard let ref = LocalNoticeRef(raw) else { return .failure(.malformed("reference_format")) }
        return .success(ref)
    }
}

/// A bounded first-seen set. Inserting an already-seen reference reports a duplicate.
public struct LocalNoticeLedger: Sendable {
    public let capacity: Int
    private var order: [LocalNoticeRef] = []
    private var seen: Set<LocalNoticeRef> = []

    public init(capacity: Int = 256) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { seen.count }

    public func contains(_ ref: LocalNoticeRef) -> Bool { seen.contains(ref) }

    /// Returns `true` when the reference is new.
    @discardableResult
    public mutating func insert(_ ref: LocalNoticeRef) -> Bool {
        guard seen.insert(ref).inserted else { return false }
        order.append(ref)
        if order.count > capacity { seen.remove(order.removeFirst()) }
        return true
    }

    public mutating func remove(_ ref: LocalNoticeRef) {
        guard seen.remove(ref) != nil else { return }
        order.removeAll { $0 == ref }
    }

    public mutating func removeAll() {
        order.removeAll()
        seen.removeAll()
    }
}

/// Tracks the APNs device token without retaining or exposing more than a fingerprint for diagnostics.
public struct LocalNoticeTokenTracker: Sendable {
    public enum Event: Equatable, Sendable {
        case first(fingerprint: String)
        case rotated(previous: String, current: String)
        case unchanged
        case invalid
    }

    public private(set) var fingerprint: String?

    public init() {}

    /// Hex encoding of the raw OS token (what a provider expects).
    public static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    /// Redacted diagnostic form; never the token itself.
    public static func redacted(_ fingerprint: String?) -> String {
        guard let fingerprint else { return "none" }
        return "sha256:" + fingerprint.prefix(8) + "…"
    }

    public mutating func receive(_ token: Data) -> Event {
        guard !token.isEmpty, token.count <= 256 else { return .invalid }
        let current = pushTokenFingerprint(Self.hex(token))
        defer { fingerprint = current }
        switch fingerprint {
        case nil: return .first(fingerprint: current)
        case current?: return .unchanged
        case let previous?: return .rotated(previous: previous, current: current)
        }
    }

    public mutating func reset() { fingerprint = nil }
}

/// Capped exponential backoff for APNs registration failures.
public struct LocalNoticeRetryPolicy: Equatable, Sendable {
    public let baseSeconds: Int
    public let maxSeconds: Int
    public let maxAttempts: Int

    public init(baseSeconds: Int = 5, maxSeconds: Int = 300, maxAttempts: Int = 6) {
        precondition(baseSeconds > 0 && maxSeconds >= baseSeconds && maxAttempts > 0)
        self.baseSeconds = baseSeconds
        self.maxSeconds = maxSeconds
        self.maxAttempts = maxAttempts
    }

    /// The delay before retry number `attempt` (1-based), or `nil` once attempts are exhausted.
    public func delay(afterFailure attempt: Int) -> Int? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        let shift = min(attempt - 1, 30)
        let (value, overflow) = baseSeconds.multipliedReportingOverflow(by: 1 << shift)
        return overflow ? maxSeconds : min(value, maxSeconds)
    }
}
