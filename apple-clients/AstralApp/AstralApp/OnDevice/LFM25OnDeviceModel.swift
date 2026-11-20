// Answers the kernel's on-device requests from LFM2.5 through the generator VoiceModelOwner shares with the voice session, under plain-text limits: no structured schemas and bounded input and output.
// RumbleVoiceModels builds it, RumbleTextModel wraps AstralVoiceRuntime's TextGenerator, and OwnedTextGenerator is the voice path's view of the same loaded model.

import AstralVoiceRuntime
import Foundation

nonisolated final class RumbleTextModel: VoiceTextModel {
    private let generator: TextGenerator

    init(generator: TextGenerator) {
        self.generator = generator
    }

    func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error> {
        let messages = Self.messages(for: request)
        let options = GenerationOptions(maxTokens: max(1, request.maxTokens))
        let source = generator.stream(messages, options: options)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in source { continuation.yield(piece) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: VoiceModelRuntimeError.mapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unload() async {
        await generator.unload()
    }

    static func messages(for request: OnDeviceRequest) -> [ChatMessage] {
        request.messages.map { message in
            switch message.role {
            case .system: ChatMessage(.system, message.text)
            case .user: ChatMessage(.user, message.text)
            case .assistant: ChatMessage(.assistant, message.text)
            case .tool: ChatMessage(.user, "[Untrusted tool output]\n" + message.text)
            }
        }
    }
}

nonisolated struct OwnedTextGenerator: VoiceTextGenerating {
    let owner: VoiceModelOwner

    func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error> {
        let owner = owner
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = try await owner.textGenerator()
                    do {
                        for try await piece in model.generate(request) { continuation.yield(piece) }
                    } catch VoiceModelRuntimeError.needsReload {
                        await owner.discard(model)
                        throw VoiceModelRuntimeError.needsReload
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

nonisolated struct LFM25OnDeviceModel: AstralOnDeviceModel {
    private let owner: VoiceModelOwner
    private let installed: @Sendable () -> Bool

    init(owner: VoiceModelOwner, installed: @escaping @Sendable () -> Bool) {
        self.owner = owner
        self.installed = installed
    }

    func available() -> Bool { installed() }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        guard request.schemaJSON == nil else { return .failed(.schemaUnsupported) }
        guard OnDevicePromptComposer.compose(request.messages) != nil else { return .failed(.emptyRequest) }
        guard request.messages.count <= 128,
            request.messages.reduce(0, { $0 + $1.text.utf8.count }) <= 65_536
        else { return .failed(.contextTooLarge) }
        guard available() else { return .unavailable(.modelNotReady) }
        let bounded = OnDeviceRequest(
            messages: request.messages, schemaJSON: nil, maxTokens: min(2_048, max(1, request.maxTokens)))
        await owner.open()
        let response = await answer(bounded)
        await owner.close()
        return response
    }

    private func answer(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        do {
            try Task.checkCancellation()
            let text = try await OwnedTextGenerator(owner: owner).generate(request).collected()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed(.generationFailed)
            }
            return .text(text)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch let error as VoiceModelRuntimeError where error.isModelUnavailable {
            return .unavailable(.modelNotReady)
        } catch {
            return .failed(.generationFailed)
        }
    }
}
