// Verifies one real kernel capture reaches native primitives with its stored identity, outside-agent provenance and denied links and controls intact.
@testable import AstralDeep
import AstralCore
import AstralKernel
import XCTest

@MainActor
final class MeshStoredSurfaceTests: XCTestCase {
    func testBothNativeProfilesUseTheSameStoredEventAndSafePrimitiveValues() throws {
        XCTAssertEqual(MeshStoredSurfaceFixture.digest, MeshStoredSurfaceFixture.payloadDigest)
        let snapshot = try MeshStoredSurfaceFixture.load()
        XCTAssertEqual(snapshot.event.id, MeshStoredSurfaceFixture.eventId)
        XCTAssertEqual(snapshot.event.body.objectValue?["source"]?.objectValue?["origin"], .string("agent"))
        let folded = KernelSurfaceFold.fold([try snapshot.event.native()])
        XCTAssertEqual(folded.map(\.surface.surfaceId), [snapshot.event.id])
        XCTAssertEqual(folded.first?.surface.nodes["pulse"]?.provenance, "agent")
        XCTAssertEqual(Set(snapshot.profiles.keys), ["mac", "iphone"])
        for profile in snapshot.profiles.values {
            XCTAssertEqual(profile.surface, snapshot.event.id)
            XCTAssertEqual(profile.document, snapshot.event.body.objectValue?["document"])
            XCTAssertTrue(profile.untrusted)
            XCTAssertTrue(profile.rejected.isEmpty)
            XCTAssertTrue(profile.unresolved.isEmpty)
            let rendered = try XCTUnwrap(KernelChatMapper.rendered(try profile.native()))
            let components = MeshRenderedMapper.components(for: rendered, resolved: [:])
            XCTAssertEqual(components.first?.children.map(\.componentId), ["heading", "pulse", "link", "send"])
            XCTAssertEqual(components.first?.children.dropFirst().first?.textContent, "Pulse: 72 bpm")
            XCTAssertEqual(components.first?.children.dropFirst(2).first?.textContent, MeshModelText.neutralize("[text with a link was removed]"))
            XCTAssertEqual(components.first?.children.dropFirst(3).first?.type, "text")
            for component in components.first?.children ?? [] {
                XCTAssertNil(component.raw["action"])
                XCTAssertNil(component.raw["capability"])
                XCTAssertNil(component.raw["href"])
                XCTAssertNil(component.raw["src"])
            }
        }
    }

    func testStoredAgentSurfaceIsAssociatedWithItsAssistantMessage() throws {
        let snapshot = try MeshStoredSurfaceFixture.load()
        let event = try snapshot.event.native()
        let message = AstralKernel.ChatMessage(
            id: "result", role: .assistant, kind: "chat.assistant_message", text: "Outside lab summary",
            componentJson: nil, turn: nil, branch: nil,
            labels: LabelView(confidentiality: "private", integrity: "untrusted"), status: .complete,
            feed: event.feed, seq: 1, clock: ClockStamp(ms: event.clock.ms - 1, n: 0), author: "agent", attachments: [])
        let view = AstralKernel.ChatView(
            chatId: "chat", title: "Shared clinical summary", created: nil, lastActivity: event.clock,
            messages: [message], turns: [], branches: [], forkPoints: [], surfaces: [event],
            unreadable: [], waiting: [], invalid: [])
        let folded = KernelChatMapper.fold(view, queuedBases: [:])
        XCTAssertEqual(folded.messages.first?.surfaceIds, [event.id])
    }

    func testTheRealKernelImportsTheCapturedOutsidePageBeforeNativeMapping() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("surface-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "surface-import-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let keys = try DeviceKeys(
            store: MeshMemorySecretStore(), defaults: UserDefaults(suiteName: suite)!, preferHardware: false)
        let config = KernelConfig(
            dataDir: directory.path, operationsSecret: try keys.operationsSecret(), wrapSecret: try keys.wrapSecret(),
            restoreMarker: try keys.installMarker(), deviceLabel: "Surface importer", deviceKind: .desktop,
            issuers: [TestTokenIssuer.config], network: KernelNetworking.loopback)
        let signer = KernelHostSigner(MeshHostSigner(keys: keys, presenter: RecordingPresenter()))
        let kernel = try Kernel.open(config: config, signer: signer)
        _ = try await Task.detached {
            let request = try kernel.beginMeshCreation()
            return try kernel.completeMeshCreation(idToken: TestTokenIssuer.token(nonce: request.nonce))
        }.value
        let snapshot = try MeshStoredSurfaceFixture.load()
        let chat = try kernel.createChat(title: "Outside page")
        let imported = try kernel.importA2uiSurface(
            chatId: chat, documentJson: String(decoding: try JSONEncoder().encode(snapshot.a2ui), as: UTF8.self),
            origin: .agent, name: "outside-lab-agent", turnId: nil)
        XCTAssertEqual(Set(imported.notices.map(\.code)), ["a2ui.link_removed", "a2ui.control_dropped"])
        let detail = try kernel.chat(chatId: chat)
        let event = try XCTUnwrap(detail.view.surfaces.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(event.bodyJson).utf8))
        XCTAssertEqual(body.objectValue?["source"], snapshot.event.body.objectValue?["source"])
        XCTAssertEqual(KernelSurfaceFold.fold([event]).first?.surface.surfaceId, imported.surfaceId)
        for (device, width) in [("browser", 1280), ("mobile", 390)] {
            try kernel.setDeviceProfile(deviceProfileJson: "{\"device_type\":\"\(device)\",\"viewport_width\":\(width)}")
            let rendered = try XCTUnwrap(kernel.chat(chatId: chat).rendered.first)
            XCTAssertTrue(rendered.untrusted)
            let document = try JSONDecoder().decode(JSONValue.self, from: Data(rendered.documentJson.utf8))
            XCTAssertEqual(document, snapshot.event.body.objectValue?["document"])
            let native = try XCTUnwrap(KernelChatMapper.rendered(rendered))
            XCTAssertEqual(MeshRenderedMapper.components(for: native, resolved: [:]).first?.children.dropFirst().first?.textContent, "Pulse: 72 bpm")
        }
        do {
            _ = try await kernel.act(surfaceId: imported.surfaceId, componentId: "send", actionJson: "{}")
            XCTFail("An imported outside control must not run a tool")
        } catch {
            XCTAssertTrue(String(describing: error).contains("surface.no_origin_turn"), "\(error)")
        }
        await kernel.stopNetwork()
    }

    func testUntrustedMarkersFollowKernelIntegrityAndAgentProvenance() throws {
        let snapshot = try MeshStoredSurfaceFixture.load()
        let event = try snapshot.event.native()
        let surface = try XCTUnwrap(KernelSurfaceFold.fold([event]).first?.surface)
        let rendered = try XCTUnwrap(KernelChatMapper.rendered(try XCTUnwrap(snapshot.profiles["mac"]).native()))
        let message = MeshRuntimeHarness.message("result", parent: nil, author: .assistant, at: 1, surfaces: [event.id])
        func row(surfaces: [MeshSurface], rendered: [MeshRenderedSurface]) throws -> MeshChatMapper.Row {
            let view = MeshChatView(
                chatId: "chat", title: "Summary", messages: [message], branches: [], surfaces: surfaces,
                rendered: rendered, labels: [], status: .idle)
            return try XCTUnwrap(MeshChatMapper.rows(for: view, head: nil).first)
        }
        XCTAssertEqual(try row(surfaces: [], rendered: [rendered]).untrustedSurfaceIds, [event.id])
        XCTAssertEqual(try row(surfaces: [surface], rendered: []).untrustedSurfaceIds, [event.id])
        XCTAssertTrue(try row(surfaces: [], rendered: []).untrustedSurfaceIds.isEmpty)
        let trusted = MeshRenderedSurface(surfaceId: event.id, tree: rendered.tree, untrusted: false, rejected: [])
        XCTAssertTrue(try row(surfaces: [], rendered: [trusted]).untrustedSurfaceIds.isEmpty)
    }

    func testUnknownProvenanceIsStillRejected() throws {
        let snapshot = try MeshStoredSurfaceFixture.load()
        var event = try snapshot.event.native()
        event.bodyJson = event.bodyJson?.replacingOccurrences(of: "\"agent\"", with: "\"administrator\"")
        XCTAssertTrue(KernelSurfaceFold.fold([event]).isEmpty)
    }
}
