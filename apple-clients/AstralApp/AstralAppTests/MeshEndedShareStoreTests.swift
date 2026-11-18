// Tests that ended shares survive a relaunch of the store and that unreadable files read as empty.
// They cover MeshEndedShareStore directly, in a throwaway directory.

import XCTest

@testable import AstralDeep

final class MeshEndedShareStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func share(_ id: String, state: MeshShareState = .inEffect) -> MeshShareInfo {
        MeshShareInfo(
            id: id, chat: "chat-" + id, title: "Title " + id, contact: "mesh-" + id, contactName: "Ana " + id,
            phi: true, phiWithheld: false, state: state)
    }

    func testRevokedSharesStayRevokedInANewStore() {
        MeshEndedShareStore(directory: directory).save(["a": share("a").revoked(), "b": share("b").revoked()])
        let loaded = MeshEndedShareStore(directory: directory).load()
        XCTAssertEqual(Set(loaded.keys), ["a", "b"])
        XCTAssertEqual(loaded["a"]?.state, .revoked)
        XCTAssertEqual(loaded["a"]?.contactName, "Ana a")
        XCTAssertEqual(loaded["b"]?.chat, "chat-b")
    }

    func testMissingOrCorruptFileReadsAsEmpty() throws {
        let store = MeshEndedShareStore(directory: directory)
        XCTAssertTrue(store.load().isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.file)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testSavingAgainReplacesTheEarlierList() {
        let store = MeshEndedShareStore(directory: directory)
        store.save(["a": share("a").revoked()])
        store.save(["b": share("b").revoked()])
        XCTAssertEqual(Set(store.load().keys), ["b"])
    }
}
