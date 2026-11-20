// Checks that the streaming filter matches FluidAudio's whole-buffer post-processing however the audio is cut into frames.
// No model or network is involved, so this guards the streamed voice against drifting from the sound that was judged.
import FluidAudio
import XCTest

@testable import AstralVoiceSpeech

final class TtsPostFilterTests: XCTestCase {
    private func syntheticSpeech(count: Int) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<count).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(Int64(bitPattern: state >> 11) % 2000) / 20_000
            let t = Float(index) / 24_000
            return 0.4 * sin(2 * .pi * 180 * t) + 0.2 * sin(2 * .pi * 7_200 * t) + noise + 0.05
        }
    }

    private func reference(_ samples: [Float]) -> [Float] {
        var copy = samples
        AudioPostProcessor.applyTtsPostProcessing(&copy, sampleRate: 24_000, deEssAmount: -3.0, smoothing: false)
        return copy
    }

    private func streamed(_ samples: [Float], frameSize: Int) -> [Float] {
        var filter = TtsPostFilter(sampleRate: 24_000)
        var output: [Float] = []
        var start = 0
        while start < samples.count {
            var frame = Array(samples[start..<min(start + frameSize, samples.count)])
            filter.process(&frame)
            output += frame
            start += frameSize
        }
        return output
    }

    func testStreamingMatchesTheWholeBufferResultForEveryFrameSize() {
        let input = syntheticSpeech(count: 24_000 * 2 + 17)
        let expected = reference(input)
        for frameSize in [1920, 1, 7, 480, 5_000, input.count] {
            let actual = streamed(input, frameSize: frameSize)
            XCTAssertEqual(actual.count, expected.count)
            let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(worst, 1e-5, "frame size \(frameSize)")
        }
    }

    func testFilterStateCarriesAcrossFrames() {
        let input = syntheticSpeech(count: 3_840)
        var fresh: [Float] = []
        for start in stride(from: 0, to: input.count, by: 1_920) {
            var filter = TtsPostFilter(sampleRate: 24_000)
            var frame = Array(input[start..<start + 1_920])
            filter.process(&frame)
            fresh += frame
        }
        let carried = streamed(input, frameSize: 1_920)
        XCTAssertNotEqual(fresh, carried)
        XCTAssertEqual(carried.count, reference(input).count)
    }

    func testTheFirstSampleOfAnUtterancePassesThroughTheRumbleStage() {
        var filter = TtsPostFilter(sampleRate: 24_000)
        var one: [Float] = [0.5]
        filter.process(&one)
        var expected: [Float] = [0.5, 0.25, 0.1]
        AudioPostProcessor.applyTtsPostProcessing(&expected, sampleRate: 24_000, deEssAmount: -3.0, smoothing: false)
        XCTAssertEqual(one[0], expected[0], accuracy: 1e-6)
    }

    func testSilenceStaysSilent() {
        var filter = TtsPostFilter(sampleRate: 24_000)
        var silence = [Float](repeating: 0, count: 1_920)
        filter.process(&silence)
        XCTAssertEqual(silence.max(), 0)
        XCTAssertEqual(silence.min(), 0)
    }
}
