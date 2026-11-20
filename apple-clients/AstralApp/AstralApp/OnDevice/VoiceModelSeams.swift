// Defines the three seams the voice pipeline calls its models through: recognition, speech and local text.
// MLXVoiceInference conforms to all three today, and each seam can be backed by a different engine because none of them names an engine type.

import AstralVoiceRuntime
import AstralVoiceSpeech
import Foundation

nonisolated protocol VoiceRecognizing: Sendable {
    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String
}

nonisolated protocol VoiceSpeaking: Sendable {
    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error>
}

nonisolated protocol VoiceTextGenerating: Sendable {
    func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error>
}

typealias VoiceModelInference = VoiceRecognizing & VoiceSpeaking & VoiceTextGenerating

extension AsyncThrowingStream where Element == String, Failure == Error {
    nonisolated func collected() async throws -> String {
        var text = ""
        for try await piece in self { text += piece }
        try Task.checkCancellation()
        return text
    }
}
