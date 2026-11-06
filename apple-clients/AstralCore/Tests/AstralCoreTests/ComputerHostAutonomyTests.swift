// Tests the Mac autonomy-mode wire pieces: closed-set decoding of the server's computer_mode presence, the
// auto-review verdict fields on tool steps, the owner's chrome_computer_mode_set frame, session tolerance,
// and the committed computer_autonomy_v1 manifest contract with its fixture.

import XCTest

@testable import AstralCore

final class ComputerHostAutonomyTests: XCTestCase {
    private let host = "77777777-7777-4777-8777-777777777777"
    private let session = "88888888-8888-4888-8888-888888888888"

    private func modeJSON(mode: String, supported: [String], breaker: [String: JSONValue]? = nil)
        -> JSONValue
    {
        var object: [String: JSONValue] = [
            "mode": .string(mode), "supported": .array(supported.map(JSONValue.string)),
        ]
        if let breaker { object["breaker"] = .object(breaker) }
        return .object(object)
    }

    func testAutonomyStateDecodesTheClosedModeVocabularyAndBreaker() throws {
        let full = try ComputerAutonomyState(
            json: modeJSON(mode: "auto_review", supported: ["ask", "auto_review", "bypass"]))
        XCTAssertEqual(full.mode, .autoReview)
        XCTAssertEqual(full.supported, [.ask, .autoReview, .bypass])
        XCTAssertTrue(full.offersAutoReview)
        XCTAssertFalse(full.breakerTripped)

        let partial = try ComputerAutonomyState(json: modeJSON(mode: "ask", supported: ["ask"]))
        XCTAssertFalse(partial.offersAutoReview)

        let tripped = try ComputerAutonomyState(
            json: modeJSON(
                mode: "ask", supported: ["ask", "auto_review"],
                breaker: ["open": .bool(true), "reason": .string("Five denials in a row.")]))
        XCTAssertTrue(tripped.breakerTripped)
        XCTAssertEqual(tripped.breakerReason, "Five denials in a row.")
        XCTAssertEqual(tripped.mode, .ask)

        let breakerWithoutReason = try ComputerAutonomyState(
            json: modeJSON(mode: "ask", supported: ["ask"], breaker: ["open": .bool(true)]))
        XCTAssertEqual(breakerWithoutReason.breakerReason, nil)
        XCTAssertTrue(breakerWithoutReason.breakerTripped)
    }

    func testAutonomyStateRefusesOutOfVocabularyAndInconsistentStates() {
        let refused: [JSONValue] = [
            modeJSON(mode: "yolo", supported: ["ask", "yolo"]),
            modeJSON(mode: "auto_review", supported: ["ask", "bypass"]),
            modeJSON(mode: "ask", supported: []),
            modeJSON(mode: "ask", supported: ["ask", "ask"]),
            modeJSON(mode: "ask", supported: ["ask", "auto_review", "bypass", "ask"]),
            .object(["supported": .array([.string("ask")])]),
            .object(["mode": .string("ask"), "supported": .string("ask")]),
            .string("ask"),
            modeJSON(mode: "auto_review", supported: ["ask", "auto_review"], breaker: ["open": .bool(true)]),
            modeJSON(
                mode: "ask", supported: ["ask"],
                breaker: ["open": .bool(true), "unexpected": .bool(true)]),
            modeJSON(
                mode: "ask", supported: ["ask"],
                breaker: ["open": .string("yes")]),
            modeJSON(
                mode: "ask", supported: ["ask"],
                breaker: ["open": .bool(true), "reason": .string(String(repeating: "r", count: 301))]),
        ]
        for value in refused {
            XCTAssertThrowsError(try ComputerAutonomyState(json: value), "\(value)")
        }
    }

    func testVerdictDecodingIsTolerantExactAndPrefixBound() throws {
        func verdict(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }
        let allow = try XCTUnwrap(
            ComputerReviewVerdict(
                json: verdict([
                    "event_id": .string("review.auto.1b6f4c2e-8a41-4c2e-9b6f-4c2e8a411b6f"),
                    "decision": .string("allow"), "reason": .string("Within the granted workspace."),
                    "card_raised": .bool(false),
                ])))
        XCTAssertEqual(allow.decision, .allow)
        XCTAssertFalse(allow.blocked)
        XCTAssertFalse(allow.cardRaised)

        let deny = try XCTUnwrap(
            ComputerReviewVerdict(
                json: verdict([
                    "event_id": .string("review.auto.2c7a5d3f-9b52-4d3f-ac7a-5d3f9b522c7a"),
                    "decision": .string("deny"), "reason": .string("Command leaves the granted folders."),
                    "card_raised": .bool(false),
                ])))
        XCTAssertTrue(deny.blocked)

        let escalate = try XCTUnwrap(
            ComputerReviewVerdict(
                json: verdict([
                    "event_id": .string("review.auto.3d8b6e4a-ac63-4e4a-bd8b-6e4aac633d8b"),
                    "decision": .string("escalate"), "reason": "",
                    "card_raised": .bool(true),
                ])))
        XCTAssertFalse(escalate.blocked)
        XCTAssertTrue(escalate.cardRaised)

        let missingReason = try XCTUnwrap(
            ComputerReviewVerdict(
                json: verdict([
                    "event_id": .string("review.auto.x"), "decision": .string("allow"),
                    "card_raised": .bool(false),
                ])))
        XCTAssertEqual(missingReason.reason, "")

        let refused: [[String: JSONValue]] = [
            ["decision": .string("allow"), "card_raised": .bool(false)],
            [
                "event_id": .string("audit.1b6f4c2e"), "decision": .string("allow"),
                "card_raised": .bool(false),
            ],
            [
                "event_id": .string("review.auto."), "decision": .string("allow"),
                "card_raised": .bool(false),
            ],
            [
                "event_id": .string("review.auto.has\nnewline"), "decision": .string("allow"),
                "card_raised": .bool(false),
            ],
            [
                "event_id": .string("review.auto." + String(repeating: "x", count: 200)),
                "decision": .string("allow"), "card_raised": .bool(false),
            ],
            [
                "event_id": .string("review.auto.ok"), "decision": .string("maybe"),
                "card_raised": .bool(false),
            ],
            [
                "event_id": .string("review.auto.ok"), "decision": .string("allow"),
                "card_raised": .bool(true),
            ],
            [
                "event_id": .string("review.auto.ok"), "decision": .string("deny"),
                "card_raised": .bool(true),
            ],
            ["event_id": .string("review.auto.ok"), "decision": .string("allow")],
            [
                "event_id": .string("review.auto.ok"), "decision": .string("allow"),
                "card_raised": .bool(false), "reason": .string(String(repeating: "r", count: 1001)),
            ],
        ]
        for fields in refused {
            XCTAssertNil(ComputerReviewVerdict(json: verdict(fields)), "\(fields)")
        }
    }

    func testTheModeFrameIsAHostCurrentConnectionFrameWithAClosedPayload() throws {
        let frame = ComputerHostOutbound.autonomyModeFrame(hostId: host, mode: .autoReview)
        XCTAssertTrue(ComputerHostOutbound.isValid(frame))
        XCTAssertTrue(ComputerHostOutbound.claimsCurrentConnectionSemantics(frameText: frame))
        XCTAssertNil(QueuedOperationReplay(frameText: frame))
        let generation = "99999999-9999-4999-8999-999999999999"
        let bound = try XCTUnwrap(ComputerHostOutbound.bindToConnection(frame, connectionGeneration: generation))
        XCTAssertTrue(ComputerHostOutbound.isBound(bound, connectionGeneration: generation))
        for payload: [String: JSONValue] in [
            ["host_id": .string(host)],
            ["host_id": .string(host), "mode": .string("yolo")],
            ["host_id": .string("not-a-host"), "mode": .string("ask")],
            ["host_id": .string(host), "mode": .string("ask"), "enabled": .bool(true)],
        ] {
            let built = ComputerHostOutbound.frame(action: "chrome_computer_mode_set", payload: payload)
            XCTAssertFalse(ComputerHostOutbound.isValid(built), "\(payload)")
        }
    }

    func testSessionFramesCarryAutonomyTolerantly() throws {
        func sessionFrame(_ extra: [String: JSONValue]) throws -> ComputerHostSession {
            var payload: [String: JSONValue] = [
                "session_id": .string(session), "host_id": .string(host), "state": .string("active"),
            ]
            payload.merge(extra) { $1 }
            return try ComputerHostSession(json: .object(payload))
        }
        XCTAssertNil(try sessionFrame([:]).autonomy)
        let decoded = try sessionFrame([
            "computer_mode": modeJSON(mode: "bypass", supported: ["ask", "bypass"]),
            "bypass": .bool(true),
        ])
        XCTAssertEqual(decoded.autonomy?.mode, .bypass)
        XCTAssertEqual(decoded.autonomy?.supported, [.ask, .bypass])
        XCTAssertEqual(decoded.bypass, true)
        XCTAssertNil(try sessionFrame(["computer_mode": modeJSON(mode: "yolo", supported: ["yolo"])]).autonomy)
    }

    func testTheCommittedAutonomyContractStaysClosedAndBoundToTheFixture() throws {
        let data = try Data(contentsOf: try ManifestDriftTests.manifestURL())
        let root = try JSONValue.parse(data)
        let contract = try XCTUnwrap(root["presentation_contracts"]?["computer_autonomy_v1"]?.objectValue)
        XCTAssertEqual(contract["version"], .number(1))
        XCTAssertEqual(
            Set(contract["modes"]?.objectValue?.keys ?? []),
            ["ask", "auto_review", "bypass"])
        XCTAssertEqual(
            Set(contract["clients"]?.objectValue?.keys ?? []),
            ["macos", "browser", "windows", "android", "ios", "watch"])
        let actions = Set(root["accept_actions"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        for action in ["chrome_computer_mode_set", "chrome_computer_review_retry"] {
            XCTAssertTrue(actions.contains(action), action)
            XCTAssertNotNil(contract["client_actions"]?[action])
        }
        let modeField = try XCTUnwrap(
            root["additive_fields"]?.arrayValue?.first {
                $0["field"] == .string("computer_mode")
            })
        XCTAssertEqual(modeField["carried_on"], .array([.string("computer_host"), .string("computer_session")]))
        let verdictField = try XCTUnwrap(
            root["additive_fields"]?.arrayValue?.first {
                $0["field"] == .string("review_verdict")
            })
        XCTAssertEqual(verdictField["carried_on"], .array([.string("chat_step step (tool_call)")]))
        XCTAssertEqual(
            verdictField["contract"], .string("accept_actions.chrome_computer_review_retry"))

        let fixturePath = try XCTUnwrap(contract["fixture"]?.stringValue)
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var fixtureURL: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(fixturePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                fixtureURL = candidate
                break
            }
            dir.deleteLastPathComponent()
        }
        let fixture = try JSONValue.parse(Data(contentsOf: try XCTUnwrap(fixtureURL)))
        XCTAssertEqual(fixture["version"], .number(1))
        XCTAssertEqual(
            Set(fixture["modes"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            ["ask", "auto_review", "bypass"])
        let frames = try XCTUnwrap(fixture["supported_frames"]?.objectValue)
        XCTAssertEqual(frames["legacy"]?["computer_mode"], nil)
        let confirmed = try ComputerAutonomyState(json: XCTUnwrap(frames["auto_review"]?["computer_mode"]))
        XCTAssertEqual(confirmed.supported, [.ask, .autoReview, .bypass])
        let breaker = try ComputerAutonomyState(json: XCTUnwrap(frames["breaker_open"]?["computer_mode"]))
        XCTAssertTrue(breaker.breakerTripped)
        let verdictFrames = try XCTUnwrap(fixture["verdict_frames"]?.objectValue)
        for (name, expected) in [
            ("allow", ComputerReviewVerdict.Decision.allow),
            ("deny", ComputerReviewVerdict.Decision.deny),
            ("escalate", ComputerReviewVerdict.Decision.escalate),
        ] {
            let verdict = try XCTUnwrap(
                ComputerReviewVerdict(json: XCTUnwrap(verdictFrames[name]?["step"]?["review_verdict"])))
            XCTAssertEqual(verdict.decision, expected, name)
            XCTAssertEqual(verdict.cardRaised, expected == .escalate, name)
        }
        for invalid in fixture["invalid"]?.objectValue?.values ?? [] {
            if invalid["computer_mode"] != nil {
                XCTAssertThrowsError(try ComputerAutonomyState(json: XCTUnwrap(invalid["computer_mode"])))
            }
            if let step = invalid["step"] {
                XCTAssertNil(ComputerReviewVerdict(json: XCTUnwrap(step["review_verdict"])))
            }
        }
    }
}
