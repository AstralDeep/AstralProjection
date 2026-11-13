// Exercises the MLX voice adapters with deterministic inference and PCM fixtures.
// The fake inference boundary avoids model downloads while checking cancellation and transcript ownership.

import AVFoundation
@testable import AstralDeep
import XCTest

final class MLXVoiceRuntimeTests: XCTestCase {
    func testFinalTranscriptionReceivesMonoSixteenKilohertzSamples() async throws {
        let inference = VoiceInferenceFixture()
        let transcriber = MLXVoiceTranscriber(inference: inference)
        let final = expectation(description: "final transcript")
        transcriber.setEventHandler { event in
            if case .final("The patient is stable.", _) = event { final.fulfill() }
        }
        try transcriber.beginSegment()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        for index in 0..<800 { buffer.floatChannelData![0][index] = 0.2 }
        transcriber.append(buffer)
        transcriber.endSegment()
        await fulfillment(of: [final], timeout: 2)
        let sampleCount = await inference.lastSampleCount()
        XCTAssertEqual(sampleCount, 800)
        transcriber.shutdown()
    }

    func testCaptureResamplingPreservesPitchDurationAndScalingAcrossPCMFormats() async throws {
        for kind in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
            let inference = VoiceInferenceFixture()
            let transcriber = MLXVoiceTranscriber(inference: inference)
            let final = expectation(description: "converted final \(kind)")
            transcriber.setEventHandler { if case .final = $0 { final.fulfill() } }
            try transcriber.beginSegment()
            let format = try XCTUnwrap(
                AVAudioFormat(commonFormat: kind, sampleRate: 48_000, channels: 2, interleaved: true))
            for start in stride(from: 0, to: 48_000, by: 1_024) {
                let frames = min(1_024, 48_000 - start)
                let buffer = try XCTUnwrap(
                    AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                buffer.frameLength = AVAudioFrameCount(frames)
                for frame in 0..<frames {
                    let sample = sin(Float(start + frame) * 2 * .pi * 440 / 48_000) * 0.25
                    for channel in 0..<2 {
                        if kind == .pcmFormatFloat32 {
                            buffer.floatChannelData![0][frame * 2 + channel] = sample
                        } else {
                            buffer.int16ChannelData![0][frame * 2 + channel] = Int16(sample * Float(Int16.max))
                        }
                    }
                }
                transcriber.append(try XCTUnwrap(VoiceDuplexEngine.copyMicrophoneBuffer(buffer)))
            }
            transcriber.endSegment()
            await fulfillment(of: [final], timeout: 5)
            let samples = await inference.lastSamples()
            XCTAssertTrue(
                (15_936...16_064).contains(samples.count),
                "The capture duration must remain one second after conversion.")
            XCTAssertEqual(samples.map(abs).max() ?? 0, 0.25, accuracy: 0.02)
            let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            XCTAssertTrue((435...445).contains(crossings), "Capture conversion must retain the 440 Hz tone.")
            transcriber.shutdown()
        }
    }

    func testNewRecognitionSegmentDoesNotInheritThePreviousAudioFilterTail() async throws {
        let inference = VoiceInferenceFixture()
        let transcriber = MLXVoiceTranscriber(inference: inference)
        defer { transcriber.shutdown() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        func buffer(_ value: Float) throws -> AVAudioPCMBuffer {
            let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
            result.frameLength = 1_024
            for index in 0..<1_024 { result.floatChannelData![0][index] = value }
            return result
        }
        let first = expectation(description: "first segment")
        transcriber.setEventHandler { if case .final = $0 { first.fulfill() } }
        try transcriber.beginSegment()
        for _ in 0..<10 { transcriber.append(try buffer(0.25)) }
        transcriber.endSegment()
        await fulfillment(of: [first], timeout: 5)
        let next = expectation(description: "silent next segment")
        transcriber.setEventHandler { if case .final = $0 { next.fulfill() } }
        try transcriber.beginSegment()
        transcriber.append(try buffer(0))
        transcriber.endSegment()
        await fulfillment(of: [next], timeout: 5)
        let samples = await inference.lastSamples()
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0)
    }

    func testShutdownFencesALateRecognitionResult() async throws {
        let inference = VoiceInferenceFixture()
        await inference.suspend()
        let transcriber = MLXVoiceTranscriber(inference: inference)
        let calls = VoiceEventRecorder()
        transcriber.setEventHandler { event in calls.append(event) }
        try transcriber.beginSegment()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        transcriber.append(buffer)
        transcriber.endSegment()
        await inference.waitForCall()
        transcriber.shutdown()
        await inference.resume()
        await inference.waitForReturn()
        XCTAssertEqual(calls.events, [])
    }

    func testAcknowledgementUsesMLXAndRejectsAStructuredRequest() async throws {
        let inference = VoiceInferenceFixture()
        let model = MLXVoiceAcknowledgementModel(inference: inference)
        XCTAssertTrue(model.available())
        let response = await model.complete(VoiceAcknowledgement.request(for: "Call the clinic tomorrow."))
        XCTAssertEqual(response, .text("I heard you."))
        let structured = OnDeviceRequest(messages: [], schemaJSON: "{}", maxTokens: 24)
        let rejected = await model.complete(structured)
        XCTAssertEqual(rejected, .failed(.schemaUnsupported))
    }
}

private nonisolated final class VoiceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VoiceRecognizerEvent] = []
    var events: [VoiceRecognizerEvent] { lock.withLock { values } }
    func append(_ event: VoiceRecognizerEvent) { lock.withLock { values.append(event) } }
}

private actor VoiceInferenceFixture: VoiceModelInference {
    private var count = 0
    private var samples: [Float] = []
    private var paused = false
    private var hold: CheckedContinuation<Void, Never>?
    private var called: CheckedContinuation<Void, Never>?
    private var returned: CheckedContinuation<Void, Never>?
    private var hasReturned = false

    func lastSampleCount() -> Int { count }
    func lastSamples() -> [Float] { samples }
    func suspend() { paused = true }
    func waitForCall() async {
        if count > 0 { return }
        await withCheckedContinuation { called = $0 }
    }
    func waitForReturn() async {
        if hasReturned { return }
        await withCheckedContinuation { returned = $0 }
    }
    func resume() {
        hold?.resume()
        hold = nil
    }
    func transcribe(_ audio: [Float], onText: @escaping @Sendable (String) -> Void) async throws -> String {
        count = audio.count
        samples = audio
        called?.resume()
        called = nil
        if paused { await withCheckedContinuation { hold = $0 } }
        onText("The patient is stable.")
        hasReturned = true
        returned?.resume()
        returned = nil
        return "The patient is stable."
    }
    func synthesize(_ text: String, onAudio: @escaping @Sendable ([Float]) -> Void) async throws {
        onAudio([0, 0.1, 0])
    }
    func acknowledgement(_ request: OnDeviceRequest) async throws -> String { "I heard you." }
}
