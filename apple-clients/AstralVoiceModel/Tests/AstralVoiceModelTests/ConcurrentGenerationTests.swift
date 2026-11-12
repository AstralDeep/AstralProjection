// Checks that speech generation leaves the engine available for microphone recognition and cancellation.
// Tiny saved model files exercise the same loading and generation APIs as a downloaded model without network access.

import MLX
import XCTest

@testable import AstralVoiceModel

final class ConcurrentGenerationTests: XCTestCase {
    func testInterleavedRequestsKeepCachesAndRandomSamplingIndependent() throws {
        MLXRandom.seed(11)
        let model = LFM3AudioModel(try TinyModel.configuration())
        eval(model)
        var a = GenerationOptions()
        a.seed = 3
        a.maxNewTokens = 12
        a.text = SamplerSettings(temperature: 0.8, topK: 8)
        var b = a
        b.seed = 19
        func drain(_ cursor: LFM3AudioModel.GenerationCursor) throws -> [Int] {
            var tokens: [Int] = []
            while let slot = try cursor.next() { tokens.append(slot.token) }
            return tokens
        }
        let expectedA = try drain(model.generation(ids: [1, 5, 6], features: nil, mode: .text, options: a))
        let expectedB = try drain(model.generation(ids: [8, 7, 6], features: nil, mode: .text, options: b))
        let first = try model.generation(ids: [1, 5, 6], features: nil, mode: .text, options: a)
        let second = try model.generation(ids: [8, 7, 6], features: nil, mode: .text, options: b)
        var actualA: [Int] = []
        var actualB: [Int] = []
        for _ in 0..<12 {
            MLXRandom.seed(999)
            if let slot = try first.next() { actualA.append(slot.token) }
            if let slot = try second.next() { actualB.append(slot.token) }
        }
        XCTAssertEqual(actualA, expectedA)
        XCTAssertEqual(actualB, expectedB)
    }

    func testRecognitionCompletesAndSpeechCancelsBeforeSynthesisDrains() async throws {
        let directory = try TinyModel.writeEngineDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try LFM3AudioEngine(directory: directory)
        let probe = AudioChunkProbe()
        let (chunks, continuation) = AsyncStream<Void>.makeStream()
        var speechOptions = LFM3Sampling()
        speechOptions.maxNewTokens = 128
        speechOptions.audioTemperature = 0
        speechOptions.audioTopK = 0
        let speech = Task {
            try await engine.synthesize(
                text: "Please read this reply.", options: speechOptions,
                handlers: LFM3Handlers(onAudio: { _ in
                    if probe.append() == 1 { continuation.yield(()) }
                }))
        }
        defer {
            speech.cancel()
            continuation.finish()
        }
        for await _ in chunks { break }
        var recognitionOptions = LFM3Sampling()
        recognitionOptions.maxNewTokens = 2
        _ = try await engine.transcribe(audio: [Float](repeating: 0.1, count: 4_000), options: recognitionOptions)
        speech.cancel()
        do {
            _ = try await speech.value
            XCTFail("Recognition must enter while speech is still cancellable.")
        } catch is CancellationError {
        }
        XCTAssertLessThan(probe.count, 33)
    }
}

private final class AudioChunkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = 0
    var count: Int { lock.withLock { chunks } }
    func append() -> Int {
        lock.withLock {
            chunks += 1
            return chunks
        }
    }
}

extension TinyModel {
    static func writeEngineDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-engine-\(UUID().uuidString)")
        let codecDirectory = root.appendingPathComponent("audio_tokenizer")
        try FileManager.default.createDirectory(at: codecDirectory, withIntermediateDirectories: true)
        let text: [String: Any] = [
            "vocab_size": 512, "hidden_size": 32, "intermediate_size": 64, "num_hidden_layers": 2,
            "num_attention_heads": 4, "num_key_value_heads": 2, "head_dim": 8, "conv_L_cache": 3,
            "layer_types": ["conv", "full_attention"], "use_sandwich_norm": true,
        ]
        let encoder: [String: Any] = [
            "dim_in": 128, "dim_conv": 8, "dim_out": 16, "sliding_window": 4,
            "lfm": [
                "model_type": "lfm2", "vocab_size": 2, "hidden_size": 16, "intermediate_size": 32,
                "num_hidden_layers": 2, "num_attention_heads": 2, "num_key_value_heads": 1,
                "head_dim": 8, "conv_L_cache": 3, "layer_types": ["conv", "full_attention"], "use_sandwich_norm": false,
            ],
        ]
        let depth: [String: Any] = [
            "vocab_size": 1, "hidden_size": 16, "intermediate_size": 32, "num_hidden_layers": 1,
            "num_attention_heads": 2, "num_key_value_heads": 1, "head_dim": 8,
            "layer_types": ["full_attention"], "use_sandwich_norm": false,
        ]
        let object: [String: Any] = [
            "lfm": text, "encoder": encoder, "depthformer": depth,
            "codebooks": 3, "audio_vocab_size": 10, "maskgit_steps": 2,
            "audio_token_id": 502, "audio_out_token_id": 503, "audio_start_token_id": 504,
            "text_end_token_id": 505, "mixed_start_token_id": 506, "eos_token_id": [507],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: root.appendingPathComponent("config.json"))
        try tokenizerJSON().write(to: root.appendingPathComponent("tokenizer.json"))
        MLXRandom.seed(11)
        let model = LFM3AudioModel(try ModelConfiguration.decode(data))
        var arrays = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        for (key, value) in arrays where key.hasPrefix("depth_decoder.") { arrays[key] = MLXArray.zeros(like: value) }
        try save(arrays: arrays, url: root.appendingPathComponent("model.safetensors"))
        let codecObject: [String: Any] = [
            "encoder_dim": 16, "quantizer_dim": 8, "fsq_levels": [4, 3, 2, 2], "n_q": 3,
            "stft_n_fft": 16, "stft_hop_length": 4, "stft_frame_stack": 2, "decoder_window": 6,
        ]
        try JSONSerialization.data(withJSONObject: codecObject).write(
            to: codecDirectory.appendingPathComponent("config.json"))
        let codec = LiquidCodec(try CodecConfiguration.load(from: codecDirectory.appendingPathComponent("config.json")))
        codec.decoder.istft.window = MLXArray((0..<16).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 16)) })
        try save(
            arrays: Dictionary(uniqueKeysWithValues: codec.parameters().flattened()),
            url: codecDirectory.appendingPathComponent("model.safetensors"))
        return root
    }
}
