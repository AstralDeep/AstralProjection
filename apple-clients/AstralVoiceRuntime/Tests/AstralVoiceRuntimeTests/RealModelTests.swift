// Integration tests that run the real Rumble and LFM2.5 models on a real 16 kHz mono recording, and skip unless the ASTRAL_VOICE_* variables name them.
// They check behaviour end to end on the accelerated and CPU-only configurations without wall-clock bounds or network access.
import AstralVoiceRuntime
import XCTest

final class RealModelTests: XCTestCase {
    private func recognizer(_ models: RealModels, scheduler: RuntimeScheduler = RuntimeScheduler(), configuration: RuntimeConfiguration = RuntimeConfiguration()) async throws -> SpeechRecognizer {
        try await SpeechRecognizer.load(model: models.rumble, audioEncoder: models.encoder, configuration: configuration, scheduler: scheduler)
    }

    private func generator(_ models: RealModels, scheduler: RuntimeScheduler = RuntimeScheduler(), configuration: RuntimeConfiguration = RuntimeConfiguration(contextTokens: 4096)) async throws -> TextGenerator {
        try await TextGenerator.load(model: models.chat, configuration: configuration, scheduler: scheduler)
    }

    func testRumbleTranscribesTheClipWithTheExpectedWords() async throws {
        let models = try RealModels.fromEnvironment()
        let result = try await recognizer(models).transcribe(models.samples, language: .english)
        print("transcript: \(result.text)")
        let heard = Set(words(in: result.text))
        for word in models.expectedWords { XCTAssertTrue(heard.contains(word), "missing \"\(word)\" in \"\(result.text)\"") }
        XCTAssertEqual(result.stop, .endOfSequence)
    }

    func testAShortCutAddsNoWordThatIsAbsentFromTheFullTranscript() async throws {
        let models = try RealModels.fromEnvironment()
        let rumble = try await recognizer(models)
        let full = try await rumble.transcribe(models.samples, language: .english)
        let cut = try await rumble.transcribe(Array(models.samples.prefix(9_600)), language: .english)
        print("full: \(full.text)\ncut:  \(cut.text)")
        let fullWords = Set(words(in: full.text))
        for word in words(in: cut.text) { XCTAssertTrue(fullWords.contains(word), "\"\(word)\" from the cut is not in \"\(full.text)\"") }
    }

    func testLFM25AnswersThroughItsChatTemplateWithinTheLimit() async throws {
        let models = try RealModels.fromEnvironment()
        let result = try await generator(models).generate(
            [ChatMessage(.system, "You are a helpful voice assistant. Reply in one short sentence."), ChatMessage(.user, "Name one fruit that starts with C.")],
            options: GenerationOptions(maxTokens: 48)
        )
        print("reply: \(result.text)")
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertLessThanOrEqual(result.tokenCount, 48)
    }

    func testCancellingTheStreamAfterTwentyTokensStopsGeneration() async throws {
        let models = try RealModels.fromEnvironment()
        let lfm = try await generator(models)
        let produced = Counter()
        let task = Task { () -> Int in
            var received = 0
            let stream = lfm.stream([ChatMessage(.user, "Write a very long story about a dragon.")], options: GenerationOptions(maxTokens: 3_000))
            for try await _ in stream {
                received += 1
                produced.tick()
                if received == 20 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            try Task.checkCancellation()
            return received
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(produced.count, 20)
        let follow = try await lfm.generate([ChatMessage(.user, "Say hi.")], options: GenerationOptions(maxTokens: 4))
        XCTAssertGreaterThan(follow.tokenCount, 0)
    }

    func testRecognitionAndGenerationShareTheSchedulerRecognitionFirst() async throws {
        let models = try RealModels.fromEnvironment()
        let scheduler = RuntimeScheduler()
        let rumble = try await recognizer(models, scheduler: scheduler)
        let lfm = try await generator(models, scheduler: scheduler)
        let gate = Gate()
        let log = EventLog()
        let overlap = OverlapProbe()
        let holder = Task { try await scheduler.perform(.generation) { await gate.wait() } }
        await waitUntil { await scheduler.isBusy }
        let generation = Task {
            let result = try await lfm.generate([ChatMessage(.user, "Say hello.")], options: GenerationOptions(maxTokens: 12)) { _ in overlap.touch("generation") }
            await log.add("generation")
            return result
        }
        await waitUntil { await scheduler.waitingCount == 1 }
        let recognition = Task {
            let result = try await rumble.transcribe(models.samples, language: .english) { _ in overlap.touch("recognition") }
            await log.add("recognition")
            return result
        }
        await waitUntil { await scheduler.waitingCount == 2 }
        await gate.open()
        try await holder.value
        _ = try await recognition.value
        _ = try await generation.value
        let events = await log.events
        XCTAssertEqual(events, ["recognition", "generation"])
        XCTAssertEqual(overlap.interleavings, 0)
    }

    func testCPUOnlyLoadsBothRealModelsAndTranscribesTheClip() async throws {
        let models = try RealModels.fromEnvironment()
        let cpu = RuntimeConfiguration(compute: .cpuOnly)
        let result = try await recognizer(models, configuration: cpu).transcribe(models.samples, language: .english)
        print("cpu transcript: \(result.text)")
        let heard = Set(words(in: result.text))
        for word in models.expectedWords { XCTAssertTrue(heard.contains(word), "missing \"\(word)\" in \"\(result.text)\"") }
        let reply = try await generator(models, configuration: RuntimeConfiguration(compute: .cpuOnly, contextTokens: 2048)).generate([ChatMessage(.user, "Say hi.")], options: GenerationOptions(maxTokens: 8))
        XCTAssertFalse(reply.text.isEmpty)
    }
}
