// Generates text with a chat GGUF, formatting the conversation with the model's own chat template and streaming tokens as they are produced.
// It shares RuntimeScheduler with SpeechRecognizer at lower priority, and cancellation stops the decode loop between tokens.
import CAstralLlama
import Dispatch
import Foundation

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

public struct GenerationOptions: Sendable, Equatable {
    public var maxTokens: Int
    public var temperature: Float
    public var topK: Int
    public var seed: UInt32

    public init(maxTokens: Int = 128, temperature: Float = 0, topK: Int = 40, seed: UInt32 = 0) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topK = topK
        self.seed = seed
    }
}

public struct Generation: Sendable, Equatable {
    public let text: String
    public let tokenCount: Int
    public let stop: StopReason
}

public actor TextGenerator {
    private let native: NativeModel
    private let queue: DispatchSerialQueue
    private let scheduler: RuntimeScheduler

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private init(native: NativeModel, queue: DispatchSerialQueue, scheduler: RuntimeScheduler) {
        self.native = native
        self.queue = queue
        self.scheduler = scheduler
    }

    public static func load(
        model: URL,
        configuration: RuntimeConfiguration = RuntimeConfiguration(contextTokens: 4096),
        scheduler: RuntimeScheduler = .shared
    ) async throws -> TextGenerator {
        let queue = ModelQueue.make("generation")
        let native = try await ModelQueue.load(on: queue) {
            try NativeModel.load(model: model, encoder: nil, configuration: configuration)
        }
        return TextGenerator(native: native, queue: queue, scheduler: scheduler)
    }

    public func unload() {
        native.close()
    }

    public nonisolated func generate(
        _ messages: [ChatMessage],
        options: GenerationOptions = GenerationOptions(),
        onText: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Generation {
        guard !messages.isEmpty else { throw VoiceRuntimeError.emptyConversation }
        guard options.maxTokens > 0 else { throw VoiceRuntimeError.invalidTokenLimit(options.maxTokens) }
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await scheduler.perform(.generation) {
                try await self.run(messages, options: options, flag: flag, onText: onText)
            }
        } onCancel: {
            flag.raise()
        }
    }

    public nonisolated func stream(_ messages: [ChatMessage], options: GenerationOptions = GenerationOptions()) -> AsyncThrowingStream<String, Error> {
        textStream { emit in
            _ = try await self.generate(messages, options: options, onText: emit)
        }
    }

    private func run(_ messages: [ChatMessage], options: GenerationOptions, flag: CancelFlag, onText: @Sendable (String) -> Void) throws -> Generation {
        try Task.checkCancellation()
        let prompt = try native.chatPrompt(messages.map { ($0.role.rawValue, $0.content) })
        let sampling = NativeSampling(temperature: options.temperature, topK: options.topK, seed: options.seed)
        let outcome = try native.generate(prompt: prompt, sampling: sampling, limit: options.maxTokens, cancel: flag, onText: onText)
        return Generation(text: outcome.text, tokenCount: outcome.tokenCount, stop: outcome.stop)
    }
}
