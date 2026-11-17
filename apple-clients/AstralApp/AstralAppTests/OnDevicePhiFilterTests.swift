// Verifies the shipped host path for the PHI filter request: the answer check, refusal and absence mapping, the busy wait and the bridge deadline.
// A scripted model stands in for Foundation Models, and the contract copy in this bundle shapes the request exactly as the Kernel sends it.

@testable import AstralDeep
import AstralKernel
import CryptoKit
import Foundation
import XCTest

private final class ScriptedPhiModel: AstralOnDeviceModel, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [AstralDeep.OnDeviceResponse]
    private var log: [AstralDeep.OnDeviceRequest] = []

    init(_ script: [AstralDeep.OnDeviceResponse]) { self.script = script }

    var requests: [AstralDeep.OnDeviceRequest] { lock.withLock { log } }

    func available() -> Bool { true }

    func complete(_ request: AstralDeep.OnDeviceRequest) async -> AstralDeep.OnDeviceResponse {
        lock.withLock {
            log.append(request)
            return script.count > 1 ? script.removeFirst() : (script.first ?? .json(#"{"findings":[]}"#))
        }
    }
}

final class OnDevicePhiFilterTests: XCTestCase {
    private let empty = #"{"findings":[]}"#
    private let found = #"{"findings":[{"kind":"name","text":"Avery Quill"}]}"#

    private func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: OnDevicePhiFilterTests.self)
        return try Data(contentsOf: XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), name))
    }

    private func contract() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data("PhiFilterContractCopy")) as? [String: Any])
    }

    private func schemaJSON() throws -> String {
        let schema = try XCTUnwrap(contract()["schema"])
        return String(
            decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
    }

    private func kernelRequest(_ chunk: String) throws -> AstralKernel.OnDeviceRequest {
        AstralKernel.OnDeviceRequest(
            messages: [
                AstralKernel.OnDeviceMessage(
                    role: "system", content: try XCTUnwrap(contract()["instructions"] as? String)),
                AstralKernel.OnDeviceMessage(role: "user", content: chunk),
            ], jsonSchema: try schemaJSON(), grammar: nil, maxTokens: 2048)
    }

    private func host(
        _ script: [AstralDeep.OnDeviceResponse], deadline: Duration = .milliseconds(300),
        margin: Duration = .milliseconds(100)
    ) -> (
        KernelOnDeviceModel, ScriptedPhiModel
    ) {
        let model = ScriptedPhiModel(script)
        return (
            KernelOnDeviceModel(model, deadline: deadline, margin: margin, backoff: .milliseconds(5)), model
        )
    }

    private func failure(_ model: KernelOnDeviceModel, _ chunk: String = "Note for Avery Quill.") throws -> String {
        do {
            _ = try model.complete(request: try kernelRequest(chunk))
            return ""
        } catch HostCallError.Failed(let message) {
            return message
        }
    }

    func testContractCopyMatchesThePinnedDigest() throws {
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data("PhiFilterVectors")) as? [String: Any])
        let digest = SHA256.hash(data: try data("PhiFilterContractCopy")).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual("sha256:" + digest, vectors["filter_digest"] as? String)
    }

    func testTheKernelRequestAlreadyCarriesInstructionsAndSchemaAndTheHostForwardsThemUnchanged() throws {
        let (host, model) = host([.json(empty)])
        let request = try kernelRequest("Visit on Tuesday.")
        XCTAssertEqual(try host.complete(request: request).text, empty)
        let sent = try XCTUnwrap(model.requests.first)
        XCTAssertEqual(sent.schemaJSON, request.jsonSchema)
        XCTAssertEqual(sent.messages.map(\.role.rawValue), ["system", "user"])
        XCTAssertEqual(sent.messages.first?.text, try contract()["instructions"] as? String)
        XCTAssertEqual(sent.messages.last?.text, "Visit on Tuesday.")
    }

    func testAnswerVectorsPassThroughOrFailTheSchemaCheck() throws {
        let schema = try OnDeviceJSONSchema(json: try schemaJSON())
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data("PhiFilterVectors")) as? [String: Any])
        let rows = try XCTUnwrap(vectors["filter_answer"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let id = try XCTUnwrap(row["id"] as? String)
            let answer = try XCTUnwrap(row["answer"] as? String)
            let expect = try XCTUnwrap(row["expect"] as? [String: Any])
            let failed = expect["reason"] as? String == "detector_failed"
            // Foundation reads a duplicate key as one value, so the adapter forwards it and the Kernel's strict parser fails it.
            let expected = id == "duplicate_key" ? true : !failed
            XCTAssertEqual(schema.checked(answer), expected ? .json(answer) : .failed(.outputMismatchedSchema), id)
        }
    }

    func testSchemaEnforcesStringLengthsInCodePoints() throws {
        let schema = try OnDeviceJSONSchema(json: try schemaJSON())
        let sixtyFour = String(repeating: "\u{1F600}", count: 64)
        XCTAssertTrue(schema.accepts(#"{"findings":[{"kind":"other","text":"\#(sixtyFour)"}]}"#))
        XCTAssertFalse(schema.accepts(#"{"findings":[{"kind":"other","text":"\#(sixtyFour)a"}]}"#))
        XCTAssertFalse(schema.accepts(#"{"findings":[{"kind":"other","text":""}]}"#))
    }

    func testRefusalAbsenceAndFailuresSurfaceAsHostFailuresTheKernelTreatsAsPhi() throws {
        let cases: [(AstralDeep.OnDeviceResponse, String)] = [
            (.refused("guardrail"), "on_device.refused"),
            (.failed(.outputMismatchedSchema), "on_device.output_mismatched_schema"),
            (.failed(.contextTooLarge), "on_device.context_too_large"),
            (.failed(.generationFailed), "on_device.generation_failed"),
            (.unavailable(.osVersionTooOld), "on_device.unavailable: os_version_too_old"),
            (.unavailable(.deviceNotEligible), "on_device.unavailable: device_not_eligible"),
            (.unavailable(.appleIntelligenceDisabled), "on_device.unavailable: apple_intelligence_disabled"),
            (.unavailable(.modelNotReady), "on_device.unavailable: model_not_ready"),
            (.unavailable(.unknown), "on_device.unavailable: unavailable_unknown"),
        ]
        for (response, message) in cases {
            let (host, model) = host([response])
            XCTAssertEqual(try failure(host), message)
            XCTAssertEqual(model.requests.count, 1, "no retry or truncation for \(message)")
        }
    }

    func testWhitespaceOnlyChunkComposesToNothingSoTheRunRefusesAsEmptyRequest() {
        let blank = [
            OnDeviceMessage(role: .system, text: "Screen."), OnDeviceMessage(role: .user, text: "  \n\t "),
        ]
        XCTAssertNil(OnDevicePromptComposer.compose(blank))
    }

    func testBusyThenSuccessWithinTheDeadlineAnswers() throws {
        let (host, model) = host([.failed(.busy), .failed(.busy), .json(found)])
        XCTAssertEqual(try host.complete(request: try kernelRequest("Avery Quill")).text, found)
        XCTAssertEqual(model.requests.count, 3)
    }

    func testDefaultDeadlineEqualsTheContractTimeout() throws {
        let limits = try XCTUnwrap(contract()["limits"] as? [String: Any])
        let timeout = try XCTUnwrap(limits["timeout_ms"] as? Int)
        XCTAssertEqual(KernelOnDeviceModel.defaultDeadline, .milliseconds(timeout))
    }

    func testBusyPastTheDeadlineFailsAsBusy() throws {
        let (host, _) = host([.failed(.busy)], deadline: .milliseconds(60), margin: .seconds(10))
        XCTAssertEqual(try failure(host), "on_device.busy")
    }

    func testHungModelFailsAtTheDeadlineAndIsCancelled() throws {
        let hung = FakeOnDeviceModel(mode: .hang)
        let host = KernelOnDeviceModel(
            hung, deadline: .milliseconds(60), margin: .milliseconds(40), backoff: .milliseconds(5))
        XCTAssertEqual(try failure(host), "on_device.timeout")
        let cancelled = expectation(description: "cancelled")
        DispatchQueue.global().async {
            while hung.cancellationCount == 0 { usleep(2000) }
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 5)
    }

    func testBridgeReturnsValueWithinTimeoutAndNilPastIt() {
        XCTAssertEqual(BlockingBridge.run(timeout: .seconds(2)) { 7 }, 7)
        let slow: Int? = BlockingBridge.run(timeout: .milliseconds(30)) {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            return 1
        }
        XCTAssertNil(slow)
    }
}
