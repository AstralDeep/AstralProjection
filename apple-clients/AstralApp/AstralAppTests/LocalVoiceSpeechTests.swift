// Drives the local voice over a fake speech synthesizer to cover availability, loading, warm-up, speech and cancellation.
// No model or audio device is involved, and the fake records every call the voice makes.

import AstralVoiceSpeech
import XCTest

@testable import AstralDeep

actor FakeSpeechSynthesizer: SpeechSynthesizer {
    nonisolated let availability: SpeechAvailability
    private(set) var loads: [URL] = []
    private(set) var cancels = 0
    private(set) var unloads = 0
    private(set) var spoken: [String] = []
    private var loaded = false
    private let loadError: Error?
    private let buffers: [SpeechAudioBuffer]
    private let streamFailure: Error?

    init(
        availability: SpeechAvailability = .available, loadError: Error? = nil,
        buffers: [SpeechAudioBuffer] = [SpeechAudioBuffer(samples: [0.5, -0.5], sampleRate: 24_000)],
        streamFailure: Error? = nil
    ) {
        self.availability = availability
        self.loadError = loadError
        self.buffers = buffers
        self.streamFailure = streamFailure
    }

    var isLoaded: Bool { loaded }

    func load(from folder: URL) async throws {
        loads.append(folder)
        if let loadError { throw loadError }
        loaded = true
    }

    func synthesize(sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        guard loaded else { throw SpeechSynthesisError.notLoaded }
        spoken.append(sentence)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechAudioBuffer.self, throwing: Error.self)
        for buffer in buffers { continuation.yield(buffer) }
        continuation.finish(throwing: streamFailure)
        return stream
    }

    func cancel() async { cancels += 1 }

    func unload() async {
        unloads += 1
        loaded = false
    }
}

final class LocalVoiceSpeechTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/phonon")

    private func collect(_ stream: AsyncThrowingStream<SpeechAudioBuffer, Error>) async throws -> [SpeechAudioBuffer] {
        var all: [SpeechAudioBuffer] = []
        for try await buffer in stream { all.append(buffer) }
        return all
    }

    func testItReportsAnOldOperatingSystemBeforeLookingForTheVoice() async {
        let synthesizer = FakeSpeechSynthesizer(
            availability: .unavailable(.operatingSystemTooOld(required: "iOS 18")))
        let voice = LocalVoiceSpeech(synthesizer: synthesizer) {
            XCTFail("must not be asked")
            return nil
        }
        let reason = await voice.unavailability()
        XCTAssertEqual(reason, .operatingSystemTooOld)
        do {
            _ = try await voice.speak("hello")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? VoiceSpeechUnavailable, VoiceSpeechUnavailable(reason: .operatingSystemTooOld))
        }
        let loads = await synthesizer.loads
        XCTAssertTrue(loads.isEmpty)
    }

    func testItReportsAVoiceThatIsNotInstalled() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let voice = LocalVoiceSpeech(synthesizer: synthesizer) { nil }
        let reason = await voice.unavailability()
        XCTAssertEqual(reason, .notInstalled)
        do {
            try await voice.warmUp()
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? VoiceSpeechUnavailable, VoiceSpeechUnavailable(reason: .notInstalled))
        }
    }

    func testALoadFailureIsReportedAndStaysUntilTheFolderChangesOrARetryIsAsked() async throws {
        let synthesizer = FakeSpeechSynthesizer(loadError: SpeechSynthesisError.loadFailed("bad"))
        let current = LockedURL(folder)
        let voice = LocalVoiceSpeech(synthesizer: synthesizer) { current.value }
        do {
            try await voice.warmUp()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? VoiceSpeechUnavailable, VoiceSpeechUnavailable(reason: .loadFailed))
        }
        var reason = await voice.unavailability()
        XCTAssertEqual(reason, .loadFailed)
        do {
            _ = try await voice.speak("hello")
        } catch {}
        var loads = await synthesizer.loads
        XCTAssertEqual(loads.count, 1, "a failed folder is not retried on every sentence")
        current.value = URL(fileURLWithPath: "/tmp/phonon-2")
        reason = await voice.unavailability()
        XCTAssertNil(reason)
        await voice.retryAfterFailure()
        current.value = folder
        reason = await voice.unavailability()
        XCTAssertNil(reason)
        loads = await synthesizer.loads
        XCTAssertEqual(loads.count, 1)
    }

    func testWarmUpLoadsOnceWithoutSpeakingAndTheFirstSentenceReusesIt() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let voice = LocalVoiceSpeech(synthesizer: synthesizer) { self.folder }
        try await voice.warmUp()
        var loads = await synthesizer.loads
        var spoken = await synthesizer.spoken
        XCTAssertEqual(loads, [folder])
        XCTAssertTrue(spoken.isEmpty)
        let buffers = try await collect(try await voice.speak("hello there"))
        XCTAssertEqual(buffers, [SpeechAudioBuffer(samples: [0.875, -0.875], sampleRate: 24_000)])
        loads = await synthesizer.loads
        spoken = await synthesizer.spoken
        XCTAssertEqual(loads.count, 1)
        XCTAssertEqual(spoken, ["hello there"])
    }

    func testConcurrentFirstSentencesShareOneLoad() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let voice = LocalVoiceSpeech(synthesizer: synthesizer) { self.folder }
        async let first: Void = voice.warmUp()
        async let second: Void = voice.warmUp()
        _ = try await (first, second)
        let loads = await synthesizer.loads
        XCTAssertEqual(loads.count, 1)
    }

    func testAMovedFolderIsReloaded() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let current = LockedURL(folder)
        let voice = LocalVoiceSpeech(synthesizer: synthesizer) { current.value }
        try await voice.warmUp()
        current.value = URL(fileURLWithPath: "/tmp/phonon-2")
        try await voice.warmUp()
        let loads = await synthesizer.loads
        XCTAssertEqual(loads.count, 2)
    }

    func testStreamFailuresReachTheCaller() async throws {
        let synthesizer = FakeSpeechSynthesizer(streamFailure: SpeechSynthesisError.synthesisFailed("boom"))
        let voice = LocalVoiceSpeech(synthesizer: synthesizer) { self.folder }
        do {
            _ = try await collect(try await voice.speak("hello"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .synthesisFailed("boom"))
        }
    }

    func testCancelAndUnloadReachTheSynthesizer() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let voice = LocalVoiceSpeech(synthesizer: synthesizer) { self.folder }
        try await voice.warmUp()
        await voice.cancel()
        await voice.unload()
        let cancels = await synthesizer.cancels
        let unloads = await synthesizer.unloads
        let loaded = await synthesizer.isLoaded
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(unloads, 1)
        XCTAssertFalse(loaded)
        try await voice.warmUp()
        let loads = await synthesizer.loads
        XCTAssertEqual(loads.count, 2)
    }

    func testOneFixedGainIsAppliedToEverySentenceAndTheLoudestMeasuredPeakStaysAtOrUnderFullScale() async throws {
        let synthesizer = FakeSpeechSynthesizer(buffers: [
            SpeechAudioBuffer(samples: [0.2, -0.57, 0.9], sampleRate: 24_000)
        ])
        let voice = LocalVoiceSpeech(synthesizer: synthesizer) { self.folder }
        for _ in 0..<2 {
            let buffers = try await collect(try await voice.speak("hello"))
            let samples = try XCTUnwrap(buffers.first?.samples)
            XCTAssertEqual(samples.count, 3)
            XCTAssertEqual(samples[0], 0.2 * LocalVoiceSpeech.playbackGain, accuracy: 0.0001)
            XCTAssertEqual(samples[1], -0.57 * LocalVoiceSpeech.playbackGain, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(abs(samples[1]), 1)
            XCTAssertEqual(samples[2], 1, "samples are clamped at full scale")
        }
        XCTAssertEqual(LocalVoiceSpeech.playbackGain, 1.75)
    }
}

final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    init(_ url: URL?) { stored = url }

    var value: URL? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
