// Exercises the duplex playback graph with synthetic buffers, without opening a microphone or audio device.
// The mixer must convert model speech to the same client format used by voice-processed capture.

import AVFoundation
@testable import AstralDeep
import XCTest

@MainActor
final class VoiceDuplexEngineTests: XCTestCase {
    func testAggregateInputNegotiatesTheSameMonoFloatClientFormatForCaptureAndPlayback() throws {
        let format = try VoiceDuplexEngine.captureFormat(sampleRate: 48_000, channelCount: 7)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(format.isInterleaved)
        XCTAssertEqual(format.sampleRate, 48_000)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let speech = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        VoiceDuplexEngine.connectPlayback(in: engine, player: player, playbackFormat: speech, duplexFormat: format)
        XCTAssertEqual(engine.outputNode.inputFormat(forBus: 0), format)
    }

    func testMissingAndInvalidHardwareFormatsAreRefusedBeforeOpeningAudio() {
        XCTAssertThrowsError(try VoiceDuplexEngine.captureFormat(sampleRate: 0, channelCount: 7))
        XCTAssertThrowsError(try VoiceDuplexEngine.captureFormat(sampleRate: .infinity, channelCount: 7))
        XCTAssertThrowsError(try VoiceDuplexEngine.captureFormat(sampleRate: 48_000, channelCount: 0))
    }
    func testSentenceBuffersUntilSynthesisFinishesAndThenPlaysWithoutChunkGaps() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        engine.attach(player)
        VoiceDuplexEngine.connectPlayback(in: engine, player: player, playbackFormat: source, duplexFormat: output)
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 1_024)
        try engine.start()
        defer { engine.stop() }
        let sentence = VoiceSentenceAudio(player: player, format: source)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1_024))
        for chunk in 0..<4 {
            let samples = (0..<2_400).map { sin(Float(chunk * 2_400 + $0) * 2 * .pi * 440 / 24_000) * 0.1 }
            XCTAssertTrue(sentence.append(samples))
            XCTAssertEqual(try engine.renderOffline(1_024, to: buffer), .success)
            XCTAssertTrue((0..<Int(buffer.frameLength)).allSatisfy { buffer.floatChannelData![0][$0] == 0 })
        }
        XCTAssertEqual(sentence.count, 4)
        sentence.play(onPlayed: {})
        var samples: [Float] = []
        for _ in 0..<20 {
            XCTAssertEqual(try engine.renderOffline(1_024, to: buffer), .success)
            samples.append(
                contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        let crossings = audibleCycles(samples)
        XCTAssertTrue((172...178).contains(crossings), "The four chunks must play as one 0.4 second 440 Hz waveform.")
        var longestGap = 0
        var gap = 0
        for sample in samples[1_024..<17_408] {
            gap = abs(sample) < 0.001 ? gap + 1 : 0
            longestGap = max(longestGap, gap)
        }
        XCTAssertLessThan(longestGap, 32)
        XCTAssertFalse(sentence.append([0]))
    }

    func testInvalidAndOversizedSynthesizedAudioIsRefused() throws {
        let player = AVAudioPlayerNode()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let sentence = VoiceSentenceAudio(player: player, format: format)
        XCTAssertFalse(sentence.append([.nan]))
        XCTAssertFalse(sentence.append([.infinity]))
        XCTAssertFalse(sentence.append(Array(repeating: 0, count: 2_880_001)))
        XCTAssertEqual(sentence.count, 0)
    }

    func testModelSpeechRendersAtTheCaptureClientFormat() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let capture = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        engine.attach(player)
        VoiceDuplexEngine.connectPlayback(in: engine, player: player, playbackFormat: source, duplexFormat: capture)
        XCTAssertEqual(engine.mainMixerNode.outputFormat(forBus: 0), capture)
        XCTAssertEqual(engine.outputNode.inputFormat(forBus: 0), capture)
        try engine.enableManualRenderingMode(.offline, format: capture, maximumFrameCount: 1_024)
        let speech = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 2_400))
        speech.frameLength = speech.frameCapacity
        for index in 0..<Int(speech.frameLength) {
            speech.floatChannelData![0][index] = sin(Float(index) * 2 * .pi * 440 / 24_000) * 0.1
        }
        player.scheduleBuffer(speech)
        try engine.start()
        defer { engine.stop() }
        player.play()
        let rendered = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: capture, frameCapacity: 1_024))
        var heardAudio = false
        var samples: [Float] = []
        for _ in 0..<8 {
            let status = try engine.renderOffline(1_024, to: rendered)
            XCTAssertEqual(status, .success)
            heardAudio =
                heardAudio
                || (0..<Int(rendered.frameLength)).contains { abs(rendered.floatChannelData![0][$0]) > 0.001 }
            samples.append(
                contentsOf: UnsafeBufferPointer(start: rendered.floatChannelData![0], count: Int(rendered.frameLength)))
        }
        XCTAssertTrue(heardAudio)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertEqual(peak, 0.1, accuracy: 0.01)
        let crossings = audibleCycles(samples)
        XCTAssertTrue((40...46).contains(crossings), "The 0.1 second speech fixture must retain its 440 Hz tone.")
    }

    private func audibleCycles(_ samples: [Float]) -> Int {
        var negative = true
        var count = 0
        for sample in samples {
            if sample > 0.01, negative {
                count += 1
                negative = false
            }
            if sample < -0.01 { negative = true }
        }
        return count
    }
}
