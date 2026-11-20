// Covers the shared session parts: the standard composition opens and closes the one model owner around a session, unloads the models and the local voice on the idle rule, on memory pressure and on request and hands the phone and Watch pipelines the same recognizer, text generator and voice.
// Fake models behind a real VoiceModelOwner stand in for AstralVoiceRuntime, and the pack folder is a counting closure, so nothing loads a model or waits on the clock.

import AstralVoiceRuntime
import AstralVoiceSpeech
import XCTest

@testable import AstralDeep

@MainActor
final class VoiceSessionPartsTests: XCTestCase {
    private final class FolderProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func ask() -> URL? {
            lock.withLock { count += 1 }
            return nil
        }
    }

    private func models(_ harness: RumbleHarness) -> RumbleVoiceModels {
        let memory = AsyncStream<Void>.makeStream()
        let background = AsyncStream<Void>.makeStream()
        return RumbleVoiceModels(
            owner: harness.owner, installed: { true },
            lifecycle: .init(memoryWarnings: memory.stream, backgrounded: background.stream))
    }

    func testTheStandardPartsOpenTheModelsOnceAndWarmTheVoiceFromThePackFolder() async throws {
        let harness = RumbleHarness()
        let probe = FolderProbe()
        let parts = VoiceSessionParts.standard(folder: { probe.ask() }, models: models(harness))
        try await parts.begin()
        XCTAssertEqual(harness.recognition.created.count, 1)
        XCTAssertEqual(harness.generation.created.count, 1)
        for _ in 0..<2_000 where probe.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(probe.calls, 0)
    }

    func testTheModelsUnloadOnTheIdleRuleAfterTheSessionEnds() async throws {
        let harness = RumbleHarness()
        let parts = VoiceSessionParts.standard(folder: { nil }, models: models(harness))
        try await parts.begin()
        let recognizer = try XCTUnwrap(harness.recognition.created.first)
        let generator = try XCTUnwrap(harness.generation.created.first)
        await parts.end()
        await harness.idleSleeps.wait(for: 1)
        let early = await recognizer.unloads.value
        XCTAssertEqual(early, 0)
        await harness.idleGate.release()
        await recognizer.unloads.wait(for: 1)
        await generator.unloads.wait(for: 1)
        let limits = await harness.durations.values
        XCTAssertEqual(limits, [.seconds(60)])
    }

    func testUnloadReleasesTheModelsAtOnceAndTheNextSessionLoadsThemAgain() async throws {
        let harness = RumbleHarness()
        let parts = VoiceSessionParts.standard(folder: { nil }, models: models(harness))
        try await parts.begin()
        let first = try XCTUnwrap(harness.recognition.created.first)
        await parts.unload()
        await first.unloads.wait(for: 1)
        try await parts.begin()
        XCTAssertEqual(harness.recognition.created.count, 2)
        XCTAssertEqual(harness.generation.created.count, 2)
    }

    func testAModelThatCannotLoadSurfacesFromBeginAndTheNextSessionRetries() async throws {
        let harness = RumbleHarness()
        harness.recognition.failure = VoiceModelRuntimeError.filesMissing("rumble")
        let parts = VoiceSessionParts.standard(folder: { nil }, models: models(harness))
        do {
            try await parts.begin()
            XCTFail("a missing model file must fail the session start")
        } catch {
            XCTAssertEqual(error as? VoiceModelRuntimeError, .filesMissing("rumble"))
        }
        await parts.end()
        harness.recognition.failure = nil
        try await parts.begin()
        let text = try await parts.recognizer.recognize([0], language: .english)
        XCTAssertEqual(text, "heard")
    }

    private struct Signals {
        let memory: AsyncStream<Void>.Continuation
        let models: RumbleVoiceModels
    }

    private func signalModels(_ harness: RumbleHarness) -> Signals {
        let memory = AsyncStream<Void>.makeStream()
        let background = AsyncStream<Void>.makeStream()
        let models = RumbleVoiceModels(
            owner: harness.owner, installed: { true },
            lifecycle: .init(memoryWarnings: memory.stream, backgrounded: background.stream))
        return Signals(memory: memory.continuation, models: models)
    }

    private func voiceParts(_ models: RumbleVoiceModels, _ synthesizer: FakeSpeechSynthesizer) -> VoiceSessionParts {
        VoiceSessionParts.standard(
            folder: { URL(fileURLWithPath: "/tmp/phonon") }, models: models, synthesizer: synthesizer,
            system: SilentSwitchable(), language: { .english })
    }

    private func wait(_ synthesizer: FakeSpeechSynthesizer, loads: Int? = nil, unloads: Int? = nil) async throws {
        for _ in 0..<2_000 {
            let state = (await synthesizer.loads.count, await synthesizer.unloads)
            if state.0 >= (loads ?? 0), state.1 >= (unloads ?? 0) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the voice never reached loads \(String(describing: loads)) unloads \(String(describing: unloads))")
    }

    func testTheVoiceWarmsWithTheSessionAndUnloadsOnTheIdleRuleAfterTheLastSessionEnds() async throws {
        let harness = RumbleHarness()
        let synthesizer = FakeSpeechSynthesizer()
        let parts = voiceParts(signalModels(harness).models, synthesizer)
        try await parts.begin()
        try await wait(synthesizer, loads: 1)
        await parts.end()
        await harness.idleSleeps.wait(for: 1)
        let early = await synthesizer.unloads
        XCTAssertEqual(early, 0)
        await harness.idleGate.release()
        try await wait(synthesizer, unloads: 1)
        let loaded = await synthesizer.isLoaded
        XCTAssertFalse(loaded)
        let limits = await harness.durations.values
        XCTAssertEqual(limits, [.seconds(60)])
    }

    func testAMemoryWarningUnloadsTheVoiceAtOnceAndANewSessionWarmsItAgain() async throws {
        let harness = RumbleHarness()
        let synthesizer = FakeSpeechSynthesizer()
        let signals = signalModels(harness)
        let parts = voiceParts(signals.models, synthesizer)
        try await parts.begin()
        try await wait(synthesizer, loads: 1)
        signals.memory.yield()
        try await wait(synthesizer, unloads: 1)
        try await parts.begin()
        try await wait(synthesizer, loads: 2)
        let loaded = await synthesizer.isLoaded
        XCTAssertTrue(loaded)
    }

    func testAMemoryWarningDuringASentenceLetsItFinishBeforeTheVoiceUnloads() async throws {
        let synthesizer = HeldSynthesizer()
        let local = LocalVoiceSpeech(synthesizer: synthesizer) { URL(fileURLWithPath: "/tmp/phonon") }
        let stream = try await local.speak("Hello there.")
        await local.unload()
        let during = await synthesizer.unloads
        XCTAssertEqual(during, 0)
        await synthesizer.finish()
        for try await _ in stream {}
        for _ in 0..<2_000 where await synthesizer.unloads == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let after = await synthesizer.unloads
        XCTAssertEqual(after, 1)
    }

    func testRemovingThePackUnloadsTheVoiceEvenMidSentence() async throws {
        let synthesizer = HeldSynthesizer()
        let local = LocalVoiceSpeech(synthesizer: synthesizer) { URL(fileURLWithPath: "/tmp/phonon") }
        _ = try await local.speak("Hello there.")
        await local.unload(force: true)
        let unloads = await synthesizer.unloads
        XCTAssertEqual(unloads, 1)
        await synthesizer.finish()
    }

    func testThePhoneAndWatchPipelinesAreBuiltFromTheSamePartsAndTheRumbleTranscriber() async throws {
        let parts = VoiceSessionParts.recording(recognizer: SilentRecognizer())
        XCTAssertEqual(parts.transcriber().kind, .rumble)
        XCTAssertNotNil(parts.fastPath())
        let phone = parts.pipeline(link: FakeKernelLink())
        phone.stop()
    }
}

private struct SilentSwitchable: SwitchableVoice {
    func unavailability() async -> VoiceSpeechUnavailability? { nil }
    func warmUp() async throws {}
    func cancel() async {}
    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor HeldSynthesizer: SpeechSynthesizer {
    nonisolated let availability = SpeechAvailability.available
    private(set) var unloads = 0
    private var loaded = false
    private var continuation: AsyncThrowingStream<SpeechAudioBuffer, Error>.Continuation?

    var isLoaded: Bool { loaded }
    func load(from folder: URL) async throws { loaded = true }
    func synthesize(sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechAudioBuffer.self, throwing: Error.self)
        continuation.yield(SpeechAudioBuffer(samples: [0.1], sampleRate: 24_000))
        self.continuation = continuation
        return stream
    }
    func cancel() async {}
    func unload() async {
        unloads += 1
        loaded = false
    }
    func finish() { continuation?.finish() }
}
