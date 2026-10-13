// Validates owner safety controls for current-connection delivery without offline replay.
// Server authorization and durable stop state remain authoritative.

import Foundation

public struct SafetySurfaceRequest: Equatable, Sendable {
    public static let actions: Set<String> = ["chrome_safety_stop", "chrome_safety_resume", "chrome_safety_verify"]
    public let action: String
    public let payload: JSONValue

    public init?(action: String, payload: JSONValue) {
        guard let fields = payload.objectValue, fields["surface"]?.stringValue == "safety" else { return nil }
        switch action {
        case "chrome_open":
            guard Set(fields.keys) == ["surface", "params"], fields["params"] == .object([:]) else { return nil }
        case "chrome_close", "chrome_safety_stop", "chrome_safety_verify":
            guard Set(fields.keys) == ["surface"] else { return nil }
        case "chrome_safety_resume":
            guard Set(fields.keys) == ["surface", "expected_revision"],
                let supplied = fields["expected_revision"], case .number(let revision) = supplied, revision.isFinite,
                revision > 0, revision <= 9_007_199_254_740_991, revision.rounded(.down) == revision
            else { return nil }
        default: return nil
        }
        self.action = action
        self.payload = payload
    }

    public init?(frameText: String) {
        guard frameText.utf8.count <= 16_384, let replay = QueuedOperationReplay(frameText: frameText),
            let frame = InboundFrame.parse(frameText), frame.payload["session_id"] == .null,
            var fields = frame.payload["payload"]?.objectValue
        else { return nil }
        fields.removeValue(forKey: "submission_id")
        fields.removeValue(forKey: "request_generation")
        self.init(action: replay.action, payload: .object(fields))
    }

    public static func claimsCurrentConnectionSemantics(frameText: String) -> Bool {
        guard let frame = InboundFrame.parse(frameText), frame.name == "ui_event" else { return false }
        return actions.contains(frame.payload["action"]?.stringValue ?? "")
            || frame.payload["payload"]?["surface"]?.stringValue == "safety"
    }
}
