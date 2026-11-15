// Builds tiny random-weight model, codec and tokenizer fixtures so unit tests exercise the full code paths without the real weights.
// The tiny configuration mirrors the real layer types: conv, full attention and sliding attention in the language model, an LFM2 encoder, a gated depth decoder and a sliding-window codec.

import Foundation
import XCTest

@testable import AstralVoiceModel

enum TinyModel {
    static let textVocab = 64

    static func configuration(quantized: Bool = false) throws -> ModelConfiguration {
        let text = BackboneConfiguration(
            vocabSize: textVocab, hiddenSize: 32, intermediateSize: 64, layerCount: 4, attentionHeads: 4,
            keyValueHeads: 2, headDim: 8, convKernel: 3, layerTypes: ["conv", "full_attention", "sliding_attention", "conv"],
            slidingWindow: 5, sandwichNorm: true)
        let encoderBackbone = BackboneConfiguration(
            modelType: "lfm2", vocabSize: 2, hiddenSize: 16, intermediateSize: 32, layerCount: 2, attentionHeads: 2,
            keyValueHeads: 1, convKernel: 3, layerTypes: ["conv", "full_attention"], sandwichNorm: false,
            fullAttentionRope: RopeSettings(ropeTheta: 10_000, partialRotaryFactor: 1), blockMultipleOf: 8)
        let depth = BackboneConfiguration(
            vocabSize: 1, hiddenSize: 16, intermediateSize: 32, layerCount: 1, attentionHeads: 2, keyValueHeads: 1,
            headDim: 8, convKernel: 3, layerTypes: ["full_attention"], sandwichNorm: false,
            fullAttentionRope: RopeSettings(ropeTheta: 10_000, partialRotaryFactor: 1))
        return try ModelConfiguration(
            text: text,
            encoder: EncoderConfiguration(melBins: 16, convChannels: 8, hiddenSize: 16, slidingWindow: 4, backbone: encoderBackbone),
            depth: depth, codebooks: 3, codebookSize: 10, maskgitSchedule: [1, 2], interleavedText: 2, interleavedAudio: 3,
            audioTokenID: 60, audioOutTokenID: 61, audioStartTokenID: 57, textEndTokenID: 58, mixedStartTokenID: 59,
            eosTokenIDs: [2], quantization: quantized ? .init(groupSize: 32, bits: 4) : nil)
    }

    static func codecConfiguration() -> CodecConfiguration {
        var config = CodecConfiguration()
        config.encoderDim = 16
        config.quantizerDim = 8
        config.fsqLevels = [4, 3, 2, 2]
        config.quantizerCount = 3
        config.fftSize = 16
        config.hop = 4
        config.frameStack = 2
        config.decoderWindow = 6
        return config
    }

    static func tokenizerJSON() -> Data {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var table = [Int: Int]()
        for byte in bytes { table[byte] = byte }
        var extra = 0
        for byte in 0..<256 where table[byte] == nil {
            table[byte] = 256 + extra
            extra += 1
        }
        bytes = Array(0..<256)
        var vocab = [String: Int]()
        for byte in bytes { vocab[String(UnicodeScalar(table[byte]!)!)] = vocab.count }
        let merges = ["h e", "l l", "he ll", "hell o", "\u{120} w", "\u{120}w o"]
        var next = vocab.count
        for merge in merges {
            let joined = merge.replacingOccurrences(of: " ", with: "")
            if vocab[joined] == nil {
                vocab[joined] = next
                next += 1
            }
        }
        vocab["hello"] = vocab["hell"].map { _ in next } ?? next
        let tokenizer: [String: Any] = [
            "added_tokens": [
                ["id": 500, "content": "<|im_start|>", "special": true],
                ["id": 501, "content": "<|im_end|>", "special": true],
                ["id": 502, "content": "<|audio|>", "special": true],
            ],
            "pre_tokenizer": [
                "type": "Sequence",
                "pretokenizers": [
                    [
                        "type": "Split",
                        "pattern": ["Regex": "[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s+"],
                        "behavior": "Isolated",
                    ]
                ],
            ],
            "model": ["type": "BPE", "vocab": vocab, "merges": merges],
        ]
        return try! JSONSerialization.data(withJSONObject: tokenizer)
    }

    static func writeTokenizer() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiny-tokenizer-\(UUID().uuidString).json")
        try tokenizerJSON().write(to: url)
        return url
    }
}
