// Reads llm_usage_report frames into a bounded per-session tally of the model in use and its token counts.
// AppModel keeps the tally for the Mac status footer; the frame names no chat, so totals cover the signed-in session.

import Foundation

public struct LLMUsageReport: Equatable, Sendable {
    public static let maximumTokens = 100_000_000
    public let feature: String
    public let model: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let succeeded: Bool

    public init?(frame: InboundFrame) {
        guard frame.name == "llm_usage_report" else { return nil }
        let payload = frame.payload
        feature = Self.text(payload["feature"], maximum: 80) ?? ""
        model = Self.text(payload["model"], maximum: 200)
        promptTokens = Self.count(payload["prompt_tokens"])
        completionTokens = Self.count(payload["completion_tokens"])
        totalTokens = Self.count(payload["total_tokens"])
        succeeded = payload["outcome"]?.stringValue == "success"
    }

    public var tokens: Int? {
        if let totalTokens { return totalTokens }
        guard let promptTokens, let completionTokens else { return nil }
        return promptTokens + completionTokens
    }

    private static func count(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.isFinite, number >= 0, number <= Double(maximumTokens),
            number.rounded() == number
        else { return nil }
        return Int(number)
    }

    private static func text(_ value: JSONValue?, maximum: Int) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let kept = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= maximum else { return nil }
        return text
    }
}

public struct LLMUsageTally: Equatable, Sendable {
    public static let ceiling = 1_000_000_000
    public private(set) var model: String?
    public private(set) var contextTokens: Int?
    public private(set) var sessionTokens = 0

    public init() {}

    public var isEmpty: Bool { model == nil && sessionTokens == 0 && contextTokens == nil }

    public mutating func record(_ report: LLMUsageReport) {
        if let model = report.model { self.model = model }
        guard report.succeeded else { return }
        if let tokens = report.tokens { sessionTokens = min(sessionTokens + tokens, Self.ceiling) }
        if report.feature == "chat_dispatch", let prompt = report.promptTokens { contextTokens = prompt }
    }
}
