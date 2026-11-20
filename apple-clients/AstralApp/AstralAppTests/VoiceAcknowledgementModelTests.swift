// Checks that the acknowledgement model drafts through the local text generator, refuses structured and empty requests, and reports cancellation and failures honestly.
// A scripted generator stands in for LFM2.5, so no model loads.

import XCTest

@testable import AstralDeep

final class VoiceAcknowledgementModelTests: XCTestCase {
    private struct ScriptedGenerator: VoiceTextGenerating {
        let result: Result<String, Error>
        func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                switch result {
                case .success(let text):
                    continuation.yield(text)
                    continuation.finish()
                case .failure(let error): continuation.finish(throwing: error)
                }
            }
        }
    }

    func testAcknowledgementUsesTheGeneratorAndRejectsAStructuredRequest() async {
        let model = VoiceAcknowledgementModel(generator: ScriptedGenerator(result: .success("I heard you.")))
        XCTAssertTrue(model.available())
        let response = await model.complete(VoiceAcknowledgement.request(for: "Call the clinic tomorrow."))
        XCTAssertEqual(response, .text("I heard you."))
        let structured = OnDeviceRequest(messages: [], schemaJSON: "{}", maxTokens: 24)
        let rejected = await model.complete(structured)
        XCTAssertEqual(rejected, .failed(.schemaUnsupported))
    }

    func testAnEmptyRequestIsRefusedBeforeTheGeneratorRuns() async {
        let model = VoiceAcknowledgementModel(generator: ScriptedGenerator(result: .success("never")))
        let response = await model.complete(OnDeviceRequest(messages: [], schemaJSON: nil, maxTokens: 24))
        XCTAssertEqual(response, .failed(.emptyRequest))
    }

    func testAGeneratorFailureIsReportedAsAFailedGeneration() async {
        let model = VoiceAcknowledgementModel(generator: ScriptedGenerator(result: .failure(CocoaError(.fileReadUnknown))))
        let response = await model.complete(VoiceAcknowledgement.request(for: "Call the clinic tomorrow."))
        XCTAssertEqual(response, .failed(.generationFailed))
    }

    func testACancelledDraftReportsCancelled() async {
        let model = VoiceAcknowledgementModel(generator: ScriptedGenerator(result: .success("late")))
        let task = Task { () -> OnDeviceResponse in
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.complete(VoiceAcknowledgement.request(for: "Call the clinic tomorrow."))
        }
        let response = await task.value
        XCTAssertEqual(response, .failed(.cancelled))
    }
}
