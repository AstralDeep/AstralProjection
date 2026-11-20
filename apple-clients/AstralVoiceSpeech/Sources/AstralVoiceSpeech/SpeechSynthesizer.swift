// Defines the speech seam the voice pipeline calls and the value types that cross it, with no engine types in the signatures.
// PhononSpeech conforms to it here, and the app's system-voice implementation conforms to the same protocol.
import Foundation

public struct SpeechAudioBuffer: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
}

public enum SpeechUnavailableReason: Sendable, Equatable {
    case operatingSystemTooOld(required: String)
}

public enum SpeechAvailability: Sendable, Equatable {
    case available
    case unavailable(SpeechUnavailableReason)
}

public enum SpeechSynthesisError: Error, Sendable, Equatable {
    case unavailable(SpeechUnavailableReason)
    case modelFolderIncomplete(missing: [String])
    case loadFailed(String)
    case loadInProgress
    case notLoaded
    case emptySentence
    case synthesisFailed(String)
    case cancelled
}

extension SpeechSynthesisError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(.operatingSystemTooOld(let required)):
            return "This voice needs \(required) or later."
        case .modelFolderIncomplete(let missing):
            return "The voice folder is incomplete. Missing: \(missing.joined(separator: ", "))."
        case .loadFailed(let detail):
            return "The voice could not be loaded. \(detail)"
        case .loadInProgress:
            return "The voice is already loading."
        case .notLoaded:
            return "The voice is not loaded."
        case .emptySentence:
            return "There is nothing to say."
        case .synthesisFailed(let detail):
            return "The voice could not speak. \(detail)"
        case .cancelled:
            return "Speech was cancelled."
        }
    }
}

public protocol SpeechSynthesizer: Sendable {
    nonisolated var availability: SpeechAvailability { get }
    var isLoaded: Bool { get async }
    func load(from folder: URL) async throws
    func synthesize(sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error>
    func cancel() async
    func unload() async
}
