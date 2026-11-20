// Covers the recognizer-backed transcriber's partial cadence, skipped ticks, final result, retired segments, cancellation, 30 second cap and language, using a scripted fake recognizer.
// No test runs a model or waits on the clock: calls are held and released by latches.

import AVFoundation
import AstralVoiceRuntime
import XCTest

@testable import AstralDeep

private actor ScriptedRecognizer: VoiceRecognizing {
    struct Call: Equatable {
        let samples: Int
        let language: String
    }

    private(set) var calls: [Call] = []
    private(set) var cancellations = 0
    private var holding: Bool
    private let honorsCancellation: Bool
    private var held: [CheckedContinuation<Bool, Never>] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(holding: Bool = false, honorsCancellation: Bool = true) {
        self.holding = holding
        self.honorsCancellation = honorsCancellation
    }

    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String {
        calls.append(Call(samples: audio.count, language: language.code))
        for waiter in callWaiters.filter({ $0.0 <= calls.count }) { waiter.1.resume() }
        callWaiters.removeAll { $0.0 <= calls.count }
        if holding {
            let cancelled = await withTaskCancellationHandler {
                await withCheckedContinuation { held.append($0) }
            } onCancel: {
                Task { await self.cancelHeld() }
            }
            if cancelled && honorsCancellation { throw CancellationError() }
        }
        return "heard \(audio.count)"
    }

    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    func release() {
        holding = false
        for continuation in held { continuation.resume(returning: false) }
        held.removeAll()
    }

    private func cancelHeld() {
        cancellations += 1
        for continuation in held { continuation.resume(returning: true) }
        held.removeAll()
    }
}

private nonisolated final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VoiceRecognizerEvent] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var events: [VoiceRecognizerEvent] { lock.withLock { values } }

    func append(_ event: VoiceRecognizerEvent) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            values.append(event)
            let due = waiters.filter { $0.0 <= values.count }
            waiters.removeAll { $0.0 <= values.count }
            return due.map(\.1)
        }
        for continuation in ready { continuation.resume() }
    }

    func wait(for count: Int) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if values.count >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }
}

final class RumbleTranscriberTests: XCTestCase {
    private func buffer(samples: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)))
        buffer.frameLength = AVAudioFrameCount(samples)
        return buffer
    }

    private func transcriber(
        _ recognizer: ScriptedRecognizer, language: ConversationLanguage = .english
    ) -> (RumbleTranscriber, Recorded) {
        let transcriber = RumbleTranscriber(recognizer: recognizer, language: { language.recognitionLanguage })
        let recorded = Recorded()
        transcriber.setEventHandler { recorded.append($0) }
        return (transcriber, recorded)
    }

    func testAPartialArrivesEveryHalfSecondOfAudioAndATickDuringARunningPartialIsSkipped() async throws {
        let recognizer = ScriptedRecognizer(holding: true)
        let (transcriber, recorded) = transcriber(recognizer)
        defer { transcriber.shutdown() }
        try transcriber.beginSegment()
        transcriber.append(try buffer(samples: 4_000))
        transcriber.append(try buffer(samples: 4_000))
        await recognizer.waitForCalls(1)
        transcriber.append(try buffer(samples: 8_000))
        transcriber.append(try buffer(samples: 8_000))
        let whileRunning = await recognizer.calls
        XCTAssertEqual(whileRunning.map(\.samples), [8_000])
        await recognizer.release()
        await recorded.wait(for: 1)
        XCTAssertEqual(recorded.events, [.partial("heard 8000", segmentID: transcriber.segmentID)])
        transcriber.append(try buffer(samples: 8_000))
        await recognizer.waitForCalls(2)
        let afterwards = await recognizer.calls
        XCTAssertEqual(afterwards.map(\.samples), [8_000, 32_000])
        await recorded.wait(for: 2)
    }

    func testAFinalFollowsTheEndOfTheSegmentWithAllItsAudio() async throws {
        let recognizer = ScriptedRecognizer()
        let (transcriber, recorded) = transcriber(recognizer)
        defer { transcriber.shutdown() }
        try transcriber.beginSegment()
        let id = try XCTUnwrap(transcriber.segmentID)
        transcriber.append(try buffer(samples: 5_000))
        transcriber.endSegment()
        await recorded.wait(for: 1)
        XCTAssertEqual(recorded.events, [.final("heard 5000", segmentID: id)])
        XCTAssertNil(transcriber.segmentID)
    }

    func testARetiredSegmentNeverDeliversItsPartial() async throws {
        let recognizer = ScriptedRecognizer(holding: true, honorsCancellation: false)
        let (transcriber, recorded) = transcriber(recognizer)
        defer { transcriber.shutdown() }
        try transcriber.beginSegment()
        transcriber.append(try buffer(samples: 8_000))
        await recognizer.waitForCalls(1)
        try transcriber.beginSegment()
        await recognizer.release()
        transcriber.append(try buffer(samples: 1_000))
        transcriber.endSegment()
        await recorded.wait(for: 1)
        XCTAssertEqual(recorded.events.count, 1)
        guard case .final(let text, _) = recorded.events[0] else { return XCTFail("expected the new segment's final") }
        XCTAssertEqual(text, "heard 1000")
    }

    func testEndingASegmentCancelsItsStalePartial() async throws {
        let recognizer = ScriptedRecognizer(holding: true)
        let (transcriber, recorded) = transcriber(recognizer)
        defer { transcriber.shutdown() }
        try transcriber.beginSegment()
        transcriber.append(try buffer(samples: 8_000))
        await recognizer.waitForCalls(1)
        transcriber.endSegment()
        await recognizer.waitForCalls(2)
        await recognizer.release()
        await recorded.wait(for: 1)
        let cancellations = await recognizer.cancellations
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(recorded.events.count, 1)
        guard case .final = recorded.events[0] else { return XCTFail("a cancelled partial must not be delivered") }
    }

    func testASegmentLongerThanThirtySecondsFailsAndDeliversNothingMore() async throws {
        let recognizer = ScriptedRecognizer(holding: true)
        let (transcriber, recorded) = transcriber(recognizer)
        defer { transcriber.shutdown() }
        try transcriber.beginSegment()
        transcriber.append(try buffer(samples: 480_000))
        transcriber.append(try buffer(samples: 1))
        await recorded.wait(for: 1)
        XCTAssertEqual(recorded.events, [.failed("voice_segment_too_long")])
        XCTAssertNil(transcriber.segmentID)
        transcriber.endSegment()
        let calls = await recognizer.calls
        XCTAssertEqual(calls.map(\.samples), [480_000])
    }

    func testTheConversationLanguageReachesPartialAndFinalRecognition() async throws {
        let recognizer = ScriptedRecognizer()
        let (transcriber, recorded) = transcriber(recognizer, language: .german)
        defer { transcriber.shutdown() }
        try transcriber.beginSegment()
        transcriber.append(try buffer(samples: 8_000))
        await recorded.wait(for: 1)
        transcriber.endSegment()
        await recorded.wait(for: 2)
        let calls = await recognizer.calls
        XCTAssertEqual(calls.map(\.language), ["de", "de"])
    }

    func testTheDefaultLanguageIsTheSavedConversationLanguage() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ConversationLanguage.defaultsKey)
        defer { defaults.set(previous, forKey: ConversationLanguage.defaultsKey) }
        ConversationLanguage.japanese.save()
        let recognizer = ScriptedRecognizer()
        let transcriber = RumbleTranscriber(recognizer: recognizer)
        let recorded = Recorded()
        transcriber.setEventHandler { recorded.append($0) }
        defer { transcriber.shutdown() }
        try transcriber.beginSegment()
        transcriber.append(try buffer(samples: 1_000))
        transcriber.endSegment()
        await recorded.wait(for: 1)
        let calls = await recognizer.calls
        XCTAssertEqual(calls.map(\.language), ["ja"])
    }

    func testTheTranscriberReportsTheRumbleKind() {
        XCTAssertEqual(RumbleTranscriber(recognizer: ScriptedRecognizer()).kind, .rumble)
    }
}
