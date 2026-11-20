// Errors the runtime reports for bad files, bad input and failed inference; cancellation is reported as CancellationError instead.
// SpeechRecognizer and TextGenerator throw these, and the native status codes from CAstralLlama map onto them in NativeModel.
import Foundation

public enum VoiceRuntimeError: Error, Equatable, Sendable {
    case fileNotFound(URL)
    case modelLoadFailed(URL)
    case encoderLoadFailed(URL)
    case encoderHasNoAudioInput(URL)
    case contextCreationFailed
    case invalidConfiguration(String)
    case emptyAudio
    case audioTooLong(maximumSeconds: Int)
    case unsupportedLanguage(String)
    case invalidTokenLimit(Int)
    case emptyConversation
    case chatTemplateUnavailable
    case tokenizationFailed
    case promptTooLong
    case encodeFailed
    case decodeFailed
    case unloaded
}

extension VoiceRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): return "No model file at \(url.lastPathComponent)."
        case .modelLoadFailed(let url): return "\(url.lastPathComponent) is not a model the runtime can load."
        case .encoderLoadFailed(let url): return "\(url.lastPathComponent) is not an audio encoder that matches the model."
        case .encoderHasNoAudioInput(let url): return "\(url.lastPathComponent) has no audio input."
        case .contextCreationFailed: return "The runtime could not allocate its working memory."
        case .invalidConfiguration(let reason): return "Invalid runtime configuration: \(reason)."
        case .emptyAudio: return "There is no audio to recognize."
        case .audioTooLong(let seconds): return "Audio is longer than \(seconds) seconds."
        case .unsupportedLanguage(let language): return "\(language) is not a language the recognizer accepts."
        case .invalidTokenLimit(let limit): return "A token limit of \(limit) is not valid."
        case .emptyConversation: return "There are no messages to answer."
        case .chatTemplateUnavailable: return "The model has no chat template the runtime can apply."
        case .tokenizationFailed: return "The prompt could not be tokenized."
        case .promptTooLong: return "The prompt does not fit in the model's context."
        case .encodeFailed: return "The audio could not be encoded."
        case .decodeFailed: return "The model failed while generating."
        case .unloaded: return "The model has been unloaded."
        }
    }
}
