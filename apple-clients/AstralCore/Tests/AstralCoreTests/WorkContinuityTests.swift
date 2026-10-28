@testable import AstralCore
// Verifies closed Work continuity payloads and current-connection request correlation for all Apple consumers.
import XCTest

final class WorkContinuityTests: XCTestCase {
    let operation = "180cd30b-cc38-432d-8349-1851b0d3ad7e"
    let submission = "fc5c2124-ce23-48d9-927b-9c004d950c10"
    let generation = "48873d61-2e9b-4f38-bc36-bbfa81d78580"
    let connection = "9819d775-e7c8-4fa1-baa6-f5918567f69b"
    func payload() -> JSONValue {
        .object([
            "version": .number(1), "operation_id": .string(operation), "expected_revision": .number(3),
            "submission_id": .string(submission),
        ])
    }

    func testCurrentRequestRoundTripsExactCapturedPayload() throws {
        let request = try XCTUnwrap(WorkContinuityRequest(payload: payload()))
        let text = request.frameText(requestGeneration: generation, connectionGeneration: connection)
        let frame = try XCTUnwrap(InboundFrame.parse(text))
        XCTAssertEqual(frame.payload["payload"], payload())
        XCTAssertEqual(frame.payload["submission_id"]?.stringValue, submission)
        XCTAssertEqual(frame.payload["request_generation"]?.stringValue, generation)
        XCTAssertEqual(frame.payload["connection_generation"]?.stringValue, connection)
        XCTAssertEqual(WorkContinuityRequest(frameText: text), request)
        XCTAssertTrue(WorkReadRequest.isCurrentConnectionEvent(text))
        XCTAssertTrue(WorkReadRequest.claimsCurrentConnectionSemantics(frameText: text))
    }

    func testMalformedOrExtraAuthorityIsDenied() {
        let changes: [(String, JSONValue)] = [
            ("version", .bool(true)), ("version", .string("1")), ("version", .number(2)),
            ("expected_revision", .bool(true)), ("expected_revision", .number(0)), ("expected_revision", .number(3.5)),
            ("expected_revision", .number(9_007_199_254_740_992)), ("operation_id", .string("foreign")),
            ("submission_id", .string(submission.uppercased())), ("token", .string("private")),
        ]
        for (key, value) in changes {
            var fields = payload().objectValue!
            fields[key] = value
            XCTAssertNil(WorkContinuityRequest(payload: .object(fields)))
        }
        XCTAssertNil(WorkContinuityRequest(payload: .null))
    }

    func testMutationTicketAcceptsOnlyItsOwnSubmissionAndConnectionReply() throws {
        let command = try XCTUnwrap(WorkContinuityRequest(payload: payload()))
        var state = WorkReadState()
        XCTAssertTrue(state.beginContinuity(command, generation: generation))
        let text = command.frameText(requestGeneration: generation, connectionGeneration: connection)
        XCTAssertTrue(state.bindSubmission(frameText: text))
        XCTAssertEqual(state.submissionId, submission)
        let other = command.frameText(requestGeneration: connection, connectionGeneration: connection)
        XCTAssertFalse(state.bindSubmission(frameText: other))
        state.invalidate()
        XCTAssertFalse(state.bindSubmission(frameText: text))
    }
}

extension WorkContinuityTests {
    func testSharedWaitingFixtureIsStrictAndOtherStatesOfferNoMutation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let value = try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/work_088/continuity.json")))
        let command = try XCTUnwrap(WorkContinuityRequest(payload: value["command"]!))
        for (name, fields) in value["frames"]!.objectValue! {
            let update = try XCTUnwrap(WorkSurfaceUpdate(frame: InboundFrame(name: "chrome_surface", payload: fields)))
            XCTAssertEqual(update.permits(command), name == "waiting")
        }
        let text = command.frameText(requestGeneration: generation, connectionGeneration: connection)
        var fields = InboundFrame.parse(text)!.payload.objectValue!
        fields["authority"] = .string("forbidden")
        XCTAssertNil(WorkContinuityRequest(frameText: Outbound.encode(.object(fields))))
        fields.removeValue(forKey: "authority")
        fields["submission_id"] = .string(generation)
        XCTAssertNil(WorkContinuityRequest(frameText: Outbound.encode(.object(fields))))
        XCTAssertTrue(WorkReadRequest.claimsCurrentConnectionSemantics(frameText: Outbound.encode(.object(fields))))
        XCTAssertEqual(command.frameText(requestGeneration: "invalid", connectionGeneration: connection), "{}")
        var state = WorkReadState()
        XCTAssertFalse(state.beginContinuity(command, generation: "invalid"))
    }
}
