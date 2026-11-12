// Clock-injected end-of-turn detection from voice activity and partial transcripts, with a speculation signal for the fast path.
// VoicePipeline owns one; hold-to-talk mode ends the turn on release instead of on silence.

import Foundation

nonisolated struct VoiceTurnConfiguration: Equatable, Sendable {
    var speculationSilence: TimeInterval = 0.25
    var endSilence: TimeInterval = 0.6
    var continuationExtension: TimeInterval = 0.4
    var continuationWords: Set<String> = [
        "and", "but", "so", "or", "the", "a", "an", "to", "of", "because", "then", "with", "that",
        "uh", "um", "if", "for", "in", "on",
    ]
}

nonisolated enum VoiceTurnSignal: Equatable, Sendable {
    case speculate(String)
    case discardDraft
    case endOfTurn(String)
}

nonisolated enum VoiceCaptureMode: Equatable, Sendable {
    case handsFree
    case pushToTalk
}

nonisolated final class VoiceEndOfTurnDetector {
    private let configuration: VoiceTurnConfiguration
    private let clock: VoiceClock
    private(set) var mode: VoiceCaptureMode
    private var text = ""
    private var talking = false
    private var silentSince: TimeInterval?
    private var speculated: String?

    init(
        configuration: VoiceTurnConfiguration = VoiceTurnConfiguration(), clock: VoiceClock,
        mode: VoiceCaptureMode = .handsFree
    ) {
        self.configuration = configuration
        self.clock = clock
        self.mode = mode
    }

    var currentText: String { text }

    func setMode(_ newMode: VoiceCaptureMode) {
        mode = newMode
        reset()
    }

    func voiceActivity(active: Bool) -> [VoiceTurnSignal] {
        talking = active
        if active {
            silentSince = nil
            return discardSpeculation()
        }
        silentSince = clock.now
        return []
    }

    func partial(_ newText: String) -> [VoiceTurnSignal] {
        guard newText != text else { return [] }
        text = newText
        if !talking { silentSince = clock.now }
        return speculated != nil && speculated != newText ? discardSpeculation() : []
    }

    func finalized(_ finalText: String) -> [VoiceTurnSignal] {
        let spoken = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        return spoken.isEmpty ? [] : [.endOfTurn(spoken)]
    }

    func release() -> [VoiceTurnSignal] {
        guard mode == .pushToTalk else { return [] }
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        return spoken.isEmpty ? [] : [.endOfTurn(spoken)]
    }

    func tick() -> [VoiceTurnSignal] {
        guard mode == .handsFree, !talking, let silentSince else { return [] }
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return [] }
        let silence = clock.now - silentSince
        if silence >= endSilence(for: spoken) {
            reset()
            return [.endOfTurn(spoken)]
        }
        if silence >= configuration.speculationSilence && speculated == nil {
            speculated = text
            return [.speculate(spoken)]
        }
        return []
    }

    func reset() {
        text = ""
        silentSince = nil
        speculated = nil
    }

    private func endSilence(for spoken: String) -> TimeInterval {
        let last = spoken.split(whereSeparator: { $0.isWhitespace }).last
            .map { $0.lowercased().filter { $0.isLetter } } ?? ""
        let extra = configuration.continuationWords.contains(last) ? configuration.continuationExtension : 0
        return configuration.endSilence + extra
    }

    private func discardSpeculation() -> [VoiceTurnSignal] {
        guard speculated != nil else { return [] }
        speculated = nil
        return [.discardDraft]
    }
}
