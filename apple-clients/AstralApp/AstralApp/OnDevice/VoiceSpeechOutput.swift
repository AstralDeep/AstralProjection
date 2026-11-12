// Describes sentence-by-sentence speech playback and maps playback position to the characters that were actually heard.
// VoicePipeline drives a VoiceSpeechOutput, and VoiceDuplexEngine implements it on the shared audio graph.

import Foundation

nonisolated enum VoiceSpeechEvent: Equatable, Sendable {
    case started(index: Int)
    case finished(index: Int)
    case failed(index: Int)
}

nonisolated struct VoiceSpeechProgress: Equatable, Sendable {
    let index: Int
    let characters: Int
}

@MainActor
protocol VoiceSpeechOutput: AnyObject {
    var onEvent: ((VoiceSpeechEvent) -> Void)? { get set }
    func speak(index: Int, text: String)
    func stopSpeaking()
    func setVolume(_ volume: Float)
    func playedProgress() -> VoiceSpeechProgress?
}

nonisolated struct VoiceSpeechTimeline: Equatable, Sendable {
    struct Word: Equatable, Sendable {
        let endCharacter: Int
        let startSeconds: Double
    }

    let words: [Word]

    func charactersSpoken(atSeconds seconds: Double) -> Int {
        var spoken = 0
        for position in words.indices.dropLast() where words[position + 1].startSeconds <= seconds {
            spoken = words[position].endCharacter
        }
        return spoken
    }

    static func make(
        text: String, wordRanges: [(range: NSRange, offset: Double)], secondsPerOffsetUnit: Double
    ) -> VoiceSpeechTimeline {
        let words = wordRanges.compactMap { entry -> Word? in
            guard let range = Range(entry.range, in: text) else { return nil }
            return Word(
                endCharacter: text.distance(from: text.startIndex, to: range.upperBound),
                startSeconds: entry.offset * secondsPerOffsetUnit)
        }
        return VoiceSpeechTimeline(words: words)
    }
}
