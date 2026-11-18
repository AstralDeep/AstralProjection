// Verifies the one-time legacy-to-protected Keychain migration against in-memory backends, never the real Keychain.
// It covers copy-verify-delete order, fail-closed errors that keep the legacy item, and no legacy access after.

import XCTest

@testable import AstralCore

private final class FakeBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    var items: [String: Data] = [:]
    var touches = 0
    var failWrite: Int32?
    var failDelete: Int32?
    var failEnumerate: Int32?
    var corruptWrites = false

    private func id(_ service: String, _ account: String) -> String { service + "|" + account }

    func accounts(service: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        touches += 1
        if let failEnumerate { throw KeychainBackendError(status: failEnumerate) }
        let prefix = service + "|"
        return items.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }

    func read(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        touches += 1
        return items[id(service, account)]
    }

    func write(service: String, account: String, value: Data, accessibility: KeychainAccessibility) throws {
        lock.lock()
        defer { lock.unlock() }
        touches += 1
        if let failWrite { throw KeychainBackendError(status: failWrite) }
        items[id(service, account)] = corruptWrites ? Data([0]) : value
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        touches += 1
        if let failDelete { throw KeychainBackendError(status: failDelete) }
        items.removeValue(forKey: id(service, account))
    }
}

private final class FakeMarker: KeychainMigrationMarker, @unchecked Sendable {
    var done: Set<String> = []
    func isMigrated(_ service: String) -> Bool { done.contains(service) }
    func markMigrated(_ service: String) { done.insert(service) }
}

final class KeychainMigrationTests: XCTestCase {
    private let service = "svc"
    private let legacy = FakeBackend()
    private let protected = FakeBackend()
    private let marker = FakeMarker()

    private func migrator() -> LegacyKeychainMigrator {
        LegacyKeychainMigrator(legacy: legacy, protected: protected, marker: marker)
    }

    func testCopiesVerifiesThenRemovesLegacyAndMarks() throws {
        legacy.items["svc|a"] = Data([1, 2])
        legacy.items["svc|b"] = Data([3])
        legacy.items["other|a"] = Data([9])
        try migrator().ensureMigrated(service: service, accessibility: .whenUnlocked)
        XCTAssertEqual(protected.items, ["svc|a": Data([1, 2]), "svc|b": Data([3])])
        XCTAssertEqual(legacy.items, ["other|a": Data([9])])
        XCTAssertTrue(marker.isMigrated(service))
    }

    func testFailedWriteKeepsLegacyAndLeavesNoMarker() {
        legacy.items["svc|a"] = Data([1])
        protected.failWrite = -34018
        XCTAssertThrowsError(try migrator().ensureMigrated(service: service, accessibility: .whenUnlocked)) {
            XCTAssertEqual($0 as? KeychainMigrationError, KeychainMigrationError(code: "write--34018"))
        }
        XCTAssertEqual(legacy.items["svc|a"], Data([1]))
        XCTAssertFalse(marker.isMigrated(service))
    }

    func testVerifyMismatchKeepsLegacy() {
        legacy.items["svc|a"] = Data([1])
        protected.corruptWrites = true
        XCTAssertThrowsError(try migrator().ensureMigrated(service: service, accessibility: .whenUnlocked)) {
            XCTAssertEqual($0 as? KeychainMigrationError, KeychainMigrationError(code: "verify"))
        }
        XCTAssertEqual(legacy.items["svc|a"], Data([1]))
        XCTAssertFalse(marker.isMigrated(service))
    }

    func testFailedDeleteKeepsProtectedCopyAndLeavesNoMarker() {
        legacy.items["svc|a"] = Data([1])
        legacy.failDelete = -25244
        XCTAssertThrowsError(try migrator().ensureMigrated(service: service, accessibility: .whenUnlocked)) {
            XCTAssertEqual($0 as? KeychainMigrationError, KeychainMigrationError(code: "delete--25244"))
        }
        XCTAssertEqual(legacy.items["svc|a"], Data([1]))
        XCTAssertEqual(protected.items["svc|a"], Data([1]))
        XCTAssertFalse(marker.isMigrated(service))
    }

    func testFailedEnumerationFailsClosed() {
        legacy.failEnumerate = -25293
        XCTAssertThrowsError(try migrator().ensureMigrated(service: service, accessibility: .whenUnlocked)) {
            XCTAssertEqual($0 as? KeychainMigrationError, KeychainMigrationError(code: "enumerate--25293"))
        }
        XCTAssertFalse(marker.isMigrated(service))
    }

    func testExistingProtectedItemWinsOverStaleLegacy() throws {
        legacy.items["svc|a"] = Data([1])
        protected.items["svc|a"] = Data([2])
        try migrator().ensureMigrated(service: service, accessibility: .whenUnlocked)
        XCTAssertEqual(protected.items["svc|a"], Data([2]))
        XCTAssertNil(legacy.items["svc|a"])
    }

    func testRetryAfterFailureCompletes() throws {
        legacy.items["svc|a"] = Data([1])
        protected.failWrite = -1
        XCTAssertThrowsError(try migrator().ensureMigrated(service: service, accessibility: .whenUnlocked))
        protected.failWrite = nil
        try migrator().ensureMigrated(service: service, accessibility: .whenUnlocked)
        XCTAssertEqual(protected.items["svc|a"], Data([1]))
        XCTAssertTrue(legacy.items.isEmpty)
    }

    func testSecondRunAndSecondLaunchNeverTouchLegacy() throws {
        legacy.items["svc|a"] = Data([1])
        let first = migrator()
        try first.ensureMigrated(service: service, accessibility: .whenUnlocked)
        let touches = legacy.touches
        try first.ensureMigrated(service: service, accessibility: .whenUnlocked)
        try migrator().ensureMigrated(service: service, accessibility: .whenUnlocked)
        XCTAssertEqual(legacy.touches, touches)
    }

    func testEmptyLegacyMarksWithoutWriting() throws {
        try migrator().ensureMigrated(service: service, accessibility: .afterFirstUnlock)
        XCTAssertTrue(marker.isMigrated(service))
        XCTAssertTrue(protected.items.isEmpty)
    }

    func testDefaultsMarkerPersistsPerService() {
        let suite = "KeychainMigrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = DefaultsKeychainMigrationMarker(defaults: defaults)
        XCTAssertFalse(marker.isMigrated("a"))
        marker.markMigrated("a")
        XCTAssertTrue(DefaultsKeychainMigrationMarker(defaults: defaults).isMigrated("a"))
        XCTAssertFalse(marker.isMigrated("b"))
    }
}
