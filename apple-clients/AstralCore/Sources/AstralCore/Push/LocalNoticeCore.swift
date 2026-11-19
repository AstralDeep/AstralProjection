// Platform-neutral decisions for content-free local mesh notices: permission transitions, opaque reference payloads,
// bounded duplicate suppression, redacted APNs token rotation and capped registration retry.

import CryptoKit
import Foundation

public enum LocalNoticePermission: Equatable, Sendable {
    case notDetermined
    case provisional
    case authorized
    case denied
    case revoked

    public var allowsPosting: Bool { self == .authorized || self == .provisional }

    public var canRequest: Bool { self == .notDetermined }

    public enum Reported: Equatable, Sendable {
        case notDetermined, provisional, authorized, ephemeral, denied
    }

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

public struct LocalNoticeRef: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    static let pattern = "^[A-Za-z0-9._:-]{8,128}$"

    public init?(_ value: String) {
        guard value.range(of: Self.pattern, options: .regularExpression) != nil else { return nil }
        self.value = value
    }

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

public enum LocalNoticePayload {
    public static let referenceKey = "astral_local_ref"
    public static let identifierPrefix = "astral-mesh-"

    public static func userInfo(_ ref: LocalNoticeRef) -> [String: String] { [referenceKey: ref.value] }

    public static func identifier(_ ref: LocalNoticeRef) -> String { identifierPrefix + ref.value }

    public static func claims(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo.keys.contains { ($0 as? String) == referenceKey }
    }

    public static func decode(_ userInfo: [AnyHashable: Any]) -> Result<LocalNoticeRef, LocalNoticeRejection> {
        guard claims(userInfo) else { return .failure(.notLocalNotice) }
        guard userInfo.count == 1 else { return .failure(.malformed("unexpected_fields")) }
        guard let raw = userInfo[referenceKey] as? String else { return .failure(.malformed("reference_type")) }
        guard let ref = LocalNoticeRef(raw) else { return .failure(.malformed("reference_format")) }
        return .success(ref)
    }
}

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

public struct LocalNoticeTokenTracker: Sendable {
    public enum Event: Equatable, Sendable {
        case first(fingerprint: String)
        case rotated(previous: String, current: String)
        case unchanged
        case invalid
    }

    public private(set) var fingerprint: String?

    public init() {}

    public static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

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

    public func delay(afterFailure attempt: Int) -> Int? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        let shift = min(attempt - 1, 30)
        let (value, overflow) = baseSeconds.multipliedReportingOverflow(by: 1 << shift)
        return overflow ? maxSeconds : min(value, maxSeconds)
    }
}
