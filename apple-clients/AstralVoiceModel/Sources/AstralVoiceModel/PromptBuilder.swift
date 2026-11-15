// Renders the LFM3 chat template for system, user and assistant turns with text and audio parts, and expands each audio placeholder to the number of encoder frames of its clip.
// LFM3AudioEngine builds every task prompt with it, and the parity tests compare its output to the reference template rendering.

import Foundation

public struct LFM3Message: Sendable {
    public enum Part: Sendable {
        case text(String)
        case audio([Float])
    }

    public enum Role: String, Sendable {
        case system, user, assistant
    }

    public var role: Role
    public var parts: [Part]

    public init(role: Role, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    public init(role: Role, text: String) {
        self.init(role: role, parts: [.text(text)])
    }
}

public struct PreparedPrompt: Sendable {
    public var tokenIDs: [Int]
    public var clips: [[Float]]
}

public struct PromptBuilder: Sendable {
    public static let audioMarker = "<|audio|>"
    static let beginning = "<|startoftext|>"

    let tokenizer: BPETokenizer
    let audioTokenID: Int

    public init(tokenizer: BPETokenizer, audioTokenID: Int) {
        self.tokenizer = tokenizer
        self.audioTokenID = audioTokenID
    }

    public static func render(_ messages: [LFM3Message], addGenerationPrompt: Bool = true) -> String {
        var items = messages
        var output = beginning
        if let first = items.first, first.role == .system {
            let system = content(first).trimmingCharacters(in: .whitespacesAndNewlines)
            if !system.isEmpty { output += "<|im_start|>system\n\(system)<|im_end|>\n" }
            items.removeFirst()
        }
        let lastUser = items.lastIndex { $0.role == .user } ?? -1
        for (index, message) in items.enumerated() {
            output += "<|im_start|>\(message.role.rawValue)\n"
            var body = content(message)
            if message.role == .assistant {
                if index <= lastUser, let range = body.range(of: "</think>", options: .backwards) {
                    body = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            output += body + "<|im_end|>\n"
        }
        if addGenerationPrompt { output += "<|im_start|>assistant\n" }
        return output
    }

    private static func content(_ message: LFM3Message) -> String {
        message.parts.map { part -> String in
            switch part {
            case .text(let text): return text
            case .audio: return audioMarker
            }
        }.joined()
    }

    public func prepare(_ messages: [LFM3Message]) throws -> PreparedPrompt {
        let clips = messages.flatMap { $0.parts.compactMap { part -> [Float]? in
            if case .audio(let samples) = part { return samples }
            return nil
        } }
        for clip in clips where clip.isEmpty || !clip.allSatisfy(\.isFinite) {
            throw LFM3Error.invalidInput("audio must be a nonempty waveform of finite samples")
        }
        let encoded = try tokenizer.encode(Self.render(messages))
        var counts = clips.map { LogMel.encoderTokenCount(frames: LogMel.frameCount(samples: $0.count)) }
        counts.reverse()
        var ids = [Int]()
        for id in encoded {
            if id == audioTokenID {
                guard let count = counts.popLast() else { throw LFM3Error.invalidInput("more placeholders than clips") }
                ids.append(contentsOf: Array(repeating: id, count: count))
            } else {
                ids.append(id)
            }
        }
        guard counts.isEmpty else { throw LFM3Error.invalidInput("clip without a placeholder") }
        return PreparedPrompt(tokenIDs: ids, clips: clips)
    }
}
