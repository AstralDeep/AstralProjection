// Unit tests for configuration decoding, the BPE tokenizer, prompt rendering, mel features, sampling, the generation loop and the streaming codec using tiny random weights.
// They need a Metal device but no downloaded model, so they always run under xcodebuild test.

import MLX
import XCTest

@testable import AstralVoiceModel

final class ConfigurationTests: XCTestCase {
    func testScheduleSplitsCodebooksAndRemainderGoesLast() throws {
        XCTAssertEqual(ModelConfiguration.schedule(codebooks: 12, steps: 3), [4, 4, 4])
        XCTAssertEqual(ModelConfiguration.schedule(codebooks: 13, steps: 3), [4, 4, 5])
    }

    func testInvalidScheduleAndEndCodeAreRejected() throws {
        let tiny = try TinyModel.configuration()
        XCTAssertThrowsError(
            try ModelConfiguration(text: tiny.text, encoder: tiny.encoder, depth: tiny.depth, codebooks: 3, codebookSize: 10, maskgitSchedule: [1, 1]))
        XCTAssertThrowsError(
            try ModelConfiguration(text: tiny.text, encoder: tiny.encoder, depth: tiny.depth, codebooks: 3, codebookSize: 10, audioEOSCode: 10))
    }

    func testDecodesRealConfigShape() throws {
        let json = """
            {"audio_vocab_size":2017,"codebooks":12,"maskgit_steps":3,"quantization":{"group_size":64,"bits":3,"mode":"affine"},
            "eos_token_id":[124900,125014],
            "lfm":{"vocab_size":128000,"hidden_size":2048,"intermediate_size":7680,"num_hidden_layers":24,"num_attention_heads":16,
            "num_key_value_heads":4,"head_dim":128,"conv_L_cache":7,"use_sandwich_norm":true,"tie_word_embeddings":true,
            "rope_parameters":{"full_attention":{"partial_rotary_factor":0.5,"rope_theta":1000000.0,"rope_type":"default"},
            "sliding_attention":{"rope_theta":10000,"rope_type":"default"}}},
            "encoder":{"dim_in":128,"dim_conv":256,"dim_out":768,"sliding_window":32,"lfm":{"vocab_size":2,"hidden_size":768,
            "intermediate_size":2560,"num_hidden_layers":17,"num_attention_heads":8,"num_key_value_heads":4,"conv_L_cache":3,
            "rope_parameters":{"rope_theta":1000000.0,"rope_type":"default"},"model_type":"lfm2"}},
            "depthformer":{"hidden_size":1024}}
            """
        let config = try ModelConfiguration.decode(Data(json.utf8))
        XCTAssertEqual(config.text.layerCount, 24)
        XCTAssertEqual(config.text.layerTypes[4], "sliding_attention")
        XCTAssertEqual(config.text.fullAttentionRope.partialRotaryFactor, 0.5)
        XCTAssertEqual(config.text.slidingAttentionRope.ropeTheta, 10_000)
        XCTAssertEqual(config.encoder.backbone.feedForwardDim, 1792)
        XCTAssertEqual(config.encoder.backbone.layerTypes.count, 17)
        XCTAssertEqual(config.depth.hiddenSize, 1024)
        XCTAssertEqual(config.depth.layerCount, 3)
        XCTAssertEqual(config.maskgitSchedule, [4, 4, 4])
        XCTAssertEqual(config.eosTokenIDs, [124_900, 125_014])
        XCTAssertEqual(config.quantization, ModelConfiguration.QuantizationSettings(groupSize: 64, bits: 3))
    }

    func testUnsupportedQuantizationModeIsRejected() throws {
        let json = #"{"quantization":{"group_size":64,"bits":4,"mode":"mxfp4"},"lfm":{"vocab_size":8,"hidden_size":16,"intermediate_size":32,"num_hidden_layers":1,"num_attention_heads":2}}"#
        XCTAssertThrowsError(try ModelConfiguration.decode(Data(json.utf8)))
        XCTAssertThrowsError(try ModelConfiguration.decode(Data("[]".utf8)))
    }

    func testCodecConfigurationRejectsMismatchedWindow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codec-\(UUID().uuidString).json")
        try Data(#"{"stft_n_fft":1280,"stft_win_length":640,"stft_hop_length":320}"#.utf8).write(to: url)
        XCTAssertThrowsError(try CodecConfiguration.load(from: url))
        XCTAssertEqual(CodecConfiguration().codebookSize, 2016)
        XCTAssertEqual(CodecConfiguration().samplesPerFrame, 1920)
    }
}

final class TokenizerAndPromptTests: XCTestCase {
    func testMergesAndRoundTrip() throws {
        let tokenizer = try BPETokenizer(contentsOf: try TinyModel.writeTokenizer())
        let ids = try tokenizer.encode("hello world")
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(tokenizer.decode(ids), "hello world")
        XCTAssertEqual(tokenizer.decode(try tokenizer.encode("naïve 日本 \n x")), "naïve 日本 \n x")
    }

    func testAddedTokensAreSingleIdsAndSpecialsAreSkippedOnDecode() throws {
        let tokenizer = try BPETokenizer(contentsOf: try TinyModel.writeTokenizer())
        let ids = try tokenizer.encode("<|im_start|>user\nhi<|im_end|>")
        XCTAssertEqual(ids.first, 500)
        XCTAssertEqual(ids.last, 501)
        XCTAssertEqual(tokenizer.decode(ids), "user\nhi")
        XCTAssertEqual(tokenizer.tokenID(for: "<|audio|>"), 502)
    }

    func testMalformedTokenizerIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        XCTAssertThrowsError(try BPETokenizer(contentsOf: url))
    }

    func testTemplateRendersSystemUserAssistantAndGenerationPrompt() {
        let text = PromptBuilder.render([
            LFM3Message(role: .system, text: "  Be brief. "), LFM3Message(role: .user, text: " Hi "),
            LFM3Message(role: .assistant, text: "<think>x</think> Hello"), LFM3Message(role: .user, parts: [.audio([0.1]), .text("now")]),
        ])
        XCTAssertEqual(
            text,
            "<|startoftext|><|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\nHello<|im_end|>\n<|im_start|>user\n<|audio|>now<|im_end|>\n<|im_start|>assistant\n")
        XCTAssertFalse(PromptBuilder.render([LFM3Message(role: .user, text: "a")], addGenerationPrompt: false).hasSuffix("assistant\n"))
        XCTAssertFalse(PromptBuilder.render([LFM3Message(role: .system, text: "  "), LFM3Message(role: .user, text: "a")]).contains("system"))
    }

    func testPlaceholdersExpandToEncoderFrameCounts() throws {
        let tokenizer = try BPETokenizer(contentsOf: try TinyModel.writeTokenizer())
        let builder = PromptBuilder(tokenizer: tokenizer, audioTokenID: 502)
        let samples = [Float](repeating: 0.1, count: 16_000)
        let prepared = try builder.prepare([LFM3Message(role: .user, parts: [.audio(samples)])])
        let expected = LogMel.encoderTokenCount(frames: LogMel.frameCount(samples: 16_000))
        XCTAssertEqual(prepared.tokenIDs.filter { $0 == 502 }.count, expected)
        XCTAssertEqual(expected, 13)
        XCTAssertThrowsError(try builder.prepare([LFM3Message(role: .user, parts: [.audio([])])]))
        XCTAssertThrowsError(try builder.prepare([LFM3Message(role: .user, parts: [.audio([Float.nan])])]))
    }
}

final class SignalTests: XCTestCase {
    func testFrameCountFollowsReferencePadding() {
        XCTAssertEqual(LogMel.frameCount(samples: 400), 1)
        XCTAssertEqual(LogMel.frameCount(samples: 100), 1)
        XCTAssertEqual(LogMel.frameCount(samples: 401), 2)
        XCTAssertEqual(LogMel.frameCount(samples: 16_000), 99)
        XCTAssertEqual(LogMel.encoderTokenCount(frames: 99), 13)
    }

    func testSilenceHitsTheLogFloorAndToneHasEnergy() {
        let silence = LogMel.features([Float](repeating: 0, count: 1_600))
        XCTAssertEqual(silence.values.count, LogMel.melBins * silence.frames)
        XCTAssertTrue(silence.values.allSatisfy { $0 == -2 })
        let tone = (0..<1_600).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        let features = LogMel.features(tone)
        XCTAssertGreaterThan(features.values.max() ?? 0, 0)
    }

    func testGreedySamplingAppliesRepetitionPenaltyAndSuppression() {
        let logits = MLXArray([Float](arrayLiteral: 1, 5, 4.9, 0)).reshaped(1, 4)
        XCTAssertEqual(sampleToken(logits, settings: SamplerSettings(temperature: 0)).item(Int.self), 1)
        let history = MLXArray([Int32(1)]).reshaped(1, 1)
        let penalized = sampleToken(logits, settings: SamplerSettings(temperature: 0, repetitionPenalty: 2), history: history)
        XCTAssertEqual(penalized.item(Int.self), 2)
        let suppress = MLXArray([Float(0), -Float.infinity, 0, 0])
        XCTAssertEqual(sampleToken(logits, settings: SamplerSettings(temperature: 0), suppress: suppress).item(Int.self), 2)
    }

    func testTopKRestrictsAndSeedMakesSamplingRepeatable() {
        let logits = MLXArray([Float](arrayLiteral: 0, 3, 2, 1, -1, -2)).reshaped(1, 6)
        for seed in 0..<20 {
            MLXRandom.seed(UInt64(seed))
            let token = sampleToken(logits, settings: SamplerSettings(temperature: 1, topK: 2)).item(Int.self)
            XCTAssertTrue([1, 2].contains(token))
        }
        MLXRandom.seed(5)
        let first = sampleToken(logits, settings: SamplerSettings(temperature: 1)).item(Int.self)
        MLXRandom.seed(5)
        XCTAssertEqual(sampleToken(logits, settings: SamplerSettings(temperature: 1)).item(Int.self), first)
        let nucleus = applyTopP(log(softmax(logits, axis: -1)), 0.5)
        XCTAssertTrue(nucleus[0, 1].item(Float.self).isFinite)
        XCTAssertEqual(nucleus[0, 5].item(Float.self), -Float.infinity)
    }

    func testFramesAreNormalizedToAllEndCodeAndEmbeddedBySummingCodebooks() {
        let codes = MLXArray([Int32(3), 9, 4]).reshaped(1, 3)
        XCTAssertEqual(normalizeEOS(codes, eos: 9).asArray(Int32.self), [9, 9, 9])
        XCTAssertEqual(normalizeEOS(codes, eos: 8).asArray(Int32.self), [3, 9, 4])
    }
}

final class GenerationLoopTests: XCTestCase {
    private func model(quantized: Bool = false) throws -> LFM3AudioModel {
        MLXRandom.seed(11)
        let model = LFM3AudioModel(try TinyModel.configuration(quantized: quantized))
        eval(model)
        return model
    }

    private func collect(_ model: LFM3AudioModel, ids: [Int], mode: GenerationMode?, max: Int, order: [[Int]]? = nil, stopAfter: Int = .max) throws -> [GeneratedSlot] {
        var options = GenerationOptions()
        options.maxNewTokens = max
        options.seed = 3
        options.frameOrder = order
        var slots = [GeneratedSlot]()
        try model.streamSlots(ids: ids, features: nil, mode: mode, options: options) { slot in
            slots.append(slot)
            return slots.count < stopAfter
        }
        return slots
    }

    func testTextModeStopsAtMaxTokensAndNeverEmitsSuppressedTokens() throws {
        let slots = try collect(try model(), ids: [1, 5, 6, 7], mode: .text, max: 12)
        XCTAssertLessThanOrEqual(slots.count, 12)
        XCTAssertFalse(slots.isEmpty)
        XCTAssertTrue(slots.allSatisfy { $0.codes == nil })
        XCTAssertTrue(slots.allSatisfy { ![60, 61, 59, 57].contains($0.token) })
    }

    func testQuantizedLanguageModelRunsTheSameLoop() throws {
        let slots = try collect(try model(quantized: true), ids: [1, 5, 6], mode: .text, max: 6)
        XCTAssertFalse(slots.isEmpty)
    }

    func testGreedyTextIsDeterministic() throws {
        let model = try model()
        var options = GenerationOptions()
        options.maxNewTokens = 8
        var first = [Int](), second = [Int]()
        try model.streamSlots(ids: [1, 5, 6], features: nil, mode: .text, options: options) { first.append($0.token); return true }
        try model.streamSlots(ids: [1, 5, 6], features: nil, mode: .text, options: options) { second.append($0.token); return true }
        XCTAssertEqual(first, second)
    }

    func testAudioModeEmitsFramesOfValidCodesAndHonorsFrameOrder() throws {
        let order = (0..<8).map { _ in [2, 0, 1] }
        let slots = try collect(try model(), ids: [1, 5, 6], mode: .audio, max: 8, order: order)
        let frames = slots.compactMap(\.codes)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.allSatisfy { $0.count == 3 && $0.allSatisfy { (0...9).contains($0) } })
        XCTAssertTrue(slots.filter { $0.codes != nil }.allSatisfy { $0.token == 61 })
    }

    func testInterleavedModeAlternatesTextAndSpeechBlocks() throws {
        let slots = try collect(try model(), ids: [1, 5, 6], mode: .interleaved, max: 20)
        XCTAssertFalse(slots.isEmpty)
        XCTAssertNil(slots.first?.codes, "interleaving starts with a text block")
    }

    func testCallbackCanStopGenerationAndCancellationThrows() throws {
        let model = try model()
        XCTAssertEqual(try collect(model, ids: [1, 5], mode: .text, max: 50, stopAfter: 3).count, 3)
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try self.collect(model, ids: [1, 5], mode: .text, max: 50)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let cancelled = expectation(description: "cancelled")
        Task {
            if await task.value { cancelled.fulfill() }
        }
        wait(for: [cancelled], timeout: 30)
    }

    func testInvalidInputsAreRejected() throws {
        let model = try model()
        XCTAssertThrowsError(try collect(model, ids: [], mode: .text, max: 4))
        XCTAssertThrowsError(try collect(model, ids: [1, 60, 6], mode: .text, max: 4), "placeholder without audio")
        XCTAssertThrowsError(try collect(model, ids: [1, 61, 6], mode: .text, max: 4), "speech history")
        XCTAssertThrowsError(try collect(model, ids: [1], mode: .text, max: 0))
    }

    func testAudioFeaturesFillPlaceholders() throws {
        let model = try model()
        let mel = LogMel.features([Float](repeating: 0.2, count: 3_200))
        let wide = (0..<16).flatMap { bin in Array(mel.values[(bin * mel.frames)..<((bin + 1) * mel.frames)]) }
        let features = MLXArray(wide, [1, 16, mel.frames])
        let count = LogMel.encoderTokenCount(frames: mel.frames)
        var ids = [1, 5]
        ids += Array(repeating: 60, count: count)
        ids.append(6)
        var options = GenerationOptions()
        options.maxNewTokens = 4
        var produced = 0
        try model.streamSlots(ids: ids, features: features, mode: .text, options: options) { _ in produced += 1; return true }
        XCTAssertGreaterThan(produced, 0)
        XCTAssertThrowsError(try model.streamSlots(ids: ids + [60], features: features, mode: .text, options: options) { _ in true })
    }
}

final class CodecTests: XCTestCase {
    private func codec() -> LiquidCodec {
        MLXRandom.seed(21)
        let codec = LiquidCodec(TinyModel.codecConfiguration())
        codec.decoder.istft.window = MLXArray((0..<16).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 16)) })
        eval(codec)
        return codec
    }

    private func randomCodes(_ frames: Int) -> [[Int32]] {
        (0..<frames).map { f in (0..<3).map { Int32((f * 7 + $0 * 5) % 48) } }
    }

    func testDecodeProducesSamplesPerFrameAndRejectsBadCodes() throws {
        let codec = codec()
        let frames = randomCodes(5)
        let codes = MLXArray(frames.flatMap { $0 }, [5, 3]).transposed(1, 0)
        XCTAssertEqual(try codec.decode(codes: codes).dim(0), 5 * 8)
        XCTAssertEqual(try codec.decode(codes: MLXArray.zeros([3, 0], type: Int32.self)).dim(0), 0)
        XCTAssertThrowsError(try codec.decode(codes: MLXArray([Int32(48), 0, 0]).reshaped(3, 1)))
        XCTAssertThrowsError(try codec.decode(codes: MLXArray([Int32(-1), 0, 0]).reshaped(3, 1)))
        XCTAssertThrowsError(try codec.decode(codes: MLXArray.zeros([2, 4], type: Int32.self)))
    }

    func testChunkedStreamingEqualsWholeDecodeWhenContextCoversEverything() throws {
        let codec = codec()
        let frames = randomCodes(11)
        let whole = try codec.decode(codes: MLXArray(frames.flatMap { $0 }, [11, 3]).transposed(1, 0))
        let expected = whole.asArray(Float.self)
        let streamer = StreamingCodecDecoder(codec: codec, contextFrames: 100)
        var pieces = [Float]()
        for (index, frame) in frames.enumerated() {
            streamer.append(frame)
            if (index + 1) % 3 == 0, index < frames.count - 1 { pieces += try streamer.flush(final: false) }
        }
        pieces += try streamer.flush(final: true)
        XCTAssertEqual(pieces.count, expected.count)
        let worst = zip(pieces, expected).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(worst, 1e-3)
    }

    func testStreamingWithShortContextStaysCloseToWholeDecode() throws {
        let codec = codec()
        let frames = randomCodes(30)
        let whole = try codec.decode(codes: MLXArray(frames.flatMap { $0 }, [30, 3]).transposed(1, 0)).asArray(Float.self)
        let streamer = StreamingCodecDecoder(codec: codec, contextFrames: 20)
        var pieces = [Float]()
        for (index, frame) in frames.enumerated() {
            streamer.append(frame)
            if (index + 1) % 4 == 0 { pieces += try streamer.flush(final: index == frames.count - 1) }
        }
        pieces += try streamer.flush(final: true)
        XCTAssertEqual(pieces.count, whole.count)
        let scale = whole.map(abs).max() ?? 1
        let worst = zip(pieces, whole).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(worst, 0.05 * scale)
    }

    func testEmptyStreamerFlushesNothing() throws {
        XCTAssertEqual(try StreamingCodecDecoder(codec: codec()).flush(final: true), [])
    }
}

final class LayerCacheTests: XCTestCase {
    func testSlidingCacheKeepsOnlyTheWindowDuringDecode() {
        let cache = LayerCache(window: 4)
        let first = cache.append(keys: MLXArray.zeros([1, 1, 6, 2]), values: MLXArray.zeros([1, 1, 6, 2]))
        XCTAssertEqual(first.0.dim(2), 6)
        let next = cache.append(keys: MLXArray.ones([1, 1, 1, 2]), values: MLXArray.ones([1, 1, 1, 2]))
        XCTAssertEqual(next.0.dim(2), 4)
        XCTAssertEqual(cache.offset, 7)
    }

    func testBandedMaskLimitsLookback() {
        guard case .array(let mask) = AttentionMask.banded(length: 6, window: 3) else { return XCTFail("expected array mask") }
        XCTAssertTrue(mask[5, 3].item(Bool.self))
        XCTAssertFalse(mask[5, 2].item(Bool.self))
        XCTAssertFalse(mask[2, 3].item(Bool.self))
        if case .causal = AttentionMask.banded(length: 3, window: 5) {} else { XCTFail("short sequences use plain causal") }
        if case .none = AttentionMask.banded(length: 1, window: 5) {} else { XCTFail("single token needs no mask") }
    }
}
