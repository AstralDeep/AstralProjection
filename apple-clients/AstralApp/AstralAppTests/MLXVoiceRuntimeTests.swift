// Exercises the MLX voice adapters with deterministic inference and PCM fixtures.
// The fake inference boundary avoids model downloads while checking cancellation and transcript ownership.

import AVFoundation
import XCTest

@testable import AstralDeep

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
    private var paused = false
    private var hold: CheckedContinuation<Void, Never>?
    private var called: CheckedContinuation<Void, Never>?
    private var returned: CheckedContinuation<Void, Never>?
    private var hasReturned = false

    func lastSampleCount() -> Int { count }
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
