// Checks bounded proposal metadata and captures without a model, tool runner, credentials or network.
// The host returns an unexecuted proposal and the Kernel retains authorization and dispatch.

@testable import AstralDeep
import Foundation
import XCTest

final class OnDeviceToolProposalTests: XCTestCase {
    private var metadata: String {
        #"{"x-astral-tool-proposals":{"version":1,"tools":[{"name":"send_message","description":"Record synthetic text.","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}}]}}"#
    }

    func testCatalogRequiresVersionedUniqueBoundedDescriptors() throws {
        XCTAssertNil(try OnDeviceToolCatalog(schemaJSON: #"{"type":"object"}"#))
        let catalog = try XCTUnwrap(OnDeviceToolCatalog(schemaJSON: metadata))
        XCTAssertEqual(catalog.tools.map(\.name), ["send_message"])
        for bad in [
            metadata.replacingOccurrences(of: #""version":1"#, with: #""version":true"#),
            metadata.replacingOccurrences(of: #""version":1"#, with: #""version":2"#),
            metadata.replacingOccurrences(of: "send_message", with: "bad name"),
            #"{"x-astral-tool-proposals":{"version":1,"tools":[]}}"#,
        ] {
            XCTAssertThrowsError(try OnDeviceToolCatalog(schemaJSON: bad))
        }
    }

    func testCaptureValidatesArgumentsAndReturnsOnlyOneUnexecutedCall() throws {
        let tool = try XCTUnwrap(OnDeviceToolCatalog(schemaJSON: metadata)).tools[0]
        let capture = OnDeviceProposalCapture()
        XCTAssertThrowsError(try capture.record(tool: tool, argumentsJSON: #"{"text":"synthetic control"}"#)) {
            XCTAssertTrue($0 is OnDeviceProposalReady)
        }
        let envelope = try capture.finish()
        let value = try JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        XCTAssertEqual(value?["text"] as? String, "")
        let calls = try XCTUnwrap(value?["calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0]["tool"] as? String, "send_message")
        XCTAssertEqual(calls[0]["arguments_json"] as? String, #"{"text":"synthetic control"}"#)
        XCTAssertThrowsError(try capture.record(tool: tool, argumentsJSON: #"{"text":"late"}"#))
        XCTAssertThrowsError(try capture.finish())
    }

    func testInvalidOrMultipleProposalsCannotBecomeAnEnvelope() throws {
        let tool = try XCTUnwrap(OnDeviceToolCatalog(schemaJSON: metadata)).tools[0]
        for arguments in [#"{"text":7}"#, #"{"text":"x","extra":true}"#, "not JSON", "{}"] {
            let capture = OnDeviceProposalCapture()
            XCTAssertThrowsError(try capture.record(tool: tool, argumentsJSON: arguments))
            XCTAssertThrowsError(try capture.finish())
        }
        let capture = OnDeviceProposalCapture()
        XCTAssertThrowsError(try capture.record(tool: tool, argumentsJSON: #"{"text":"first"}"#))
        XCTAssertThrowsError(try capture.record(tool: tool, argumentsJSON: #"{"text":"second"}"#))
        XCTAssertThrowsError(try capture.finish())
    }

    func testUnionAndConstantSchemasAcceptOnlyTheirDeclaredChoices() throws {
        let schema = try OnDeviceJSONSchema(
            json:
                #"{"anyOf":[{"type":"object","properties":{"type":{"const":"text"},"content":{"type":"string"}},"required":["type","content"]},{"type":"string","enum":["done"]}]}"#
        )
        XCTAssertTrue(schema.accepts(#"{"type":"text","content":"hello"}"#))
        XCTAssertTrue(schema.accepts(#""done""#))
        XCTAssertFalse(schema.accepts(#"{"type":"button","content":"hello"}"#))
        XCTAssertFalse(schema.accepts(#""anything""#))
    }
    func testDuplicateAndOversizedCatalogsAreRejected() throws {
        let root = try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as! [String: Any]
        let spec = root["x-astral-tool-proposals"] as! [String: Any]
        let tool = (spec["tools"] as! [[String: Any]])[0]
        for rows in [[tool, tool], Array(repeating: tool, count: 65)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "x-astral-tool-proposals": ["version": 1, "tools": rows]
            ])
            XCTAssertThrowsError(try OnDeviceToolCatalog(schemaJSON: String(decoding: data, as: UTF8.self)))
        }
        XCTAssertThrowsError(try OnDeviceToolCatalog(schemaJSON: String(repeating: "x", count: 524_289)))
    }

    func testCancelledCaptureNeverReturnsAProposal() async throws {
        let tool = try XCTUnwrap(OnDeviceToolCatalog(schemaJSON: metadata)).tools[0]
        let capture = OnDeviceProposalCapture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try capture.record(tool: tool, argumentsJSON: #"{"text":"cancelled"}"#)
                return false
            } catch { return error is CancellationError }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertThrowsError(try capture.finish())
    }

    func testSchemaDepthIsBoundedBeforeRecursiveConversion() throws {
        var value: [String: Any] = ["type": "string"]
        for _ in 0..<40 { value = ["type": "array", "items": value] }
        let data = try JSONSerialization.data(withJSONObject: value)
        XCTAssertThrowsError(try OnDeviceJSONSchema(json: String(decoding: data, as: UTF8.self)))
    }

}
