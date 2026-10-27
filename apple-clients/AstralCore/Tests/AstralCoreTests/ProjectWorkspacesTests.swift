// Validates server project records, immutable host grant contracts, and authenticated paginated transport.
// The same bounded contract is consumed by Mac grant storage and server authority.

import XCTest

@testable import AstralCore

final class ProjectWorkspacesTests: XCTestCase {
    private let project = "12345678-1234-1234-9234-123456789abc"

    func testProjectRecordsAndChatMembershipKeepCanonicalIdentity() throws {
        let record = try ProjectRecord(json: projectJSON())
        XCTAssertEqual(record.id, project)
        XCTAssertEqual(record.revision, 1)
        let chat = try XCTUnwrap(
            ChatSummary(
                json: .object([
                    "id": .string(" legacy\nchat "), "project_id": .string(project),
                ])))
        XCTAssertEqual(chat.id, " legacy\nchat ")
        XCTAssertEqual(chat.projectId, project)
        for invalid in [JSONValue.number(0), .number(1.5), .bool(true), .number(9_007_199_254_740_992)] {
            var json = projectJSON().objectValue!
            json["revision"] = invalid
            XCTAssertThrowsError(try ProjectRecord(json: .object(json)))
        }
    }

    func testManifestRejectsPartialMalformedOrOverboundGrantsAndPreservesPrimaryOrder() throws {
        let roots = [
            ComputerHostWorkspaceRoot(name: "First", path: "/tmp/one"),
            ComputerHostWorkspaceRoot(name: "Second", path: "/tmp/two"),
        ]
        let grant = try ComputerProjectWorkspace(projectId: project, grantRevision: 2, roots: roots)
        let manifest = try ComputerProjectManifest(generation: 3, projects: [grant])
        XCTAssertEqual(try ComputerProjectManifest(json: manifest.json), manifest)
        XCTAssertEqual(manifest.projects[0].roots[0].path, "/tmp/one")
        XCTAssertThrowsError(try ComputerProjectManifest(generation: 0, projects: [grant]))
        XCTAssertThrowsError(try ComputerProjectManifest(generation: 3, projects: [grant, grant]))
        XCTAssertThrowsError(
            try ComputerProjectWorkspace(projectId: project.uppercased(), grantRevision: 1, roots: roots))
        XCTAssertThrowsError(
            try ComputerProjectWorkspace(
                projectId: project, grantRevision: 1, roots: Array(repeating: roots[0], count: 17)))
        for path in ["/", "/tmp/../bad", "/tmp/./bad", "/tmp//bad", "/tmp/bad/", "relative"] {
            XCTAssertThrowsError(
                try ComputerProjectWorkspace(
                    projectId: project, grantRevision: 1,
                    roots: [.init(name: "Root", path: path)]))
        }
        XCTAssertThrowsError(
            try ComputerProjectWorkspace(
                projectId: project, grantRevision: 1,
                roots: [.init(name: String(repeating: "n", count: 129), path: "/tmp/one")]))
        var json = manifest.json.objectValue!
        json["unknown"] = .bool(true)
        XCTAssertThrowsError(try ComputerProjectManifest(json: .object(json)))
        let context = try ComputerProjectContext(
            chatId: " legacy\nchat ", projectId: project, grantRevision: 2,
            manifestGeneration: 3)
        XCTAssertEqual(try ComputerProjectContext(json: context.json).chatId, " legacy\nchat ")
    }

    func testProjectPaginationUsesQueryItemsAndBearerWithoutCookie() async throws {
        let record = projectJSON()
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!,
            projectConnection: .init(deviceId: "device", generation: "connection"), tokenProvider: { "token" },
            transport: { request in
                XCTAssertEqual(request.url?.path, "/api/projects")
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(items.first(where: { $0.name == "cursor" })?.value, "a+b/=?&x")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Astral-Device-Id"), "device")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Astral-Connection-Generation"), "connection")
                return (200, try JSONValue.object(["projects": .array([record]), "next_cursor": .null]).encoded())
            })
        let page = try await client.projects(cursor: "a+b/=?&x")
        XCTAssertEqual(page.projects.map(\.id), [project])
        XCTAssertNil(page.nextCursor)
    }

    func testDeviceOptInSurvivesViewportUpdatesButDoesNotAffectOtherClients() throws {
        var device = DeviceDescriptor.macos(viewportWidth: 1200, viewportHeight: 900)
        device.projectWorkspacesSupported = true
        let registration = try JSONValue.parse(
            Data(
                Outbound.registerUI(
                    token: "token", sessionId: nil,
                    device: device, resumed: false
                ).utf8))
        XCTAssertTrue(registration["capabilities"]!.arrayValue!.contains(.string("project_workspaces_v1")))
        device.viewportWidth = 800
        let update = try JSONValue.parse(Data(Outbound.updateDevice(sessionId: nil, device: device).utf8))
        XCTAssertEqual(update["payload"]?["device"]?["project_workspaces_v1"], .bool(true))
        device.deviceType = "ios"
        XCTAssertNil(device.json["project_workspaces_v1"])
    }

    func testEveryProjectMutationUsesReviewedDirectRecordAndRevisionContract() async throws {
        let record = projectJSON()
        let projectId = project
        let chatId = "abcdefab-1234-4234-9234-123456789abc"
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!, tokenProvider: { "token" },
            transport: { request in
                let body = try request.httpBody.map(JSONValue.parse)
                switch (request.httpMethod, request.url!.path) {
                case ("POST", "/api/projects"):
                    XCTAssertEqual(body?["project_id"], .string(projectId))
                    XCTAssertEqual(body?["name"], .string("Research"))
                    return (201, try record.encoded())
                case ("GET", "/api/projects/\(projectId)"):
                    return (200, try record.encoded())
                case ("PATCH", "/api/projects/\(projectId)"):
                    XCTAssertEqual(body?.objectValue?.count, 2)
                    XCTAssertEqual(body?["revision"], .number(1))
                    return (200, try record.encoded())
                case ("DELETE", "/api/projects/\(projectId)"):
                    XCTAssertEqual(
                        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                        [URLQueryItem(name: "revision", value: "1")])
                    return (200, try JSONValue.object(["success": .bool(true)]).encoded())
                case ("POST", "/api/chats"):
                    XCTAssertEqual(body?["chat_id"], .string(chatId))
                    XCTAssertEqual(body?["project_id"], .string(projectId))
                    return (
                        201,
                        try JSONValue.object(["chat_id": .string(chatId), "project_id": .string(projectId)]).encoded()
                    )
                default:
                    XCTFail("Unexpected request")
                    throw URLError(.badURL)
                }
            })
        let created = try await client.createProject(id: project, name: "Research")
        XCTAssertEqual(created.id, project)
        let fetched = try await client.project(id: project)
        XCTAssertEqual(fetched, created)
        let renamed = try await client.renameProject(id: project, name: "Research", revision: 1)
        XCTAssertEqual(renamed, created)
        try await client.deleteProject(id: project, revision: 1)
        for _ in 0..<2 {
            let id = try await client.createProjectChat(id: chatId, projectId: project)
            XCTAssertEqual(id, chatId)
        }
    }

    func testMalformedPageIsNeverReturnedAsPartialCatalogAndConflictRemainsTyped() async throws {
        XCTAssertThrowsError(
            try ProjectPage(
                json: .object([
                    "projects": .array([projectJSON(), .object([:])]), "next_cursor": .null,
                ])))
        XCTAssertThrowsError(
            try ProjectChatPage(
                json: .object([
                    "project_id": .string(project), "chats": .array([.object(["id": .string("old")])]),
                    "next_cursor": .null,
                ])))
        let client = RestClient(
            serverBase: URL(string: "https://example.test")!, tokenProvider: { "token" },
            transport: { _ in
                (
                    409,
                    try JSONValue.object([
                        "detail": .object([
                            "code": .string("project_conflict"),
                            "message": .string("Project changed."),
                        ])
                    ]).encoded()
                )
            })
        do {
            _ = try await client.renameProject(id: project, name: "Research", revision: 1)
            XCTFail("Expected conflict")
        } catch {
            XCTAssertEqual(
                error as? ProjectAPIError, .refused(status: 409, code: "project_conflict", message: "Project changed."))
        }
    }

    func testCanonicalSharedManifestDigest() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = try JSONValue.parse(
            Data(contentsOf: root.appendingPathComponent("contracts/fixtures/project-workspaces.json")))
        let manifest = try ComputerProjectManifest(json: fixture["manifest"]!)
        XCTAssertEqual(manifest.digest, fixture["sha256"]?.stringValue)
        XCTAssertEqual(try ComputerProjectContext(json: fixture["context"]!).json, fixture["context"])
    }

    private func projectJSON() -> JSONValue {
        .object([
            "project_id": .string(project), "name": .string("Research"), "position": .number(0),
            "revision": .number(1), "created_at": .number(1000), "updated_at": .number(1000),
        ])
    }
}
