// Validates shared mesh management actions for current-connection owner transport.
// Local identity/redemption controls never become queued or server-dispatched UI events.

import Foundation

public struct MeshSurfaceRequest: Equatable, Sendable {
    public static let actions: Set<String> = [
        "chrome_mesh_create", "chrome_mesh_confirm", "chrome_mesh_reject",
        "chrome_mesh_rename", "chrome_mesh_revoke", "chrome_mesh_remove_invitation",
    ]
    public static let localActions: Set<String> = ["chrome_mesh_identity", "chrome_mesh_redeem"]
    public let action: String
    public let payload: JSONValue

    public init?(action: String, payload: JSONValue) {
        guard let body = payload.objectValue, body["surface"] == .string("mesh") else { return nil }
        switch action {
        case "chrome_open":
            guard Set(body.keys) == ["surface", "params"], body["params"] == .object([:]) else { return nil }
        case "chrome_close":
            guard Set(body.keys) == ["surface"] else { return nil }
        case "chrome_mesh_confirm", "chrome_mesh_reject", "chrome_mesh_remove_invitation":
            guard Set(body.keys) == ["surface", "invite_id"], Self.identity(body["invite_id"]) else { return nil }
        case "chrome_mesh_revoke":
            guard Set(body.keys) == ["surface", "member_id"], Self.identity(body["member_id"]) else { return nil }
        case "chrome_mesh_rename":
            guard Set(body.keys) == ["surface", "member_id", "fields"], Self.identity(body["member_id"]),
                let fields = body["fields"]?.objectValue, Set(fields.keys) == ["label"],
                Self.text(fields["label"], maximum: 256)
            else { return nil }
        case "chrome_mesh_create":
            guard Set(body.keys) == ["surface", "fields"], let fields = body["fields"]?.objectValue,
                Set(fields.keys) == ["label", "device_key", "scopes", "ttl_seconds"],
                Self.text(fields["label"], maximum: 256), Self.text(fields["scopes"], maximum: 256),
                Self.text(fields["ttl_seconds"], maximum: 16),
                let raw = fields["device_key"]?.stringValue, raw.utf8.count <= 2048,
                let key = try? JSONValue.parse(Data(raw.utf8)),
                (try? MeshEnrollmentCustody.validatePublicIdentity(key)) != nil
            else { return nil }
        default: return nil
        }
        self.action = action
        self.payload = payload
    }

    public init?(frameText: String) {
        guard frameText.utf8.count <= 16384, let replay = QueuedOperationReplay(frameText: frameText),
            let frame = InboundFrame.parse(frameText), frame.payload["session_id"] == .null,
            var fields = frame.payload["payload"]?.objectValue
        else { return nil }
        fields.removeValue(forKey: "submission_id")
        fields.removeValue(forKey: "request_generation")
        self.init(action: replay.action, payload: .object(fields))
    }

    public static func claimsCurrentConnectionSemantics(frameText: String) -> Bool {
        guard let frame = InboundFrame.parse(frameText), frame.name == "ui_event" else { return false }
        return frame.payload["action"]?.stringValue?.hasPrefix("chrome_mesh_") == true
            || frame.payload["payload"]?["surface"] == .string("mesh")
    }

    private static func identity(_ value: JSONValue?) -> Bool {
        value?.stringValue?.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
    }

    private static func text(_ value: JSONValue?, maximum: Int) -> Bool {
        value?.stringValue.map { !$0.isEmpty && $0.utf8.count <= maximum } == true
    }
}
