// Verifies leaving or deleting a mesh from this device: the confirmation, the removal, the retired store and the erased keys.
// It runs MeshRuntime over an in-memory kernel and never signs or writes outside a temporary folder.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshExitTests: XCTestCase {
    private func retired(_ suite: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        return (names ?? []).filter { $0.hasPrefix(suite) && $0.contains(".retired-") }
    }

    private func withTwoDevices() async -> MeshRuntimeHarness {
        let h = MeshRuntimeHarness(hasMesh: true, staleStore: true)
        await h.runtime.open()
        return h
    }

    func testSingleMemberOffersDeleteAndConfirmingRetiresTheStoreWithoutARemoval() async {
        let h = MeshRuntimeHarness(hasMesh: true, staleStore: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        let kernel = h.kernel
        XCTAssertEqual(h.runtime.members.count, 1)
        h.runtime.requestExit()
        XCTAssertEqual(h.runtime.confirmingExit, .delete)
        await h.runtime.confirmExit()
        XCTAssertEqual(retired(h.suite).count, 1)
        XCTAssertFalse(h.runtime.hasMesh)
        XCTAssertEqual(h.runtime.phase, .ready)
        XCTAssertFalse(kernel.calls.contains { $0.name == "removeDevice" })
    }

    func testLeavingSignsThisDevicesRemovalThenRetiresTheStoreAndErasesTheKeys() async {
        let h = await withTwoDevices()
        defer { h.cleanUp() }
        let kernel = h.kernel
        let other = MeshMember(
            memberId: "sha256:" + String(repeating: "d", count: 64), label: "Phone", kind: .pocket,
            isThisDevice: false, lastSeen: nil, path: .none)
        h.kernel.addMember(other)
        await h.runtime.refreshRoster()
        h.runtime.requestExit()
        XCTAssertEqual(h.runtime.confirmingExit, .leave)
        await h.runtime.confirmExit()
        XCTAssertTrue(kernel.calls.contains { $0.name == "removeDevice" })
        XCTAssertEqual(retired(h.suite).count, 1)
        XCTAssertFalse(h.runtime.restoredInstall)
    }

    func testCancelChangesNothing() async {
        let h = await withTwoDevices()
        defer { h.cleanUp() }
        h.runtime.requestExit()
        h.runtime.cancelExit()
        XCTAssertNil(h.runtime.confirmingExit)
        await h.runtime.confirmExit()
        XCTAssertTrue(retired(h.suite).isEmpty)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "removeDevice" })
    }

    func testADeviceWithoutAUsableMeshOffersAReset() async {
        let h = MeshRuntimeHarness(hasMesh: false, staleStore: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        h.runtime.requestExit()
        XCTAssertEqual(h.runtime.confirmingExit, .reset)
        await h.runtime.confirmExit()
        XCTAssertEqual(retired(h.suite).count, 1)
    }

    func testTheConfirmationsSayPlainlyWhatHappens() {
        XCTAssertEqual(
            MeshExit.leave.message, "This device leaves the mesh. Your chats stay on your other devices.")
        XCTAssertTrue(MeshExit.delete.message.contains("can't be recovered"))
        XCTAssertEqual(MeshExit.delete.button, "Delete This Mesh")
    }

    func testSettingsExitActionLabelFollowsTheDeviceCount() async {
        let h = await withTwoDevices()
        defer { h.cleanUp() }
        XCTAssertEqual(h.runtime.exitAction, .delete)
        XCTAssertEqual(h.runtime.exitAction.button, "Delete This Mesh")
        h.kernel.addMember(
            MeshMember(
                memberId: "sha256:" + String(repeating: "e", count: 64), label: "Phone", kind: .pocket,
                isThisDevice: false, lastSeen: nil, path: .none))
        await h.runtime.refreshRoster()
        XCTAssertEqual(h.runtime.exitAction, .leave)
        XCTAssertEqual(h.runtime.exitAction.button, "Leave This Mesh")
        h.runtime.requestExit()
        XCTAssertEqual(h.runtime.confirmingExit, h.runtime.exitAction)
    }
}
