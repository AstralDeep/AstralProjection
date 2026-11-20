// Checks the speech resampler on synthetic sine buffers across sample rates, sample formats and channel counts.
// It also feeds a non-24 kHz sentence through the duplex engine's playback feed to prove every voice reaches the engine at its playback rate.

import AVFoundation
import AstralVoiceSpeech
import XCTest

@testable import AstralDeep

final class SpeechResamplerTests: XCTestCase {
    private let tone: Double = 440
    private let amplitude: Float = 0.5

    private func makeBuffer(
        rate: Double, format: AVAudioCommonFormat, channels: AVAudioChannelCount, start: Int, frames: Int
    ) throws -> AVAudioPCMBuffer {
        let audio = try XCTUnwrap(
            AVAudioFormat(commonFormat: format, sampleRate: rate, channels: channels, interleaved: channels > 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * .pi * tone * Double(start + frame) / rate))
            for channel in 0..<Int(channels) {
                let index = frame * Int(channels) + channel
                switch format {
                case .pcmFormatInt16: buffer.int16ChannelData![0][index] = Int16(value * 32_767)
                case .pcmFormatInt32: buffer.int32ChannelData![0][index] = Int32(value * 2_147_483_000)
                default:
                    if channels > 1 {
                        buffer.floatChannelData![0][index] = value
                    } else {
                        buffer.floatChannelData![0][frame] = value
                    }
                }
            }
        }
        return buffer
    }

    private func run(
        rate: Double, format: AVAudioCommonFormat, channels: AVAudioChannelCount, seconds: Double,
        chunks: [Int], target: Double? = 24_000
    ) throws -> (samples: [Float], frames: Int) {
        let total = Int(seconds * rate)
        let resampler = SpeechResampler(targetRate: target)
        var samples: [Float] = []
        var start = 0
        var index = 0
        while start < total {
            let size = min(chunks[index % chunks.count], total - start)
            samples += try resampler.resample(
                makeBuffer(rate: rate, format: format, channels: channels, start: start, frames: size))
            start += size
            index += 1
        }
        samples += try resampler.finish()
        return (samples, total)
    }

    private func assertSine(_ samples: [Float], rate: Double, file: StaticString = #filePath, line: UInt = #line) {
        let body = samples.dropFirst(256).dropLast(256)
        let peak = body.map(abs).max() ?? 0
        XCTAssertEqual(peak, amplitude, accuracy: 0.03, "amplitude", file: file, line: line)
        let step = Float(2 * .pi * tone / rate) * amplitude
        let jump = zip(body, body.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThan(jump, step * 1.25, "no discontinuity at a buffer boundary", file: file, line: line)
        var crossings = 0
        var previous: Float = 0
        for sample in body {
            if previous <= 0, sample > 0 { crossings += 1 }
            previous = sample
        }
        let expected = tone * Double(body.count) / rate
        XCTAssertEqual(Double(crossings), expected, accuracy: 2, "pitch", file: file, line: line)
    }

    func testEveryRateFormatAndChannelCountReachesTheTargetRateWithTheSameDurationAndContinuity() throws {
        let formats: [AVAudioCommonFormat] = [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32]
        for rate in [16_000.0, 22_050, 24_000, 48_000] {
            for format in formats {
                for channels in [AVAudioChannelCount(1), 2] {
                    let result = try run(
                        rate: rate, format: format, channels: channels, seconds: 1.3, chunks: [997, 2_048, 311, 4_000])
                    let expected = Double(result.frames) * 24_000 / rate
                    let label = "\(rate) \(format.rawValue) \(channels)ch"
                    XCTAssertEqual(Double(result.samples.count), expected, accuracy: 2, label)
                    assertSine(result.samples, rate: 24_000)
                }
            }
        }
    }

    func testChunkedConversionMatchesConvertingTheWholeSentenceAtOnce() throws {
        for rate in [16_000.0, 22_050, 48_000] {
            let chunked = try run(
                rate: rate, format: .pcmFormatInt16, channels: 1, seconds: 0.9, chunks: [123, 1_001, 77]
            ).samples
            let whole = try run(rate: rate, format: .pcmFormatInt16, channels: 1, seconds: 0.9, chunks: [1_000_000])
                .samples
            XCTAssertEqual(chunked.count, whole.count, accuracy: 1)
            let difference = zip(chunked, whole).map { abs($0 - $1) }.max() ?? 1
            XCTAssertLessThan(difference, 0.01, "rate \(rate)")
        }
    }

    func testIdenticalStereoChannelsKeepTheirLevelWhenMixedToMono() throws {
        let result = try run(rate: 22_050, format: .pcmFormatFloat32, channels: 2, seconds: 0.5, chunks: [2_000])
        XCTAssertEqual(result.samples.map(abs).max() ?? 0, amplitude, accuracy: 0.03)
    }

    func testMonoFloatAtTheTargetRatePassesThroughUnchanged() throws {
        let resampler = SpeechResampler(targetRate: 24_000)
        let samples = (0..<500).map { Float($0) / 1_000 }
        XCTAssertEqual(try resampler.resample(SpeechAudioBuffer(samples: samples, sampleRate: 24_000)), samples)
        XCTAssertEqual(try resampler.finish(), [])
    }

    func testWithoutATargetTheRateIsKeptAndChannelsAndFormatAreFlattened() throws {
        let result = try run(
            rate: 22_050, format: .pcmFormatInt16, channels: 2, seconds: 0.4, chunks: [999], target: nil)
        XCTAssertEqual(result.samples.count, result.frames)
        assertSine(result.samples, rate: 22_050)
    }

    func testAFormatChangeBetweenBuffersFlushesTheEarlierConverter() throws {
        let resampler = SpeechResampler(targetRate: 24_000)
        var samples = try resampler.resample(
            makeBuffer(rate: 16_000, format: .pcmFormatFloat32, channels: 1, start: 0, frames: 16_000))
        samples += try resampler.resample(
            makeBuffer(rate: 48_000, format: .pcmFormatInt16, channels: 1, start: 0, frames: 48_000))
        samples += try resampler.finish()
        XCTAssertEqual(Double(samples.count), 48_000, accuracy: 4)
    }

    func testEmptyAndInvalidBuffersAreHandled() throws {
        let resampler = SpeechResampler(targetRate: 24_000)
        XCTAssertEqual(try resampler.resample(SpeechAudioBuffer(samples: [], sampleRate: 16_000)), [])
        XCTAssertEqual(
            try resampler.resample(makeBuffer(rate: 16_000, format: .pcmFormatInt16, channels: 1, start: 0, frames: 0)),
            [])
        XCTAssertThrowsError(try resampler.resample(SpeechAudioBuffer(samples: [0.1], sampleRate: 0)))
        XCTAssertEqual(try resampler.finish(), [])
    }

    func testTheEnginePlaybackFeedAcceptsASentenceAtAnotherSampleRate() async throws {
        let sentence = (0..<16_000).map { Float(sin(2 * .pi * 440 * Double($0) / 16_000)) * 0.5 }
        let speech = ScriptedSpeech(buffers: [
            SpeechAudioBuffer(samples: Array(sentence[..<5_000]), sampleRate: 16_000),
            SpeechAudioBuffer(samples: Array(sentence[5_000...]), sampleRate: 16_000),
        ])
        var played: [Float] = []
        try await VoiceDuplexEngine.playbackSamples(of: speech, text: "hello") { played += $0 }
        XCTAssertEqual(Double(played.count), 24_000, accuracy: 2)
        assertSine(played, rate: 24_000)
    }

    func testTheEnginePlaybackFeedFailsWhenTheVoiceFails() async {
        let speech = ScriptedSpeech(buffers: [], failure: SpeechSynthesisError.synthesisFailed("no"))
        do {
            try await VoiceDuplexEngine.playbackSamples(of: speech, text: "hello") { _ in }
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .synthesisFailed("no"))
        }
    }
}

final class ScriptedSpeech: VoiceSpeaking, @unchecked Sendable {
    private let buffers: [SpeechAudioBuffer]
    private let failure: Error?
    private let speakFailure: Error?
    private let lock = NSLock()
    private var texts: [String] = []

    init(buffers: [SpeechAudioBuffer], failure: Error? = nil, speakFailure: Error? = nil) {
        self.buffers = buffers
        self.failure = failure
        self.speakFailure = speakFailure
    }

    var spoken: [String] { lock.withLock { texts } }

    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        lock.withLock { texts.append(sentence) }
        if let speakFailure { throw speakFailure }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechAudioBuffer.self, throwing: Error.self)
        for buffer in buffers { continuation.yield(buffer) }
        continuation.finish(throwing: failure)
        return stream
    }
}
