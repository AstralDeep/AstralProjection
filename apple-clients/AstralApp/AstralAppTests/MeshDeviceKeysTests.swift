// Verifies DeviceKeys key shapes, signatures, honest hardware reporting and backup-restore detection with in-memory storage.
// One Keychain round trip uses a throwaway service name and removes its items afterwards.

import CryptoKit
import XCTest

@testable import AstralDeep

nonisolated final class MeshMemorySecretStore: MeshSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func load(_ account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func save(_ value: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = value
    }

    func remove(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = nil
    }
}

final class MeshDeviceKeysTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let suite = "MeshDeviceKeysTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func verify(_ signature: Data, over message: Data, publicKey: Data) throws -> Bool {
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        return key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message)
    }

    func testPublicKeysAreUncompressedPointsAndDiffer() throws {
        let keys = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults(), preferHardware: false)
        let identity = try keys.identityPublicKey()
        let presence = try keys.presencePublicKey()
        XCTAssertEqual(identity.count, 65)
        XCTAssertEqual(identity.first, 0x04)
        XCTAssertEqual(presence.count, 65)
        XCTAssertNotEqual(identity, presence)
    }

    func testSignaturesAreRawSixtyFourBytesAndVerify() throws {
        let keys = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults(), preferHardware: false)
        let message = Data("astral.consent/v1\n{}".utf8)
        let identitySig = try keys.identitySign(message)
        let presenceSig = try keys.presenceSign(message, authentication: nil)
        XCTAssertEqual(identitySig.count, 64)
        XCTAssertEqual(presenceSig.count, 64)
        XCTAssertTrue(try verify(identitySig, over: message, publicKey: try keys.identityPublicKey()))
        XCTAssertTrue(try verify(presenceSig, over: message, publicKey: try keys.presencePublicKey()))
        XCTAssertFalse(try verify(identitySig, over: Data("other".utf8), publicKey: try keys.identityPublicKey()))
        XCTAssertFalse(try verify(identitySig, over: message, publicKey: try keys.presencePublicKey()))
    }

    func testKeysPersistAcrossInstances() throws {
        let store = MeshMemorySecretStore()
        let defaults = defaults()
        let first = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
        let second = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
        XCTAssertEqual(try first.identityPublicKey(), try second.identityPublicKey())
        XCTAssertEqual(try first.presencePublicKey(), try second.presencePublicKey())
        XCTAssertFalse(second.wasRestored)
    }

    func testSoftwareFallbackReportsNotHardwareBacked() throws {
        let keys = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults(), preferHardware: false)
        XCTAssertFalse(keys.hardwareBacked)
    }

    func testHardwareReportingMatchesWhatWasCreated() throws {
        let keys = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults(), preferHardware: true)
        if keys.hardwareBacked {
            XCTAssertTrue(SecureEnclave.isAvailable)
        }
        XCTAssertEqual(try keys.identityPublicKey().count, 65)
    }

    func testFirstRunIsNotARestore() throws {
        let keys = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults(), preferHardware: false)
        XCTAssertFalse(keys.wasRestored)
    }

    func testRestoredBackupGetsNewKeysAndReportsRestoreUntilAcknowledged() throws {
        let defaults = defaults()
        let original = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults, preferHardware: false)
        let originalPublic = try original.identityPublicKey()
        let freshStore = MeshMemorySecretStore()
        let restored = try DeviceKeys(store: freshStore, defaults: defaults, preferHardware: false)
        XCTAssertTrue(restored.wasRestored)
        XCTAssertNotEqual(try restored.identityPublicKey(), originalPublic)
        let again = try DeviceKeys(store: freshStore, defaults: defaults, preferHardware: false)
        XCTAssertTrue(again.wasRestored)
        again.acknowledgeRestore()
        XCTAssertFalse(again.wasRestored)
        let after = try DeviceKeys(store: freshStore, defaults: defaults, preferHardware: false)
        XCTAssertFalse(after.wasRestored)
        XCTAssertEqual(try after.identityPublicKey(), try restored.identityPublicKey())
    }

    func testClearedDefaultsAreNotMistakenForARestore() throws {
        let store = MeshMemorySecretStore()
        let first = try DeviceKeys(store: store, defaults: defaults(), preferHardware: false)
        let second = try DeviceKeys(store: store, defaults: defaults(), preferHardware: false)
        XCTAssertFalse(second.wasRestored)
        XCTAssertEqual(try first.identityPublicKey(), try second.identityPublicKey())
    }

    func testCorruptStoredKeyFailsClosed() throws {
        let store = MeshMemorySecretStore()
        try store.save(Data([0x09, 0x01]), account: "identity-key")
        XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults(), preferHardware: false)) {
            XCTAssertEqual($0 as? DeviceKeysError, .corruptKey)
        }
    }

    func testKeychainStoreRoundTrip() throws {
        let service = "com.personalailabs.astraldeep.mesh-device.test.\(UUID().uuidString)"
        let store = MeshKeychainStore(service: service)
        defer { try? store.remove("a") }
        do {
            let existing = try store.load("a")
            XCTAssertNil(existing)
        } catch MeshSecretStoreError.keychain(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain needs a signed host; unsigned simulator test builds have none")
        }
        try store.save(Data([1, 2, 3]), account: "a")
        XCTAssertEqual(try store.load("a"), Data([1, 2, 3]))
        try store.save(Data([4]), account: "a")
        XCTAssertEqual(try store.load("a"), Data([4]))
        try store.remove("a")
        XCTAssertNil(try store.load("a"))
    }
}
