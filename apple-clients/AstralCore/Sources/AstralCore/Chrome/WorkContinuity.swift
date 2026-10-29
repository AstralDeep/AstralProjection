// Validates server-issued Work continuity commands and binds them to one current Apple connection request.
import Foundation

public struct WorkContinuityRequest: Equatable, Sendable {
    public static let action = "chrome_work_continuity"
    public let payload: JSONValue
    public let operationId: String
    public let submissionId: String

    public init?(payload: JSONValue) {
        guard let fields = payload.objectValue,
            Set(fields.keys) == ["version", "operation_id", "expected_revision", "submission_id"],
            fields["version"]?.numberValue == 1,
            let operation = continuityUUID4(fields["operation_id"]?.stringValue),
            let submission = continuityUUID4(fields["submission_id"]?.stringValue),
            let revision = fields["expected_revision"]?.numberValue,
            revision.isFinite, revision.rounded() == revision, revision >= 1, revision <= 9_007_199_254_740_991
        else { return nil }
        self.payload = payload
        operationId = operation
        submissionId = submission
    }

    public init?(component: AstralComponent) {
        guard component.type == "button", component.raw["action"]?.stringValue == Self.action,
            component.raw["local"]?.boolValue == false, component.raw["disabled"]?.boolValue == false,
            let payload = component.raw["payload"]
        else { return nil }
        self.init(payload: payload)
    }

    public init?(frameText: String) {
        guard let frame = InboundFrame.parse(frameText), let fields = frame.payload.objectValue,
            Set(fields.keys) == [
                "type", "action", "session_id", "payload", "submission_id", "request_generation",
                "connection_generation",
            ],
            frame.name == "ui_event", fields["action"]?.stringValue == Self.action,
            fields["session_id"] == .null, continuityUUID4(fields["request_generation"]?.stringValue) != nil,
            continuityUUID4(fields["connection_generation"]?.stringValue) != nil,
            let payload = fields["payload"]
        else { return nil }
        self.init(payload: payload)
        guard fields["submission_id"]?.stringValue == submissionId else { return nil }
    }

    public func frameText(requestGeneration: String, connectionGeneration: String) -> String {
        guard continuityUUID4(requestGeneration) != nil, continuityUUID4(connectionGeneration) != nil else {
            return "{}"
        }
        return Outbound.encode(
            .object([
                "type": .string("ui_event"), "action": .string(Self.action), "session_id": .null,
                "payload": payload, "submission_id": .string(submissionId),
                "request_generation": .string(requestGeneration),
                "connection_generation": .string(connectionGeneration),
            ]))
    }
}
