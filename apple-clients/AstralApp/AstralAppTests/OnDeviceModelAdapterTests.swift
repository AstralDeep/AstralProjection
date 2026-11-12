// Verifies the on-device model adapter's schema parsing, output validation, prompt composition and availability reporting.
// Generation itself needs the system model, so these tests cover only the paths that return before any generation.

import Foundation
import XCTest

#if canImport(FoundationModels)
    import FoundationModels
#endif

@testable import AstralDeep

final class OnDeviceModelAdapterTests: XCTestCase {
    private let schemaJSON = """
        {"type":"object","properties":{
          "date":{"type":"string"},
          "kind":{"type":"string","enum":["meeting","deadline"]},
          "count":{"type":"integer","minimum":1,"maximum":5},
          "tags":{"type":"array","items":{"type":"string"},"maxItems":2},
          "urgent":{"type":"boolean"}},
         "required":["date","kind"]}
        """

    func testSchemaParsesAndAcceptsConformingJSON() throws {
        let schema = try OnDeviceJSONSchema(json: schemaJSON)
        XCTAssertTrue(schema.accepts(#"{"date":"2026-11-12","kind":"meeting","count":3,"tags":["a"],"urgent":true}"#))
        XCTAssertTrue(schema.accepts(#"{"date":"x","kind":"deadline"}"#))
    }

    func testSchemaRejectsNonConformingJSON() throws {
        let schema = try OnDeviceJSONSchema(json: schemaJSON)
        XCTAssertFalse(schema.accepts(#"{"kind":"meeting"}"#))
        XCTAssertFalse(schema.accepts(#"{"date":"x","kind":"party"}"#))
        XCTAssertFalse(schema.accepts(#"{"date":"x","kind":"meeting","count":9}"#))
        XCTAssertFalse(schema.accepts(#"{"date":"x","kind":"meeting","count":2.5}"#))
        XCTAssertFalse(schema.accepts(#"{"date":"x","kind":"meeting","tags":["a","b","c"]}"#))
        XCTAssertFalse(schema.accepts(#"{"date":"x","kind":"meeting","urgent":1}"#))
        XCTAssertFalse(schema.accepts(#"{"date":"x","kind":"meeting","extra":1}"#))
        XCTAssertFalse(schema.accepts("not json"))
        XCTAssertFalse(schema.accepts(#"["date"]"#))
    }

    func testSchemaRejectsUnsupportedShapes() {
        XCTAssertThrowsError(try OnDeviceJSONSchema(json: "nope"))
        XCTAssertThrowsError(try OnDeviceJSONSchema(json: #"{"type":"null"}"#))
        XCTAssertThrowsError(try OnDeviceJSONSchema(json: #"{"properties":{}}"#))
        XCTAssertThrowsError(try OnDeviceJSONSchema(json: #"{"type":"string","enum":[]}"#))
        XCTAssertThrowsError(try OnDeviceJSONSchema(json: #"{"type":"array"}"#))
    }

    func testPromptComposerSeparatesInstructionsFromConversation() {
        let composed = OnDevicePromptComposer.compose([
            OnDeviceMessage(role: .system, text: "Be brief."),
            OnDeviceMessage(role: .user, text: "first"),
            OnDeviceMessage(role: .assistant, text: "answer"),
            OnDeviceMessage(role: .user, text: "second"),
        ])
        XCTAssertEqual(composed?.instructions, "Be brief.")
        XCTAssertTrue(composed?.prompt.contains("[assistant] answer") == true)
        XCTAssertTrue(composed?.prompt.hasSuffix("second") == true)
    }

    func testPromptComposerSingleUserMessageIsPassedThrough() {
        let composed = OnDevicePromptComposer.compose([OnDeviceMessage(role: .user, text: "hello")])
        XCTAssertEqual(composed, OnDevicePromptComposer.Composed(instructions: nil, prompt: "hello"))
    }

    func testPromptComposerRefusesRequestsWithoutAFinalUserMessage() {
        XCTAssertNil(OnDevicePromptComposer.compose([]))
        XCTAssertNil(OnDevicePromptComposer.compose([OnDeviceMessage(role: .system, text: "x")]))
        XCTAssertNil(
            OnDevicePromptComposer.compose([
                OnDeviceMessage(role: .user, text: "q"), OnDeviceMessage(role: .assistant, text: "a"),
            ]))
        XCTAssertNil(OnDevicePromptComposer.compose([OnDeviceMessage(role: .user, text: "   ")]))
    }

    func testAvailabilityAgreesWithAvailableAndNamesAReasonWhenOff() {
        let model = FoundationModelsOnDeviceModel()
        switch model.availability() {
        case .available: XCTAssertTrue(model.available())
        case .unavailable(let reason):
            XCTAssertFalse(model.available())
            XCTAssertFalse(reason.rawValue.isEmpty)
        }
    }

    func testRequestsThatNeverReachGenerationReportExactOutcomes() async {
        let model = FoundationModelsOnDeviceModel()
        let empty = await model.complete(OnDeviceRequest(messages: [], schemaJSON: nil, maxTokens: 10))
        let badSchema = await model.complete(
            OnDeviceRequest(
                messages: [OnDeviceMessage(role: .user, text: "hi")], schemaJSON: "{", maxTokens: 10))
        switch model.availability() {
        case .available:
            XCTAssertEqual(empty, .failed(.emptyRequest))
            XCTAssertEqual(badSchema, .failed(.schemaUnsupported))
        case .unavailable(let reason):
            XCTAssertEqual(empty, .unavailable(reason))
            XCTAssertEqual(badSchema, .unavailable(reason))
        }
    }

    #if canImport(FoundationModels)
        func testSystemAvailabilityMapsToExactReasons() {
            guard #available(iOS 26.0, macOS 26.0, *) else { return }
            XCTAssertEqual(OnDeviceModelAvailability(.available), .available)
            XCTAssertEqual(
                OnDeviceModelAvailability(.unavailable(.deviceNotEligible)),
                .unavailable(.deviceNotEligible))
            XCTAssertEqual(
                OnDeviceModelAvailability(.unavailable(.appleIntelligenceNotEnabled)),
                .unavailable(.appleIntelligenceDisabled))
            XCTAssertEqual(
                OnDeviceModelAvailability(.unavailable(.modelNotReady)), .unavailable(.modelNotReady))
        }

        func testSchemaConvertsToAGenerationSchema() throws {
            guard #available(iOS 26.0, macOS 26.0, *) else { return }
            let schema = try OnDeviceJSONSchema(json: schemaJSON)
            XCTAssertNoThrow(try schema.generationSchema())
        }
    #endif
}
