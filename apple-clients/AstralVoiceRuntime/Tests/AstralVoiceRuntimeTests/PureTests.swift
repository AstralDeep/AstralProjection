// Tests for the parts of the runtime that need no model: the padding rule, UTF-8 assembly of split tokens, language names and the scheduler's queueing.
// They run on every platform the package supports and make no assumptions about timing.
@testable import AstralVoiceRuntime
import XCTest

final class AudioPaddingTests: XCTestCase {
    func testPadsToWholeSecondsMinusOneHundredSixtySamples() {
        XCTAssertEqual(AudioPadding.paddedCount(for: 1), 15_840)
        XCTAssertEqual(AudioPadding.paddedCount(for: 15_840), 15_840)
        XCTAssertEqual(AudioPadding.paddedCount(for: 15_841), 31_840)
        XCTAssertEqual(AudioPadding.paddedCount(for: 16_000), 31_840)
        XCTAssertEqual(AudioPadding.paddedCount(for: 48_000), 63_840)
        XCTAssertEqual(AudioPadding.paddedCount(for: 479_999), 495_840)
    }

    func testEveryPaddedLengthIsAWholeNumberOfHundredMelFrames() {
        for count in stride(from: 1, to: 100_000, by: 977) {
            let padded = AudioPadding.paddedCount(for: count)
            XCTAssertGreaterThanOrEqual(padded, count)
            XCTAssertEqual((padded + 160) % 16_000, 0)
            XCTAssertEqual((padded / 160 + 1) % 100, 0)
            XCTAssertLessThan(padded - count, 16_000)
        }
    }

    func testPaddedClipKeepsSamplesAndAppendsZeros() {
        let samples: [Float] = [0.5, -0.25, 0.75]
        let padded = AudioPadding.padded(samples)
        XCTAssertEqual(padded.count, 15_840)
        XCTAssertEqual(Array(padded.prefix(3)), samples)
        XCTAssertTrue(padded.dropFirst(3).allSatisfy { $0 == 0 })
        let exact = [Float](repeating: 0.1, count: 15_840)
        XCTAssertEqual(AudioPadding.padded(exact), exact)
    }
}

final class Utf8AssemblerTests: XCTestCase {
    func testHoldsBackAnIncompleteCharacter() {
        var assembler = Utf8Assembler()
        let bytes = Array("é€😀".utf8)
        var output = ""
        for byte in bytes { output += assembler.append([byte]) }
        output += assembler.finish()
        XCTAssertEqual(output, "é€😀")
    }

    func testEmitsCompletePrefixImmediately() {
        var assembler = Utf8Assembler()
        XCTAssertEqual(assembler.append(Array("ab".utf8) + [0xE2, 0x82]), "ab")
        XCTAssertEqual(assembler.append([0xAC]), "€")
        XCTAssertEqual(assembler.finish(), "")
    }

    func testDanglingBytesFlushAsReplacement() {
        var assembler = Utf8Assembler()
        XCTAssertEqual(assembler.append([0xE2, 0x82]), "")
        XCTAssertEqual(assembler.finish(), "\u{FFFD}")
    }
}

final class RecognitionLanguageTests: XCTestCase {
    func testAcceptsCodesAndNames() throws {
        XCTAssertEqual(try RecognitionLanguage(code: "de").englishName, "German")
        XCTAssertEqual(try RecognitionLanguage(code: "JA").englishName, "Japanese")
        XCTAssertEqual(try RecognitionLanguage(code: "Spanish").code, "es")
        XCTAssertEqual(RecognitionLanguage.english.englishName, "English")
    }

    func testRejectsUnknownLanguages() {
        XCTAssertThrowsError(try RecognitionLanguage(code: "xx")) { XCTAssertEqual($0 as? VoiceRuntimeError, .unsupportedLanguage("xx")) }
        XCTAssertThrowsError(try RecognitionLanguage(code: ""))
    }

    func testStyleTags() {
        XCTAssertEqual(RecognitionStyle().tags, "<digits><nofiller><verbatim>")
        XCTAssertEqual(RecognitionStyle(digits: false, fillers: true, verbatim: false).tags, "<nodigits><filler><noverbatim>")
    }
}

final class SchedulerQueueTests: XCTestCase {
    func testRecognitionIsServedBeforeEarlierGeneration() async throws {
        let scheduler = RuntimeScheduler()
        let gate = Gate()
        let log = EventLog()
        let holder = Task { try await scheduler.perform(.generation) { await gate.wait() } }
        await waitUntil { await scheduler.isBusy }
        let firstGeneration = Task { try await scheduler.perform(.generation) { await log.add("generation-1") } }
        await waitUntil { await scheduler.waitingCount == 1 }
        let secondGeneration = Task { try await scheduler.perform(.generation) { await log.add("generation-2") } }
        await waitUntil { await scheduler.waitingCount == 2 }
        let recognition = Task { try await scheduler.perform(.recognition) { await log.add("recognition") } }
        await waitUntil { await scheduler.waitingCount == 3 }
        await gate.open()
        try await holder.value
        try await firstGeneration.value
        try await secondGeneration.value
        try await recognition.value
        let events = await log.events
        XCTAssertEqual(events, ["recognition", "generation-1", "generation-2"])
    }

    func testCancelledWaiterLeavesTheQueueAndTheSlotIsReleased() async throws {
        let scheduler = RuntimeScheduler()
        let gate = Gate()
        let holder = Task { try await scheduler.perform(.recognition) { await gate.wait() } }
        await waitUntil { await scheduler.isBusy }
        let waiting = Task { try await scheduler.perform(.generation) { 1 } }
        await waitUntil { await scheduler.waitingCount == 1 }
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("a cancelled waiter must not run")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await waitUntil { await scheduler.waitingCount == 0 }
        await gate.open()
        try await holder.value
        let value = try await scheduler.perform(.generation) { 7 }
        XCTAssertEqual(value, 7)
        let busy = await scheduler.isBusy
        XCTAssertFalse(busy)
    }

    func testOperationErrorStillReleasesTheSlot() async throws {
        struct Failure: Error {}
        let scheduler = RuntimeScheduler()
        do {
            try await scheduler.perform(.generation) { throw Failure() }
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        let busy = await scheduler.isBusy
        XCTAssertFalse(busy)
    }
}
