// Speaks one sentence at a time with the on-device Phonon voice, loaded from the folder the voice pack store reports.
// It answers the VoiceSpeaking seam, reports why it cannot speak, and applies one fixed playback gain, never a per-sentence level.

import AstralVoiceSpeech
import Foundation

actor LocalVoiceSpeech: SwitchableVoice {
    typealias FolderProvider = @Sendable () async -> URL?
    nonisolated static let playbackGain: Float = 1.75

    private let synthesizer: any SpeechSynthesizer
    private let folder: FolderProvider
    private var failedFolder: URL?
    private var loadedFolder: URL?
    private var loading: Task<Void, Error>?

    init(synthesizer: any SpeechSynthesizer = PhononSpeech(), folder: @escaping FolderProvider) {
        self.synthesizer = synthesizer
        self.folder = folder
    }

    func unavailability() async -> VoiceSpeechUnavailability? {
        if case .unavailable = synthesizer.availability { return .operatingSystemTooOld }
        guard let url = await folder() else { return .notInstalled }
        return failedFolder == url ? .loadFailed : nil
    }

    func warmUp() async throws {
        _ = try await ready()
    }

    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        _ = try await ready()
        let stream = try await synthesizer.synthesize(sentence: sentence)
        return Self.scaled(stream, by: Self.playbackGain)
    }

    func cancel() async {
        await synthesizer.cancel()
    }

    func unload() async {
        loading?.cancel()
        loading = nil
        loadedFolder = nil
        await synthesizer.unload()
    }

    func retryAfterFailure() {
        failedFolder = nil
    }

    private func ready() async throws -> URL {
        if let reason = await unavailability() { throw VoiceSpeechUnavailable(reason: reason) }
        guard let url = await folder() else { throw VoiceSpeechUnavailable(reason: .notInstalled) }
        if loadedFolder == url, await synthesizer.isLoaded { return url }
        let pending =
            loading
            ?? Task {
                try await synthesizer.load(from: url)
            }
        loading = pending
        defer { loading = nil }
        do {
            try await pending.value
            loadedFolder = url
            return url
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failedFolder = url
            loadedFolder = nil
            throw VoiceSpeechUnavailable(reason: .loadFailed)
        }
    }

    private static func scaled(
        _ stream: AsyncThrowingStream<SpeechAudioBuffer, Error>, by gain: Float
    ) -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        guard gain != 1 else { return stream }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await buffer in stream {
                        let samples = buffer.samples.map { min(1, max(-1, $0 * gain)) }
                        continuation.yield(SpeechAudioBuffer(samples: samples, sampleRate: buffer.sampleRate))
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
