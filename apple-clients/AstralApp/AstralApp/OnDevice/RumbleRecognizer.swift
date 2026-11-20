// Wraps AstralVoiceRuntime's SpeechRecognizer as the app's VoiceRecognitionModel and maps the runtime's errors onto the voice errors the pipeline handles.
// VoiceModelOwner loads and unloads it, and OwnedRecognizer calls it through the owner so a model that failed its decode is rebuilt on next use.

import AstralVoiceRuntime
import Foundation

nonisolated enum VoiceModelRuntimeError: Error, Equatable, Sendable {
    case filesMissing(String)
    case digestMismatch(String)
    case deviceUnsupported
    case emptyInput
    case inputTooLong
    case unsupportedLanguage
    case needsReload
    case failed

    init(_ error: VoiceRuntimeError) {
        switch error {
        case .fileNotFound(let url): self = .filesMissing(url.lastPathComponent)
        case .emptyAudio, .emptyConversation: self = .emptyInput
        case .audioTooLong, .promptTooLong: self = .inputTooLong
        case .unsupportedLanguage: self = .unsupportedLanguage
        case .decodeFailed, .encodeFailed, .unloaded: self = .needsReload
        default: self = .failed
        }
    }

    static func mapping(_ error: Error) -> Error {
        if error is CancellationError || error is VoiceModelRuntimeError { return error }
        if let runtime = error as? VoiceRuntimeError { return VoiceModelRuntimeError(runtime) }
        return VoiceModelRuntimeError.failed
    }

    var isModelUnavailable: Bool {
        switch self {
        case .filesMissing, .digestMismatch, .deviceUnsupported: true
        default: false
        }
    }
}

nonisolated final class RumbleRecognitionModel: VoiceRecognitionModel {
    private let recognizer: SpeechRecognizer

    init(recognizer: SpeechRecognizer) {
        self.recognizer = recognizer
    }

    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String {
        do {
            try Task.checkCancellation()
            let transcription = try await recognizer.transcribe(audio, language: language)
            try Task.checkCancellation()
            return transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw VoiceModelRuntimeError.mapping(error)
        }
    }

    func unload() async {
        await recognizer.unload()
    }
}

nonisolated struct OwnedRecognizer: VoiceRecognizing {
    let owner: VoiceModelOwner

    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String {
        let model = try await owner.recognizer()
        do {
            return try await model.recognize(audio, language: language)
        } catch VoiceModelRuntimeError.needsReload {
            await owner.discard(model)
            throw VoiceModelRuntimeError.needsReload
        }
    }
}
