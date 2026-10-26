// Pure decision machine for the Apple notification destination: permission and availability
// gates, APNs token enrollment with rotation generation and fingerprints, bounded duplicate
// suppression, and lifecycle-dependent presentation decisions. PushNotificationService binds
// these decisions to UserNotifications; PushRest performs the destination boundary calls.

import CryptoKit
import Foundation

public enum PushLifecycle: Equatable, Sendable {
    case foreground
    case background
    case terminated
}

public enum PushPermissionState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case revoked
}

public enum ProviderAvailability: Equatable, Sendable {
    case unknown
    case supported
    case unsupported
}

public struct PushIdentity: Equatable, Sendable {
    public let deviceId: String
    public let label: String?

    public init(deviceId: String, label: String? = nil) {
        let valid = deviceId.count >= 8 && deviceId.count <= 128
            && deviceId.first.map { $0.isLetter || $0.isNumber } == true
            && deviceId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
        precondition(valid, PushIdentity.reasonDeviceId)
        precondition(label == nil || (label?.count ?? 0) <= PushIdentity.maxLabelChars, PushIdentity.reasonLabel)
        self.deviceId = deviceId
        self.label = label
    }

    static let maxLabelChars = 64
    static let reasonDeviceId = "device_id"
    static let reasonLabel = "label"
}

public struct PushPayload: Equatable, Sendable {
    public let notificationId: String
    public let title: String?
    public let body: String?
    public let level: String
    public let chatId: String?

    public static let levelInfo = "info"
    public static let levelWarning = "warning"
    public static let levelError = "error"
    public static let levels: Set<String> = [levelInfo, levelWarning, levelError]
    public static let maxTitleChars = 128
    public static let maxBodyChars = 256
    public static let maxChatIdChars = 128
    static let notificationIdPattern = "^[A-Za-z0-9._:-]{8,128}$"
}

public enum PushPayloadResult: Equatable, Sendable {
    case decoded(PushPayload)
    case malformed(String)
}

public enum PushEffect: Equatable, Sendable {
    case requestToken(reason: String)
    case enrollDestination(deviceId: String, platform: String, token: String, label: String?, tokenGeneration: Int)
    case acknowledge(deviceId: String, notificationId: String)
    case cancelPresented([String])
}

public enum PushRegistrationState: Equatable, Sendable {
    case idle
    case requestingToken
    case enrolling
    case registered(tokenFingerprint: String, tokenGeneration: Int)
    case failedRetryable(code: String, attempts: Int)
    case failedPermanent(code: String)
}

public enum PushMessageReceipt: Equatable, Sendable {
    case accepted(payload: PushPayload, effects: [PushEffect], presentedAsSystemNotification: Bool)
    case duplicate(String)
    case malformed(String)
    case notPermitted
    case unsupported
}

public func decodePushPayload(_ data: [String: String]) -> PushPayloadResult {
    guard let notificationId = trimmed(data["notification_id"]) else {
        return .malformed("notification_id")
    }
    guard notificationId.range(of: PushPayload.notificationIdPattern, options: .regularExpression) != nil else {
        return .malformed("notification_id")
    }
    let title = trimmed(data["title"])
    let body = trimmed(data["body"])
    if (title ?? "").isEmpty && (body ?? "").isEmpty {
        return .malformed("notification_text")
    }
    if let title, title.count > PushPayload.maxTitleChars || containsControlCharacter(title) {
        return .malformed("title")
    }
    if let body, body.count > PushPayload.maxBodyChars || containsControlCharacter(body) {
        return .malformed("body")
    }
    let level = trimmed(data["level"]) ?? PushPayload.levelInfo
    guard PushPayload.levels.contains(level) else {
        return .malformed("level")
    }
    if let chatId = trimmed(data["chat_id"]),
        chatId.count > PushPayload.maxChatIdChars || containsControlCharacter(chatId)
    {
        return .malformed("chat_id")
    }
    return .decoded(
        PushPayload(notificationId: notificationId, title: title, body: body, level: level, chatId: chatId))
}

public func pushTokenFingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
}

private func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

public final class PushDestinationMachine {
    public private(set) var lifecycle: PushLifecycle = .terminated
    public private(set) var permission: PushPermissionState = .notDetermined
    public private(set) var availability: ProviderAvailability = .unknown
    public private(set) var registration: PushRegistrationState = .idle
    public private(set) var unsupportedReason: String?
    public private(set) var accepted: [String] = []

    private let identity: PushIdentity
    private let acceptedCapacity: Int
    private var currentToken: String?
    private var currentFingerprint: String?
    private var currentGeneration = 0
    private var retryableAttempts = 0

    public init(identity: PushIdentity, acceptedCapacity: Int = 64) {
        precondition(acceptedCapacity > 0, "accepted_capacity")
        self.identity = identity
        self.acceptedCapacity = acceptedCapacity
    }

    public var platform: String { "ios" }

    public var deviceUnsupported: Bool { availability == .unsupported }

    public func seedAccepted(_ ids: some Collection<String>) {
        for id in ids where !id.isEmpty {
            remember(id)
        }
    }

    public func onLifecycle(_ phase: PushLifecycle) {
        lifecycle = phase
    }

    public func onPermissionReport(granted: Bool, notificationsAuthorized: Bool) -> [PushEffect] {
        let previous = permission
        if granted && notificationsAuthorized {
            permission = .granted
        } else if granted && !notificationsAuthorized {
            permission = .revoked
        } else if previous == .granted || previous == .revoked {
            permission = .revoked
        } else {
            permission = .denied
        }
        if previous == .granted && permission == .revoked {
            let cancelled = accepted
            accepted = []
            return [.cancelPresented(cancelled)]
        }
        if permission == .granted {
            return bootstrapEffects()
        }
        return []
    }

    public func onAvailability(supported: Bool, reason: String? = nil) -> [PushEffect] {
        availability = supported ? .supported : .unsupported
        if !supported {
            registration = .idle
            unsupportedReason = reason ?? Self.reasonProviderUnavailable
            currentToken = nil
            currentFingerprint = nil
            currentGeneration = 0
            return []
        }
        unsupportedReason = nil
        return bootstrapEffects()
    }

    public func onDeviceToken(_ token: String?) -> [PushEffect] {
        if deviceUnsupported || permission != .granted { return [] }
        guard let token else {
            switch registration {
            case .requestingToken, .enrolling, .registered:
                retryableAttempts += 1
                registration = .failedRetryable(code: Self.codeTokenUnavailable, attempts: retryableAttempts)
                currentToken = nil
                currentFingerprint = nil
                currentGeneration = 0
            default:
                break
            }
            return []
        }
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.count > Self.maxTokenChars || containsControlCharacter(normalized) {
            registration = .failedPermanent(code: Self.codeTokenInvalid)
            return []
        }
        let fingerprint = pushTokenFingerprint(normalized)
        if fingerprint == currentFingerprint {
            registration = .registered(tokenFingerprint: fingerprint, tokenGeneration: currentGeneration)
            retryableAttempts = 0
            return []
        }
        currentToken = normalized
        currentFingerprint = fingerprint
        currentGeneration += 1
        registration = .enrolling
        return [enrollEffect(normalized)]
    }

    public func onTokenRequestFailed(transient: Bool, code: String) -> [PushEffect] {
        guard registration == .requestingToken else { return [] }
        if transient {
            retryableAttempts += 1
            registration = .failedRetryable(code: code, attempts: retryableAttempts)
        } else {
            registration = .failedPermanent(code: code)
        }
        return []
    }

    public func onEnrollmentAccepted() -> [PushEffect] {
        guard registration == .enrolling, let fingerprint = currentFingerprint else { return [] }
        registration = .registered(tokenFingerprint: fingerprint, tokenGeneration: currentGeneration)
        retryableAttempts = 0
        return []
    }

    public func onEnrollmentRejected(transient: Bool, code: String) -> [PushEffect] {
        guard registration == .enrolling else { return [] }
        if transient {
            retryableAttempts += 1
            registration = .failedRetryable(code: code, attempts: retryableAttempts)
        } else {
            registration = .failedPermanent(code: code)
        }
        return []
    }

    public func retryRegistration() -> [PushEffect] {
        if deviceUnsupported || permission != .granted { return [] }
        switch registration {
        case .failedRetryable:
            if let token = currentToken {
                registration = .enrolling
                return [enrollEffect(token)]
            }
            registration = .requestingToken
            return [.requestToken(reason: Self.reasonRetry)]
        case .idle:
            return bootstrapEffects()
        default:
            return []
        }
    }

    public func onForegroundDelivery(_ data: [String: String]) -> PushMessageReceipt {
        receipt(for: data, systemPresents: false)
    }

    public func onSystemDelivery(_ data: [String: String]) -> PushMessageReceipt {
        receipt(for: data, systemPresents: true)
    }

    public func onDismissed(_ notificationId: String) -> Bool {
        guard let index = accepted.firstIndex(of: notificationId) else { return false }
        accepted.remove(at: index)
        return true
    }

    private func receipt(for data: [String: String], systemPresents: Bool) -> PushMessageReceipt {
        if deviceUnsupported { return .unsupported }
        let decoded = decodePushPayload(data)
        guard case .decoded(let payload) = decoded else {
            if case .malformed(let reason) = decoded { return .malformed(reason) }
            return .malformed("notification_id")
        }
        if accepted.contains(payload.notificationId) {
            return .duplicate(payload.notificationId)
        }
        if lifecycle == .foreground && !systemPresents {
            remember(payload.notificationId)
            return .accepted(
                payload: payload,
                effects: [.acknowledge(deviceId: identity.deviceId, notificationId: payload.notificationId)],
                presentedAsSystemNotification: false)
        }
        if permission == .granted {
            remember(payload.notificationId)
            return .accepted(
                payload: payload,
                effects: [.acknowledge(deviceId: identity.deviceId, notificationId: payload.notificationId)],
                presentedAsSystemNotification: systemPresents)
        }
        return .notPermitted
    }

    private func enrollEffect(_ token: String) -> PushEffect {
        .enrollDestination(
            deviceId: identity.deviceId,
            platform: platform,
            token: token,
            label: identity.label,
            tokenGeneration: currentGeneration)
    }

    private func bootstrapEffects() -> [PushEffect] {
        guard permission == .granted, availability == .supported, registration == .idle else { return [] }
        registration = .requestingToken
        return [.requestToken(reason: Self.reasonBootstrap)]
    }

    private func remember(_ notificationId: String) {
        if !accepted.contains(notificationId) {
            accepted.append(notificationId)
        }
        while accepted.count > acceptedCapacity {
            accepted.removeFirst()
        }
    }

    static let maxTokenChars = 4096
    static let codeTokenUnavailable = "provider_token_unavailable"
    static let codeTokenInvalid = "token_invalid"
    static let reasonBootstrap = "bootstrap"
    static let reasonRetry = "retry"
    static let reasonProviderUnavailable = "provider_unavailable"
}
