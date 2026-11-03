// Decoders and builders for the turn_steer_v1 presentation contract: the rote_config capability
// acknowledgement, the chat_steer/chat_queue/side_question client actions with their stable
// client_message_id, and the chat_steer_*/chat_queue_updated/side_question_result server frames.
// AppModel consumes these to gate mid-turn composer behavior on the server advertisement.

import Foundation

private func turnSteerUUID(_ value: JSONValue?) -> String? {
    continuityUUID4(value?.stringValue)
}

private func turnSteerUnsignedInteger(_ value: JSONValue?) -> Int? {
    guard let number = value?.numberValue, number.isFinite, number >= 0,
        number.rounded() == number, number <= 9_007_199_254_740_991, number <= Double(Int.max)
    else { return nil }
    return Int(number)
}

private func turnSteerExactKeys(_ object: [String: JSONValue], _ keys: Set<String>) -> Bool {
    Set(object.keys) == keys
}

public struct TurnSteerAcknowledgement: Sendable, Equatable {
    public let queueCapable: Bool

    public static func fromRoteConfig(_ payload: JSONValue) -> TurnSteerAcknowledgement? {
        TurnSteerAcknowledgement(json: payload["device_profile"]?["console"]?["turn_steer"])
    }
}

extension TurnSteerAcknowledgement {
    public init?(json: JSONValue?) {
        guard let object = json?.objectValue,
            turnSteerExactKeys(object, ["version", "queue_capable"]),
            object["version"] == .number(1),
            let queueCapable = object["queue_capable"]?.boolValue
        else { return nil }
        self.queueCapable = queueCapable
    }
}

public struct QueuedFollowUpItem: Sendable, Equatable, Identifiable {
    public static let maximumMessageScalars = 20_000
    public static let maximumItems = 16

    public let id: String
    public let message: String
    public let revision: Int

    public init?(json: JSONValue) {
        guard let object = json.objectValue,
            turnSteerExactKeys(object, ["queue_id", "message", "revision"]),
            let id = turnSteerUUID(object["queue_id"]),
            let message = object["message"]?.stringValue,
            !message.isEmpty, message.count <= Self.maximumMessageScalars,
            let revision = turnSteerUnsignedInteger(object["revision"]), revision > 0
        else { return nil }
        self.id = id
        self.message = message
        self.revision = revision
    }

    var json: JSONValue {
        .object([
            "queue_id": .string(id), "message": .string(message), "revision": .number(Double(revision)),
        ])
    }
}

public struct ChatQueueUpdated: Sendable, Equatable {
    public let chatId: String
    public let revision: Int
    public let items: [QueuedFollowUpItem]

    public init?(frame: InboundFrame) {
        guard frame.name == "chat_queue_updated",
            let object = frame.payload.objectValue,
            Set(object.keys).isSuperset(of: ["type", "chat_id", "revision", "items"]),
            Set(object.keys).isSubset(of: ["type", "chat_id", "revision", "items"]),
            object["type"] == .string("chat_queue_updated"),
            let chatId = turnSteerUUID(object["chat_id"]),
            let revision = turnSteerUnsignedInteger(object["revision"]), revision > 0,
            let rawItems = object["items"]?.arrayValue,
            rawItems.count <= QueuedFollowUpItem.maximumItems
        else { return nil }
        let items = rawItems.compactMap(QueuedFollowUpItem.init(json:))
        guard items.count == rawItems.count else { return nil }
        self.chatId = chatId
        self.revision = revision
        self.items = items
    }
}

public struct SkippedToolCall: Sendable, Equatable {
    public static let maximumSkippedCalls = 50

    public let name: String
    public let reason: String
}

extension SkippedToolCall {
    public init?(json: JSONValue) {
        guard let object = json.objectValue,
            turnSteerExactKeys(object, ["name", "reason"]),
            let name = object["name"]?.stringValue, !name.isEmpty,
            let reason = object["reason"]?.stringValue, !reason.isEmpty
        else { return nil }
        self.name = name
        self.reason = reason
    }
}

public struct ChatSteerRecorded: Sendable, Equatable {
    public let chatId: String?
    public let clientMessageId: String
    public let skippedCalls: [SkippedToolCall]

    public init?(frame: InboundFrame) {
        guard frame.name == "chat_steer_recorded",
            let object = frame.payload.objectValue,
            Set(object.keys).isSuperset(of: ["type", "client_message_id"]),
            Set(object.keys).isSubset(of: ["type", "chat_id", "client_message_id", "skipped_calls"]),
            object["type"] == .string("chat_steer_recorded"),
            let clientMessageId = turnSteerUUID(object["client_message_id"]),
            object["chat_id"] == nil || turnSteerUUID(object["chat_id"]) != nil
        else { return nil }
        let rawSkipped = object["skipped_calls"]?.arrayValue ?? []
        guard rawSkipped.count <= SkippedToolCall.maximumSkippedCalls else { return nil }
        let skipped = rawSkipped.compactMap(SkippedToolCall.init(json:))
        guard skipped.count == rawSkipped.count else { return nil }
        self.chatId = turnSteerUUID(object["chat_id"])
        self.clientMessageId = clientMessageId
        self.skippedCalls = skipped
    }
}

public struct ChatSteerRefused: Sendable, Equatable {
    public enum Code: String, Sendable {
        case staleTurn = "stale_turn"
        case notRunning = "not_running"
        case approvalPending = "approval_pending"
        case invalidInput = "invalid_input"
        case capacityExceeded = "capacity_exceeded"
    }

    public let clientMessageId: String
    public let code: Code
    public let message: String

    public init?(frame: InboundFrame) {
        guard frame.name == "chat_steer_refused",
            let object = frame.payload.objectValue,
            Set(object.keys).isSuperset(of: ["type", "client_message_id", "code", "message"]),
            Set(object.keys).isSubset(
                of: ["type", "chat_id", "client_message_id", "code", "message"]),
            object["type"] == .string("chat_steer_refused"),
            let clientMessageId = turnSteerUUID(object["client_message_id"]),
            let rawCode = object["code"]?.stringValue,
            let code = Code(rawValue: rawCode),
            let message = object["message"]?.stringValue, !message.isEmpty
        else { return nil }
        self.clientMessageId = clientMessageId
        self.code = code
        self.message = message
    }
}

public struct SideQuestionResult: Sendable, Equatable {
    public let clientMessageId: String
    public let answer: String

    public init?(frame: InboundFrame) {
        guard frame.name == "side_question_result",
            let object = frame.payload.objectValue,
            turnSteerExactKeys(object, ["type", "client_message_id", "answer"]),
            object["type"] == .string("side_question_result"),
            let clientMessageId = turnSteerUUID(object["client_message_id"]),
            let answer = object["answer"]?.stringValue, !answer.isEmpty
        else { return nil }
        self.clientMessageId = clientMessageId
        self.answer = answer
    }
}

public enum TurnSteerOutbound {
    static let maximumMessageScalars = 20_000

    static func ownerText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumMessageScalars else { return nil }
        return trimmed
    }

    static func action(
        _ action: String, _ fields: [String: JSONValue], sessionId: String?,
        submissionId: String, requestGeneration: String
    ) -> String {
        var payload = fields
        payload["client_message_id"] = .string(UUID().uuidString.lowercased())
        return Outbound.uiEvent(
            action: action, sessionId: sessionId, payload: .object(payload),
            submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func chatSteer(
        _ message: String, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard let text = ownerText(message) else { return nil }
        return action(
            "chat_steer", ["message": .string(text)], sessionId: sessionId,
            submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func chatQueuePut(
        _ message: String, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard let text = ownerText(message) else { return nil }
        return action(
            "chat_queue_put", ["message": .string(text)], sessionId: sessionId,
            submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func chatQueueEdit(
        _ message: String, queueId: String, expectedRevision: Int, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard let text = ownerText(message), continuityUUID4(queueId) != nil,
            expectedRevision > 0
        else { return nil }
        return action(
            "chat_queue_edit",
            [
                "queue_id": .string(queueId), "message": .string(text),
                "expected_revision": .number(Double(expectedRevision)),
            ],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func chatQueueRemove(
        queueId: String, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard continuityUUID4(queueId) != nil else { return nil }
        return action(
            "chat_queue_remove", ["queue_id": .string(queueId)], sessionId: sessionId,
            submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func chatQueueMove(
        queueId: String, beforeQueueId: String?, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard continuityUUID4(queueId) != nil,
            beforeQueueId == nil || continuityUUID4(beforeQueueId) != nil
        else { return nil }
        return action(
            "chat_queue_move",
            [
                "queue_id": .string(queueId),
                "before_queue_id": beforeQueueId.map(JSONValue.string) ?? .null,
            ],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func sideQuestion(
        _ question: String, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard let text = ownerText(question) else { return nil }
        return action(
            "side_question", ["question": .string(text)], sessionId: sessionId,
            submissionId: submissionId, requestGeneration: requestGeneration)
    }
}
