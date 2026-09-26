// Validates current-connection viewport hydration requests and their correlated failures.
// Native models use this read-only request to refresh ROTE layouts without replaying a chat turn.

import Foundation

public struct ViewportSnapshotRequest: Sendable, Equatable {
    public let frameText: String
    public let chatId: String
    public let connectionGeneration: String
    public let requestGeneration: String
    public let submissionId: String
    public let baseRenderRevision: UInt64

    public init?(
        device: DeviceDescriptor, snapshot: ConversationSnapshot,
        identity: ClientOperationIdentity = .fresh()
    ) {
        let connection = snapshot.connectionGeneration
        let payload: JSONValue = .object([
            "device": device.json, "chat_id": .string(snapshot.chatId),
            "base_render_revision": .number(Double(snapshot.renderRevision)),
            "connection_generation": .string(connection),
        ])
        let text = Outbound.uiEvent(
            action: "update_device", sessionId: nil, payload: payload,
            submissionId: identity.submissionId, requestGeneration: identity.requestGeneration,
            snapshotPurpose: .hydration)
        guard var json = (try? JSONValue.parse(Data(text.utf8)))?.objectValue else { return nil }
        json["connection_generation"] = .string(connection)
        self.init(frameText: Outbound.encode(.object(json)))
    }

    public init?(frameText: String) {
        guard let root = (try? JSONValue.parse(Data(frameText.utf8)))?.objectValue,
            root["type"]?.stringValue == "ui_event", root["action"]?.stringValue == "update_device",
            let payload = root["payload"]?.objectValue,
            payload["snapshot_purpose"]?.stringValue == "hydration",
            payload["device"]?.objectValue != nil,
            let chat = continuityUUID4(payload["chat_id"]?.stringValue),
            let connection = continuityUUID4(payload["connection_generation"]?.stringValue),
            root["connection_generation"]?.stringValue == connection,
            let request = continuityUUID4(payload["request_generation"]?.stringValue),
            root["request_generation"]?.stringValue == request,
            let submission = continuityUUID4(payload["submission_id"]?.stringValue),
            root["submission_id"]?.stringValue == submission,
            let revision = payload["base_render_revision"]?.numberValue,
            revision.isFinite, revision >= 0, revision.rounded() == revision,
            revision <= 9_007_199_254_740_991
        else { return nil }
        self.frameText = frameText
        chatId = chat
        connectionGeneration = connection
        requestGeneration = request
        submissionId = submission
        baseRenderRevision = UInt64(revision)
    }

    public static func claimsCurrentConnectionSemantics(frameText: String) -> Bool {
        guard let root = try? JSONValue.parse(Data(frameText.utf8)),
            root["action"]?.stringValue == "update_device"
        else { return false }
        return ["snapshot_purpose", "chat_id", "base_render_revision", "connection_generation"]
            .contains { root["payload"]?[$0] != nil }
            || root["connection_generation"] != nil || root["snapshot_purpose"] != nil
    }

    public func matches(_ snapshot: ConversationSnapshot) -> Bool {
        snapshot.chatId == chatId && snapshot.connectionGeneration == connectionGeneration
            && snapshot.requestGeneration == requestGeneration && snapshot.snapshotPurpose == "hydration"
            && snapshot.renderRevision == baseRenderRevision
    }

    public func isCurrent(in continuity: ConversationContinuityReducer) -> Bool {
        continuity.activeChatId == chatId && continuity.connectionGeneration == connectionGeneration
            && continuity.requestGeneration == requestGeneration && continuity.requestPurpose == .hydration
            && continuity.acceptedSnapshot == nil && continuity.lastCommittedRenderRevision == baseRenderRevision
    }

    public func matchesFailure(_ frame: InboundFrame) -> Bool {
        frame.name == "error"
            && ["viewport_snapshot_rejected", "viewport_snapshot_retryable"].contains(
                frame.payload["code"]?.stringValue ?? "")
            && frame.payload["chat_id"]?.stringValue == chatId
            && frame.payload["connection_generation"]?.stringValue == connectionGeneration
            && frame.payload["request_generation"]?.stringValue == requestGeneration
    }
}
