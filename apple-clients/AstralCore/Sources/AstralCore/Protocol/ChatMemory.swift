// Decoders and builders for the chat_memory_v1 presentation contract: the rote_config capability
// acknowledgement, the chat_memory_state/memory_change_recorded/memory_change_refused server frames,
// and the chat_memory_use/learn/forget/undo/decide client actions. AppModel consumes these to gate
// the per-chat memory switches and Learned chips on the server advertisement.

import Foundation

private func chatMemoryUUID(_ value: JSONValue?) -> String? {
    continuityUUID4(value?.stringValue)
}

private func chatMemoryUnsignedInteger(_ value: JSONValue?) -> Int? {
    guard let number = value?.numberValue, number.isFinite, number >= 0,
        number.rounded() == number, number <= 9_007_199_254_740_991, number <= Double(Int.max)
    else { return nil }
    return Int(number)
}

private func chatMemoryExactKeys(_ object: [String: JSONValue], _ keys: Set<String>) -> Bool {
    Set(object.keys) == keys
}

public struct ChatMemoryAcknowledgement: Sendable, Equatable {
    public static func fromRoteConfig(_ payload: JSONValue) -> ChatMemoryAcknowledgement? {
        ChatMemoryAcknowledgement(json: payload["device_profile"]?["console"]?["chat_memory"])
    }

    public init?(json: JSONValue?) {
        guard let object = json?.objectValue,
            chatMemoryExactKeys(object, ["version"]),
            object["version"] == .number(1)
        else { return nil }
    }
}

public struct ChatMemoryState: Sendable, Equatable {
    public static let maximumPending = 99

    public let chatId: String
    public let useMemory: Bool
    public let learnFromChat: Bool
    public let pending: Int

    public init?(frame: InboundFrame) {
        guard frame.name == "chat_memory_state",
            let object = frame.payload.objectValue,
            chatMemoryExactKeys(object, ["type", "chat_id", "use", "learn", "pending"]),
            object["type"] == .string("chat_memory_state"),
            let chatId = chatMemoryUUID(object["chat_id"]),
            let useMemory = object["use"]?.boolValue,
            let learnFromChat = object["learn"]?.boolValue,
            let pending = chatMemoryUnsignedInteger(object["pending"]),
            pending <= Self.maximumPending
        else { return nil }
        self.chatId = chatId
        self.useMemory = useMemory
        self.learnFromChat = learnFromChat
        self.pending = pending
    }
}

public struct MemoryChange: Sendable, Equatable {
    public static let maximumSummaryScalars = 512

    public enum State: String, Sendable {
        case applied
        case staged
    }

    public let changeId: String
    public let state: State
    public let summary: String
    public let revision: Int

    public init?(json: JSONValue?) {
        guard let object = json?.objectValue,
            chatMemoryExactKeys(object, ["change_id", "state", "summary", "revision"]),
            let changeId = chatMemoryUUID(object["change_id"]),
            let rawState = object["state"]?.stringValue,
            let state = State(rawValue: rawState),
            let summary = object["summary"]?.stringValue,
            !summary.isEmpty, summary.count <= Self.maximumSummaryScalars,
            let revision = chatMemoryUnsignedInteger(object["revision"]), revision > 0
        else { return nil }
        self.changeId = changeId
        self.state = state
        self.summary = summary
        self.revision = revision
    }
}

public struct MemoryChangeRecorded: Sendable, Equatable {
    public let chatId: String
    public let messageId: String
    public let change: MemoryChange

    public init?(frame: InboundFrame) {
        guard frame.name == "memory_change_recorded",
            let object = frame.payload.objectValue,
            chatMemoryExactKeys(object, ["type", "chat_id", "message_id", "change"]),
            object["type"] == .string("memory_change_recorded"),
            let chatId = chatMemoryUUID(object["chat_id"]),
            let messageId = chatMemoryUUID(object["message_id"]),
            let change = MemoryChange(json: object["change"])
        else { return nil }
        self.chatId = chatId
        self.messageId = messageId
        self.change = change
    }
}

public struct MemoryChangeRefused: Sendable, Equatable {
    public enum Code: String, Sendable {
        case staleRevision = "stale_revision"
        case notFound = "not_found"
        case phiProtected = "phi_protected"
        case unavailable
    }

    public let chatId: String
    public let changeId: String?
    public let code: Code
    public let message: String

    public init?(frame: InboundFrame) {
        guard frame.name == "memory_change_refused",
            let object = frame.payload.objectValue,
            Set(object.keys).isSuperset(of: ["type", "chat_id", "code", "message"]),
            Set(object.keys).isSubset(of: ["type", "chat_id", "change_id", "code", "message"]),
            object["type"] == .string("memory_change_refused"),
            let chatId = chatMemoryUUID(object["chat_id"]),
            let rawCode = object["code"]?.stringValue,
            let code = Code(rawValue: rawCode),
            let message = object["message"]?.stringValue, !message.isEmpty
        else { return nil }
        if object["change_id"] != nil, chatMemoryUUID(object["change_id"]) == nil { return nil }
        self.chatId = chatId
        self.changeId = object["change_id"].flatMap { chatMemoryUUID($0) }
        self.code = code
        self.message = message
    }
}

public enum ChatMemoryOutbound {
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

    public static func chatMemoryUse(
        _ chatId: String, enabled: Bool, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard chatMemoryUUID(chatId) != nil else { return nil }
        return action(
            "chat_memory_use",
            ["chat_id": .string(chatId), "enabled": .bool(enabled)],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func chatMemoryLearn(
        _ chatId: String, enabled: Bool, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard chatMemoryUUID(chatId) != nil else { return nil }
        return action(
            "chat_memory_learn",
            ["chat_id": .string(chatId), "enabled": .bool(enabled)],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func chatMemoryForget(
        _ chatId: String, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard chatMemoryUUID(chatId) != nil else { return nil }
        return action(
            "chat_memory_forget", ["chat_id": .string(chatId)],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func chatMemoryUndo(
        _ chatId: String, changeId: String, expectedRevision: Int, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard chatMemoryUUID(chatId) != nil, chatMemoryUUID(changeId) != nil, expectedRevision > 0
        else { return nil }
        return action(
            "chat_memory_undo",
            [
                "chat_id": .string(chatId), "change_id": .string(changeId),
                "expected_revision": .number(Double(expectedRevision)),
            ],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func chatMemoryDecide(
        _ chatId: String, changeId: String, decisionApproves: Bool, expectedRevision: Int,
        sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard chatMemoryUUID(chatId) != nil, chatMemoryUUID(changeId) != nil, expectedRevision > 0
        else { return nil }
        return action(
            "chat_memory_decide",
            [
                "chat_id": .string(chatId), "change_id": .string(changeId),
                "decision": .string(decisionApproves ? "approve" : "reject"),
                "expected_revision": .number(Double(expectedRevision)),
            ],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }
}
