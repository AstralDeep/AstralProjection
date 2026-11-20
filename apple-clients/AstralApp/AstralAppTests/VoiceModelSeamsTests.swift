// Checks the collector that turns a local-text stream into one string, including failure and cancellation.
// The seams themselves are exercised through the pipeline, transcriber and fallback tests that use fakes at these protocols.

import XCTest

@testable import AstralDeep

final class VoiceModelSeamsTests: XCTestCase {
    func testCollectedJoinsEveryPieceInOrder() async throws {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for piece in ["Hel", "lo ", "there"] { continuation.yield(piece) }
            continuation.finish()
        }
        let text = try await stream.collected()
        XCTAssertEqual(text, "Hello there")
    }

    func testCollectedPropagatesAStreamFailure() async {
        struct Failure: Error {}
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("partial")
            continuation.finish(throwing: Failure())
        }
        do {
            _ = try await stream.collected()
            XCTFail("the failure must reach the caller")
        } catch is Failure {} catch { XCTFail("unexpected \(error)") }
    }

    func testCollectedThrowsCancellationInsteadOfReturningPartialText() async {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task { try await stream.collected() }
        continuation.yield("partial")
        task.cancel()
        continuation.finish()
        do {
            _ = try await task.value
            XCTFail("a cancelled collection must not return text")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    }
}
