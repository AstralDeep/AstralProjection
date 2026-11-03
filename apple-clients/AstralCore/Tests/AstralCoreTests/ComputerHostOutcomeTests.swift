// Validates the outcome-unknown reporting contract: the descriptor's incarnation id and retained job
// inventory encode only when present and refuse malformed facts, and the host's outcome_ack event is a
// closed, incarnation-bound frame that keeps job output off the wire.

import XCTest

@testable import AstralCore

final class ComputerHostOutcomeTests: XCTestCase {
    let host = "88888888-8888-4888-8888-888888888888"
    let incarnation = "99999999-9999-4999-8999-999999999999"
    let job = "abcdef01-2345-4678-9abc-def012345678"

    func descriptor(incarnation: String? = incarnation, jobs: [ComputerHostRetainedJob] = []) throws
        -> ComputerHostDescriptor
    {
        try ComputerHostDescriptor(
            hostId: host, name: "Test Mac", clientVersion: "1.9.0",
            screens: [ComputerHostScreen(index: 0, width: 1000, height: 800, scale: 2, primary: true)],
            verbs: ["run_command"], incarnationId: incarnation, retainedJobs: jobs)
    }

    func retained(
        id: String = job, state: String = "running", exitCode: JSONValue = .null, signal: JSONValue = .null,
        outputBytes: Int = 0
    ) throws -> ComputerHostRetainedJob {
        try ComputerHostRetainedJob(
            id: id, state: state, exitCode: exitCode, signal: signal, outputBytes: outputBytes)
    }

    func testDescriptorOmitsIncarnationAndJobsUntilTheHostReportsThem() throws {
        XCTAssertNil(try descriptor(incarnation: nil, jobs: []).json["incarnation_id"])
        XCTAssertNil(try descriptor(incarnation: nil, jobs: []).json["retained_jobs"])
        let running = try retained()
        let finished = try retained(state: "exited", exitCode: .number(2), outputBytes: 2048)
        let signaled = try retained(state: "interrupted", signal: .string("TERM"))
        let json = try descriptor(jobs: [running, finished, signaled]).json
        XCTAssertEqual(json["incarnation_id"], .string(incarnation))
        XCTAssertEqual(
            json["retained_jobs"],
            .array([
                .object([
                    "job_id": .string(job), "state": .string("running"), "exit_code": .null,
                    "signal": .null, "output_bytes": .number(0),
                ]),
                .object([
                    "job_id": .string(job), "state": .string("exited"), "exit_code": .number(2),
                    "signal": .null, "output_bytes": .number(2048),
                ]),
                .object([
                    "job_id": .string(job), "state": .string("interrupted"), "exit_code": .null,
                    "signal": .string("TERM"), "output_bytes": .number(0),
                ]),
            ]))
    }

    func testRetainedJobsRefuseMalformedFacts() {
        for state in ["", "Exited", "finished", "lost"] {
            XCTAssertThrowsError(try retained(state: state), state)
        }
        XCTAssertThrowsError(try retained(id: "not-a-uuid"))
        XCTAssertThrowsError(try retained(id: job.uppercased()))
        XCTAssertThrowsError(try retained(outputBytes: -1))
        XCTAssertThrowsError(try retained(outputBytes: 9_007_199_254_740_992))
        XCTAssertThrowsError(try retained(exitCode: .number(-2)))
        XCTAssertThrowsError(try retained(exitCode: .number(1.5)))
        XCTAssertThrowsError(try retained(exitCode: .string("2")))
        XCTAssertThrowsError(try retained(signal: .string("sigterm")))
        XCTAssertThrowsError(try retained(signal: .string("TERMINATED")))
        XCTAssertThrowsError(try retained(signal: .number(15)))
        XCTAssertThrowsError(try retained(exitCode: .number(0)))
        XCTAssertThrowsError(try retained(signal: .string("INT")))
    }

    func testDescriptorBoundsTheInventoryAndIncarnation() throws {
        XCTAssertNoThrow(try descriptor(incarnation: nil))
        XCTAssertThrowsError(try descriptor(incarnation: "not-a-uuid"))
        XCTAssertThrowsError(try descriptor(incarnation: incarnation.uppercased()))
        let full = (0..<ComputerHostDescriptor.maximumRetainedJobs).map {
            try! retained(id: String(format: "abcdef01-2345-4678-9abc-def012%06d", $0))
        }
        XCTAssertNoThrow(try descriptor(jobs: full))
        XCTAssertThrowsError(
            try descriptor(
                jobs: full + [try retained(id: "ffffff01-2345-4678-9abc-def012345678")]))
        var duplicated = full
        duplicated[1] = duplicated[0]
        XCTAssertThrowsError(try descriptor(jobs: Array(duplicated.prefix(2))))
    }

    func testAnnounceFrameCarriesTheInventoryThroughTheClosedEventValidator() throws {
        let descriptor = try descriptor(jobs: [try retained(state: "exited", exitCode: .number(0))])
        let frame = ComputerHostOutbound.frame(
            action: "computer_event",
            payload: ["host_id": .string(host), "event": .string("announce"), "host": descriptor.json])
        XCTAssertTrue(ComputerHostOutbound.isValid(frame))
        XCTAssertTrue(frame.contains("incarnation_id"))
        XCTAssertTrue(frame.contains("retained_jobs"))
        XCTAssertFalse(frame.contains("stdout"))
    }

    func testSharedFixtureAnnounceAndAcknowledgmentStayValid() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var fixtureURL: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("contracts/fixtures/computer_outcome/announce_and_ack.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                fixtureURL = candidate
                break
            }
            dir.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: try XCTUnwrap(fixtureURL, "shared outcome fixture must ship with the tests"))
        let fixture = try JSONValue.parse(data)
        let announce = try XCTUnwrap(fixture["announce"]?.objectValue)
        let announceFrame = String(decoding: try JSONValue.object(announce).encoded(), as: UTF8.self)
        XCTAssertTrue(ComputerHostOutbound.isValid(announceFrame))
        let host = try XCTUnwrap(announce["payload"]?["host"]?.objectValue)
        let jobs = try XCTUnwrap(host["retained_jobs"]?.arrayValue)
        let rebuilt = try jobs.map { entry -> ComputerHostRetainedJob in
            try ComputerHostRetainedJob(
                id: try XCTUnwrap(entry["job_id"]?.stringValue), state: try XCTUnwrap(entry["state"]?.stringValue),
                exitCode: entry["exit_code"] ?? .null, signal: entry["signal"] ?? .null,
                outputBytes: Int(try XCTUnwrap(entry["output_bytes"]?.numberValue)))
        }
        let descriptor = try ComputerHostDescriptor(
            hostId: try XCTUnwrap(host["host_id"]?.stringValue), name: try XCTUnwrap(host["name"]?.stringValue),
            clientVersion: try XCTUnwrap(host["client_version"]?.stringValue),
            screens: try XCTUnwrap(host["screens"]?.arrayValue).map { screen in
                try ComputerHostScreen(
                    index: Int(try XCTUnwrap(screen["index"]?.numberValue)),
                    width: Int(try XCTUnwrap(screen["width"]?.numberValue)),
                    height: Int(try XCTUnwrap(screen["height"]?.numberValue)),
                    scale: try XCTUnwrap(screen["scale"]?.numberValue),
                    primary: try XCTUnwrap(screen["primary"]?.boolValue))
            }, verbs: try XCTUnwrap(host["verbs"]?.arrayValue).compactMap(\.stringValue),
            incarnationId: host["incarnation_id"]?.stringValue, retainedJobs: rebuilt)
        XCTAssertEqual(descriptor.json["retained_jobs"], .array(jobs))
        XCTAssertEqual(descriptor.json["incarnation_id"], host["incarnation_id"])
        let ack = try XCTUnwrap(fixture["outcome_ack"]?.objectValue)
        let ackFrame = String(decoding: try JSONValue.object(ack).encoded(), as: UTF8.self)
        XCTAssertTrue(ComputerHostOutbound.isValid(ackFrame))
    }

    func testOutcomeAckEventIsClosedAndIncarnationBound() {
        func frame(_ decision: String, incarnation: String = incarnation, extra: [String: JSONValue] = [:])
            -> String
        {
            var payload: [String: JSONValue] = [
                "host_id": .string(host), "event": .string("outcome_ack"), "decision": .string(decision),
                "incarnation_id": .string(incarnation),
            ]
            for (key, value) in extra { payload[key] = value }
            return ComputerHostOutbound.frame(action: "computer_event", payload: payload)
        }
        XCTAssertTrue(ComputerHostOutbound.isValid(frame("acknowledge")))
        XCTAssertTrue(ComputerHostOutbound.isValid(frame("discard")))
        XCTAssertFalse(ComputerHostOutbound.isValid(frame("continue")))
        XCTAssertFalse(ComputerHostOutbound.isValid(frame("ACKNOWLEDGE")))
        XCTAssertFalse(ComputerHostOutbound.isValid(frame("acknowledge", incarnation: "not-a-uuid")))
        XCTAssertFalse(ComputerHostOutbound.isValid(frame("acknowledge", extra: ["job_id": .string(job)])))
        XCTAssertFalse(ComputerHostOutbound.isValid(frame("acknowledge", extra: ["output": .string("secret")])))
        let bound = ComputerHostOutbound.bindToConnection(frame("acknowledge"), connectionGeneration: incarnation)
        XCTAssertNotNil(bound)
    }
}
