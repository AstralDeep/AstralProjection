// Decodes the server's computer autonomy-mode presence and auto-review verdicts for the Mac host, and builds
// the owner's mode and retry frames. Server state is authoritative; requests stay pending until confirmed.

import Foundation

public enum ComputerAutonomyMode: String, CaseIterable, Sendable, Equatable {
    case ask
    case autoReview = "auto_review"
    case bypass
}

public struct ComputerAutonomyState: Sendable, Equatable {
    public static let maximumSupported = 3
    public static let maximumBreakerReason = 300
    public let mode: ComputerAutonomyMode
    public let supported: [ComputerAutonomyMode]
    public let breakerOpen: Bool
    public let breakerReason: String?

    public init(mode: ComputerAutonomyMode, supported: [ComputerAutonomyMode]) throws {
        guard supported.contains(mode), !supported.isEmpty, supported.count <= Self.maximumSupported,
            Set(supported).count == supported.count
        else { throw ComputerHostError("out_of_range", "The autonomy mode state is invalid.") }
        self.mode = mode
        self.supported = supported
        breakerOpen = false
        breakerReason = nil
    }

    public init(json: JSONValue) throws {
        guard let object = json.objectValue, let rawMode = object["mode"]?.stringValue,
            let mode = ComputerAutonomyMode(rawValue: rawMode),
            let rawSupported = object["supported"]?.arrayValue, !rawSupported.isEmpty,
            rawSupported.count <= Self.maximumSupported
        else { throw ComputerHostError("out_of_range", "The autonomy mode state is invalid.") }
        var supported: [ComputerAutonomyMode] = []
        for value in rawSupported {
            guard let raw = value.stringValue, let decoded = ComputerAutonomyMode(rawValue: raw),
                !supported.contains(decoded)
            else { throw ComputerHostError("out_of_range", "The autonomy mode state is invalid.") }
            supported.append(decoded)
        }
        guard supported.contains(mode) else {
            throw ComputerHostError("out_of_range", "The autonomy mode state is invalid.")
        }
        self.mode = mode
        self.supported = supported
        if let breaker = object["breaker"] {
            guard let breakerObject = breaker.objectValue,
                breakerObject["open"]?.boolValue == true, mode == .ask,
                breakerObject["reason"]?.stringValue.map({
                    $0.unicodeScalars.count <= Self.maximumBreakerReason
                        && !$0.unicodeScalars.contains(where: { $0.value == 0 })
                }) ?? true,
                Set(breakerObject.keys).isSubset(of: ["open", "reason"])
            else { throw ComputerHostError("out_of_range", "The autonomy mode state is invalid.") }
            breakerOpen = true
            breakerReason = breakerObject["reason"]?.stringValue
        } else {
            breakerOpen = false
            breakerReason = nil
        }
    }

    public var offersAutoReview: Bool { supported.contains(.autoReview) }
    public var breakerTripped: Bool { breakerOpen }
}

public struct ComputerReviewVerdict: Sendable, Equatable {
    public static let maximumEventId = 200
    public static let maximumReason = 1000
    public static let eventPrefix = "review.auto."

    public enum Decision: String, Sendable { case allow, deny, escalate }

    public let eventId: String
    public let decision: Decision
    public let reason: String
    public let cardRaised: Bool

    public init?(json: JSONValue) {
        guard let object = json.objectValue, let eventId = object["event_id"]?.stringValue,
            eventId.hasPrefix(Self.eventPrefix), eventId.count > Self.eventPrefix.count,
            eventId.unicodeScalars.count <= Self.maximumEventId,
            !eventId.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            let rawDecision = object["decision"]?.stringValue, let decision = Decision(rawValue: rawDecision),
            let cardRaised = object["card_raised"]?.boolValue,
            decision == .escalate || !cardRaised
        else { return nil }
        let reason = object["reason"]?.stringValue ?? ""
        guard reason.unicodeScalars.count <= Self.maximumReason else { return nil }
        self.eventId = eventId
        self.decision = decision
        self.reason = reason
        self.cardRaised = cardRaised
    }

    public var blocked: Bool { decision == .deny && !cardRaised }
}

extension ComputerHostOutbound {
    public static func autonomyModeFrame(hostId: String, mode: ComputerAutonomyMode) -> String {
        frame(action: "chrome_computer_mode_set", payload: ["host_id": .string(hostId), "mode": .string(mode.rawValue)])
    }
}
