// Verifies starting a new mesh on a device restored from a backup: the confirmation, retiring the stale store, and the restore banner.
// It runs MeshRuntime over an in-memory kernel whose enrolment follows a marker file in the data directory.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshNewMeshTests: XCTestCase {
    private func entries(_ suite: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        return (names ?? []).filter { $0.hasPrefix(suite) }.sorted()
    }

    func testRetireMovesTheStoreAsideKeepsItsContentsAndLeavesAnEmptyOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = root.appendingPathComponent("mesh-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data([7]).write(to: store.appendingPathComponent("log.db"))
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = try XCTUnwrap(try MeshStoreRetirement.retire(store, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(moved.lastPathComponent, "mesh-v2.retired-19700101T000000Z")
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("log.db")), Data([7]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), [])
        let again = try XCTUnwrap(try MeshStoreRetirement.retire(store, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(again.lastPathComponent, "mesh-v2.retired-19700101T000000Z-2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    func testRetireWithNothingToMoveDoesNothing() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(try MeshStoreRetirement.retire(missing, now: Date()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testChoosingCreateOnARestoredDeviceAsksFirstAndCancelChangesNothing() async {
        let h = MeshRuntimeHarness(hasMesh: false, staleStore: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        XCTAssertTrue(h.runtime.restoredInstall)
        await h.runtime.chooseCreateMesh()
        XCTAssertTrue(h.runtime.confirmingNewMesh)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "createMesh" })
        let before = entries(h.suite)
        h.runtime.cancelNewMesh()
        XCTAssertFalse(h.runtime.confirmingNewMesh)
        await h.runtime.confirmNewMesh()
        XCTAssertEqual(entries(h.suite), before)
        XCTAssertTrue(h.runtime.restoredInstall)
        XCTAssertEqual(h.runtime.creation, .idle)
    }

    func testConfirmingRetiresTheStaleStoreThenCreatesAndClearsTheBanner() async {
        let h = MeshRuntimeHarness(hasMesh: false, staleStore: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        XCTAssertTrue(h.kernel.refusesCreate)
        await h.runtime.chooseCreateMesh()
        await h.runtime.confirmNewMesh()
        XCTAssertTrue(entries(h.suite).contains { $0.contains(".retired-") })
        XCTAssertFalse(h.kernel.refusesCreate)
        guard case .recovery = h.runtime.creation else { return XCTFail("\(h.runtime.creation)") }
        XCTAssertFalse(h.runtime.restoredInstall)
        XCTAssertFalse(h.runtime.confirmingNewMesh)
    }

    func testCreatingWithoutARestoreSkipsTheConfirmation() async {
        let h = MeshRuntimeHarness(hasMesh: false)
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.chooseCreateMesh()
        XCTAssertFalse(h.runtime.confirmingNewMesh)
        guard case .recovery = h.runtime.creation else { return XCTFail("\(h.runtime.creation)") }
    }

    func testTheRestoreBannerClearsOnceRecoveryRestoresTheMesh() async {
        let h = MeshRuntimeHarness(hasMesh: false, staleStore: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        h.kernel.hasLocalMesh = true
        h.kernel.recoveryWords = (0..<24).map { "word" + String(UnicodeScalar(UInt8(97 + $0))) }
        await h.runtime.recoverMesh(words: h.kernel.recoveryWords.joined(separator: " "), backup: nil)
        XCTAssertFalse(h.runtime.restoredInstall)
    }

    func testAFailedCreateKeepsTheBannerAndTheStoreUntouched() async {
        let h = MeshRuntimeHarness(hasMesh: false, staleStore: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        let before = entries(h.suite)
        await h.runtime.createMesh()
        XCTAssertEqual(h.runtime.creation, .failed("This device already belongs to a mesh."))
        XCTAssertTrue(h.runtime.restoredInstall)
        XCTAssertEqual(entries(h.suite), before)
    }
}
