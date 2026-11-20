// Checks that the one-time cleanup removes exactly the retired model folder, leaves the voice pack and every sibling alone, and never follows a symbolic link out of the folder.
// A fixture tree in a temporary directory stands in for Application Support, and the completion flag lives in an isolated defaults suite.

import XCTest

@testable import AstralDeep

final class LegacyVoiceModelCleanupTests: XCTestCase {
    private var support: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        suite = "legacy-voice-cleanup-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: support)
    }

    private var legacy: URL { support.appendingPathComponent("AstralDeep/VoiceModel", isDirectory: true) }
    private var pack: URL { support.appendingPathComponent("AstralDeep/VoicePack", isDirectory: true) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func installLegacyTree() throws {
        try write("weights", to: legacy.appendingPathComponent("model/model.safetensors"))
        try write("{}", to: legacy.appendingPathComponent("model/.installed.json"))
        try write("notice", to: legacy.appendingPathComponent("model/NOTICE"))
        try write("partial", to: legacy.appendingPathComponent("staging/audio_tokenizer/model.safetensors.resume"))
        try write("{}", to: legacy.appendingPathComponent("download-request.json"))
    }

    func testTheLegacyFolderIsTheOldStoresApplicationSupportFolder() {
        let path = LegacyVoiceModelCleanup.legacyRoot().path
        XCTAssertTrue(path.hasSuffix("/AstralDeep/VoiceModel"))
        XCTAssertNotEqual(path, VoicePackStore.defaultRoot().path)
    }

    func testItDeletesTheWeightsStagingAndMarkersAndNothingElse() throws {
        try installLegacyTree()
        try write("pack", to: pack.appendingPathComponent("model/rumble/Rumble.gguf"))
        try write("{}", to: pack.appendingPathComponent("model/.installed.json"))
        try write("sibling", to: support.appendingPathComponent("AstralDeep/Other/keep.txt"))
        try write("top", to: support.appendingPathComponent("unrelated.txt"))
        let task = try XCTUnwrap(LegacyVoiceModelCleanup.runOnce(root: legacy, defaults: defaults))
        let done = expectation(description: "cleanup finished")
        Task {
            await task.value
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(exists(legacy))
        XCTAssertTrue(exists(pack.appendingPathComponent("model/rumble/Rumble.gguf")))
        XCTAssertTrue(exists(pack.appendingPathComponent("model/.installed.json")))
        XCTAssertTrue(exists(support.appendingPathComponent("AstralDeep/Other/keep.txt")))
        XCTAssertTrue(exists(support.appendingPathComponent("unrelated.txt")))
        XCTAssertTrue(defaults.bool(forKey: LegacyVoiceModelCleanup.completedKey))
    }

    func testItRunsOnceAndNeverTouchesAFolderCreatedAfterwards() throws {
        let first = try XCTUnwrap(LegacyVoiceModelCleanup.runOnce(root: legacy, defaults: defaults))
        let finished = expectation(description: "first run")
        Task {
            await first.value
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        try installLegacyTree()
        XCTAssertNil(LegacyVoiceModelCleanup.runOnce(root: legacy, defaults: defaults))
        XCTAssertTrue(exists(legacy.appendingPathComponent("model/model.safetensors")))
    }

    func testAnAbsentFolderIsSafeAndRecordsCompletion() throws {
        XCTAssertFalse(exists(legacy))
        XCTAssertTrue(LegacyVoiceModelCleanup.remove(legacy))
        let task = try XCTUnwrap(LegacyVoiceModelCleanup.runOnce(root: legacy, defaults: defaults))
        let done = expectation(description: "absent folder")
        Task {
            await task.value
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(defaults.bool(forKey: LegacyVoiceModelCleanup.completedKey))
    }

    func testASymbolicLinkInsideTheFolderIsRemovedWithoutFollowingIt() throws {
        try installLegacyTree()
        let outside = support.appendingPathComponent("Outside", isDirectory: true)
        try write("precious", to: outside.appendingPathComponent("data.bin"))
        try FileManager.default.createSymbolicLink(
            at: legacy.appendingPathComponent("model/escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: legacy.appendingPathComponent("link-to-pack"), withDestinationURL: pack)
        try write("pack", to: pack.appendingPathComponent("model/keep.gguf"))
        XCTAssertTrue(LegacyVoiceModelCleanup.remove(legacy))
        XCTAssertFalse(exists(legacy))
        XCTAssertTrue(exists(outside.appendingPathComponent("data.bin")))
        XCTAssertTrue(exists(pack.appendingPathComponent("model/keep.gguf")))
    }

    func testTheFolderItselfBeingASymbolicLinkRemovesOnlyTheLink() throws {
        let target = support.appendingPathComponent("Elsewhere", isDirectory: true)
        try write("precious", to: target.appendingPathComponent("data.bin"))
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: target)
        XCTAssertTrue(LegacyVoiceModelCleanup.remove(legacy))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: legacy.path))
        XCTAssertTrue(exists(target.appendingPathComponent("data.bin")))
    }

    func testAFailedRemovalIsReportedAndRetriedOnTheNextLaunch() throws {
        try installLegacyTree()
        let locked = legacy.appendingPathComponent("model")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: legacy.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacy.path) }
        XCTAssertFalse(LegacyVoiceModelCleanup.remove(legacy))
        XCTAssertTrue(exists(locked))
        let task = try XCTUnwrap(LegacyVoiceModelCleanup.runOnce(root: legacy, defaults: defaults))
        let done = expectation(description: "failed run")
        Task {
            await task.value
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(defaults.bool(forKey: LegacyVoiceModelCleanup.completedKey))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacy.path)
        let retry = try XCTUnwrap(LegacyVoiceModelCleanup.runOnce(root: legacy, defaults: defaults))
        let retried = expectation(description: "retried run")
        Task {
            await retry.value
            retried.fulfill()
        }
        wait(for: [retried], timeout: 5)
        XCTAssertFalse(exists(legacy))
        XCTAssertTrue(defaults.bool(forKey: LegacyVoiceModelCleanup.completedKey))
    }
}
