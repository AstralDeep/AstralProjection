// Exercises origin-bound native effect admission independently from the sidebar and host transport.
// Revocation removes already-issued ticket authority before resources can be released.

import XCTest

@testable import AstralCore

final class ComputerProjectAuthorityTests: XCTestCase {
    let session = "88888888-8888-4888-8888-888888888888"
    let project = "12345678-1234-1234-9234-123456789abc"

    func testSessionAndRequestCarryExactContextAndDigestChanges() throws {
        let origin = try context()
        let decoded = try ComputerHostSession(
            json: .object([
                "session_id": .string(session),
                "host_id": .string(session), "state": .string("active"), "project_context": origin.json,
            ]))
        XCTAssertEqual(decoded.projectContext, origin)
        let request = try request(context: origin)
        XCTAssertEqual(request.projectContext, origin)
        XCTAssertNotEqual(request.digest, try self.request(context: context(revision: 2)).digest)
    }

    func testProjectFenceRejectsMissingForeignOrChangedOriginWithSameSession() throws {
        let origin = try context()
        var fence = ComputerHostFence()
        try fence.begin(sessionId: session, projectContext: origin)
        XCTAssertThrowsError(try fence.admit(request(context: nil), now: 1))
        XCTAssertThrowsError(try fence.admit(request(context: context(chat: "other")), now: 1))
        XCTAssertThrowsError(try fence.begin(sessionId: session, projectContext: context(revision: 2)))
        let ticket = try fence.admit(request(context: origin), now: 1)
        XCTAssertEqual(ticket.projectContext, origin)
        XCTAssertTrue(fence.permits(ticket, now: 1))
    }

    func testLocalRevocationImmediatelyRetiresAdmittedTicketAndCannotRestoreOldSession() throws {
        let authority = ComputerHostAuthority(now: { 1 })
        authority.setDesktopAvailable(true)
        let origin = try context()
        let grant = try ComputerProjectWorkspace(
            projectId: project, grantRevision: 1,
            roots: [.init(name: "Root", path: "/tmp/one")])
        let manifest = try ComputerProjectManifest(generation: 1, projects: [grant])
        authority.configureProjects(true)
        XCTAssertThrowsError(try authority.begin(session, projectContext: origin))
        try authority.acceptProjectManifest(manifest)
        try authority.begin(session, projectContext: origin)
        let ticket = try authority.admit(request(context: origin))
        try authority.verify(ticket)
        authority.revokeProject(project)
        XCTAssertThrowsError(try authority.verify(ticket))
        XCTAssertThrowsError(try authority.begin(session, projectContext: origin))
        XCTAssertThrowsError(try authority.acceptProjectManifest(manifest))
        XCTAssertThrowsError(try authority.begin(session, projectContext: origin))
    }

    func testEmptyProjectGrantAllowsNonFileSessionButRefusesFileAndCommandRequests() throws {
        let authority = ComputerHostAuthority(now: { 1 })
        authority.setDesktopAvailable(true)
        authority.configureProjects(true)
        try authority.acceptProjectManifest(try ComputerProjectManifest(generation: 1, projects: []))
        let origin = try ComputerProjectContext(
            chatId: "chat", projectId: project, grantRevision: nil, manifestGeneration: 1)
        try authority.begin(session, projectContext: origin)
        XCTAssertThrowsError(try authority.admit(request(context: origin)))
        XCTAssertNoThrow(try authority.admit(request(context: origin, verb: "list_windows", args: [:])))
    }

    func testOtherProjectUpdatePreservesOriginTicketAndRemovalPreventsABA() throws {
        let authority = ComputerHostAuthority(now: { 1 })
        authority.setDesktopAvailable(true)
        authority.configureProjects(true)
        let first = try ComputerProjectWorkspace(
            projectId: project, grantRevision: 1, roots: [.init(name: "A", path: "/tmp/a")])
        let other = try ComputerProjectWorkspace(
            projectId: "12345678-1234-1234-9234-123456789abd", grantRevision: 1,
            roots: [.init(name: "B", path: "/tmp/b")])
        try authority.acceptProjectManifest(try ComputerProjectManifest(generation: 1, projects: [first]))
        try authority.begin(session, projectContext: context())
        let ticket = try authority.admit(request(context: context()))
        try authority.acceptProjectManifest(try ComputerProjectManifest(generation: 2, projects: [first, other]))
        XCTAssertNoThrow(try authority.verify(ticket))
        try authority.acceptProjectManifest(try ComputerProjectManifest(generation: 3, projects: [other]))
        XCTAssertThrowsError(try authority.verify(ticket))
        XCTAssertThrowsError(
            try authority.acceptProjectManifest(ComputerProjectManifest(generation: 4, projects: [first, other])))
        let next = try ComputerProjectWorkspace(projectId: project, grantRevision: 2, roots: first.roots)
        try authority.acceptProjectManifest(try ComputerProjectManifest(generation: 5, projects: [next, other]))
        XCTAssertThrowsError(try authority.begin(session, projectContext: context()))
        XCTAssertThrowsError(try authority.verify(ticket))
    }

    private func context(chat: String = "chat", revision: UInt64 = 1) throws -> ComputerProjectContext {
        try ComputerProjectContext(chatId: chat, projectId: project, grantRevision: revision, manifestGeneration: 1)
    }
    private func request(
        context: ComputerProjectContext?, verb: String = "read_file",
        args: [String: JSONValue] = ["path": .string("/tmp/one/file")]
    ) throws -> ComputerHostRequest {
        var json: [String: JSONValue] = [
            "type": .string("computer_request"),
            "request_id": .string("creq_" + String(repeating: "a", count: 32)), "session_id": .string(session),
            "verb": .string(verb), "args": .object(args), "deadline_ms": .number(1000),
        ]
        if let context { json["project_context"] = context.json }
        return try ComputerHostRequest(json: .object(json))
    }
}
