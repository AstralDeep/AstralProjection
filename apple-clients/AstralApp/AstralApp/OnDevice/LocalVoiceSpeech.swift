// Speaks one sentence at a time with the on-device Phonon voice, loaded from the folder the voice pack store reports.
// It answers the VoiceSpeaking seam, reports why it cannot speak, applies one fixed playback gain, never a per-sentence level, and defers an unload until the sentence being spoken has ended.

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
    private var speaking = 0
    private var unloadPending = false

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
        speaking += 1
        do {
            _ = try await ready()
            let stream = try await synthesizer.synthesize(sentence: sentence)
            return Self.scaled(stream, by: Self.playbackGain) { [self] in await finishedSpeaking() }
        } catch {
            await finishedSpeaking()
            throw error
        }
    }

    func cancel() async {
        await synthesizer.cancel()
    }

    func unload(force: Bool = false) async {
        if speaking > 0, !force {
            unloadPending = true
            return
        }
        unloadPending = false
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

    private func finishedSpeaking() async {
        speaking -= 1
        if speaking == 0, unloadPending { await unload() }
    }

    private static func scaled(
        _ stream: AsyncThrowingStream<SpeechAudioBuffer, Error>, by gain: Float,
        onEnd: @escaping @Sendable () async -> Void
    ) -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        AsyncThrowingStream { continuation in
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
                await onEnd()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
