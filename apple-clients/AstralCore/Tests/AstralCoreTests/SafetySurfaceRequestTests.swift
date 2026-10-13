// Exercises the shared safety fixture and rejects stale or fabricated client authority.
// Safety frames require current-connection delivery and cannot enter the offline queue.

import XCTest

@testable import AstralCore

final class SafetySurfaceRequestTests: XCTestCase {
    func testSharedSafetyControlsPreserveTheExactOfferedRevision() throws {
        let root = try ManifestDriftTests.manifestURL().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/safety/owner_stop.json")))
        let buttons = try XCTUnwrap(fixture["buttons"]?.arrayValue)
        XCTAssertEqual(Set(buttons.compactMap { $0["action"]?.stringValue }), SafetySurfaceRequest.actions)
        let manifest = try JSONDecoder().decode(
            ManifestDriftTests.Manifest.self, from: Data(contentsOf: ManifestDriftTests.manifestURL()))
        XCTAssertTrue(SafetySurfaceRequest.actions.isSubset(of: Set(manifest.acceptActions)))
        for button in buttons {
            let action = try XCTUnwrap(button["action"]?.stringValue)
            let payload = try XCTUnwrap(button["payload"])
            let frame = Outbound.uiEvent(action: action, sessionId: nil, payload: payload)
            XCTAssertEqual(SafetySurfaceRequest(frameText: frame)?.payload, payload)
            XCTAssertTrue(SafetySurfaceRequest.claimsCurrentConnectionSemantics(frameText: frame))
        }
    }

    func testResumeRejectsInexactRevisionsAndClaimedAuthority() {
        for revision: JSONValue in [
            .null, .bool(true), .string("7"), .number(0), .number(-1), .number(1.5), .number(9_007_199_254_740_992),
        ] {
            XCTAssertNil(
                SafetySurfaceRequest(
                    action: "chrome_safety_resume",
                    payload: .object(["surface": .string("safety"), "expected_revision": revision])))
        }
        for action in SafetySurfaceRequest.actions {
            let payload: JSONValue = .object(["surface": .string("safety"), "owner_id": .string("forged")])
            let frame = Outbound.uiEvent(action: action, sessionId: nil, payload: payload)
            XCTAssertNil(SafetySurfaceRequest(frameText: frame))
            XCTAssertTrue(SafetySurfaceRequest.claimsCurrentConnectionSemantics(frameText: frame))
            XCTAssertNil(SafetySurfaceRequest(action: action, payload: .object(["surface": .string("theme")])))
        }
        XCTAssertNil(SafetySurfaceRequest(frameText: "{}"))
        XCTAssertFalse(SafetySurfaceRequest.claimsCurrentConnectionSemantics(frameText: "{}"))
        XCTAssertNil(SafetySurfaceRequest(action: "chrome_other", payload: .object(["surface": .string("safety")])))
    }

    func testNavigationAndStopPayloadsAreClosed() {
        for action in ["chrome_open", "chrome_close", "chrome_safety_stop", "chrome_safety_verify"] {
            var fields: [String: JSONValue] = ["surface": .string("safety")]
            if action == "chrome_open" { fields["params"] = .object([:]) }
            let payload = JSONValue.object(fields)
            XCTAssertNotNil(SafetySurfaceRequest(action: action, payload: payload))
            let frame = Outbound.uiEvent(action: action, sessionId: "chat", payload: payload)
            XCTAssertNil(SafetySurfaceRequest(frameText: frame))
        }
        XCTAssertNil(
            SafetySurfaceRequest(
                action: "chrome_open",
                payload: .object(["surface": .string("safety"), "params": .object(["owner_id": .string("forged")])])))
    }
}
