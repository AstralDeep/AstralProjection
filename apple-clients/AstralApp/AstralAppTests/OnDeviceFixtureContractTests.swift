// Keeps scripted model answers compatible with the engine's constrained local tool envelope.
// Other reader schemas and explicit malformed or refused responses remain unchanged.

@testable import AstralDeep
import Foundation
import XCTest

final class OnDeviceFixtureContractTests: XCTestCase {
    private let envelope =
        #"{"type":"object","properties":{"text":{"type":"string"},"calls":{"type":"array","minItems":0,"maxItems":64,"items":{"type":"object","properties":{"tool":{"type":"string","enum":["current_datetime"]},"arguments_json":{"type":"string"}},"required":["tool","arguments_json"],"additionalProperties":false}}},"required":["text","calls"],"additionalProperties":false}"#

    private func request(_ schema: String?) -> OnDeviceRequest {
        OnDeviceRequest(
            messages: [OnDeviceMessage(role: .user, text: "A fixture question")], schemaJSON: schema, maxTokens: 128)
    }

    func testPlainFixtureAnswerBecomesAValidTextOnlyToolEnvelope() async throws {
        let text = "A quoted \"answer\"."
        let model = FakeOnDeviceModel(mode: .respond(.text(text)))
        let result = await model.complete(request(envelope))
        guard case .json(let json) = result else {
            return XCTFail("The constrained request needs its valid JSON envelope")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["text", "calls"])
        XCTAssertEqual(object["text"] as? String, text)
        XCTAssertEqual((object["calls"] as? [Any])?.count, 0)
    }

    func testMissingDifferentAndMalformedSchemasDoNotChangePlainResponses() async throws {
        let model = FakeOnDeviceModel(mode: .respond(.text("Plain")))
        var alternate = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        alternate["required"] = ["text"]
        let changed = String(decoding: try JSONSerialization.data(withJSONObject: alternate), as: UTF8.self)
        var constrained = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        var properties = try XCTUnwrap(constrained["properties"] as? [String: Any])
        properties["text"] = ["type": "string", "enum": ["Literal"]]
        constrained["properties"] = properties
        let otherText = String(decoding: try JSONSerialization.data(withJSONObject: constrained), as: UTF8.self)
        for schema in [
            nil, "{", #"{"type":"object","properties":{"date":{"type":"string"}},"required":["date"]}"#, changed,
            otherText,
        ] {
            let result = await model.complete(request(schema))
            XCTAssertEqual(result, .text("Plain"))
        }
    }

    func testExplicitRefusalsUnsupportedAndMalformedJSONAreNeverRepaired() async {
        for response: OnDeviceResponse in [.refused("Refused"), .failed(.schemaUnsupported), .json("not JSON")] {
            let model = FakeOnDeviceModel(mode: .respond(response))
            let result = await model.complete(request(envelope))
            XCTAssertEqual(result, response)
        }
    }
}
