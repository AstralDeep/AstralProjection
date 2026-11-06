// Decoders and builders for the plan_interaction_v1 presentation contract: the rote_config capability
// acknowledgement, the plan_mode_state/plan_proposal/plan_mode_notice/question_request/question_resolved
// server frames, and the plan_mode_set/plan_approve/plan_approve_review/plan_revise/question_submit/
// question_skip owner actions with their stable client_message_id.

import Foundation

private func planUUID(_ value: JSONValue?) -> String? {
    continuityUUID4(value?.stringValue)
}

private func planUnsignedInteger(_ value: JSONValue?) -> Int? {
    guard let number = value?.numberValue, number.isFinite, number >= 0,
        number.rounded() == number, number <= 9_007_199_254_740_991, number <= Double(Int.max)
    else { return nil }
    return Int(number)
}

private func planExactKeys(_ object: [String: JSONValue], _ keys: Set<String>) -> Bool {
    Set(object.keys) == keys
}

private func planBoundedText(_ value: JSONValue?, limit: Int) -> String? {
    guard let text = value?.stringValue, !text.isEmpty, text.count <= limit else { return nil }
    return text
}

private func planBoundedList(_ value: JSONValue?, capacity: Int, minimum: Int = 0) -> [String]? {
    guard let raw = value?.arrayValue, raw.count >= minimum, raw.count <= capacity else { return nil }
    var items: [String] = []
    items.reserveCapacity(raw.count)
    for entry in raw {
        guard let text = planBoundedText(entry, limit: 20_000) else { return nil }
        items.append(text)
    }
    return items
}

public struct PlanInteractionAcknowledgement: Sendable, Equatable {
    public static func fromRoteConfig(_ payload: JSONValue) -> PlanInteractionAcknowledgement? {
        PlanInteractionAcknowledgement(json: payload["device_profile"]?["console"]?["plan_interaction"])
    }

    public init?(json: JSONValue?) {
        guard let object = json?.objectValue,
            planExactKeys(object, ["version"]),
            object["version"] == .number(1)
        else { return nil }
    }
}

public struct PlanModeState: Sendable, Equatable {
    public enum Mode: String, Sendable {
        case plan
        case execute
    }

    public enum Status: String, Sendable {
        case none
        case proposed
        case approved
    }

    public enum Review: String, Sendable {
        case auto
        case manual
    }

    public static let maximumVersion = 9_007_199_254_740_991

    public let chatId: String?
    public let mode: Mode
    public let status: Status
    public let planVersion: Int?
    public let review: Review

    public init?(frame: InboundFrame) {
        guard frame.name == "plan_mode_state",
            let object = frame.payload.objectValue,
            planExactKeys(object, ["type", "chat_id", "mode", "plan_status", "plan_version", "review"]),
            object["type"] == .string("plan_mode_state"),
            let rawMode = object["mode"]?.stringValue,
            let mode = Mode(rawValue: rawMode),
            let rawStatus = object["plan_status"]?.stringValue,
            let status = Status(rawValue: rawStatus),
            let rawReview = object["review"]?.stringValue,
            let review = Review(rawValue: rawReview)
        else { return nil }
        var version: Int?
        if object["plan_version"] != .null {
            guard let decoded = planUnsignedInteger(object["plan_version"]), decoded > 0,
                decoded <= Self.maximumVersion
            else { return nil }
            version = decoded
        }
        self.chatId = planUUID(object["chat_id"])
        self.mode = mode
        self.status = status
        self.planVersion = version
        self.review = review
    }
}

public struct PlanProposal: Sendable, Equatable {
    public static let maximumSteps = 50
    public static let maximumAssumptions = 50
    public static let maximumFiles = 100
    public static let maximumApps = 50

    public let chatId: String?
    public let planId: String
    public let version: Int
    public let steps: [String]
    public let assumptions: [String]
    public let files: [String]
    public let apps: [String]

    public init?(frame: InboundFrame) {
        guard frame.name == "plan_proposal",
            let object = frame.payload.objectValue,
            planExactKeys(object, ["type", "chat_id", "plan_id", "version", "steps", "assumptions", "files", "apps"]),
            object["type"] == .string("plan_proposal"),
            let planId = planUUID(object["plan_id"]),
            let version = planUnsignedInteger(object["version"]), version > 0,
            let steps = planBoundedList(object["steps"], capacity: Self.maximumSteps, minimum: 1),
            let assumptions = planBoundedList(object["assumptions"], capacity: Self.maximumAssumptions),
            let files = planBoundedList(object["files"], capacity: Self.maximumFiles),
            let apps = planBoundedList(object["apps"], capacity: Self.maximumApps)
        else { return nil }
        self.chatId = planUUID(object["chat_id"])
        self.planId = planId
        self.version = version
        self.steps = steps
        self.assumptions = assumptions
        self.files = files
        self.apps = apps
    }
}

public struct PlanModeNotice: Sendable, Equatable {
    public enum Code: String, Sendable {
        case planModeActive = "plan_mode_active"
        case planNotApproved = "plan_not_approved"
        case planStale = "plan_stale"
        case invalidInput = "invalid_input"
    }

    public let chatId: String?
    public let code: Code
    public let message: String

    public init?(frame: InboundFrame) {
        guard frame.name == "plan_mode_notice",
            let object = frame.payload.objectValue,
            planExactKeys(object, ["type", "chat_id", "code", "message"]),
            object["type"] == .string("plan_mode_notice"),
            let rawCode = object["code"]?.stringValue,
            let code = Code(rawValue: rawCode),
            let message = planBoundedText(object["message"], limit: 2_000)
        else { return nil }
        self.chatId = planUUID(object["chat_id"])
        self.code = code
        self.message = message
    }
}

public struct QuestionPrompt: Sendable, Equatable, Identifiable {
    public static let maximumPrompts = 3
    public static let maximumOptions = 8

    public let id: String
    public let prompt: String
    public let options: [String]

    public init?(json: JSONValue) {
        guard let object = json.objectValue,
            planExactKeys(object, ["id", "prompt", "options"]),
            let id = planUUID(object["id"]),
            let prompt = planBoundedText(object["prompt"], limit: 500),
            let options = planBoundedList(object["options"], capacity: Self.maximumOptions)
        else { return nil }
        for option in options where option.count > 200 { return nil }
        self.id = id
        self.prompt = prompt
        self.options = options
    }
}

public struct QuestionRequest: Sendable, Equatable {
    public static let minimumTimeoutMs = 1_000
    public static let maximumTimeoutMs = 600_000

    public let chatId: String?
    public let questionId: String
    public let prompts: [QuestionPrompt]
    public let timeoutMs: Int

    public init?(frame: InboundFrame) {
        guard frame.name == "question_request",
            let object = frame.payload.objectValue,
            planExactKeys(object, ["type", "chat_id", "question_id", "questions", "timeout_ms"]),
            object["type"] == .string("question_request"),
            let questionId = planUUID(object["question_id"]),
            let rawPrompts = object["questions"]?.arrayValue,
            rawPrompts.count >= 1, rawPrompts.count <= QuestionPrompt.maximumPrompts,
            let timeoutMs = planUnsignedInteger(object["timeout_ms"]),
            timeoutMs >= Self.minimumTimeoutMs, timeoutMs <= Self.maximumTimeoutMs
        else { return nil }
        let prompts = rawPrompts.compactMap(QuestionPrompt.init(json:))
        guard prompts.count == rawPrompts.count else { return nil }
        self.chatId = planUUID(object["chat_id"])
        self.questionId = questionId
        self.prompts = prompts
        self.timeoutMs = timeoutMs
    }
}

public struct QuestionResolution: Sendable, Equatable {
    public enum Disposition: String, Sendable {
        case answered
        case skipped
        case timedOut = "timed_out"
        case superseded
    }

    public let chatId: String?
    public let questionId: String
    public let disposition: Disposition

    public init?(frame: InboundFrame) {
        guard frame.name == "question_resolved",
            let object = frame.payload.objectValue,
            planExactKeys(object, ["type", "chat_id", "question_id", "disposition"]),
            object["type"] == .string("question_resolved"),
            let questionId = planUUID(object["question_id"]),
            let rawDisposition = object["disposition"]?.stringValue,
            let disposition = Disposition(rawValue: rawDisposition)
        else { return nil }
        self.chatId = planUUID(object["chat_id"])
        self.questionId = questionId
        self.disposition = disposition
    }
}

public enum PlanInteractionOutbound {
    static let maximumAnswerScalars = 2_000

    static func ownerText(_ text: String, limit: Int = 20_000) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit else { return nil }
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

    static func planAction(
        _ decision: String, planId: String, version: Int, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard continuityUUID4(planId) != nil, version > 0 else { return nil }
        return action(
            decision,
            ["plan_id": .string(planId), "version": .number(Double(version))],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func planModeSet(
        enabled: Bool, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String {
        action(
            "plan_mode_set", ["enabled": .bool(enabled)], sessionId: sessionId,
            submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func planApprove(
        planId: String, version: Int, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        planAction(
            "plan_approve", planId: planId, version: version, sessionId: sessionId,
            submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func planApproveReview(
        planId: String, version: Int, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        planAction(
            "plan_approve_review", planId: planId, version: version, sessionId: sessionId,
            submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func planRevise(
        planId: String, version: Int, feedback: String, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard let text = ownerText(feedback) else { return nil }
        guard continuityUUID4(planId) != nil, version > 0 else { return nil }
        return action(
            "plan_revise",
            [
                "plan_id": .string(planId), "version": .number(Double(version)),
                "feedback": .string(text),
            ],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func questionSubmit(
        questionId: String, answers: [String: String], sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard continuityUUID4(questionId) != nil, !answers.isEmpty else { return nil }
        var payload: [String: JSONValue] = [:]
        for (id, rawAnswer) in answers {
            guard let id = continuityUUID4(id), let answer = ownerText(rawAnswer, limit: maximumAnswerScalars)
            else { return nil }
            payload[id] = .string(answer)
        }
        return action(
            "question_submit",
            ["question_id": .string(questionId), "answers": .object(payload)],
            sessionId: sessionId, submissionId: submissionId, requestGeneration: requestGeneration)
    }

    public static func questionSkip(
        questionId: String, sessionId: String?,
        submissionId: String = UUID().uuidString.lowercased(),
        requestGeneration: String = UUID().uuidString.lowercased()
    ) -> String? {
        guard continuityUUID4(questionId) != nil else { return nil }
        return action(
            "question_skip", ["question_id": .string(questionId)], sessionId: sessionId,
            submissionId: submissionId, requestGeneration: requestGeneration)
    }
}
