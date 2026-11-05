// Verifies the native schedule decoder accepts the server's bounded job projection and fails closed on malformed data.
// Schedule execution and authorization remain server decisions.

import XCTest

@testable import AstralCore

final class ScheduledWorkTests: XCTestCase {
    private let id = "6d12ed1e-7485-4a76-8e94-9827b049fce8"

    private actor Recorder {
        var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
    }

    private func job(_ changes: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "name": .string("Daily research"),
            "instruction": .string("Review the latest results"), "status": .string("active"),
            "schedule_kind": .string("interval"), "schedule_expr": .string("1d"),
            "timezone": .string("America/New_York"), "consented_scopes": .array([.string("tools:read")]),
            "next_run_at": .number(1_783_000_000_000), "last_run_at": .null,
        ]
        fields.merge(changes) { _, new in new }
        return .object(fields)
    }

    func testDecodesOwnerJobAndRunTimes() {
        let decoded = ScheduledWorkJob(json: job())
        XCTAssertEqual(decoded?.id, id)
        XCTAssertEqual(decoded?.scheduleKind, "interval")
        XCTAssertEqual(decoded?.consentedScopes, ["tools:read"])
        XCTAssertEqual(decoded?.nextRunAtMillis, 1_783_000_000_000)
        XCTAssertNil(decoded?.lastRunAtMillis)
    }

    func testRefusesMalformedIdentityAndPolicyFields() {
        XCTAssertNil(ScheduledWorkJob(json: job(["id": .string("../other")])))
        XCTAssertNil(ScheduledWorkJob(json: job(["status": .string("unknown")])))
        XCTAssertNil(ScheduledWorkJob(json: job(["consented_scopes": .array([.number(1)])])))
        XCTAssertNil(ScheduledWorkJob(json: job(["next_run_at": .number(-1)])))
        XCTAssertNil(ScheduledWorkJob(json: job(["schedule_kind": .string("manual")])))
        XCTAssertEqual(ScheduledWorkJob(json: job(["status": .string("completed")]))?.status, "completed")
        XCTAssertEqual(ScheduledWorkJob(json: job(["status": .string("expired")]))?.status, "expired")
        XCTAssertFalse(ScheduledWorkJob(json: job(["status": .string("completed")]))?.canRunNow ?? true)
    }

    func testListUsesOwnerBearerAndRefusesMalformedResponse() async throws {
        let recorder = Recorder()
        let valid = try JSONValue.object(["jobs": .array([job()])]).encoded()
        let client = RestClient(
            serverBase: URL(string: "https://sandbox.example.test")!, tokenProvider: { "owner-access" },
            transport: { request in
                await recorder.record(request)
                return (200, valid)
            })
        let jobs = try await client.scheduledWorkJobs()
        XCTAssertEqual(jobs.map(\.id), [id])
        let requests = await recorder.requests
        XCTAssertEqual(requests.first?.url?.path, "/api/schedule")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer owner-access")

        let invalid = RestClient(
            serverBase: URL(string: "https://sandbox.example.test")!, tokenProvider: { "owner-access" },
            transport: { _ in (200, Data("{\"jobs\":[{}]}".utf8)) })
        do {
            _ = try await invalid.scheduledWorkJobs()
            XCTFail("Malformed schedule data must fail closed")
        } catch { XCTAssertTrue(error is URLError) }
    }

    func testControlsSendExactJobAndSubmissionIdentity() async throws {
        let recorder = Recorder()
        let run = UUID(uuidString: "e0c1e42a-bf7f-40f7-94ed-4d49076ceabc")!
        let response = try JSONValue.object([
            "job_id": .string(id), "submission_id": .string(run.uuidString.lowercased()),
            "occurrence_id": .string("86b9785a-b852-4547-80f0-0d33f52e9f84"), "duplicate": .bool(false),
        ]).encoded()
        let client = RestClient(
            serverBase: URL(string: "https://sandbox.example.test")!, tokenProvider: { "owner-access" },
            transport: { request in
                await recorder.record(request)
                return (202, response)
            })
        try await client.scheduledWorkAction(id: id, action: .runNow(submissionId: run))
        let requests = await recorder.requests
        XCTAssertEqual(requests.first?.url?.path, "/api/schedule/\(id)/run-now")
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(
            try requests.first?.httpBody.flatMap(JSONValue.parse)?["submission_id"]?.stringValue,
            run.uuidString.lowercased())
    }

    func testControlRejectsMismatchedReceiptAndInvalidJobBeforeTransport() async {
        let recorder = Recorder()
        let client = RestClient(
            serverBase: URL(string: "https://sandbox.example.test")!, tokenProvider: { "owner-access" },
            transport: { request in
                await recorder.record(request)
                return (200, Data("{\"job_id\":\"00000000-0000-4000-8000-000000000000\",\"status\":\"paused\"}".utf8))
            })
        do {
            try await client.scheduledWorkAction(id: id, action: .pause)
            XCTFail("A different job must not satisfy the control receipt")
        } catch { XCTAssertTrue(error is URLError) }
        do {
            try await client.scheduledWorkAction(id: "../other", action: .pause)
            XCTFail("Invalid identity must fail before transport")
        } catch { XCTAssertTrue(error is URLError) }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRetiredCredentialPreventsScheduleTransport() async {
        let recorder = Recorder()
        let client = RestClient(
            serverBase: URL(string: "https://sandbox.example.test")!, tokenProvider: { nil },
            transport: { request in
                await recorder.record(request)
                return (200, Data())
            })
        do {
            _ = try await client.scheduledWorkJobs()
            XCTFail("Missing owner credential must fail before network")
        } catch { XCTAssertTrue(error is URLError) }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }
}
