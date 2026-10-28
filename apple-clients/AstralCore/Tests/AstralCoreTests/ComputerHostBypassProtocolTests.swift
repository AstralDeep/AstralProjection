// Checks the wire pieces of the Mac bypass mode: the host's own bypass frame, the session bypass flag and the
// approval source a server may attach to an auto-approved request, each decoded tolerantly and bounded.

import XCTest

@testable import AstralCore

final class ComputerHostBypassProtocolTests: XCTestCase {
    private let host = "77777777-7777-4777-8777-777777777777"
    private let session = "88888888-8888-4888-8888-888888888888"

    private func request(_ extra: [String: JSONValue] = [:], args: [String: JSONValue] = [:]) throws
        -> ComputerHostRequest
    {
        var envelope: [String: JSONValue] = [
            "type": .string("computer_request"), "request_id": .string("creq_" + String(repeating: "b", count: 32)),
            "session_id": .string(session), "verb": .string("browser_click"),
            "args": .object(["ref": .string("e3"), "snapshot_id": .string("s1")].merging(args) { $1 }),
            "deadline_ms": .number(5000),
        ]
        envelope.merge(extra) { $1 }
        return try ComputerHostRequest(json: .object(envelope))
    }

    func testTheBypassFrameIsAHostCurrentConnectionFrameWithAClosedPayload() throws {
        let on = ComputerHostOutbound.frame(
            action: "chrome_computer_bypass_set", payload: ["host_id": .string(host), "enabled": .bool(true)])
        XCTAssertTrue(ComputerHostOutbound.isValid(on))
        XCTAssertTrue(ComputerHostOutbound.claimsCurrentConnectionSemantics(frameText: on))
        XCTAssertNil(QueuedOperationReplay(frameText: on))
        let bound = try XCTUnwrap(
            ComputerHostOutbound.bindToConnection(on, connectionGeneration: "99999999-9999-4999-8999-999999999999"))
        XCTAssertTrue(
            ComputerHostOutbound.isBound(bound, connectionGeneration: "99999999-9999-4999-8999-999999999999"))
        for payload: [String: JSONValue] in [
            ["host_id": .string(host)], ["host_id": .string(host), "enabled": .string("yes")],
            ["host_id": .string("not-a-host"), "enabled": .bool(false)],
            ["host_id": .string(host), "enabled": .bool(false), "scope": .string("all")],
        ] {
            XCTAssertEqual(
                ComputerHostOutbound.frame(action: "chrome_computer_bypass_set", payload: payload), "{}", "\(payload)")
        }
    }

    func testSessionFramesCarryAnOptionalBypassFlag() throws {
        let base: [String: JSONValue] = [
            "session_id": .string(session), "host_id": .string(host), "state": .string("active"),
        ]
        XCTAssertNil(try ComputerHostSession(json: .object(base)).bypass)
        XCTAssertEqual(
            try ComputerHostSession(json: .object(base.merging(["bypass": .bool(true)]) { $1 })).bypass, true)
        XCTAssertEqual(
            try ComputerHostSession(json: .object(base.merging(["bypass": .bool(false)]) { $1 })).bypass, false)
        XCTAssertNil(try ComputerHostSession(json: .object(base.merging(["bypass": .string("on")]) { $1 })).bypass)
    }

    func testAnApprovalSourceIsAcceptedOnTheEnvelopeOrInArgumentsButNeverConflicting() throws {
        XCTAssertNil(try request().approvalSource)
        XCTAssertEqual(try request(["approval_source": .string("bypass")]).approvalSource, "bypass")
        let inArgs = try request(args: ["approval_source": .string("bypass")])
        XCTAssertEqual(inArgs.approvalSource, "bypass")
        XCTAssertNil(inArgs.args["approval_source"])
        XCTAssertEqual(
            try request(["approval_source": .string("bypass")], args: ["approval_source": .string("bypass")])
                .approvalSource, "bypass")
        XCTAssertThrowsError(
            try request(["approval_source": .string("bypass")], args: ["approval_source": .string("user")]))
        XCTAssertThrowsError(try request(["approval_source": .string("Bypass!")]))
        XCTAssertThrowsError(try request(["approval_source": .bool(true)]))
        XCTAssertThrowsError(try request(["extra": .string("x")]))
    }
}
