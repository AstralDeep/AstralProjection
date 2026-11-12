// Splits streamed answer text into speakable sentences and strips markup the synthesizer should not read aloud.
// VoicePipeline feeds it answer deltas so speech can start early and stop between and inside sentences.

import Foundation

nonisolated struct VoiceSentenceSplitter {
    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "st", "vs", "e.g", "i.e", "no", "fig",
    ]
    private static let clauseLimit = 160

    private var buffer = ""

    mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var sentences: [String] = []
        while let end = boundary() {
            let sentence = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    mutating func flush() -> [String] {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? [] : [rest]
    }

    mutating func reset() { buffer = "" }

    private func boundary() -> String.Index? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if character == "\n" { return buffer.index(after: index) }
            if ".!?…".contains(character) {
                var end = buffer.index(after: index)
                while end < buffer.endIndex, "\"')]”’.!?".contains(buffer[end]) {
                    end = buffer.index(after: end)
                }
                guard end < buffer.endIndex, buffer[end].isWhitespace else { index = end; continue }
                if character == ".", isAbbreviation(before: index) { index = end; continue }
                return end
            }
            index = buffer.index(after: index)
        }
        return clauseBoundary()
    }

    private func isAbbreviation(before dot: String.Index) -> Bool {
        let head = buffer[..<dot]
        let word = head.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let lowered = word.lowercased()
        if Self.abbreviations.contains(lowered) { return true }
        return word.count == 1 && word.first?.isUppercase == true
    }

    private func clauseBoundary() -> String.Index? {
        guard buffer.count > Self.clauseLimit else { return nil }
        let window = buffer.prefix(Self.clauseLimit)
        guard let comma = window.lastIndex(where: { ",;:".contains($0) }) else { return nil }
        let after = buffer.index(after: comma)
        guard after < buffer.endIndex, buffer[after].isWhitespace else { return nil }
        return after
    }
}

nonisolated enum VoiceSpeechText {
    static func clean(_ sentence: String) -> String {
        var text = sentence
        text = text.replacingOccurrences(
            of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"^\s{0,3}(#{1,6}|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        text = text.filter { !"*_`#~|>".contains($0) }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(where: { $0.isLetter || $0.isNumber }) ? trimmed : ""
    }
}
