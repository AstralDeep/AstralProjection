// Validates console agent-introduction reads and closes before their current-connection transport.
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
            payload["surface"]?.stringValue == "agent_intro",
            Set(payload.keys)
                == Set(
                    ["surface", "submission_id", "request_generation"]
                        + (replay.action == "chrome_open" ? ["params"] : []))
        else { return nil }
        if replay.action == "chrome_open" {
            guard let params = payload["params"]?.objectValue, Set(params.keys) == ["agent_id"],
                let identity = ConsoleDecoding.text(params["agent_id"], maximum: 200)
            else { return nil }
            agentID = identity
        } else {
            agentID = nil
        }
        action = replay.action
    }
}
