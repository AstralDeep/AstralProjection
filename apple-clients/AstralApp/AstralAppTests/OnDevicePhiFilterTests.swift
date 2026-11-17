// Verifies the on-device PHI filter adapter against the contract copy and vectors with a scripted model in place of Foundation Models.
// Absence, refusal and schema misses must surface as such, and answers the model gave must reach the Kernel unaltered.

import CryptoKit
import Foundation
import XCTest

@testable import AstralDeep

private final class ScriptedPhiModel: AstralOnDeviceModel, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [OnDeviceResponse]
    private var log: [OnDeviceRequest] = []

    init(_ script: [OnDeviceResponse]) { self.script = script }

    var requests: [OnDeviceRequest] { lock.withLock { log } }

    func available() -> Bool { true }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        lock.withLock {
            log.append(request)
            return script.isEmpty ? .json(#"{"findings":[]}"#) : script.removeFirst()
        }
    }
}

final class OnDevicePhiFilterTests: XCTestCase {
    private let empty = #"{"findings":[]}"#
    private let found = #"{"findings":[{"kind":"name","text":"Avery Quill"}]}"#

    private func data(_ name: String, _ ext: String = "json") throws -> Data {
        let bundle = Bundle(for: OnDevicePhiFilterTests.self)
        return try Data(contentsOf: XCTUnwrap(bundle.url(forResource: name, withExtension: ext), name))
    }

    private func contract() throws -> PhiFilterContract { try PhiFilterContract.bundled() }

    private func filter(_ script: [OnDeviceResponse]) throws -> (OnDevicePhiFilter, ScriptedPhiModel) {
        let model = ScriptedPhiModel(script)
        return (try OnDevicePhiFilter(model: model, contract: try contract()), model)
    }

    func testBundledContractBytesEqualTheContractCopyAndPinnedDigest() throws {
        let shipped = try XCTUnwrap(
            Bundle(for: PhiFilterContract.BundleToken.self).url(forResource: "phi_filter", withExtension: "json"))
        let copy = try data("PhiFilterContractCopy")
        XCTAssertEqual(try Data(contentsOf: shipped), copy)
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data("PhiFilterVectors")) as? [String: Any])
        let digest = SHA256.hash(data: copy).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual("sha256:" + digest, vectors["filter_digest"] as? String)
    }

    func testInstructionsAndSchemaEqualTheContract() async throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data("PhiFilterContractCopy")) as? [String: Any])
        let loaded = try contract()
        XCTAssertEqual(loaded.instructions, root["instructions"] as? String)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(loaded.schemaJSON.utf8)) as? NSDictionary)
        XCTAssertEqual(sent, root["schema"] as? NSDictionary)
        let (filter, model) = try filter([.json(empty)])
        _ = await filter.screen("Visit on Tuesday.")
        let request = try XCTUnwrap(model.requests.first)
        XCTAssertEqual(request.schemaJSON, loaded.schemaJSON)
        XCTAssertEqual(request.messages.first, OnDeviceMessage(role: .system, text: loaded.instructions))
        XCTAssertEqual(request.messages.last, OnDeviceMessage(role: .user, text: "Visit on Tuesday."))
    }

    func testMalformedContractIsRejected() {
        XCTAssertThrowsError(try PhiFilterContract(data: Data("{}".utf8)))
        XCTAssertThrowsError(try PhiFilterContract(data: Data(#"{"format":"other"}"#.utf8)))
        XCTAssertThrowsError(try PhiFilterContract(data: Data("nope".utf8)))
    }

    func testChunkingMatchesTheVectors() throws {
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data("PhiFilterVectors")) as? [String: Any])
        let rows = try XCTUnwrap(vectors["filter_chunks"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        let (filter, _) = try filter([])
        for row in rows {
            let recipe = try XCTUnwrap(row["text_repeat"] as? [String: Any])
            let text =
                String(
                    repeating: try XCTUnwrap(recipe["unit"] as? String),
                    count: try XCTUnwrap(recipe["count"] as? Int)) + (recipe["tail"] as? String ?? "")
            let expect = try XCTUnwrap(row["expect"] as? [String: Any])
            let chunks = filter.chunks(of: text)
            XCTAssertEqual(chunks.map { $0.utf8.count }, expect["chunk_bytes"] as? [Int], row["id"] as? String ?? "")
            XCTAssertEqual(chunks.reduce(0) { $0 + $1.utf8.count }, expect["screened_bytes"] as? Int)
        }
    }

    func testEachChunkIsAskedAndAnswersPassThroughUnaltered() async throws {
        let (filter, model) = try filter([.json(found), .json(empty), .json(found)])
        let run = await filter.screen(String(repeating: "abcd", count: 2500))
        XCTAssertEqual(run, .answers([found, empty, found]))
        XCTAssertEqual(model.requests.map { $0.messages.last?.text.utf8.count }, [4096, 4096, 1808])
    }

    func testWhitespaceOnlyTextAsksNothingAndClaimsNothing() async throws {
        let (filter, model) = try filter([])
        let run = await filter.screen("  \n\t ")
        XCTAssertEqual(run, .answers([]))
        XCTAssertTrue(model.requests.isEmpty)
    }

    func testRefusalSchemaMissAndContextOverflowAreFailures() async throws {
        let cases: [(OnDeviceResponse, PhiFilterFailure)] = [
            (.refused("guardrail"), .refused),
            (.json(#"{"findings":[{"kind":"person","text":"Avery"}]}"#), .answerMissedSchema),
            (.text("Sure, here are the findings."), .answerMissedSchema),
            (.failed(.outputMismatchedSchema), .answerMissedSchema),
            (.failed(.contextTooLarge), .contextTooLarge),
            (.failed(.busy), .model(.busy)),
            (.failed(.cancelled), .model(.cancelled)),
            (.failed(.generationFailed), .model(.generationFailed)),
            (.failed(.schemaUnsupported), .model(.schemaUnsupported)),
        ]
        for (response, failure) in cases {
            let (filter, _) = try filter([response])
            let run = await filter.screen("Note for Avery Quill.")
            XCTAssertEqual(run, .failed(failure), "\(response)")
        }
    }

    func testContextOverflowStopsInsteadOfTruncatingOrRetrying() async throws {
        let (filter, model) = try filter([.json(empty), .failed(.contextTooLarge), .json(empty)])
        let run = await filter.screen(String(repeating: "abcd", count: 2500))
        XCTAssertEqual(run, .failed(.contextTooLarge))
        XCTAssertEqual(model.requests.count, 2)
    }

    func testEveryUnavailableReasonIsReportedAsAbsence() async throws {
        let reasons: [OnDeviceUnavailableReason] = [
            .osVersionTooOld, .deviceNotEligible, .appleIntelligenceDisabled, .modelNotReady, .unknown,
        ]
        for reason in reasons {
            let (filter, _) = try filter([.unavailable(reason)])
            let run = await filter.screen("Note for Avery Quill.")
            XCTAssertEqual(run, .unavailable(reason))
        }
    }

    func testAbsenceMidwayDiscardsEarlierAnswersInsteadOfClaimingAnythingLower() async throws {
        let (filter, _) = try filter([.json(empty), .unavailable(.modelNotReady)])
        let run = await filter.screen(String(repeating: "abcd", count: 2500))
        XCTAssertEqual(run, .unavailable(.modelNotReady))
    }

    func testAnswerVectorsSplitIntoPassThroughAndFailure() async throws {
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data("PhiFilterVectors")) as? [String: Any])
        let rows = try XCTUnwrap(vectors["filter_answer"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        // A duplicate key parses to one value in Foundation, so the Kernel's strict parser owns that row.
        let kernelOnly: Set<String> = ["duplicate_key"]
        for row in rows {
            let id = try XCTUnwrap(row["id"] as? String)
            if kernelOnly.contains(id) { continue }
            let answer = try XCTUnwrap(row["answer"] as? String)
            let chunk = try XCTUnwrap(row["chunk"] as? String)
            let expect = try XCTUnwrap(row["expect"] as? [String: Any])
            let (filter, _) = try filter([.json(answer)])
            let run = await filter.screen(chunk)
            if expect["reason"] as? String == "detector_failed" {
                XCTAssertEqual(run, .failed(.answerMissedSchema), id)
            } else {
                XCTAssertEqual(run, .answers([answer]), id)
            }
        }
    }

    func testSchemaEnforcesStringLengthsInCodePoints() throws {
        let schema = try OnDeviceJSONSchema(json: try contract().schemaJSON)
        let sixtyFour = String(repeating: "\u{1F600}", count: 64)
        XCTAssertTrue(schema.accepts(#"{"findings":[{"kind":"other","text":"\#(sixtyFour)"}]}"#))
        XCTAssertFalse(schema.accepts(#"{"findings":[{"kind":"other","text":"\#(sixtyFour)a"}]}"#))
        XCTAssertFalse(schema.accepts(#"{"findings":[{"kind":"other","text":""}]}"#))
    }

    func testSystemFactoryReportsAbsenceOrAnswersButNeverCrashes() async throws {
        let filter = try OnDevicePhiFilter.system(contract: try contract())
        let run = await filter.screen("   ")
        XCTAssertEqual(run, .answers([]))
    }
}
