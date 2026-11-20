// Defines streaming transcription events and the interface implemented by the downloaded MLX voice model.
// VoicePipeline feeds microphone buffers through this interface without a platform recognizer fallback.

import AVFoundation
import Foundation

nonisolated enum VoiceRecognizerEvent: Equatable, Sendable {
    case partial(String, segmentID: UUID? = nil)
    case final(String, segmentID: UUID? = nil)
    case failed(String)
}

nonisolated enum VoiceTranscriberKind: String, Equatable, Sendable {
    case mlx
    case rumble
    case speechAnalyzer = "speech_analyzer"
    case onDeviceRecognizer = "on_device_recognizer"
}

nonisolated enum VoiceTranscriberError: Error, Equatable {
    case permissionNotGranted
    case recognizerUnavailable
    case onDeviceRecognitionUnsupported
    case assetsNotInstalled
    case noCompatibleAudioFormat
}

nonisolated protocol VoiceStreamingTranscriber: AnyObject, Sendable {
    var kind: VoiceTranscriberKind { get }
    var segmentID: UUID? { get }
    func setEventHandler(_ handler: @escaping @Sendable (VoiceRecognizerEvent) -> Void)
    func prepare() async throws
    func beginSegment() throws
    func append(_ buffer: AVAudioPCMBuffer)
    func flushPartial()
    func endSegment()
    func cancelSegment()
    func shutdown()
}

extension VoiceStreamingTranscriber {
    nonisolated var segmentID: UUID? { nil }
    nonisolated func flushPartial() {}
}
