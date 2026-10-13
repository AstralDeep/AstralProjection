// Validates console agent-introduction and evidence reads and closes before their current-connection transport.
// Guidance and Work retain their independently closed request contracts and replay protection.

import Foundation

public struct ConsoleSurfaceRequest: Equatable, Sendable {
    public let action: String
    public let agentID: String?

    public init?(frameText: String) {
        guard frameText.utf8.count <= 16_384,
            let replay = QueuedOperationReplay(frameText: frameText),
            ["chrome_open", "chrome_close"].contains(replay.action),
            let frame = InboundFrame.parse(frameText), frame.payload["session_id"] == .null,
            let payload = frame.payload["payload"]?.objectValue,
            let surface = payload["surface"]?.stringValue, ["agent_intro", "evidence"].contains(surface),
            Set(payload.keys)
                == Set(
                    ["surface", "submission_id", "request_generation"]
                        + (replay.action == "chrome_open" ? ["params"] : []))
        else { return nil }
        if replay.action == "chrome_open" && surface == "agent_intro" {
            guard let params = payload["params"]?.objectValue, Set(params.keys) == ["agent_id"],
                let identity = ConsoleDecoding.text(params["agent_id"], maximum: 200)
            else { return nil }
            agentID = identity
        } else if replay.action == "chrome_open" {
            guard let params = payload["params"]?.objectValue, Self.validEvidenceParams(params) else { return nil }
            agentID = nil
        } else {
            agentID = nil
        }
        action = replay.action
    }

    public static func claimsCurrentConnectionSemantics(frameText: String) -> Bool {
        guard let frame = InboundFrame.parse(frameText), frame.name == "ui_event" else { return false }
        return frame.payload["payload"]?["surface"]?.stringValue == "evidence"
    }

    private static func validEvidenceParams(_ params: [String: JSONValue]) -> Bool {
        if params.isEmpty || params == ["kind": .string("usage")] { return true }
        if Set(params.keys) == ["view_id"] {
            return params["view_id"]?.stringValue?.range(of: "^view_[A-Za-z0-9_-]{43}\\z", options: .regularExpression)
                != nil
        }
        guard Set(params.keys).isSubset(of: ["kind", "reference", "offset"]),
            ["source", "preview"].contains(params["kind"]?.stringValue ?? ""),
            params["reference"]?.stringValue?.range(of: "^obs_[A-Za-z0-9_-]{43}\\z", options: .regularExpression) != nil
        else { return false }
        if let supplied = params["offset"] {
            guard case .number(let value) = supplied, value.isFinite,
                value >= 0, value <= 8_388_608, value.rounded(.down) == value
            else { return false }
        }
        return true
    }
}
