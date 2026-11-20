// Adapts the downloaded LFM3 model to the voice pipeline's recognition, speech and acknowledgement interfaces.
// Every inference stays in MLX on this device; cancellation fences results from retired microphone segments.

import AVFoundation
import AstralVoiceModel
import AstralVoiceRuntime
import AstralVoiceSpeech
import Foundation

nonisolated struct MLXVoiceInference: VoiceRecognizing, VoiceSpeaking, VoiceTextGenerating {
    let engine: LFM3AudioEngine

    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String {
        // LFM3 detects the spoken language itself, so the requested language is unused here.
        var options = LFM3Sampling()
        options.maxNewTokens = 256
        return try await engine.transcribe(audio: audio, options: options, handlers: LFM3Handlers()).text
    }

    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        let engine = engine
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handlers = LFM3Handlers(onAudio: {
                        continuation.yield(SpeechAudioBuffer(samples: $0, sampleRate: 24_000))
                    })
                    let result = try await engine.synthesize(text: sentence, handlers: handlers)
                    guard !result.stoppedByLength else {
                        throw LFM3Error.invalidInput("speech exceeded its token limit")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error> {
        let engine = engine
        let messages = Self.messages(for: request)
        var options = LFM3Sampling()
        options.maxNewTokens = request.maxTokens
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await engine.chat(messages: messages, options: options).text
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func messages(for request: OnDeviceRequest) -> [LFM3Message] {
        request.messages.map { message in
            switch message.role {
            case .system: LFM3Message(role: .system, text: message.text)
            case .user: LFM3Message(role: .user, text: message.text)
            case .assistant: LFM3Message(role: .assistant, text: message.text)
            case .tool: LFM3Message(role: .user, text: "[Untrusted tool output]\n" + message.text)
            }
        }
    }
}

nonisolated struct MLXVoiceAcknowledgementModel: AstralOnDeviceModel {
    let inference: any VoiceTextGenerating

    func available() -> Bool { true }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        guard request.schemaJSON == nil else { return .failed(.schemaUnsupported) }
        guard !request.messages.isEmpty else { return .failed(.emptyRequest) }
        do {
            try Task.checkCancellation()
            let text = try await inference.generate(request).collected()
            try Task.checkCancellation()
            return .text(text)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.generationFailed)
        }
    }
}

nonisolated final class MLXVoiceTranscriber: RumbleTranscriber, @unchecked Sendable {
    convenience init(inference: any VoiceRecognizing, language: RecognitionLanguage = .english) {
        self.init(recognizer: inference, kind: .mlx, language: { language })
    }
}

@MainActor
enum MLXVoiceRuntime {
    static func pipeline(directory: URL, link: VoiceKernelLink) async throws -> VoicePipeline {
        let inference = try await VoiceInferenceCache.shared.inference(directory: directory)
        try Task.checkCancellation()
        return VoicePipeline(
            audio: VoiceDuplexEngine(speech: inference), transcriber: MLXVoiceTranscriber(inference: inference),
            fastPath: VoiceFastPath(model: MLXVoiceAcknowledgementModel(inference: inference)), link: link)
    }
}
