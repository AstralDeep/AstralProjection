// Turns the raw bytes of sampled tokens into text, holding back the tail of a multi-byte character until the next token completes it.
// SpeechRecognizer and TextGenerator feed every token piece through one and stream only whole characters.
import Foundation

struct Utf8Assembler {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        let complete = pending.count - incompleteTailLength(pending)
        guard complete > 0 else { return "" }
        let text = String(decoding: pending[0..<complete], as: UTF8.self)
        pending.removeFirst(complete)
        return text
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }

    private func incompleteTailLength(_ bytes: [UInt8]) -> Int {
        var back = 0
        var index = bytes.count - 1
        while index >= 0, back < 4 {
            let byte = bytes[index]
            back += 1
            if byte & 0xC0 == 0x80 {
                index -= 1
                continue
            }
            let expected = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return back < expected ? back : 0
        }
        return 0
    }
}
