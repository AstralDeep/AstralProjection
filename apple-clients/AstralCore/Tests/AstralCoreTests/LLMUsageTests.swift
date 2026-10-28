// Verifies llm_usage_report decoding bounds and the per-session usage tally the Mac status footer reads.

import XCTest

@testable import AstralCore

final class LLMUsageTests: XCTestCase {
    private func frame(_ fields: [String: JSONValue]) -> InboundFrame {
        var payload = fields
        payload["type"] = .string("llm_usage_report")
        return InboundFrame(name: "llm_usage_report", payload: .object(payload))
    }

    func testReportReadsModelFeatureOutcomeAndTokenCounts() throws {
        let report = try XCTUnwrap(
            LLMUsageReport(
                frame: frame([
                    "feature": .string("chat_dispatch"), "model": .string("gpt-4o-mini"),
                    "prompt_tokens": .number(3_210), "completion_tokens": .number(450), "total_tokens": .number(3_660),
                    "outcome": .string("success"), "at": .string("2026-10-26T12:00:00+00:00"),
                ])))
        XCTAssertEqual(report.feature, "chat_dispatch")
        XCTAssertEqual(report.model, "gpt-4o-mini")
        XCTAssertEqual(report.promptTokens, 3_210)
        XCTAssertEqual(report.completionTokens, 450)
        XCTAssertEqual(report.tokens, 3_660)
        XCTAssertTrue(report.succeeded)
        let summed = try XCTUnwrap(
            LLMUsageReport(
                frame: frame([
                    "model": .string("m"), "prompt_tokens": .number(10), "completion_tokens": .number(5),
                    "outcome": .string("success"),
                ])))
        XCTAssertEqual(summed.tokens, 15)
        XCTAssertEqual(summed.feature, "")
    }

    func testOtherFramesAndMalformedFieldsAreRefusedOrDropped() throws {
        XCTAssertNil(LLMUsageReport(frame: InboundFrame(name: "chat_status", payload: .object([:]))))
        let report = try XCTUnwrap(
            LLMUsageReport(
                frame: frame([
                    "model": .string(" \u{0007}\n "), "prompt_tokens": .number(-1), "completion_tokens": .number(1.5),
                    "total_tokens": .string("12"), "outcome": .string("failure"),
                ])))
        XCTAssertNil(report.model)
        XCTAssertNil(report.promptTokens)
        XCTAssertNil(report.completionTokens)
        XCTAssertNil(report.tokens)
        XCTAssertFalse(report.succeeded)
        let huge = try XCTUnwrap(
            LLMUsageReport(
                frame: frame([
                    "model": .string(String(repeating: "m", count: 201)), "total_tokens": .number(1e15),
                    "prompt_tokens": .number(.infinity), "outcome": .string("success"),
                ])))
        XCTAssertNil(huge.model)
        XCTAssertNil(huge.tokens)
        XCTAssertNil(huge.promptTokens)
        let controls = try XCTUnwrap(LLMUsageReport(frame: frame(["model": .string("gpt\u{202E}-4\u{0000}o")])))
        XCTAssertEqual(controls.model, "gpt-4o")
    }

    func testTallyKeepsTheLatestModelSumsSuccessfulTokensAndTracksDispatchContext() throws {
        var tally = LLMUsageTally()
        XCTAssertTrue(tally.isEmpty)
        tally.record(
            try XCTUnwrap(
                LLMUsageReport(
                    frame: frame([
                        "feature": .string("chat_dispatch"), "model": .string("model-a"),
                        "prompt_tokens": .number(1_000), "completion_tokens": .number(200),
                        "total_tokens": .number(1_200), "outcome": .string("success"),
                    ]))))
        tally.record(
            try XCTUnwrap(
                LLMUsageReport(
                    frame: frame([
                        "feature": .string("chat_title"), "model": .string("model-a"), "prompt_tokens": .number(40),
                        "total_tokens": .number(60), "outcome": .string("success"),
                    ]))))
        XCTAssertEqual(tally.model, "model-a")
        XCTAssertEqual(tally.sessionTokens, 1_260)
        XCTAssertEqual(tally.contextTokens, 1_000)
        tally.record(
            try XCTUnwrap(
                LLMUsageReport(
                    frame: frame([
                        "feature": .string("chat_dispatch"), "model": .string("model-b"), "outcome": .string("failure"),
                    ]))))
        XCTAssertEqual(tally.model, "model-b")
        XCTAssertEqual(tally.sessionTokens, 1_260)
        XCTAssertEqual(tally.contextTokens, 1_000)
        XCTAssertFalse(tally.isEmpty)
        for _ in 0..<20 {
            tally.record(
                try XCTUnwrap(
                    LLMUsageReport(
                        frame: frame(["total_tokens": .number(100_000_000), "outcome": .string("success")]))))
        }
        XCTAssertEqual(tally.sessionTokens, LLMUsageTally.ceiling)
    }

    func testOnlyTheMacClientHandlesUsageReports() {
        XCTAssertEqual(ClientDispositions.macos.frames["llm_usage_report"], .handled)
        for client in [ClientDispositions.ios, ClientDispositions.watch] {
            guard case .ignored = client.frames["llm_usage_report"] else {
                return XCTFail("\(client.client) must keep ignoring llm_usage_report")
            }
        }
    }
}
