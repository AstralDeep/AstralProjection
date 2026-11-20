// Renders the default installed system voice for the conversation language to audio buffers and never plays through the system itself.
// It is the only file that touches AVSpeechSynthesizer, and its buffers reach the shared duplex engine through the VoiceSpeaking seam like any other voice.

import AVFoundation
import AstralVoiceSpeech
import Foundation

nonisolated struct SystemVoiceDescriptor: Equatable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard
        case enhanced
        case premium

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let identifier: String
    let language: String
    let quality: Quality
    let isPersonal: Bool
    let isNovelty: Bool
    let isLocaleDefault: Bool
}

nonisolated enum SystemVoiceSelection {
    static func select(for language: ConversationLanguage, from voices: [SystemVoiceDescriptor])
        -> SystemVoiceDescriptor?
    {
        let wanted = normalized(language.localeIdentifier)
        let family = primary(wanted)
        let eligible = voices.filter { voice in
            let tag = normalized(voice.language)
            return !voice.isPersonal && !voice.isNovelty && primary(tag) == family
                && !(language == .mandarin && tag == "zh-hk")
        }
        return eligible.min { first, second in
            let keys = [first, second].map { voice in
                (
                    normalized(voice.language) == wanted ? 0 : 1, voice.isLocaleDefault ? 0 : 1,
                    -voice.quality.rawValue
                )
            }
            if keys[0] != keys[1] { return keys[0] < keys[1] }
            return first.identifier < second.identifier
        }
    }

    private static func normalized(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func primary(_ tag: String) -> String {
        tag.split(separator: "-").first.map(String.init) ?? tag
    }
}

nonisolated protocol SystemVoiceRenderHandle: Sendable {
    func stop()
}

nonisolated protocol SystemVoiceRendering: Sendable {
    func installedVoices() -> [SystemVoiceDescriptor]
    func render(_ text: String, voice identifier: String, onBuffer: @escaping @Sendable (AVAudioBuffer) -> Void)
        -> any SystemVoiceRenderHandle
}

nonisolated struct LiveSystemVoiceRenderer: SystemVoiceRendering {
    func installedVoices() -> [SystemVoiceDescriptor] {
        let defaultIdentifiers = Set(
            ConversationLanguage.allCases.compactMap {
                AVSpeechSynthesisVoice(language: $0.localeIdentifier)?.identifier
            })
        return AVSpeechSynthesisVoice.speechVoices().map { voice in
            SystemVoiceDescriptor(
                identifier: voice.identifier, language: voice.language, quality: Self.quality(voice.quality),
                isPersonal: voice.voiceTraits.contains(.isPersonalVoice),
                isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
                isLocaleDefault: defaultIdentifiers.contains(voice.identifier))
        }
    }

    func render(_ text: String, voice identifier: String, onBuffer: @escaping @Sendable (AVAudioBuffer) -> Void)
        -> any SystemVoiceRenderHandle
    {
        let job = Job()
        DispatchQueue.main.async { job.start(text: text, voice: identifier, onBuffer: onBuffer) }
        return job
    }

    private static func quality(_ quality: AVSpeechSynthesisVoiceQuality) -> SystemVoiceDescriptor.Quality {
        switch quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
    }

    private final class Job: SystemVoiceRenderHandle, @unchecked Sendable {
        private var synthesizer: AVSpeechSynthesizer?
        private var stopped = false

        func start(text: String, voice identifier: String, onBuffer: @escaping @Sendable (AVAudioBuffer) -> Void) {
            guard !stopped else { return }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
            let renderer = AVSpeechSynthesizer()
            synthesizer = renderer
            renderer.write(utterance) { [weak self] buffer in
                onBuffer(buffer)
                if (buffer as? AVAudioPCMBuffer)?.frameLength == 0 { self?.release() }
            }
        }

        func stop() {
            DispatchQueue.main.async { [self] in
                stopped = true
                synthesizer?.stopSpeaking(at: .immediate)
                synthesizer = nil
            }
        }

        private func release() {
            DispatchQueue.main.async { [self] in synthesizer = nil }
        }
    }
}

nonisolated final class SystemVoiceSpeech: SwitchableVoice, @unchecked Sendable {
    private struct Running {
        let id = UUID()
        let handle: any SystemVoiceRenderHandle
        let continuation: AsyncThrowingStream<SpeechAudioBuffer, Error>.Continuation
    }

    private let language: @Sendable () -> ConversationLanguage
    private let renderer: any SystemVoiceRendering
    private let lock = NSLock()
    private var running: Running?

    init(
        language: @escaping @Sendable () -> ConversationLanguage = { ConversationLanguage.saved() },
        renderer: any SystemVoiceRendering = LiveSystemVoiceRenderer()
    ) {
        self.language = language
        self.renderer = renderer
    }

    func unavailability() async -> VoiceSpeechUnavailability? {
        let wanted = language()
        return SystemVoiceSelection.select(for: wanted, from: renderer.installedVoices()) == nil
            ? .noSystemVoice(wanted) : nil
    }

    func warmUp() async throws {}

    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechSynthesisError.emptySentence }
        let wanted = language()
        guard let voice = SystemVoiceSelection.select(for: wanted, from: renderer.installedVoices()) else {
            throw VoiceSpeechUnavailable(reason: .noSystemVoice(wanted))
        }
        await cancel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechAudioBuffer.self, throwing: Error.self)
        let flattener = SpeechResampler()
        let handle = renderer.render(text, voice: voice.identifier) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                continuation.finish(throwing: SpeechSynthesisError.synthesisFailed("unsupported system voice buffer"))
                return
            }
            guard pcm.frameLength > 0 else {
                continuation.finish()
                return
            }
            do {
                let samples = try flattener.resample(pcm)
                if !samples.isEmpty {
                    continuation.yield(
                        SpeechAudioBuffer(samples: samples, sampleRate: Int(pcm.format.sampleRate.rounded())))
                }
            } catch {
                continuation.finish(throwing: SpeechSynthesisError.synthesisFailed("system voice conversion failed"))
            }
        }
        let job = Running(handle: handle, continuation: continuation)
        lock.withLock { running = job }
        continuation.onTermination = { [weak self] _ in
            handle.stop()
            self?.forget(job.id)
        }
        return stream
    }

    func cancel() async {
        let job = lock.withLock {
            defer { running = nil }
            return running
        }
        job?.handle.stop()
        job?.continuation.finish(throwing: SpeechSynthesisError.cancelled)
    }

    private func forget(_ id: UUID) {
        lock.withLock { if running?.id == id { running = nil } }
    }
}
