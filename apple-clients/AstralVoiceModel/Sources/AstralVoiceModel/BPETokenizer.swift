// An exact byte-level BPE tokenizer for the LFM3 tokenizer.json: added-token splitting, the model's pre-tokenizer regex, merge ranks with ignore-merges, and byte-level decoding.
// PromptBuilder encodes chat prompts with it and LFM3AudioEngine decodes generated token ids into text deltas.

import Foundation

public struct BPETokenizer: Sendable {
    private struct MergeEntry {
        let rank: Int32
        let merged: Int32
    }

    private let vocabulary: [String: Int32]
    private let tokens: [String]
    private let merges: [UInt64: MergeEntry]
    private let addedTokens: [String: Int32]
    private let specialIDs: Set<Int32>
    private let addedPattern: NSRegularExpression?
    private let splitPattern: NSRegularExpression
    private let byteToScalar: [UInt8: Character]
    private let scalarToByte: [Character: UInt8]

    public init(contentsOf url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            let model = root["model"] as? [String: Any], let rawVocabulary = model["vocab"] as? [String: Int],
            let rawMerges = model["merges"] as? [Any]
        else { throw LFM3Error.modelFiles("tokenizer.json is malformed") }
        var vocabulary = [String: Int32](minimumCapacity: rawVocabulary.count)
        var size = 0
        for (token, id) in rawVocabulary {
            vocabulary[token] = Int32(id)
            size = max(size, id + 1)
        }
        var added = [String: Int32]()
        var special = Set<Int32>()
        for entry in root["added_tokens"] as? [[String: Any]] ?? [] {
            guard let content = entry["content"] as? String, let id = entry["id"] as? Int else { continue }
            added[content] = Int32(id)
            size = max(size, id + 1)
            if entry["special"] as? Bool == true { special.insert(Int32(id)) }
        }
        var tokens = [String](repeating: "", count: size)
        for (token, id) in vocabulary { tokens[Int(id)] = token }
        for (token, id) in added { tokens[Int(id)] = token }
        var merges = [UInt64: MergeEntry](minimumCapacity: rawMerges.count)
        for (rank, raw) in rawMerges.enumerated() {
            let pair: [String]
            if let text = raw as? String {
                pair = text.split(separator: " ", maxSplits: 1).map(String.init)
            } else if let parts = raw as? [String] {
                pair = parts
            } else {
                continue
            }
            guard pair.count == 2, let a = vocabulary[pair[0]], let b = vocabulary[pair[1]],
                let merged = vocabulary[pair[0] + pair[1]]
            else { continue }
            merges[Self.key(a, b)] = MergeEntry(rank: Int32(rank), merged: merged)
        }
        guard let pretokenizer = root["pre_tokenizer"] as? [String: Any],
            let splitter = (pretokenizer["pretokenizers"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "Split" }),
            let pattern = (splitter["pattern"] as? [String: Any])?["Regex"] as? String
        else { throw LFM3Error.modelFiles("tokenizer pre-tokenizer is unsupported") }
        self.vocabulary = vocabulary
        self.tokens = tokens
        self.merges = merges
        addedTokens = added
        specialIDs = special
        splitPattern = try NSRegularExpression(pattern: pattern)
        let ordered = added.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        addedPattern = ordered.isEmpty ? nil : try NSRegularExpression(pattern: ordered.joined(separator: "|"))
        var forward = [UInt8: Character]()
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var extra = 0
        var table = [Int: Int]()
        for byte in printable { table[byte] = byte }
        for byte in 0..<256 where table[byte] == nil {
            table[byte] = 256 + extra
            extra += 1
        }
        printable = []
        for (byte, scalar) in table { forward[UInt8(byte)] = Character(UnicodeScalar(scalar)!) }
        byteToScalar = forward
        scalarToByte = Dictionary(uniqueKeysWithValues: forward.map { ($0.value, $0.key) })
    }

    public var vocabularySize: Int { tokens.count }

    public func tokenID(for token: String) -> Int? {
        (addedTokens[token] ?? vocabulary[token]).map(Int.init)
    }

    public func encode(_ text: String) throws -> [Int] {
        var ids = [Int]()
        let ns = text as NSString
        var cursor = 0
        let matches = addedPattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        for match in matches {
            if match.range.location > cursor {
                try encodeSegment(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), into: &ids)
            }
            ids.append(Int(addedTokens[ns.substring(with: match.range)]!))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { try encodeSegment(ns.substring(from: cursor), into: &ids) }
        return ids
    }

    public func decode(_ ids: [Int], skipSpecial: Bool = true) -> String {
        var bytes = [UInt8]()
        for id in ids where id >= 0 && id < tokens.count {
            if skipSpecial, specialIDs.contains(Int32(id)) { continue }
            for scalar in tokens[id] {
                if let byte = scalarToByte[scalar] {
                    bytes.append(byte)
                } else {
                    bytes.append(contentsOf: Array(String(scalar).utf8))
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func encodeSegment(_ text: String, into ids: inout [Int]) throws {
        let ns = text as NSString
        var cursor = 0
        var pieces = [String]()
        for match in splitPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            pieces.append(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { pieces.append(ns.substring(from: cursor)) }
        for piece in pieces where !piece.isEmpty { try encodePiece(piece, into: &ids) }
    }

    private func encodePiece(_ piece: String, into ids: inout [Int]) throws {
        let mapped = String(piece.utf8.map { byteToScalar[$0]! })
        if let whole = vocabulary[mapped] {
            ids.append(Int(whole))
            return
        }
        var symbols = [Int32]()
        for scalar in mapped {
            guard let id = vocabulary[String(scalar)] else {
                throw LFM3Error.invalidInput("character outside the tokenizer alphabet")
            }
            symbols.append(id)
        }
        while symbols.count > 1 {
            var best: (index: Int, entry: MergeEntry)?
            for index in 0..<(symbols.count - 1) {
                if let entry = merges[Self.key(symbols[index], symbols[index + 1])],
                    best == nil || entry.rank < best!.entry.rank
                {
                    best = (index, entry)
                }
            }
            guard let best else { break }
            symbols.replaceSubrange(best.index...(best.index + 1), with: [best.entry.merged])
        }
        ids.append(contentsOf: symbols.map(Int.init))
    }

    private static func key(_ a: Int32, _ b: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b))
    }
}
