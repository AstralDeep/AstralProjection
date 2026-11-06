// Tests the composer_references_v1 wire layer: the rote_config acknowledgment shape, the project
// instructions report decoder with its exact-field, hash, and bounds rules, and the Bearer REST
// report and ingestion-toggle transports.

import XCTest

@testable import AstralCore

private actor ScriptedProjectsTransport {
    let payload: Data
    private(set) var requests: [URLRequest] = []
    private(set) var bodies: [Data] = []

    init(payload: Data) { self.payload = payload }

    func respond(_ request: URLRequest) -> (Int, Data) {
        requests.append(request)
        if request.httpMethod == "PUT" { bodies.append(request.body ?? Data()) }
        return (200, payload)
    }
}

final class ComposerReferencesFrameTests: XCTestCase {
    private let projectId = "12345678-1234-1234-9234-123456789abc"

    private func rote(_ console: String) throws -> ComposerReferencesAcknowledgement? {
        ComposerReferencesAcknowledgement.fromRoteConfig(
            try JSONValue.parse(
                Data(
                    """
                    {"device_profile":{"console":{"composer_references":\(console)}}}
                    """.utf8)))
    }

    private func file(_ path: String, _ hash: String, bytes: Double = 1) -> JSONValue {
        .object(["path": .string(path), "sha256": .string(hash), "bytes": .number(bytes)])
    }

    private func report(
        files: [JSONValue]? = nil, revision: UInt64 = 3, enabled: Bool = true, extra: Bool = false
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "project_id": .string(projectId),
            "enabled": .bool(enabled),
            "revision": .number(Double(revision)),
            "files": .array(
                files ?? [file("demo/AGENTS.md", String(repeating: "0a", count: 32), bytes: 2048)]),
        ]
        if extra { object["unexpected"] = .bool(true) }
        return .object(object)
    }

    func testAcknowledgementAcceptsTheExactContractShape() throws {
        XCTAssertEqual(
            try rote(#"{"version":1,"instructions_reporting":true,"ingestion_control":false}"#),
            ComposerReferencesAcknowledgement(instructionsReporting: true, ingestionControl: false))
        XCTAssertNil(try rote(#"{"version":1,"instructions_reporting":true}"#))
        XCTAssertNil(try rote(#"{"version":2,"instructions_reporting":true,"ingestion_control":true}"#))
        XCTAssertNil(try rote(#"{"version":1,"instructions_reporting":"yes","ingestion_control":true}"#))
        XCTAssertNil(
            ComposerReferencesAcknowledgement.fromRoteConfig(
                try JSONValue.parse(Data(#"{"device_profile":{"console":{}}}"#.utf8))))
        XCTAssertNil(ComposerReferencesAcknowledgement.fromRoteConfig(.null))
    }

    func testReportDecodesPathsHashesAndBounds() throws {
        let decoded = try ProjectInstructionsReport(json: report())
        XCTAssertEqual(decoded.projectId, projectId)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.revision, 3)
        XCTAssertEqual(decoded.files.map(\.path), ["demo/AGENTS.md"])
        XCTAssertEqual(decoded.files.map(\.sha256), [String(repeating: "0a", count: 32)])
        XCTAssertEqual(decoded.files.map(\.bytes), [2048])

        let hex64 = String(repeating: "a", count: 64)
        let digits = String(repeating: "0", count: 64)
        XCTAssertNoThrow(try ProjectInstructionsReport(json: report(files: [file("a.md", digits)])))
        XCTAssertThrowsError(
            try ProjectInstructionsReport(json: report(files: [file("a.md", String(repeating: "A", count: 64))])))
        XCTAssertThrowsError(
            try ProjectInstructionsReport(json: report(files: [file("a.md", String(repeating: "a", count: 63))])))
        XCTAssertThrowsError(try ProjectInstructionsReport(json: report(files: [file("/absolute/a.md", hex64)])))
        XCTAssertThrowsError(try ProjectInstructionsReport(json: report(files: [file("../a.md", hex64)])))
        XCTAssertThrowsError(try ProjectInstructionsReport(json: report(files: [file("a.md", hex64, bytes: -1)])))
        XCTAssertThrowsError(try ProjectInstructionsReport(json: report(revision: 0)))
        XCTAssertThrowsError(try ProjectInstructionsReport(json: report(extra: true)))
    }

    func testReportTransportUsesBearerProjectsPathAndParsesTheResponse() async throws {
        let transport = ScriptedProjectsTransport(payload: try JSONEncoder().encode(report()))
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!, tokenProvider: { "access-token" },
            transport: { await transport.respond($0) })
        let decoded = try await client.projectInstructions(id: projectId)
        XCTAssertEqual(decoded.files.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/projects/\(projectId)/instructions")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
    }

    func testToggleTransportSendsEnabledAndRevisionAndParsesTheUpdatedReport() async throws {
        let updated = report(enabled: false, revision: 9)
        let transport = ScriptedProjectsTransport(payload: try JSONEncoder().encode(updated))
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!, tokenProvider: { "access-token" },
            transport: { await transport.respond($0) })
        let decoded = try await client.setProjectInstructions(id: projectId, enabled: false, revision: 8)
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.revision, 9)
        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 1)
        let sent = try XCTUnwrap(JSONValue.parse(bodies[0]).objectValue)
        XCTAssertEqual(sent["enabled"], .bool(false))
        XCTAssertEqual(sent["revision"], .number(8))
    }

    func testDeviceOptInEmitsTheCapabilityForMacosOnly() throws {
        var device = DeviceDescriptor.macos(viewportWidth: 1200, viewportHeight: 900)
        device.composerReferencesSupported = true
        let registration = try JSONValue.parse(
            Data(
                Outbound.registerUI(
                    token: "token", sessionId: nil, device: device, resumed: false,
                    composerReferencesSupported: true
                ).utf8))
        XCTAssertTrue(
            registration["capabilities"]!.arrayValue!.contains(.string("composer_references_v1")))
        XCTAssertEqual(registration["device"]?["composer_references_v1"], .bool(true))
        device.deviceType = "ios"
        XCTAssertNil(device.json["composer_references_v1"])
        let legacy = try JSONValue.parse(
            Data(
                Outbound.registerUI(token: "token", sessionId: nil, device: device, resumed: false).utf8))
        XCTAssertFalse(
            legacy["capabilities"]!.arrayValue!.contains(.string("composer_references_v1")))
    }

    func testRefusalSurfacesTheServerDetailMessage() async {
        let detail =
            #"{"detail":{"code":"project_instructions_unavailable","message":"The project folders are not readable."}}"#
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
            transport: { _ in (503, Data(detail.utf8)) })
        do {
            _ = try await client.projectInstructions(id: projectId)
            XCTFail("expected a refusal")
        } catch let error as ProjectAPIError {
            XCTAssertEqual(
                error,
                .refused(
                    status: 503, code: "project_instructions_unavailable",
                    message: "The project folders are not readable."))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testInvalidProjectIdentityIsRefusedWithoutTransport() async {
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
            transport: { _ in (200, Data()) })
        do {
            _ = try await client.projectInstructions(id: "not-a-uuid")
            XCTFail("expected a local refusal")
        } catch ProjectAPIError.invalidResponse {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
