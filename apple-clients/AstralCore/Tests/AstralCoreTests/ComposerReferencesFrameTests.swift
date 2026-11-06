// Tests the composer_references_v1 wire layer: the rote_config acknowledgment shape, the project
// instructions report decoder with its exact-field, hash, and bounds rules, and the Bearer REST
// report and ingestion-toggle transports.

import XCTest

@testable import AstralCore

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

    private func report(
        files: [JSONValue]? = nil, revision: UInt64 = 3, enabled: Bool = true, extra: Bool = false
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "project_id": .string(projectId),
            "enabled": .bool(enabled),
            "revision": .number(Double(revision)),
            "files": .array(
                files
                    ?? [
                        .object([
                            "path": .string("demo/AGENTS.md"),
                            "sha256": .string(String(repeating: "0a", count: 32)),
                            "bytes": .number(2048),
                        ])
                    ]),
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
        XCTAssertNil(
            try rote(#"{"version":1,"instructions_reporting":"yes","ingestion_control":true}"#))
        XCTAssertNil(
            ComposerReferencesAcknowledgement.fromRoteConfig(
                try JSONValue.parse(Data(#"{"device_profile":{"console":{}}}"#.utf8))))
        XCTAssertNil(ComposerReferencesAcknowledgement.fromRoteConfig(.null))
    }

    func testReportDecodesPathsHashesAndBounds() throws {
        let decoded = try XCTUnwrap(ProjectInstructionsReport(json: report()))
        XCTAssertEqual(decoded.projectId, projectId)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.revision, 3)
        XCTAssertEqual(decoded.files.map(\.path), ["demo/AGENTS.md"])
        XCTAssertEqual(decoded.files.map(\.sha256), [String(repeating: "0a", count: 32)])
        XCTAssertEqual(decoded.files.map(\.bytes), [2048])

        func hashed(_ hash: String) -> JSONValue {
            report(files: [
                .object(["path": .string("a.md"), "sha256": .string(hash), "bytes": .number(1)])
            ])
        }
        XCTAssertNil(ProjectInstructionsReport(json: hashed(String(repeating: "A", count: 64))))
        XCTAssertNil(ProjectInstructionsReport(json: hashed(String(repeating: "a", count: 63))))
        XCTAssertNil(
            ProjectInstructionsReport(
                json: report(files: [
                                        .object([
                        "path": .string("/absolute/a.md"), "sha256": .string(String(repeating: "a", count: 64)),
                        "bytes": .number(1),
                    ])
                ])))
        XCTAssertNil(
            ProjectInstructionsReport(
                json: report(files: [
                                        .object([
                        "path": .string("../a.md"), "sha256": .string(String(repeating: "a", count: 64)),
                        "bytes": .number(1),
                    ])
                ])))
        XCTAssertNil(
            ProjectInstructionsReport(
                json: report(files: [
                                        .object([
                        "path": .string("a.md"), "sha256": .string(String(repeating: "a", count: 64)),
                        "bytes": .number(-1),
                    ])
                ])))
        XCTAssertNil(ProjectInstructionsReport(json: report(revision: 0)))
        XCTAssertNil(ProjectInstructionsReport(json: report(extra: true)))
    }

    func testReportTransportUsesBearerProjectsPathAndParsesTheResponse() async throws {
        var requests: [URLRequest] = []
        let payload = try JSONEncoder().encode(report())
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!, tokenProvider: { "access-token" },
            transport: { request in
                requests.append(request)
                return (200, payload)
            })
        let decoded = try await client.projectInstructions(id: projectId)
        XCTAssertEqual(decoded.files.count, 1)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/projects/\(projectId)/instructions")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
    }

    func testToggleTransportSendsEnabledAndRevisionAndParsesTheUpdatedReport() async throws {
        var bodies: [Data] = []
        let payload = try JSONEncoder().encode(report(enabled: false, revision: 9))
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!, tokenProvider: { "access-token" },
            transport: { request in
                bodies.append(request.body ?? Data())
                return (200, payload)
            })
        let decoded = try await client.setProjectInstructions(id: projectId, enabled: false, revision: 8)
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.revision, 9)
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
                Outbound.registerUI(
                    token: "token", sessionId: nil, device: device, resumed: false
                ).utf8))
        XCTAssertFalse(
            legacy["capabilities"]!.arrayValue!.contains(.string("composer_references_v1")))
    }

    func testRefusalSurfacesTheServerDetailMessage() async {
        let detail =
            #"{"detail":{"code":"project_instructions_unavailable","message":"The project folders are not readable."}}"#
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
            transport: { _ in (503, Data(detail.utf8)) }
        do {
            _ = try await client.projectInstructions(id: projectId)
            XCTFail("expected a refusal")
        } catch let error as ProjectAPIError {
            XCTAssertEqual(
                error, .refused(status: 503, code: "project_instructions_unavailable",
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
