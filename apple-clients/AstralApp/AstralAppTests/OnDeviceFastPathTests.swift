// Verifies the fast path: drafts start on a stable partial, are discarded when the person keeps talking, and yield only short, safe acknowledgements.
// A scripted model stands in for the system model.

import XCTest

@testable import AstralDeep

@MainActor
final class OnDeviceFastPathTests: XCTestCase {
    func testSanitizerKeepsShortStatementsOnly() {
        XCTAssertEqual(VoiceAcknowledgement.sanitize(" \"Sure, one moment.\" "), "Sure, one moment.")
        XCTAssertEqual(VoiceAcknowledgement.sanitize("Okay.\nSecond line"), "Okay.")
        XCTAssertNil(VoiceAcknowledgement.sanitize(""))
        XCTAssertNil(VoiceAcknowledgement.sanitize("Would you like that?"))
        XCTAssertNil(VoiceAcknowledgement.sanitize("one two three four five six seven eight nine"))
        XCTAssertNil(VoiceAcknowledgement.sanitize(String(repeating: "a", count: 81)))
    }

    func testRequestIsATextRequestWithNoSchemaAndASmallBudget() {
        let request = VoiceAcknowledgement.request(for: "what time is it")
        XCTAssertNil(request.schemaJSON)
        XCTAssertLessThanOrEqual(request.maxTokens, 32)
        XCTAssertEqual(request.messages.last, OnDeviceMessage(role: .user, text: "what time is it"))
    }

    func testSpeculationStartsOneDraftPerTranscript() async {
        let model = FakeOnDeviceModel(mode: .hang)
        let fast = VoiceFastPath(model: model)
        fast.speculate("what time is it")
        fast.speculate("What time is it?")
        let reached1 = await waitUntil { model.requests.count == 1 }
        XCTAssertTrue(reached1)
        XCTAssertTrue(fast.hasDraft)
        fast.discard()
        let reached2 = await waitUntil { model.cancellationCount == 1 }
        XCTAssertTrue(reached2)
        XCTAssertFalse(fast.hasDraft)
    }

    func testChangedTranscriptReplacesTheDraft() async {
        let model = FakeOnDeviceModel(mode: .hang)
        let fast = VoiceFastPath(model: model)
        fast.speculate("what time")
        fast.speculate("what time is it in Paris")
        let reached3 = await waitUntil { model.cancellationCount == 1 && model.requests.count == 2 }
        XCTAssertTrue(reached3)
        fast.discard()
    }

    func testMatchingFinalReusesTheDraft() async {
        let model = FakeOnDeviceModel(mode: .respond(.text("Sure.")))
        let fast = VoiceFastPath(model: model)
        fast.speculate("what time is it")
        let acknowledgement = await fast.acknowledgement(forFinal: "What time is it?")
        XCTAssertEqual(acknowledgement, "Sure.")
        XCTAssertEqual(model.requests.count, 1)
    }

    func testDifferentFinalStartsAFreshRequest() async {
        let model = FakeOnDeviceModel(mode: .respond(.text("Okay.")))
        let fast = VoiceFastPath(model: model)
        fast.speculate("what time")
        let acknowledgement = await fast.acknowledgement(forFinal: "set a timer")
        XCTAssertEqual(acknowledgement, "Okay.")
        XCTAssertEqual(model.requests.last?.messages.last?.text, "set a timer")
    }

    func testUnavailableModelProducesNothing() async {
        let model = FakeOnDeviceModel(available: false)
        let fast = VoiceFastPath(model: model)
        fast.speculate("hello")
        XCTAssertFalse(fast.hasDraft)
        let acknowledgement = await fast.acknowledgement(forFinal: "hello")
        XCTAssertNil(acknowledgement)
        XCTAssertTrue(model.requests.isEmpty)
    }

    func testRefusalsFailuresAndLongTextProduceNothing() async {
        for response in [
            OnDeviceResponse.refused("no"), .unavailable(.modelNotReady), .failed(.busy),
            .json("{}"), .text("This reply is far too long to be a short acknowledgement of anything"),
        ] {
            let fast = VoiceFastPath(model: FakeOnDeviceModel(mode: .respond(response)))
            let acknowledgement = await fast.acknowledgement(forFinal: "hello")
            XCTAssertNil(acknowledgement)
        }
    }
}
