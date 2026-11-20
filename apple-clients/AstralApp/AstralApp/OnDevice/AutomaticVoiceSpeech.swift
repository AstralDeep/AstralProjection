// Chooses between the local voice and the system voice for each sentence: local for English when it can speak, system otherwise.
// It reports a fall back from the local voice once through a callback, and finishes a sentence with the system voice only while no local audio has been yielded for it.

import AstralVoiceSpeech
import Foundation

nonisolated enum EnglishVoiceChoice: Equatable, Sendable {
    case automatic
    case system
}

nonisolated final class AutomaticVoiceSpeech: VoiceSpeaking, @unchecked Sendable {
    private let local: any SwitchableVoice
    private let system: any SwitchableVoice
    private let language: @Sendable () -> ConversationLanguage
    private let englishChoice: @Sendable () -> EnglishVoiceChoice
    private let onSwitch: @Sendable (VoiceSpeechUnavailability) -> Void
    private let lock = NSLock()
    private var reported = false

    init(
        local: any SwitchableVoice, system: any SwitchableVoice,
        language: @escaping @Sendable () -> ConversationLanguage = { ConversationLanguage.saved() },
        englishChoice: @escaping @Sendable () -> EnglishVoiceChoice = { .automatic },
        onSwitch: @escaping @Sendable (VoiceSpeechUnavailability) -> Void = { _ in }
    ) {
        self.local = local
        self.system = system
        self.language = language
        self.englishChoice = englishChoice
        self.onSwitch = onSwitch
    }

    func warmUp() async {
        guard usesLocalVoice else { return }
        try? await local.warmUp()
    }

    func cancel() async {
        await local.cancel()
        await system.cancel()
    }

    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        guard usesLocalVoice else { return try await system.speak(sentence) }
        if let reason = await local.unavailability() {
            report(reason)
            return try await system.speak(sentence)
        }
        let spoken: AsyncThrowingStream<SpeechAudioBuffer, Error>
        do {
            spoken = try await local.speak(sentence)
        } catch let unavailable as VoiceSpeechUnavailable {
            report(unavailable.reason)
            return try await system.speak(sentence)
        }
        let system = system
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                var yielded = false
                do {
                    for try await buffer in spoken {
                        yielded = true
                        continuation.yield(buffer)
                    }
                    self?.clearReport()
                    continuation.finish()
                } catch {
                    guard !yielded, !Task.isCancelled, (error as? SpeechSynthesisError) != .cancelled else {
                        continuation.finish(throwing: error)
                        return
                    }
                    self?.report(.synthesisFailed)
                    do {
                        for try await buffer in try await system.speak(sentence) { continuation.yield(buffer) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var usesLocalVoice: Bool {
        language() == .english && englishChoice() == .automatic
    }

    private func report(_ reason: VoiceSpeechUnavailability) {
        let first = lock.withLock {
            defer { reported = true }
            return !reported
        }
        if first { onSwitch(reason) }
    }

    private func clearReport() {
        lock.withLock { reported = false }
    }
}
