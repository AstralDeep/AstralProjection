// Pure, clock-injected state machine that decides when the owner talking over the assistant is a real interruption.
// VoicePipeline feeds it voice activity, partial transcripts and playback events and performs the actions it returns.

import Foundation

nonisolated struct BargeInConfiguration: Equatable, Sendable {
    var duckedVolume: Float = 0.15
    var confirmationDelay: TimeInterval = 0.25
    var noWordsTimeout: TimeInterval = 1.5
    var backchannels: Set<String> = [
        "mm", "mmm", "mhm", "mmhm", "hm", "hmm", "uh", "um", "umm", "uhhuh", "ah", "oh",
        "yeah", "yep", "yup", "ok", "okay", "right", "sure",
    ]
}

nonisolated enum BargeInAction: Equatable, Sendable {
    case duck(volume: Float)
    case restoreVolume
    case speak(index: Int, text: String)
    case stopSpeech
    case cancelModelStream
    case cancelTool(id: String)
    case recordSpoken(String)
    case beginUserTurn
}

nonisolated final class BargeInController {
    private enum SentenceState { case pending, inFlight, played }

    private struct Sentence {
        let text: String
        let speechText: String
        var state: SentenceState = .pending
        var spokenCharacters = 0
    }

    private struct PendingInterruption {
        let since: TimeInterval
        let baselineWords: Int
    }

    private let configuration: BargeInConfiguration
    private let clock: VoiceClock
    private var sentences: [Sentence] = []
    private var pending: PendingInterruption?
    private var soundActive = false
    private var suppressedUntilSoundEnds = false
    private var recognizedWords = 0
    private var tools: [String: Bool] = [:]
    private var riskyActionPending = false

    init(configuration: BargeInConfiguration = BargeInConfiguration(), clock: VoiceClock) {
        self.configuration = configuration
        self.clock = clock
    }

    var isSpeaking: Bool { sentences.contains { $0.state != .played } }

    var nextDeadline: TimeInterval? {
        guard let pending else { return nil }
        let confirmAt = pending.since + configuration.confirmationDelay
        return clock.now < confirmAt ? confirmAt : pending.since + configuration.noWordsTimeout
    }

    var spokenText: String {
        sentences.compactMap { sentence -> String? in
            sentence.state == .pending ? nil : Self.spokenPrefix(of: sentence)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    func enqueue(sentence: String, speech: String? = nil) -> [BargeInAction] {
        let speechText = speech ?? sentence
        var entry = Sentence(text: sentence, speechText: speechText)
        if speechText.isEmpty {
            entry.state = .played
            entry.spokenCharacters = sentence.count
        }
        sentences.append(entry)
        return advance()
    }

    func sentenceProgress(index: Int, characters: Int) {
        guard sentences.indices.contains(index), sentences[index].state == .inFlight else { return }
        sentences[index].spokenCharacters = max(sentences[index].spokenCharacters, characters)
    }

    func sentenceFinished(index: Int, completed: Bool) -> [BargeInAction] {
        guard sentences.indices.contains(index), sentences[index].state == .inFlight else { return [] }
        sentences[index].state = .played
        if completed { sentences[index].spokenCharacters = sentences[index].speechText.count }
        return advance()
    }

    func voiceActivity(active: Bool) -> [BargeInAction] {
        soundActive = active
        if active {
            guard !suppressedUntilSoundEnds, pending == nil, isSpeaking else { return [] }
            pending = PendingInterruption(since: clock.now, baselineWords: recognizedWords)
            return [.duck(volume: configuration.duckedVolume)]
        }
        suppressedUntilSoundEnds = false
        guard pending != nil else { return [] }
        return wordsSinceOnset > 0 ? confirm() : dismiss()
    }

    func partialTranscript(_ text: String) -> [BargeInAction] {
        recognizedWords = countWords(text)
        return tick()
    }

    func transcriptSegmentReset() {
        recognizedWords = 0
        if let current = pending { pending = PendingInterruption(since: current.since, baselineWords: 0) }
    }

    func tick() -> [BargeInAction] {
        guard let pending else { return [] }
        let elapsed = clock.now - pending.since
        if wordsSinceOnset > 0 && elapsed >= configuration.confirmationDelay { return confirm() }
        if wordsSinceOnset == 0 && elapsed >= configuration.noWordsTimeout {
            suppressedUntilSoundEnds = soundActive
            return dismiss()
        }
        return []
    }

    func toolStarted(id: String, cancelSafe: Bool) { tools[id] = cancelSafe }

    func toolFinished(id: String) { tools[id] = nil }

    func setRiskyActionPending(_ pending: Bool) { riskyActionPending = pending }

    func reset() {
        sentences = []
        pending = nil
        soundActive = false
        suppressedUntilSoundEnds = false
        recognizedWords = 0
        tools = [:]
    }

    private var wordsSinceOnset: Int {
        guard let pending else { return 0 }
        return max(0, recognizedWords - pending.baselineWords)
    }

    private func advance() -> [BargeInAction] {
        guard pending == nil, !sentences.contains(where: { $0.state == .inFlight }),
            let next = sentences.firstIndex(where: { $0.state == .pending })
        else { return [] }
        sentences[next].state = .inFlight
        return [.speak(index: next, text: sentences[next].speechText)]
    }

    private func dismiss() -> [BargeInAction] {
        pending = nil
        return [.restoreVolume] + advance()
    }

    private func confirm() -> [BargeInAction] {
        pending = nil
        var actions: [BargeInAction] = [.stopSpeech, .restoreVolume]
        if !riskyActionPending {
            actions.append(.cancelModelStream)
            actions += tools.filter(\.value).keys.sorted().map { .cancelTool(id: $0) }
        }
        actions.append(.recordSpoken(spokenText))
        actions.append(.beginUserTurn)
        sentences = []
        return actions
    }

    private func countWords(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { token in
            let letters = token.lowercased().filter { $0.isLetter || $0.isNumber }
            return !letters.isEmpty && !configuration.backchannels.contains(letters)
        }.count
    }

    private static func spokenPrefix(of sentence: Sentence) -> String {
        let text = sentence.text
        let spoken = sentence.speechText
        guard sentence.spokenCharacters > 0 else { return "" }
        guard sentence.spokenCharacters < spoken.count else { return text }
        let heard = completedWords(of: spoken, characters: sentence.spokenCharacters)
        if spoken == text { return heard }
        return leadingWords(of: text, count: heard.split(whereSeparator: \.isWhitespace).count)
    }

    private static func completedWords(of text: String, characters: Int) -> String {
        let cut = text.index(text.startIndex, offsetBy: characters)
        var prefix = String(text[..<cut])
        if !text[cut].isWhitespace, let last = prefix.last, !last.isWhitespace {
            if let boundary = prefix.lastIndex(where: { $0.isWhitespace }) {
                prefix = String(prefix[..<boundary])
            } else {
                prefix = ""
            }
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func leadingWords(of text: String, count: Int) -> String {
        guard count > 0 else { return "" }
        var seen = 0
        var inWord = false
        for index in text.indices {
            let isSpace = text[index].isWhitespace
            if inWord && isSpace {
                seen += 1
                if seen == count { return String(text[..<index]) }
            }
            inWord = !isSpace
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
