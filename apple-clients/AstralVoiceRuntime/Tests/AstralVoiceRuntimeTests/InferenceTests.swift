// Runs real llama.cpp inference on the committed tiny fixture models: loading, recognition with streamed tokens, text generation, limits, cancellation and scheduling between the two engines.
// The models have random weights, so the text is meaningless and the tests assert behaviour, not content.
@testable import AstralVoiceRuntime
import XCTest

final class RecognitionTests: XCTestCase {
    func testTranscribesAndStreamsEveryToken() async throws {
        let recognizer = try await loadRecognizer()
        let chunks = EventLog()
        let result = try await recognizer.transcribe(sine(seconds: 1.5), language: .english, maxTokens: 12) { text in
            Task { await chunks.add(text) }
        }
        XCTAssertEqual(result.tokenCount, 12)
        XCTAssertEqual(result.stop, .tokenLimit)
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertEqual(result.paddedSampleCount, 31_840)
        await waitUntil { await chunks.events.joined() == result.text }
    }

    func testSameAudioAndLanguageGiveTheSameText() async throws {
        let recognizer = try await loadRecognizer()
        let first = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 10)
        let second = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 10)
        XCTAssertEqual(first.text, second.text)
    }

    func testLanguageAndAudioChangeWhatTheModelSees() async throws {
        let recognizer = try await loadRecognizer()
        let english = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 12)
        let french = try await recognizer.transcribe(sine(seconds: 1), language: try RecognitionLanguage(code: "fr"), maxTokens: 12)
        let other = try await recognizer.transcribe(sine(seconds: 2, frequency: 1_300), language: .english, maxTokens: 12)
        XCTAssertNotEqual(english.text, french.text)
        XCTAssertNotEqual(english.text, other.text)
    }

    func testLongClipIsAccepted() async throws {
        let recognizer = try await loadRecognizer()
        let result = try await recognizer.transcribe(sine(seconds: 25), language: .english, maxTokens: 4)
        XCTAssertEqual(result.tokenCount, 4)
        XCTAssertEqual(result.paddedSampleCount, 415_840)
    }

    func testRejectsBadInput() async throws {
        let recognizer = try await loadRecognizer()
        await assertThrows(.emptyAudio) { _ = try await recognizer.transcribe([], language: .english) }
        await assertThrows(.audioTooLong(maximumSeconds: 30)) {
            _ = try await recognizer.transcribe([Float](repeating: 0, count: 30 * 16_000 + 1), language: .english)
        }
        await assertThrows(.invalidTokenLimit(0)) { _ = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 0) }
    }

    func testStopsWhenContextIsFull() async throws {
        let small = RuntimeConfiguration(compute: .cpuOnly, contextTokens: 256, batchTokens: 64, threads: 2)
        let recognizer = try await SpeechRecognizer.load(model: Fixtures.asr, audioEncoder: Fixtures.encoder, configuration: small, scheduler: RuntimeScheduler())
        let result = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 1_000)
        XCTAssertEqual(result.stop, .contextFull)
        XCTAssertGreaterThan(result.tokenCount, 0)
        XCTAssertLessThan(result.tokenCount, 256)
        await assertThrows(.promptTooLong) { _ = try await recognizer.transcribe(sine(seconds: 25), language: .english, maxTokens: 4) }
    }

    func testCancellationStopsGenerationAtTheNextToken() async throws {
        let recognizer = try await loadRecognizer()
        let counter = Counter()
        let box = TaskBox()
        let task = Task {
            try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 1_000) { _ in counter.tick() }
        }
        box.store { task.cancel() }
        counter.fire(at: 3) { box.cancel() }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(counter.count, 3)
        let next = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 5)
        XCTAssertEqual(next.tokenCount, 5)
    }

    func testStreamYieldsTextAndCancelsWhenTheConsumerStops() async throws {
        let recognizer = try await loadRecognizer()
        var joined = ""
        for try await piece in recognizer.stream(sine(seconds: 1), language: .english, maxTokens: 9) { joined += piece }
        let direct = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 9)
        XCTAssertEqual(joined, direct.text)

        var seen = 0
        for try await _ in recognizer.stream(sine(seconds: 1), language: .english, maxTokens: 1_000) {
            seen += 1
            if seen == 2 { break }
        }
        let after = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 3)
        XCTAssertEqual(after.tokenCount, 3)
    }

    func testUnloadedRecognizerRefuses() async throws {
        let recognizer = try await loadRecognizer()
        await recognizer.unload()
        await assertThrows(.unloaded) { _ = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 2) }
    }

    func testLoadFailures() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/model.gguf")
        await assertThrows(.fileNotFound(missing)) {
            _ = try await SpeechRecognizer.load(model: missing, audioEncoder: Fixtures.encoder, configuration: cpuConfiguration)
        }
        await assertThrows(.fileNotFound(missing)) {
            _ = try await SpeechRecognizer.load(model: Fixtures.asr, audioEncoder: missing, configuration: cpuConfiguration)
        }
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-model-\(UUID().uuidString).gguf")
        try Data("this is not a gguf file".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        await assertThrows(.modelLoadFailed(garbage)) {
            _ = try await SpeechRecognizer.load(model: garbage, audioEncoder: Fixtures.encoder, configuration: cpuConfiguration)
        }
        await assertThrows(.encoderLoadFailed(garbage)) {
            _ = try await SpeechRecognizer.load(model: Fixtures.asr, audioEncoder: garbage, configuration: cpuConfiguration)
        }
        await assertThrows(.modelLoadFailed(Fixtures.encoder)) {
            _ = try await SpeechRecognizer.load(model: Fixtures.encoder, audioEncoder: Fixtures.encoder, configuration: cpuConfiguration)
        }
        await assertThrows(.encoderLoadFailed(Fixtures.chat)) {
            _ = try await SpeechRecognizer.load(model: Fixtures.asr, audioEncoder: Fixtures.chat, configuration: cpuConfiguration)
        }
        let invalid = RuntimeConfiguration(compute: .cpuOnly, contextTokens: 8, batchTokens: 8, threads: 1)
        await assertThrows(.invalidConfiguration("contextTokens must be at least 256")) {
            _ = try await SpeechRecognizer.load(model: Fixtures.asr, audioEncoder: Fixtures.encoder, configuration: invalid)
        }
    }
}

final class GenerationTests: XCTestCase {
    private let conversation = [ChatMessage(.system, "Be brief."), ChatMessage(.user, "Name a fruit.")]

    func testGeneratesToTheTokenLimitAndStreams() async throws {
        let generator = try await loadGenerator()
        let chunks = EventLog()
        let result = try await generator.generate(conversation, options: GenerationOptions(maxTokens: 20)) { text in
            Task { await chunks.add(text) }
        }
        XCTAssertEqual(result.tokenCount, 20)
        XCTAssertEqual(result.stop, .tokenLimit)
        await waitUntil { await chunks.events.joined() == result.text }
    }

    func testEndsWhenTheModelEmitsItsEndToken() async throws {
        let generator = try await loadGenerator(Fixtures.chatShort)
        let result = try await generator.generate(conversation, options: GenerationOptions(maxTokens: 50))
        XCTAssertEqual(result.stop, .endOfSequence)
        XCTAssertEqual(result.tokenCount, 0)
        XCTAssertEqual(result.text, "")
    }

    func testGreedyIsRepeatableAndSeededSamplingFollowsTheSeed() async throws {
        let generator = try await loadGenerator()
        let greedyA = try await generator.generate(conversation, options: GenerationOptions(maxTokens: 16))
        let greedyB = try await generator.generate(conversation, options: GenerationOptions(maxTokens: 16))
        XCTAssertEqual(greedyA.text, greedyB.text)
        let sampled = GenerationOptions(maxTokens: 16, temperature: 1.5, topK: 40, seed: 7)
        let first = try await generator.generate(conversation, options: sampled)
        let second = try await generator.generate(conversation, options: sampled)
        let reseeded = try await generator.generate(conversation, options: GenerationOptions(maxTokens: 16, temperature: 1.5, topK: 40, seed: 8))
        XCTAssertEqual(first.text, second.text)
        XCTAssertNotEqual(first.text, reseeded.text)
    }

    func testTheConversationChangesTheOutput() async throws {
        let generator = try await loadGenerator()
        let one = try await generator.generate(conversation, options: GenerationOptions(maxTokens: 12))
        let two = try await generator.generate([ChatMessage(.user, "Something else entirely, with more words in it.")], options: GenerationOptions(maxTokens: 12))
        XCTAssertNotEqual(one.text, two.text)
    }

    func testStopsWhenContextIsFull() async throws {
        let generator = try await loadGenerator()
        let result = try await generator.generate(conversation, options: GenerationOptions(maxTokens: 100_000))
        XCTAssertEqual(result.stop, .contextFull)
        XCTAssertGreaterThan(result.tokenCount, 900)
        let long = [ChatMessage(.user, String(repeating: "word ", count: 2_000))]
        await assertThrows(.promptTooLong) { _ = try await generator.generate(long, options: GenerationOptions(maxTokens: 4)) }
    }

    func testRejectsBadInput() async throws {
        let generator = try await loadGenerator()
        await assertThrows(.emptyConversation) { _ = try await generator.generate([]) }
        await assertThrows(.invalidTokenLimit(-1)) { _ = try await generator.generate(conversation, options: GenerationOptions(maxTokens: -1)) }
    }

    func testModelWithoutTemplateIsRefused() async throws {
        let generator = try await loadGenerator(Fixtures.asr)
        await assertThrows(.chatTemplateUnavailable) { _ = try await generator.generate(conversation) }
    }

    func testCancellationStopsGenerationAtTheNextToken() async throws {
        let generator = try await loadGenerator()
        let counter = Counter()
        let box = TaskBox()
        let task = Task {
            try await generator.generate(conversation, options: GenerationOptions(maxTokens: 100_000)) { _ in counter.tick() }
        }
        box.store { task.cancel() }
        counter.fire(at: 5) { box.cancel() }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(counter.count, 5)
    }

    func testStreamFinishesAndMatchesGenerate() async throws {
        let generator = try await loadGenerator()
        var joined = ""
        for try await piece in generator.stream(conversation, options: GenerationOptions(maxTokens: 10)) { joined += piece }
        let direct = try await generator.generate(conversation, options: GenerationOptions(maxTokens: 10))
        XCTAssertEqual(joined, direct.text)
    }

    func testLoadFailures() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/chat.gguf")
        do {
            _ = try await TextGenerator.load(model: missing, configuration: cpuConfiguration)
            XCTFail("expected a throw")
        } catch { XCTAssertEqual(error as? VoiceRuntimeError, .fileNotFound(missing)) }
        do {
            _ = try await TextGenerator.load(model: Fixtures.encoder, configuration: cpuConfiguration)
            XCTFail("expected a throw")
        } catch { XCTAssertEqual(error as? VoiceRuntimeError, .modelLoadFailed(Fixtures.encoder)) }
    }
}

final class SharedSchedulerTests: XCTestCase {
    func testRecognitionRunsBeforeWaitingGenerationOnRealModels() async throws {
        let scheduler = RuntimeScheduler()
        let recognizer = try await loadRecognizer(scheduler: scheduler)
        let generator = try await loadGenerator(scheduler: scheduler)
        let gate = Gate()
        let log = EventLog()
        let holder = Task { try await scheduler.perform(.generation) { await gate.wait() } }
        await waitUntil { await scheduler.isBusy }
        let generation = Task {
            let result = try await generator.generate([ChatMessage(.user, "Hello")], options: GenerationOptions(maxTokens: 6))
            await log.add("generation")
            return result
        }
        await waitUntil { await scheduler.waitingCount == 1 }
        let recognition = Task {
            let result = try await recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 6)
            await log.add("recognition")
            return result
        }
        await waitUntil { await scheduler.waitingCount == 2 }
        await gate.open()
        try await holder.value
        let heard = try await recognition.value
        let said = try await generation.value
        XCTAssertEqual(heard.tokenCount, 6)
        XCTAssertEqual(said.tokenCount, 6)
        let events = await log.events
        XCTAssertEqual(events, ["recognition", "generation"])
    }

    func testTwoEnginesNeverRunTogether() async throws {
        let scheduler = RuntimeScheduler()
        let recognizer = try await loadRecognizer(scheduler: scheduler)
        let generator = try await loadGenerator(scheduler: scheduler)
        let overlap = OverlapProbe()
        async let heard = recognizer.transcribe(sine(seconds: 1), language: .english, maxTokens: 30) { _ in overlap.touch("recognition") }
        async let said = generator.generate([ChatMessage(.user, "Hello")], options: GenerationOptions(maxTokens: 30)) { _ in overlap.touch("generation") }
        _ = try await (heard, said)
        XCTAssertEqual(overlap.interleavings, 0)
    }
}

final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?

    func store(_ action: @escaping () -> Void) {
        lock.lock(); self.action = action; lock.unlock()
    }

    func cancel() {
        lock.lock(); let pending = action; lock.unlock()
        pending?()
    }
}

final class OverlapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var last: String?
    private var sequence: [String] = []

    func touch(_ source: String) {
        lock.lock(); defer { lock.unlock() }
        if sequence.last != source { sequence.append(source) }
        last = source
    }

    var interleavings: Int {
        lock.lock(); defer { lock.unlock() }
        return max(0, sequence.count - 2)
    }
}

func assertThrows(_ expected: VoiceRuntimeError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? VoiceRuntimeError, expected, file: file, line: line)
    }
}
