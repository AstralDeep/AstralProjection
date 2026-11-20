// Covers the composed voice models: loading when a session starts, the idle and memory-warning unloads, the background unload, and the reload after a failed decode, driven through injected streams and an injected sleep.
// Fake models behind a real VoiceModelOwner stand in for AstralVoiceRuntime, and nothing waits on the clock.

import AstralVoiceRuntime
import XCTest

@testable import AstralDeep

final class RumbleVoiceModelsTests: XCTestCase {
    private struct Signals {
        let memory: AsyncStream<Void>.Continuation
        let background: AsyncStream<Void>.Continuation
        let sources: VoiceModelLifecycleObserver.Sources
    }

    private func signals() -> Signals {
        let memory = AsyncStream<Void>.makeStream()
        let background = AsyncStream<Void>.makeStream()
        return Signals(
            memory: memory.continuation, background: background.continuation,
            sources: .init(memoryWarnings: memory.stream, backgrounded: background.stream))
    }

    private func models(_ harness: RumbleHarness, _ signals: Signals) -> RumbleVoiceModels {
        RumbleVoiceModels(owner: harness.owner, installed: { true }, lifecycle: signals.sources)
    }

    func testStartingASessionLoadsBothModelsOnceAndSharesTheScheduler() async {
        let scheduler = RuntimeScheduler()
        let harness = RumbleHarness(scheduler: scheduler)
        let voice = models(harness, signals())
        await voice.beginSession()
        await voice.beginSession()
        XCTAssertEqual(harness.recognition.created.count, 1)
        XCTAssertEqual(harness.generation.created.count, 1)
        XCTAssertTrue(harness.recognition.schedulers[0] === scheduler)
        XCTAssertTrue(harness.generation.schedulers[0] === scheduler)
        XCTAssertTrue(voice.owner.scheduler === scheduler)
    }

    func testAFailedPreloadSurfacesOnFirstUseAndTheNextUseRetries() async throws {
        let harness = RumbleHarness()
        harness.recognition.failure = VoiceModelRuntimeError.filesMissing("rumble")
        let voice = models(harness, signals())
        await voice.beginSession()
        do {
            _ = try await voice.recognizer.recognize([0], language: .english)
            XCTFail("the load error must surface")
        } catch {
            XCTAssertEqual(error as? VoiceModelRuntimeError, .filesMissing("rumble"))
        }
        harness.recognition.failure = nil
        let text = try await voice.recognizer.recognize([0], language: .english)
        XCTAssertEqual(text, "heard")
    }

    func testModelsStayLoadedWhileASessionIsOpenAndUnloadAfterTheIdleLimit() async throws {
        let harness = RumbleHarness()
        let voice = models(harness, signals())
        await voice.beginSession()
        let recognizer = try XCTUnwrap(harness.recognition.created.first)
        let generator = try XCTUnwrap(harness.generation.created.first)
        let openCount = await harness.idleSleeps.value
        XCTAssertEqual(openCount, 0)
        await voice.endSession()
        await harness.idleSleeps.wait(for: 1)
        let early = await recognizer.unloads.value
        XCTAssertEqual(early, 0)
        await harness.idleGate.release()
        await recognizer.unloads.wait(for: 1)
        await generator.unloads.wait(for: 1)
        let limits = await harness.durations.values
        XCTAssertEqual(limits, [.seconds(60)])
    }

    func testReopeningASessionCancelsTheIdleUnload() async throws {
        let harness = RumbleHarness()
        let voice = models(harness, signals())
        await voice.beginSession()
        await voice.endSession()
        await harness.idleSleeps.wait(for: 1)
        await voice.beginSession()
        await harness.idleGate.release()
        let isLoaded = await harness.owner.isLoaded
        XCTAssertTrue(isLoaded)
        XCTAssertEqual(harness.recognition.created.count, 1)
    }

    func testAMemoryWarningUnloadsAtOnce() async throws {
        let harness = RumbleHarness()
        let signals = signals()
        let voice = models(harness, signals)
        await voice.beginSession()
        let recognizer = try XCTUnwrap(harness.recognition.created.first)
        let generator = try XCTUnwrap(harness.generation.created.first)
        signals.memory.yield()
        await recognizer.unloads.wait(for: 1)
        await generator.unloads.wait(for: 1)
        let isLoaded = await harness.owner.isLoaded
        XCTAssertFalse(isLoaded)
        _ = try await voice.recognizer.recognize([0], language: .english)
        XCTAssertEqual(harness.recognition.created.count, 2)
    }

    func testBackgroundingUnloadsAndTheNextUseRebuilds() async throws {
        let harness = RumbleHarness()
        let signals = signals()
        let voice = models(harness, signals)
        await voice.beginSession()
        let generator = try XCTUnwrap(harness.generation.created.first)
        signals.background.yield()
        await generator.unloads.wait(for: 1)
        let answer = try await voice.textGenerator.generate(rumbleRequest()).collected()
        XCTAssertEqual(answer, "four")
        XCTAssertEqual(harness.generation.created.count, 2)
    }

    func testAFailedDecodeSurfacesAsAnOrdinaryErrorAndTheModelIsRebuiltOnNextUse() async throws {
        let harness = RumbleHarness()
        let voice = models(harness, signals())
        _ = try await voice.recognizer.recognize([0], language: .english)
        let first = try XCTUnwrap(harness.recognition.created.first)
        first.failNext(VoiceModelRuntimeError.needsReload)
        do {
            _ = try await voice.recognizer.recognize([0], language: .english)
            XCTFail("a failed decode must throw")
        } catch {
            XCTAssertEqual(error as? VoiceModelRuntimeError, .needsReload)
        }
        await first.unloads.wait(for: 1)
        let text = try await voice.recognizer.recognize([0], language: .english)
        XCTAssertEqual(text, "heard")
        XCTAssertEqual(harness.recognition.created.count, 2)
    }

    func testAFailedGenerationDecodeRebuildsTheSharedGeneratorForBothPaths() async throws {
        let harness = RumbleHarness()
        let voice = models(harness, signals())
        _ = await voice.onDeviceModel.complete(rumbleRequest())
        let first = try XCTUnwrap(harness.generation.created.first)
        first.failNext(VoiceModelRuntimeError.needsReload)
        let failed = await voice.onDeviceModel.complete(rumbleRequest())
        XCTAssertEqual(failed, .failed(.generationFailed))
        await first.unloads.wait(for: 1)
        let spoken = try await voice.textGenerator.generate(rumbleRequest()).collected()
        let kernel = await voice.onDeviceModel.complete(rumbleRequest())
        XCTAssertEqual(spoken, "four")
        XCTAssertEqual(kernel, .text("four"))
        XCTAssertEqual(harness.generation.created.count, 2)
    }

    func testAStaleFailureNeverDropsAModelThatWasAlreadyRebuilt() async throws {
        let harness = RumbleHarness()
        _ = try await harness.owner.recognizer()
        let stale = try XCTUnwrap(harness.recognition.created.first)
        await harness.owner.unload()
        let fresh = try await harness.owner.recognizer()
        await harness.owner.discard(stale as any VoiceRecognitionModel)
        let current = try await harness.owner.recognizer()
        XCTAssertTrue(current as AnyObject === fresh as AnyObject)
        XCTAssertEqual(harness.recognition.created.count, 2)
    }

    func testStoppingTheObserverIgnoresLaterSignals() async throws {
        let harness = RumbleHarness()
        let signals = signals()
        let observer = VoiceModelLifecycleObserver(owner: harness.owner, sources: signals.sources)
        observer.start()
        observer.start()
        _ = try await harness.owner.recognizer()
        observer.stop()
        signals.memory.yield()
        await Task.yield()
        let isLoaded = await harness.owner.isLoaded
        XCTAssertTrue(isLoaded)
    }
}
