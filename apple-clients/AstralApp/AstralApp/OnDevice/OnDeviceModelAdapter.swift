// Defines the host-side on-device model interface the Rust kernel calls and implements it with Apple's Foundation Models framework.
// It serves the quarantined reader, the voice fast path and the offline fallback, and it never stands in for the owner's chosen model.

import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

nonisolated struct OnDeviceMessage: Equatable, Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let text: String
}

nonisolated struct OnDeviceRequest: Equatable, Sendable {
    let messages: [OnDeviceMessage]
    let schemaJSON: String?
    let maxTokens: Int
}

nonisolated enum OnDeviceUnavailableReason: String, Equatable, Sendable {
    case osVersionTooOld = "os_version_too_old"
    case deviceNotEligible = "device_not_eligible"
    case appleIntelligenceDisabled = "apple_intelligence_disabled"
    case modelNotReady = "model_not_ready"
    case unknown = "unavailable_unknown"
}

nonisolated enum OnDeviceFailure: String, Equatable, Sendable {
    case emptyRequest = "empty_request"
    case schemaUnsupported = "schema_unsupported"
    case outputMismatchedSchema = "output_mismatched_schema"
    case contextTooLarge = "context_too_large"
    case busy = "busy"
    case cancelled = "cancelled"
    case generationFailed = "generation_failed"
}

nonisolated enum OnDeviceResponse: Equatable, Sendable {
    case text(String)
    case json(String)
    case refused(String)
    case unavailable(OnDeviceUnavailableReason)
    case failed(OnDeviceFailure)
}

nonisolated enum OnDeviceModelAvailability: Equatable, Sendable {
    case available
    case unavailable(OnDeviceUnavailableReason)
}

nonisolated protocol AstralOnDeviceModel: Sendable {
    func available() -> Bool
    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse
}

nonisolated protocol AstralOnDeviceModelWarmable: AstralOnDeviceModel {
    func prewarm() async
}

nonisolated enum OnDevicePromptComposer {
    struct Composed: Equatable {
        let instructions: String?
        let prompt: String
    }

    static func compose(_ messages: [OnDeviceMessage]) -> Composed? {
        let system = messages.filter { $0.role == .system }.map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let conversation = messages.filter { $0.role != .system }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let last = conversation.last, last.role == .user else { return nil }
        let instructions = system.isEmpty ? nil : system.joined(separator: "\n\n")
        if conversation.count == 1 { return Composed(instructions: instructions, prompt: last.text) }
        let history = conversation.dropLast().map { "[\($0.role.rawValue)] \($0.text)" }
        let prompt =
            "Conversation so far:\n" + history.joined(separator: "\n")
            + "\n\nLatest message from the user:\n" + last.text
        return Composed(instructions: instructions, prompt: prompt)
    }
}

nonisolated final class FoundationModelsOnDeviceModel: AstralOnDeviceModelWarmable {
    init() {}

    func availability() -> OnDeviceModelAvailability {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return OnDeviceModelAvailability(SystemLanguageModel.default.availability)
            }
        #endif
        return .unavailable(.osVersionTooOld)
    }

    func available() -> Bool { availability() == .available }

    func prewarm() async {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *), available() {
                LanguageModelSession(model: .default).prewarm()
            }
        #endif
    }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return await FoundationModelsRun.perform(request)
            }
        #endif
        return .unavailable(.osVersionTooOld)
    }
}

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    nonisolated extension OnDeviceModelAvailability {
        init(_ availability: SystemLanguageModel.Availability) {
            switch availability {
            case .available:
                self = .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: self = .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled: self = .unavailable(.appleIntelligenceDisabled)
                case .modelNotReady: self = .unavailable(.modelNotReady)
                @unknown default: self = .unavailable(.unknown)
                }
            @unknown default:
                self = .unavailable(.unknown)
            }
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    nonisolated extension OnDeviceJSONSchema {
        func generationSchema() throws -> GenerationSchema {
            try GenerationSchema(root: dynamicSchema(name: "Answer"), dependencies: [])
        }

        private func dynamicSchema(name: String) -> DynamicGenerationSchema {
            switch self {
            case .object(let properties):
                return DynamicGenerationSchema(
                    name: name,
                    properties: properties.map {
                        DynamicGenerationSchema.Property(
                            name: $0.name,
                            schema: $0.schema.dynamicSchema(name: "\(name).\($0.name)"),
                            isOptional: !$0.required)
                    })
            case .string(let allowed):
                if let allowed { return DynamicGenerationSchema(name: name, anyOf: allowed) }
                return DynamicGenerationSchema(type: String.self)
            case .integer(let minimum, let maximum):
                var guides: [GenerationGuide<Int>] = []
                if let minimum { guides.append(.minimum(minimum)) }
                if let maximum { guides.append(.maximum(maximum)) }
                return DynamicGenerationSchema(type: Int.self, guides: guides)
            case .number:
                return DynamicGenerationSchema(type: Double.self)
            case .boolean:
                return DynamicGenerationSchema(type: Bool.self)
            case .array(let items, let minItems, let maxItems):
                return DynamicGenerationSchema(
                    arrayOf: items.dynamicSchema(name: "\(name).item"),
                    minimumElements: minItems, maximumElements: maxItems)
            }
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    nonisolated enum FoundationModelsRun {
        static func perform(_ request: OnDeviceRequest) async -> OnDeviceResponse {
            let model = SystemLanguageModel.default
            if case .unavailable(let reason) = OnDeviceModelAvailability(model.availability) {
                return .unavailable(reason)
            }
            guard let composed = OnDevicePromptComposer.compose(request.messages) else {
                return .failed(.emptyRequest)
            }
            let schema: OnDeviceJSONSchema?
            if let schemaJSON = request.schemaJSON {
                guard let parsed = try? OnDeviceJSONSchema(json: schemaJSON) else {
                    return .failed(.schemaUnsupported)
                }
                schema = parsed
            } else {
                schema = nil
            }
            let session = LanguageModelSession(
                model: model, tools: [], instructions: composed.instructions)
            let options = GenerationOptions(maximumResponseTokens: max(1, request.maxTokens))
            do {
                if let schema {
                    let response = try await session.respond(
                        to: composed.prompt, schema: try schema.generationSchema(), options: options)
                    let json = response.content.jsonString
                    return schema.accepts(json) ? .json(json) : .failed(.outputMismatchedSchema)
                }
                let response = try await session.respond(to: composed.prompt, options: options)
                return .text(response.content)
            } catch is CancellationError {
                return .failed(.cancelled)
            } catch let error as LanguageModelSession.GenerationError {
                return map(error)
            } catch {
                return .failed(.generationFailed)
            }
        }

        private static func map(_ error: LanguageModelSession.GenerationError) -> OnDeviceResponse {
            switch error {
            case .refusal(_, let context): return .refused(context.debugDescription)
            case .guardrailViolation(let context): return .refused(context.debugDescription)
            case .assetsUnavailable: return .unavailable(.modelNotReady)
            case .exceededContextWindowSize: return .failed(.contextTooLarge)
            case .rateLimited, .concurrentRequests: return .failed(.busy)
            default: return .failed(.generationFailed)
            }
        }
    }
#endif
