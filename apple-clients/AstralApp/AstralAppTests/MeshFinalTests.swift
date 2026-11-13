// Verifies the queued count that follows real message states, adapted surface rendering through resolved handles, the published tool catalog, mesh-wide grants, invitation pairing and renaming.
// Everything runs over the in-memory kernel, so no network, Keychain or identity provider is involved.

@testable import AstralDeep
import AstralCore
import XCTest

@MainActor
final class MeshFinalTests: XCTestCase {
    func testQueuedCountFollowsTheRealMessageStates() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        h.kernel.turnError = .refused("No model is reachable.")
        _ = await h.runtime.send("first")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.chats.first?.queuedCount, 1)
        h.kernel.turnError = nil
        _ = await h.runtime.send("second")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.currentChat?.messages.filter { $0.delivery == .queued }.count, 0)
        XCTAssertEqual(h.runtime.chats.first?.queuedCount, 0)
    }

    func testRenderedSurfaceUsesResolvedImagesAndNeverRawLinks() {
        let tree: [JSONValue] = [
            .object([
                "type": .string("container"), "id": .string("root"),
                "children": .array([
                    .object([
                        "type": .string("image"), "id": .string("pic"),
                        "src": .object(["$handle": .string("res:abc")]), "alt": .string("A chart"),
                    ]),
                    .object([
                        "type": .string("button"), "id": .string("go"), "label": .string("Go"),
                        "action": .object(["handle": .string("notes.save")]),
                    ]),
                    .object([
                        "type": .string("text"), "id": .string("t"), "content": .string("see www.example.com"),
                        "href": .object(["$handle": .string("res:missing")]),
                    ]),
                ]),
            ])
        ]
        let surface = MeshRenderedSurface(surfaceId: "s", tree: tree, untrusted: false, rejected: [])
        XCTAssertEqual(Set(MeshRenderedMapper.handles(in: surface)), ["res:abc", "res:missing"])
        let resolved = ["res:abc": MeshResolvedHandle(kind: .image, value: "AAAA", mime: "image/png")]
        let components = MeshRenderedMapper.components(for: surface, resolved: resolved)
        XCTAssertEqual(components.count, 1)
        let kids = components[0].children
        XCTAssertEqual(kids[0].url, "data:image/png;base64,AAAA")
        XCTAssertEqual(kids[1].raw["capability"]?.stringValue, "notes.save")
        XCTAssertEqual(kids[1].raw["action"]?.stringValue, "mesh_act")
        XCTAssertNil(kids[2].raw["href"])
        XCTAssertFalse(kids[2].raw["content"]?.stringValue?.contains("www.example.com") ?? true)
    }

    func testHandlesResolveThroughTheKernelWhenAChatLoads() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        h.kernel.setHandles(["res:abc": MeshResolvedHandle(kind: .url, value: "https://example.com/a", mime: nil)])
        let surface = MeshRenderedSurface(
            surfaceId: "s",
            tree: [.object(["type": .string("text"), "id": .string("t"), "href": .object(["$handle": .string("res:abc")])])],
            untrusted: false, rejected: [])
        let id = h.kernel.seedChat(
            title: "Rendered", messages: [MeshRuntimeHarness.message("m1", parent: nil, author: .assistant, at: 1, surfaces: ["s"])])
        h.kernel.setRendered(chatId: id, [surface])
        await h.runtime.openChat(id)
        XCTAssertEqual(h.runtime.resolvedHandles["res:abc"]?.value, "https://example.com/a")
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "resolveHandle", detail: id + "|res:abc")))
    }

    func testTheCatalogIsPublishedAtOpenAndGrantsComeFromTheMesh() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        XCTAssertTrue(h.kernel.calls.contains { $0.name == "publishToolCatalog" })
        let tool = try XCTUnwrap(h.runtime.toolEntries.first)
        XCTAssertFalse(h.runtime.isGranted(tool))
        await h.runtime.grant(tool)
        XCTAssertTrue(h.runtime.isGranted(tool))
        XCTAssertEqual(h.runtime.grant(for: tool)?.tool, tool.name)
        await h.runtime.revoke(tool)
        XCTAssertFalse(h.runtime.isGranted(tool))
        XCTAssertNil(h.runtime.grant(for: tool))
    }

    func testInvitationRunsFromCodeToComparisonToApproval() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.startInvitation()
        guard case .waiting(let invitation) = h.runtime.invite else { return XCTFail("expected a waiting invitation") }
        XCTAssertEqual(invitation.code, "K7QM-39XD")
        let request = MeshJoinRequest(
            comparisonCode: "4821 9307", deviceLabel: "New phone", deviceKind: .pocket, deviceId: "d",
            expiresAt: Date().addingTimeInterval(300))
        h.kernel.simulateJoinRequest(request)
        let arrived = await eventually { h.runtime.invite == .requested(request) }
        XCTAssertTrue(arrived)
        await h.runtime.approveInvitation()
        XCTAssertEqual(h.runtime.invite, .added("New phone"))
        XCTAssertEqual(h.runtime.members.count, 2)
    }

    func testADeniedInvitationApprovalAndAnExpiredCodeSayWhatHappened() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.startInvitation()
        let request = MeshJoinRequest(
            comparisonCode: "1", deviceLabel: "Phone", deviceKind: .pocket, deviceId: "d", expiresAt: Date())
        h.kernel.simulateJoinRequest(request)
        _ = await eventually { h.runtime.invite == .requested(request) }
        h.kernel.consentGate = { throw MeshKernelError.consentDenied }
        await h.runtime.approveInvitation()
        XCTAssertEqual(h.runtime.invite, .failed("Adding the device was not approved."))
        await h.runtime.startInvitation()
        h.kernel.simulateFailure(code: "pairing.expired")
        let failed = await eventually { h.runtime.invite == .failed("The code ran out of time.") }
        XCTAssertTrue(failed)
    }

    func testAcceptingAnInvitationShowsTheComparisonCodeAndRejectsOtherText() async {
        let h = MeshRuntimeHarness(hasMesh: false)
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.acceptInvitation(payload: "not an invitation")
        guard case .failed = h.runtime.join else { return XCTFail("expected a refusal") }
        h.runtime.cancelJoin()
        await h.runtime.acceptInvitation(payload: "astral-invite:v1:invitation")
        guard case .accepted(let accepted) = h.runtime.join else { return XCTFail("expected acceptance") }
        XCTAssertEqual(accepted.comparisonCode, "4821 9307")
    }

    func testRenamingChangesTheLabelAndIgnoresBlankOrUnchangedNames() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let me = try XCTUnwrap(h.runtime.members.first)
        let same = await h.runtime.renameDevice(me, to: me.label)
        XCTAssertFalse(same)
        let blank = await h.runtime.renameDevice(me, to: "   ")
        XCTAssertFalse(blank)
        let changed = await h.runtime.renameDevice(me, to: "Desk Mac")
        XCTAssertTrue(changed)
        XCTAssertEqual(h.runtime.members.first?.label, "Desk Mac")
    }
}
