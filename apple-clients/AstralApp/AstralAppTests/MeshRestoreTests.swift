// Verifies recovery from the 24 words in MeshRuntime over an in-memory kernel: word normalization, the restored mesh and device, clear errors, and that the words are neither logged nor stored.
// The real-kernel recovery is covered next to the other wrapper tests in RealMeshKernelTests.

@testable import AstralDeep
import XCTest

@MainActor
final class MeshRestoreTests: XCTestCase {
    private let words = (0..<24).map { "word" + String(UnicodeScalar(UInt8(97 + $0))) }
    private var phrase: String { words.joined(separator: " ") }

    private func opened(localMesh: Bool = false) async -> MeshRuntimeHarness {
        let h = MeshRuntimeHarness(hasMesh: false)
        await h.runtime.open()
        h.kernel.hasLocalMesh = localMesh
        h.kernel.recoveryWords = words
        return h
    }

    func testNormalizeAcceptsNumberedListsCommasAndCase() {
        XCTAssertEqual(MeshRecoveryWords.normalize("  Alpha,beta\n3. Gamma (delta)\t ").count, 4)
        XCTAssertEqual(MeshRecoveryWords.normalize("1. Alpha 2. beta"), ["alpha", "beta"])
        XCTAssertEqual(MeshRecoveryWords.normalize(""), [])
        XCTAssertEqual(MeshRecoveryWords.normalize("12 34 ,,"), [])
    }

    func testRecoveryWithAFileShowsTheRestoredMeshAndDevice() async throws {
        let h = await opened()
        defer { h.cleanUp() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString).astral")
        await h.runtime.recoverMesh(words: phrase.uppercased(), backup: file)
        guard case .restored(let restored) = h.runtime.restore else { return XCTFail("\(h.runtime.restore)") }
        XCTAssertEqual(restored.deviceLabel, "This device")
        XCTAssertEqual(restored.memberCount, 2)
        XCTAssertEqual(restored.eventsImported, 12)
        XCTAssertTrue(restored.meshId.hasPrefix("sha256:"))
        XCTAssertTrue(h.runtime.hasMesh)
        XCTAssertEqual(h.runtime.members.count, 2)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "recoverWithWords", detail: "24|" + file.path)))
        h.runtime.finishRestore()
        XCTAssertEqual(h.runtime.restore, .idle)
    }

    func testRecoveryWithoutAFileUsesTheInstallsOwnCopy() async {
        let h = await opened(localMesh: true)
        defer { h.cleanUp() }
        await h.runtime.recoverMesh(words: phrase, backup: nil)
        guard case .restored(let restored) = h.runtime.restore else { return XCTFail("\(h.runtime.restore)") }
        XCTAssertEqual(restored.eventsImported, 0)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "recoverWithWords", detail: "24|")))
    }

    func testTheWordsAreNeverLoggedOrStored() async {
        let h = await opened(localMesh: true)
        defer { h.cleanUp() }
        await h.runtime.recoverMesh(words: phrase, backup: nil)
        XCTAssertFalse(h.kernel.calls.contains { $0.detail.contains("worda") || $0.name.contains("worda") })
        let stored = h.defaults.dictionaryRepresentation()
        XCTAssertFalse(String(describing: stored).contains("worda wordb"))
        XCTAssertFalse(String(describing: h.runtime.restore).contains("wordb"))
        XCTAssertNil(h.runtime.notice)
    }

    func testTooFewWordsAreRefusedBeforeTheKernelIsAsked() async {
        let h = await opened(localMesh: true)
        defer { h.cleanUp() }
        await h.runtime.recoverMesh(words: "one two three", backup: nil)
        XCTAssertEqual(h.runtime.restore, .failed("Enter all 24 recovery words."))
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "recoverWithWords" })
        XCTAssertFalse(h.runtime.hasMesh)
    }

    func testWrongWordsGiveAClearErrorAndAllowARetry() async {
        let h = await opened(localMesh: true)
        defer { h.cleanUp() }
        let wrong = (1...24).map { "wrong\($0)" }.joined(separator: " ")
        await h.runtime.recoverMesh(words: wrong, backup: nil)
        XCTAssertEqual(
            h.runtime.restore, .failed("These words are not a valid recovery key. Check the order and the spelling."))
        XCTAssertFalse(h.runtime.hasMesh)
        await h.runtime.recoverMesh(words: phrase, backup: nil)
        guard case .restored = h.runtime.restore else { return XCTFail("\(h.runtime.restore)") }
    }

    func testAnInstallWithoutACopyNeedsABackupFile() async {
        let h = await opened(localMesh: false)
        defer { h.cleanUp() }
        await h.runtime.recoverMesh(words: phrase, backup: nil)
        XCTAssertEqual(
            h.runtime.restore, .failed("Choose a backup file. This device holds no copy of your mesh."))
        h.runtime.dismissRestoreFailure()
        XCTAssertEqual(h.runtime.restore, .idle)
    }

    func testAnEnrolledDeviceRefusesRecovery() async {
        let h = MeshRuntimeHarness(hasMesh: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.recoverMesh(words: phrase, backup: nil)
        XCTAssertEqual(h.runtime.restore, .failed("This device already belongs to a mesh."))
    }

    func testRecoveryClearsTheRestoredInstallWarning() async {
        let h = await opened(localMesh: true)
        defer { h.cleanUp() }
        await h.runtime.recoverMesh(words: phrase, backup: nil)
        XCTAssertFalse(h.runtime.restoredInstall)
    }

    func testASecondRecoveryIsIgnoredOnceTheMeshIsRestored() async {
        let h = await opened(localMesh: true)
        defer { h.cleanUp() }
        await h.runtime.recoverMesh(words: phrase, backup: nil)
        let before = h.kernel.calls.filter { $0.name == "recoverWithWords" }.count
        await h.runtime.recoverMesh(words: phrase, backup: nil)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "recoverWithWords" }.count, before)
    }
}
