// Exercises PhononSpeech against the real load-failure paths and against a fake engine for cancel timing and buffer format.
// None of these tests needs a model, and the real-folder tests also prove that a failed load reaches no network listener.
import FluidAudio
import XCTest

@testable import AstralVoiceSpeech

final class PhononSpeechTests: XCTestCase {
    private func loaded(_ engine: FakeEngine) async throws -> PhononSpeech {
        let speech = PhononSpeech(availability: .available, makeEngine: { _ in engine })
        try await speech.load(from: try completeFolder())
        return speech
    }

    private func collect(_ stream: AsyncThrowingStream<SpeechAudioBuffer, Error>) async throws -> [SpeechAudioBuffer] {
        var buffers: [SpeechAudioBuffer] = []
        for try await buffer in stream { buffers.append(buffer) }
        return buffers
    }

    func testAvailabilityBelowTheRequiredSystemReportsUnavailableAndNeverLoads() async throws {
        let factoryCalls = Counter()
        let reason = SpeechUnavailableReason.operatingSystemTooOld(required: "iOS 18")
        let speech = PhononSpeech(availability: .unavailable(reason), makeEngine: { _ in
            factoryCalls.increment()
            return FakeEngine(behavior: .frames([]))
        })
        XCTAssertEqual(speech.availability, .unavailable(reason))
        do {
            try await speech.load(from: try completeFolder())
            XCTFail("load must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .unavailable(reason))
        }
        let isLoaded = await speech.isLoaded
        XCTAssertFalse(isLoaded)
        XCTAssertEqual(factoryCalls.value, 0)
    }

    func testRealAvailabilityMatchesTheRunningSystem() {
        let expected: SpeechAvailability
        if #available(iOS 18.0, macOS 15.0, *) { expected = .available } else {
            expected = .unavailable(.operatingSystemTooOld(required: "this system"))
        }
        switch (PhononSpeech().availability, expected) {
        case (.available, .available), (.unavailable, .unavailable): break
        default: XCTFail("availability does not match the running system")
        }
    }

    func testEmptyFolderFailsWithEveryRequiredFileNamedAndNoRequest() async throws {
        let tripwire = try LoopbackTripwire()
        try await tripwire.start()
        defer { tripwire.stop() }
        let speech = PhononSpeech()
        guard speech.availability == .available else { throw XCTSkip("needs iOS 18 or macOS 15") }
        do {
            try await speech.load(from: try emptyFolder())
            XCTFail("load must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .modelFolderIncomplete(missing: PhononModelFolder.requiredFiles))
        }
        let isLoaded = await speech.isLoaded
        XCTAssertFalse(isLoaded)
        XCTAssertEqual(tripwire.connectionCount, 0)
    }

    func testMissingFolderFailsAsIncomplete() async throws {
        let speech = PhononSpeech()
        guard speech.availability == .available else { throw XCTSkip("needs iOS 18 or macOS 15") }
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        do {
            try await speech.load(from: nowhere)
            XCTFail("load must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .modelFolderIncomplete(missing: PhononModelFolder.requiredFiles))
        }
    }

    func testFolderWithOneFileMissingNamesThatFile() async throws {
        let speech = PhononSpeech()
        guard speech.availability == .available else { throw XCTSkip("needs iOS 18 or macOS 15") }
        let target = "constants_bin/default.safetensors"
        do {
            try await speech.load(from: try completeFolder(missing: target))
            XCTFail("load must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .modelFolderIncomplete(missing: [target]))
        }
    }

    func testPlaceholderFilesFailInsideTheEngineWithoutAnyRequest() async throws {
        let tripwire = try LoopbackTripwire()
        try await tripwire.start()
        defer { tripwire.stop() }
        let speech = PhononSpeech()
        guard speech.availability == .available else { throw XCTSkip("needs iOS 18 or macOS 15") }
        do {
            try await speech.load(from: try completeFolder())
            XCTFail("load must fail")
        } catch {
            guard case .loadFailed = error as? SpeechSynthesisError else {
                return XCTFail("expected loadFailed, got \(error)")
            }
        }
        XCTAssertTrue(ModelHub.offlineMode)
        XCTAssertEqual(tripwire.connectionCount, 0)
        let isLoaded = await speech.isLoaded
        XCTAssertFalse(isLoaded)
    }

    func testFactoryFailuresBecomeLoadFailedAndSpeechErrorsPassThrough() async throws {
        let failing = PhononSpeech(availability: .available, makeEngine: { _ in throw FakeFailure() })
        do {
            try await failing.load(from: try completeFolder())
            XCTFail("load must fail")
        } catch {
            guard case .loadFailed = error as? SpeechSynthesisError else { return XCTFail("\(error)") }
        }
        let passing = PhononSpeech(availability: .available, makeEngine: { _ in throw SpeechSynthesisError.notLoaded })
        do {
            try await passing.load(from: try completeFolder())
            XCTFail("load must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .notLoaded)
        }
    }

    func testSecondLoadWhileLoadingIsRejected() async throws {
        let gate = Gate()
        let entered = Gate()
        let speech = PhononSpeech(availability: .available, makeEngine: { _ in
            entered.open()
            await gate.wait()
            return FakeEngine(behavior: .frames([]))
        })
        let folder = try completeFolder()
        let first = Task { try await speech.load(from: folder) }
        await entered.wait()
        do {
            try await speech.load(from: folder)
            XCTFail("second load must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .loadInProgress)
        }
        gate.open()
        try await first.value
        let isLoaded = await speech.isLoaded
        XCTAssertTrue(isLoaded)
    }

    func testSynthesizeRequiresALoadedVoiceAndAnySpeech() async throws {
        let unloaded = PhononSpeech(availability: .available, makeEngine: { _ in FakeEngine(behavior: .frames([])) })
        do {
            _ = try await unloaded.synthesize(sentence: "Hello.")
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .notLoaded)
        }
        let speech = try await loaded(FakeEngine(behavior: .frames([])))
        do {
            _ = try await speech.synthesize(sentence: " \n ")
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .emptySentence)
        }
    }

    func testBuffersAreMonoFloat32AtTheStatedRateFiniteBoundedAndFiltered() async throws {
        let frame = (0..<1_920).map { Float(sin(Double($0) * 0.05)) * 3 }
        let engine = FakeEngine(sampleRate: 24_000, behavior: .frames([frame, frame, []]))
        let speech = try await loaded(engine)
        let buffers = try await collect(try await speech.synthesize(sentence: "One sentence."))
        XCTAssertEqual(buffers.count, 2)
        var filter = TtsPostFilter(sampleRate: 24_000)
        for buffer in buffers {
            XCTAssertEqual(buffer.sampleRate, 24_000)
            XCTAssertEqual(buffer.samples.count, 1_920)
            XCTAssertEqual(buffer.duration, 0.08, accuracy: 1e-9)
            XCTAssertTrue(buffer.samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
            var expected = frame
            filter.process(&expected)
            XCTAssertEqual(buffer.samples, expected.map { min(1, max(-1, $0)) })
        }
    }

    func testEngineFailureMidSentenceSurfacesAfterTheBuffersAlreadySent() async throws {
        let speech = try await loaded(FakeEngine(behavior: .framesThenFail([[0.1, 0.2, 0.3]])))
        let stream = try await speech.synthesize(sentence: "Hello.")
        var received = 0
        do {
            for try await _ in stream { received += 1 }
            XCTFail("stream must fail")
        } catch {
            guard case .synthesisFailed = error as? SpeechSynthesisError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(received, 1)
    }

    func testCancelWithNothingRunningIsHarmlessAndSpeechStillWorks() async throws {
        let speech = try await loaded(FakeEngine(behavior: .frames([[0.1, 0.2]])))
        await speech.cancel()
        let buffers = try await collect(try await speech.synthesize(sentence: "Hello."))
        XCTAssertEqual(buffers.count, 1)
    }

    func testCancelBeforeAnyAudioEndsTheStreamAsCancelledAndStopsTheEngine() async throws {
        let engine = FakeEngine(behavior: .holdUntilReleased)
        let speech = try await loaded(engine)
        let stream = try await speech.synthesize(sentence: "Hello.")
        await speech.cancel()
        var received = 0
        do {
            for try await _ in stream { received += 1 }
            XCTFail("stream must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .cancelled)
        }
        XCTAssertEqual(received, 0)
        XCTAssertEqual(engine.terminated.value, 1)
    }

    func testCancelDuringSynthesisStopsAfterTheBuffersAlreadyDelivered() async throws {
        let engine = FakeEngine(behavior: .holdUntilReleased)
        let speech = try await loaded(engine)
        let stream = try await speech.synthesize(sentence: "Hello.")
        engine.release.open()
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.samples.count, 2)
        await speech.cancel()
        do {
            while try await iterator.next() != nil {}
            XCTFail("stream must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .cancelled)
        }
        XCTAssertEqual(engine.terminated.value, 1)
    }

    func testStartingANewSentenceCancelsTheRunningOne() async throws {
        let engine = FakeEngine(behavior: .holdUntilReleased)
        let speech = try await loaded(engine)
        let first = try await speech.synthesize(sentence: "One.")
        let second = try await speech.synthesize(sentence: "Two.")
        do {
            for try await _ in first {}
            XCTFail("first stream must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .cancelled)
        }
        engine.release.open()
        var iterator = second.makeAsyncIterator()
        let buffer = try await iterator.next()
        XCTAssertNotNil(buffer)
        await speech.cancel()
    }

    func testUnloadCancelsSpeechAndReleasesTheVoice() async throws {
        let engine = FakeEngine(behavior: .holdUntilReleased)
        let speech = try await loaded(engine)
        let stream = try await speech.synthesize(sentence: "Hello.")
        await speech.unload()
        let isLoaded = await speech.isLoaded
        XCTAssertFalse(isLoaded)
        do {
            for try await _ in stream {}
            XCTFail("stream must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .cancelled)
        }
        do {
            _ = try await speech.synthesize(sentence: "Again.")
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .notLoaded)
        }
    }

    func testReloadReplacesTheEngine() async throws {
        let calls = Counter()
        let speech = PhononSpeech(availability: .available, makeEngine: { _ in
            calls.increment()
            return FakeEngine(behavior: .frames([[0.1]]))
        })
        let folder = try completeFolder()
        try await speech.load(from: folder)
        try await speech.load(from: folder)
        XCTAssertEqual(calls.value, 2)
        let buffers = try await collect(try await speech.synthesize(sentence: "Hello."))
        XCTAssertEqual(buffers.count, 1)
    }

    func testErrorsDescribeThemselves() {
        let errors: [SpeechSynthesisError] = [
            .unavailable(.operatingSystemTooOld(required: "iOS 18")), .modelFolderIncomplete(missing: ["a"]),
            .loadFailed("x"), .loadInProgress, .notLoaded, .emptySentence, .synthesisFailed("x"), .cancelled,
        ]
        XCTAssertTrue(errors.allSatisfy { ($0.errorDescription ?? "").isEmpty == false })
    }
}

final class LoopbackTripwireTests: XCTestCase {
    func testTheTripwireCountsARealConnectionAttempt() async throws {
        let tripwire = try LoopbackTripwire()
        try await tripwire.start()
        defer { tripwire.stop() }
        XCTAssertEqual(tripwire.connectionCount, 0)
        _ = try? await URLSession(configuration: .ephemeral).data(from: URL(string: tripwire.baseURL)!)
        XCTAssertGreaterThan(tripwire.connectionCount, 0)
    }
}
