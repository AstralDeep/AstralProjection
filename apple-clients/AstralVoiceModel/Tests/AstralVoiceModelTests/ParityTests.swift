// Compares the Swift port with the Python reference on a fixed WAV and fixed seeds: tokens, prompts, mel features, encoder rows, greedy ASR tokens, TTS code frames and codec samples.
// These tests need the real 3-bit weights and a Metal device, so run them with xcodebuild test on macOS.

import MLX
import XCTest

@testable import AstralVoiceModel

final class ParityTests: XCTestCase {
    private func assertClose(_ actual: [Float], _ expected: [Float], tolerance: Float, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, label, file: file, line: line)
        let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, tolerance, "\(label) worst difference \(worst)", file: file, line: line)
    }

    func testTokenizerMatchesReference() throws {
        let directory = try RealModel.require()
        let fixture = try ReferenceFixture.load()
        let tokenizer = try BPETokenizer(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        for entry in fixture.json["tokenizer"] as! [[String: Any]] {
            let text = entry["text"] as! String
            let expected = (entry["ids"] as! [NSNumber]).map(\.intValue)
            XCTAssertEqual(try tokenizer.encode(text), expected, "encoding of \(text)")
        }
        let decode = fixture.json["tokenizer_decode"] as! [String: Any]
        let ids = (decode["ids"] as! [NSNumber]).map(\.intValue)
        XCTAssertEqual(tokenizer.decode(ids), decode["text"] as? String)
    }

    func testPromptsMatchReferenceTemplate() throws {
        let directory = try RealModel.require()
        let fixture = try ReferenceFixture.load()
        let tokenizer = try BPETokenizer(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        let prompts = fixture.json["prompts"] as! [String: Any]
        let tts = PromptBuilder.render([
            LFM3Message(role: .system, text: "Perform TTS in English using a female voice."),
            LFM3Message(role: .user, text: "The patient is stable."),
        ])
        XCTAssertEqual(tts, prompts["tts"] as? String)
        XCTAssertEqual(try tokenizer.encode(tts), (prompts["tts_ids"] as! [NSNumber]).map(\.intValue))
        let chat = PromptBuilder.render([
            LFM3Message(role: .system, text: "Respond briefly."),
            LFM3Message(role: .user, text: "Say hello."),
            LFM3Message(role: .assistant, text: "Hello there."),
            LFM3Message(role: .user, text: "What is 2 plus 2?"),
        ])
        XCTAssertEqual(chat, prompts["chat"] as? String)
        XCTAssertEqual(try tokenizer.encode(chat), (prompts["chat_ids"] as! [NSNumber]).map(\.intValue))
        let builder = PromptBuilder(tokenizer: tokenizer, audioTokenID: 125_031)
        let prepared = try builder.prepare([
            LFM3Message(role: .system, text: "Perform ASR in English."),
            LFM3Message(role: .user, parts: [.audio(try ReferenceFixture.wavSamples())]),
        ])
        XCTAssertEqual(prepared.tokenIDs, fixture.ints("asr_prompt_ids"))
    }

    func testMelFeaturesMatchReference() throws {
        _ = try RealModel.require()
        let fixture = try ReferenceFixture.load()
        let samples = try ReferenceFixture.wavSamples()
        let mel = LogMel.features(samples)
        XCTAssertEqual(samples.count, fixture.value("mel", "samples") as Int)
        XCTAssertEqual([LogMel.melBins, mel.frames], fixture.ints("mel", "shape"))
        let head = (0..<3).flatMap { t in (0..<LogMel.melBins).map { mel.values[$0 * mel.frames + t] } }
        let tail = (0..<2).flatMap { t in (0..<LogMel.melBins).map { mel.values[$0 * mel.frames + mel.frames - 2 + t] } }
        assertClose(head, fixture.floats("mel", "head"), tolerance: 1e-4, "mel head")
        assertClose(tail, fixture.floats("mel", "tail"), tolerance: 1e-4, "mel tail")
        let sum = mel.values.reduce(0.0) { $0 + Double($1) }
        XCTAssertEqual(sum, fixture.value("mel", "sum") as Double, accuracy: 0.5)
    }

    func testEncoderAndProjectorMatchReference() async throws {
        let engine = try await RealModel.engine()
        let fixture = try ReferenceFixture.load()
        let samples = try ReferenceFixture.wavSamples()
        let mel = LogMel.features(samples)
        let features = MLXArray(mel.values, [1, LogMel.melBins, mel.frames])
        let model = engine.model
        let encoded = try model.audioTower(features)
        let projected = model.audioProjector(encoded)
        eval(encoded, projected)
        XCTAssertEqual(encoded.shape, fixture.ints("encoder", "shape"))
        let encoderRows = fixture.json["encoder"] as! [String: Any]
        let projectorRows = fixture.json["projector"] as! [String: Any]
        let indices = (encoderRows["row_indices"] as! [NSNumber]).map(\.intValue)
        for (slot, index) in indices.enumerated() {
            let expectedEncoder = ((encoderRows["rows"] as! [[NSNumber]])[slot]).map(\.floatValue)
            let actualEncoder = encoded[index, 0..<16].asType(.float32).asArray(Float.self)
            assertClose(actualEncoder, expectedEncoder, tolerance: 0.08, "encoder row \(index)")
            let expectedProjector = ((projectorRows["rows"] as! [[NSNumber]])[slot]).map(\.floatValue)
            let actualProjector = projected[index, 0..<16].asType(.float32).asArray(Float.self)
            assertClose(actualProjector, expectedProjector, tolerance: 0.15, "projector row \(index)")
        }
    }

    func testGreedyTranscriptionMatchesReference() async throws {
        let engine = try await RealModel.engine()
        let fixture = try ReferenceFixture.load()
        var options = LFM3Sampling()
        options.maxNewTokens = 48
        let result = try await engine.transcribe(audio: try ReferenceFixture.wavSamples(), options: options)
        XCTAssertEqual(Array(result.tokenIDs.prefix(48)), fixture.ints("asr_first_tokens"))
        var full = LFM3Sampling()
        full.maxNewTokens = 2048
        let complete = try await engine.transcribe(audio: try ReferenceFixture.wavSamples(), options: full)
        XCTAssertEqual(complete.text, fixture.value("asr_transcript") as String)
        XCTAssertEqual(complete.tokenIDs, fixture.ints("asr_token_ids"))
    }

    func testSpeechCodeFramesMatchReference() async throws {
        let engine = try await RealModel.engine()
        let fixture = try ReferenceFixture.load()
        var options = LFM3Sampling()
        options.maxNewTokens = 64
        options.audioTemperature = 0
        options.audioTopK = 0
        let order = (fixture.json["tts_frame_order"] as! [[NSNumber]]).map { $0.map(\.intValue) }
        let messages = [
            LFM3Message(role: .system, text: "Perform TTS in English using a female voice."),
            LFM3Message(role: .user, text: fixture.value("tts_text") as String),
        ]
        let result = try await engine.run(messages, mode: .audio, options: options, handlers: LFM3Handlers(), frameOrder: order)
        let expected = (fixture.json["tts_frames"] as! [[NSNumber]]).map { $0.map(\.int32Value) }
        let eos = Int32(2016)
        let reference = expected.filter { $0[0] != eos }
        XCTAssertGreaterThanOrEqual(result.audioFrames.count, 20)
        XCTAssertEqual(result.audioFrames[0], reference[0], "the first frame follows only the prompt, so it is exact")
        let secondMismatches = zip(result.audioFrames[1], reference[1]).filter { $0 != $1 }.count
        XCTAssertLessThanOrEqual(secondMismatches, 2, "bf16 logit ties may flip at most a couple of codes")
    }

    func testCodecDecodingMatchesReference() async throws {
        let engine = try await RealModel.engine()
        let fixture = try ReferenceFixture.load()
        let codes = (fixture.json["codec"] as! [String: Any])["codes"] as! [[NSNumber]]
        let array = MLXArray(codes.flatMap { $0.map(\.int32Value) }, [codes.count, codes[0].count])
        let wave = try engine.codec.decode(codes: array)
        eval(wave)
        let samples = wave.asArray(Float.self)
        XCTAssertEqual(samples.count, fixture.value("codec", "samples") as Int)
        assertClose(Array(samples[600..<632]), fixture.floats("codec", "head"), tolerance: 0.02, "codec head")
        assertClose(Array(samples.suffix(16)), fixture.floats("codec", "tail"), tolerance: 0.02, "codec tail")
        let absSum = samples.reduce(0.0) { $0 + Double(abs($1)) }
        XCTAssertEqual(absSum, fixture.value("codec", "abs_sum") as Double, accuracy: absSum * 0.02)
    }
}
