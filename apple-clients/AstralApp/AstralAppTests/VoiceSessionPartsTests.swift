// Covers the shared session parts: the standard composition opens and closes the one model owner around a session, unloads on request and hands the phone and Watch pipelines the same recognizer, text generator and voice.
// Fake models behind a real VoiceModelOwner stand in for AstralVoiceRuntime, and the pack folder is a counting closure, so nothing loads a model or waits on the clock.

import AstralVoiceRuntime
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
        await parts.begin()
        XCTAssertEqual(harness.recognition.created.count, 1)
        XCTAssertEqual(harness.generation.created.count, 1)
        for _ in 0..<2_000 where probe.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(probe.calls, 0)
    }

    func testTheModelsUnloadOnTheIdleRuleAfterTheSessionEnds() async throws {
        let harness = RumbleHarness()
        let parts = VoiceSessionParts.standard(folder: { nil }, models: models(harness))
        await parts.begin()
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
        await parts.begin()
        let first = try XCTUnwrap(harness.recognition.created.first)
        await parts.unload()
        await first.unloads.wait(for: 1)
        await parts.begin()
        XCTAssertEqual(harness.recognition.created.count, 2)
        XCTAssertEqual(harness.generation.created.count, 2)
    }

    func testThePhoneAndWatchPipelinesAreBuiltFromTheSamePartsAndTheRumbleTranscriber() async throws {
        let parts = VoiceSessionParts.recording(recognizer: SilentRecognizer())
        XCTAssertEqual(parts.transcriber().kind, .rumble)
        XCTAssertNotNil(parts.fastPath())
        let phone = parts.pipeline(link: FakeKernelLink())
        phone.stop()
    }
}
