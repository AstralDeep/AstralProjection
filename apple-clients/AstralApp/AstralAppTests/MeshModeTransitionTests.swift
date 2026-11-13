// Verifies that a signed-in node client can enter its personal mesh without retiring credentials or hiding active work.

import AstralCore
@testable import AstralDeep
import XCTest

@MainActor
final class MeshModeTransitionTests: XCTestCase {
    func testIdleServerSessionCanEnterMeshAndKeepItsAuthenticationState() throws {
        let (model, mode, defaults) = try makeState()
        model.accountName = "Node owner"
        XCTAssertTrue(mode.enterPersonalMesh(from: model))
        XCTAssertTrue(mode.usesMesh)
        XCTAssertEqual(AppModeStore(defaults: defaults).mode, .mesh)
        XCTAssertTrue(model.signedIn)
        XCTAssertEqual(model.accountName, "Node owner")
    }

    func testMandatorySurfaceAndActiveTurnKeepTheNodeSessionVisible() throws {
        let (model, mode, defaults) = try makeState()
        model.turnActive = true
        XCTAssertFalse(mode.enterPersonalMesh(from: model))
        XCTAssertEqual(mode.mode, .node)
        model.turnActive = false
        model.mandatorySurface = true
        XCTAssertFalse(mode.enterPersonalMesh(from: model))
        XCTAssertEqual(AppModeStore(defaults: defaults).mode, .node)
        XCTAssertTrue(model.signedIn)
    }

    func testPendingApprovalCardKeepsTheNodeSessionVisibleAfterTheTurnEnds() throws {
        let (model, mode, _) = try makeState()
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection(UUID().uuidString.lowercased()))
        model.activeChatId = "33333333-3333-4333-8333-333333333333"
        let proposal = String(repeating: "ab", count: 16)
        let buttons = [("Approve", "approve"), ("Decline", "decline")].map { label, decision in
            JSONValue.object([
                "type": .string("button"), "label": .string(label), "action": .string("remote_op_decision"),
                "payload": .object(["proposal_id": .string(proposal), "decision": .string(decision)]),
            ])
        }
        model.canvas = [
            AstralComponent(
                type: "card",
                raw: .object([
                    "type": .string("card"), "id": .string("au_approval_" + proposal),
                    "title": .string("Confirm an action on this device"),
                    "content": .array(
                        [
                            .object(["type": .string("text"), "content": .string("Open a reviewed page.")])
                        ] + buttons),
                ]))
        ]
        XCTAssertGreaterThan(model.waitingApprovals, 0)
        XCTAssertFalse(model.turnActive)
        XCTAssertFalse(model.mandatorySurface)
        XCTAssertFalse(mode.enterPersonalMesh(from: model))
        XCTAssertEqual(mode.mode, .node)
    }

    func testVoicePreparationAndCaptureKeepTheNodeSessionVisible() async throws {
        let fixture = try await VoiceModelTestFixture.installed()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var permission: CheckedContinuation<Bool, Never>?
        let controller = OnDeviceVoiceController(
            store: fixture.controller.store,
            requestPermission: { await withCheckedContinuation { permission = $0 } },
            makePipeline: { _, link in
                VoicePipeline(audio: FakeDuplexAudio(), transcriber: FakeTranscriber(), fastPath: nil, link: link)
            })
        controller.connect(link: FakeKernelLink())
        let (model, mode, _) = try makeState(voice: controller)
        let start = Task { await controller.activate() }
        defer {
            permission?.resume(returning: false)
            controller.stop()
            start.cancel()
        }
        let preparing = await waitUntil { controller.isPreparing && permission != nil }
        XCTAssertTrue(preparing)
        guard preparing else { return }
        XCTAssertFalse(mode.enterPersonalMesh(from: model))
        XCTAssertEqual(mode.mode, .node)
        permission?.resume(returning: true)
        permission = nil
        await start.value
        XCTAssertTrue(controller.isRunning)
        XCTAssertFalse(mode.enterPersonalMesh(from: model))
        XCTAssertTrue(model.signedIn)
        controller.stop()
        XCTAssertTrue(mode.enterPersonalMesh(from: model))
    }

    private func makeState(voice: OnDeviceVoiceController? = nil) throws -> (AppModel, AppModeStore, UserDefaults) {
        let suite = "MeshModeTransitionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = AppModel(tokenStore: InMemoryTokenStore(), defaults: defaults, onDeviceVoiceController: voice)
        model.signedIn = true
        let mode = AppModeStore(defaults: defaults)
        mode.choose(.node)
        return (model, mode, defaults)
    }
}
