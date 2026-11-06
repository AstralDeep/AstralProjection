// Verifies the project instructions indicator model: acknowledgment gating, report decoding, the
// scripted REST report fetch, and the revision-fenced per-project ingestion toggle.

#if os(macOS)
    import AstralCore
    import Foundation
    import XCTest
    @testable import AstralDeep

    @MainActor final class MacProjectInstructionsTests: XCTestCase {
        let project = "12345678-1234-1234-9234-123456789abc"
        static let unavailableDetail =
            #"{"detail":{"code":"project_instructions_unavailable","message":"The project folders are not readable."}}"#

        private func acknowledgement(
            reporting: Bool = true, control: Bool = true
        ) -> ComposerReferencesAcknowledgement {
            ComposerReferencesAcknowledgement.fromRoteConfig(.object([
                "device_profile": .object([
                    "console": .object([
                        "composer_references": .object([
                            "version": .number(1),
                            "instructions_reporting": .bool(reporting),
                            "ingestion_control": .bool(control),
                        ])
                    ])
                ])
            ]))
        }

        private func reportJSON(enabled: Bool, revision: UInt64, path: String = "demo/AGENTS.md") -> JSONValue {
            .object([
                "project_id": .string(project),
                "enabled": .bool(enabled),
                "revision": .number(Double(revision)),
                "files": .array([
                    .object([
                        "path": .string(path),
                        "sha256": .string(String(repeating: "a", count: 64)),
                        "bytes": .number(512),
                    ])
                ]),
            ])
        }

        func testAcknowledgmentRequiresVersionOneAndExactKeys() {
            XCTAssertEqual(
                acknowledgement(),
                ComposerReferencesAcknowledgement(instructionsReporting: true, ingestionControl: true))
            XCTAssertNil(
                ComposerReferencesAcknowledgement(json: .object([
                    "version": .number(2), "instructions_reporting": .bool(true), "ingestion_control": .bool(true),
                ])))
            XCTAssertNil(
                ComposerReferencesAcknowledgement(json: .object([
                    "version": .number(1), "instructions_reporting": .bool(true),
                ])))
        }

        func testReportDecodingRejectsBadHashesDuplicatePathsAndWrongKeys() {
            XCTAssertNotNil(ProjectInstructionsReport(json: reportJSON(enabled: true, revision: 3)))
            var broken = reportJSON(enabled: true, revision: 3)
            broken["files"] = .array([
                .object(["path": .string("demo/AGENTS.md"), "sha256": .string("abc"), "bytes": .number(1)])
            ])
            XCTAssertNil(ProjectInstructionsReport(json: broken))
            var duplicated = reportJSON(enabled: true, revision: 3)
            func entry(_ hash: String) -> JSONValue {
                .object(["path": .string("a.md"), "sha256": .string(hash), "bytes": .number(1)])
            }
            duplicated["files"] = .array([
                entry(String(repeating: "a", count: 64)), entry(String(repeating: "b", count: 64)),
            ])
            XCTAssertNil(ProjectInstructionsReport(json: duplicated))
            var extra = reportJSON(enabled: true, revision: 3)
            extra["surprise"] = .bool(true)
            XCTAssertNil(ProjectInstructionsReport(json: extra))
        }

        func testRoteConfigAcknowledgmentWiresTheIndicatorAndLegacyServersStayIdle() {
            let model = AppModel(tokenStore: InMemoryTokenStore())
            XCTAssertFalse(model.projectInstructions.negotiated)
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"rote_config","device_profile":{"console":{"composer_references":
                        {"version":1,"instructions_reporting":true,"ingestion_control":true}}}}
                    """)!)
            XCTAssertTrue(model.projectInstructions.negotiated)
            XCTAssertTrue(model.projectInstructions.ingestionControlled)
            let legacy = AppModel(tokenStore: InMemoryTokenStore())
            legacy.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"rote_config","device_profile":{"console":{"turn_steer":
                        {"version":1,"queue_capable":true}}}}
                    """)!)
            XCTAssertFalse(legacy.projectInstructions.negotiated)
            XCTAssertEqual(legacy.projectInstructions.state, .idle)
        }

        func testWithoutNegotiationTheModelStaysIdleAndNeverCallsTheServer() async {
            var requests = 0
            let model = MacProjectInstructions()
            model.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { "token" },
                    transport: { _ in
                        requests += 1
                        return (200, Data())
                    }))
            model.acknowledge(nil)
            await model.refresh()
            await model.setEnabled(false)
            XCTAssertEqual(model.state, .idle)
            XCTAssertEqual(requests, 0)
            XCTAssertFalse(model.ingestionControlled)
        }

        func testRefreshLoadsTheServerReportAndFailuresReportTheRefusal() async throws {
            var requests: [URLRequest] = []
            let body = try JSONEncoder().encode(reportJSON(enabled: true, revision: 7))
            let model = MacProjectInstructions()
            model.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { "token" },
                    transport: { request in
                        requests.append(request)
                        if request.url?.path.hasSuffix("/instructions") == true, request.httpMethod == "GET" {
                            return (200, body)
                        }
                        return (404, Data())
                    }))
            model.acknowledge(acknowledgement())
            model.select(project: project)
            await model.refresh()
            guard case .loaded(let report) = model.state else { return XCTFail("expected a loaded report") }
            XCTAssertEqual(report.files.map(\.path), ["demo/AGENTS.md"])
            XCTAssertEqual(report.revision, 7)
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(requests[0].url?.path.hasSuffix("api/projects/\(project)/instructions") == true)
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token")

            model.acknowledge(acknowledgement())
            model.select(project: nil)
            await model.refresh()
            XCTAssertEqual(model.state, .idle)

            let unavailableDetail = Self.unavailableDetail
            let refusing = MacProjectInstructions()
            refusing.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { "token" },
                    transport: { _ in (503, Data(unavailableDetail.utf8)) }))
            refusing.acknowledge(acknowledgement())
            refusing.select(project: project)
            await refusing.refresh()
            guard case .unavailable(let message) = refusing.state else {
                return XCTFail("expected an unavailable state")
            }
            XCTAssertEqual(message, "The project folders are not readable.")
        }

        func testToggleNeedsIngestionControlAndSendsTheFencedRevision() async throws {
            var bodies: [Data] = []
            let initial = try JSONEncoder().encode(reportJSON(enabled: true, revision: 7))
            let after = try JSONEncoder().encode(reportJSON(enabled: false, revision: 8))
            let model = MacProjectInstructions()
            model.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { "token" },
                    transport: { request in
                        if request.httpMethod == "PUT" {
                            bodies.append(request.body ?? Data())
                            return (200, after)
                        }
                        return (200, initial)
                    }))
            model.acknowledge(acknowledgement(reporting: true, control: false))
            model.select(project: project)
            await model.refresh()
            guard case .loaded = model.state else { return XCTFail("expected a loaded report") }
            await model.setEnabled(false)
            XCTAssertTrue(bodies.isEmpty, "the toggle must not call the server without the ingestion acknowledgment")

            model.acknowledge(acknowledgement(reporting: true, control: true))
            await model.setEnabled(false)
            XCTAssertEqual(bodies.count, 1)
            let sent = try XCTUnwrap(JSONValue.parse(bodies[0]).objectValue)
            XCTAssertEqual(sent["enabled"], .bool(false))
            XCTAssertEqual(sent["revision"], .number(7))
            guard case .loaded(let updated) = model.state else { return XCTFail("expected the updated report") }
            XCTAssertFalse(updated.enabled)
            XCTAssertEqual(updated.revision, 8)
        }
    }
#endif
