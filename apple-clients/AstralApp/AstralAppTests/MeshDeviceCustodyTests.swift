// Verifies device-only operations and wrapping key custody, persistence, and fail-closed recovery using isolated stores.

@testable import AstralDeep
import AstralKernel
import CryptoKit
import XCTest

nonisolated private final class FailingCustodyStore: MeshSecretStore, @unchecked Sendable {
    let memory = MeshMemorySecretStore()
    var deniedSave: String?
    var deniedSaveOccurrence: Int?
    var deniedLoad: String?
    var deniedRemove: String?
    private var saves: [String: Int] = [:]

    func load(_ account: String) throws -> Data? {
        if account == deniedLoad { throw MeshSecretStoreError.keychain(errSecInteractionNotAllowed) }
        return try memory.load(account)
    }

    func save(_ value: Data, account: String) throws {
        saves[account, default: 0] += 1
        if account == deniedSave, deniedSaveOccurrence == nil || saves[account] == deniedSaveOccurrence {
            throw MeshSecretStoreError.keychain(errSecInteractionNotAllowed)
        }
        try memory.save(value, account: account)
    }

    func remove(_ account: String) throws {
        if account == deniedRemove { throw MeshSecretStoreError.keychain(errSecInteractionNotAllowed) }
        try memory.remove(account)
    }
}

final class MeshDeviceCustodyTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let suite = "MeshDeviceCustodyTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func hex(_ value: String) -> Data {
        Data(
            stride(from: 0, to: value.count, by: 2).map {
                let start = value.index(value.startIndex, offsetBy: $0)
                return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
            })
    }

    private func base64URL(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func testInitializationPersistsBothCurve25519Secrets() throws {
        let store = MeshMemorySecretStore()
        _ = try DeviceKeys(store: store, defaults: defaults(), preferHardware: false)
        XCTAssertEqual(try store.load("operations-key")?.count, 32)
        XCTAssertEqual(try store.load("wrap-key")?.count, 32)
    }

    func testMalformedCurve25519SecretsRefuseInitializationWithoutReplacement() throws {
        for account in ["operations-key", "wrap-key"] {
            for size in [0, 1, 31, 33, 64] {
                let store = MeshMemorySecretStore()
                let defaults = defaults()
                _ = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
                let damaged = Data(repeating: 0x42, count: size)
                try store.save(damaged, account: account)
                XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false)) {
                    XCTAssertEqual($0 as? DeviceKeysError, .corruptKey)
                }
                XCTAssertTrue(try store.load(account) == damaged)
            }
        }
    }

    func testCompletedInstallationRefusesEveryMissingKeyWithoutRotatingOthers() throws {
        let accounts = ["identity-key", "presence-key", "operations-key", "wrap-key"]
        for missing in accounts {
            let store = MeshMemorySecretStore()
            let defaults = defaults()
            _ = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
            let original = try accounts.map { try store.load($0) }
            try store.remove(missing)
            XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false)) {
                XCTAssertEqual($0 as? DeviceKeysError, .corruptKey)
            }
            XCTAssertNil(try store.load(missing))
            for (index, account) in accounts.enumerated() where account != missing {
                XCTAssertTrue(try store.load(account) == original[index])
            }
        }
    }

    func testFailedSaveResumesInitializationWithoutReplacingStoredKeys() throws {
        let accounts = ["identity-key", "presence-key", "operations-key", "wrap-key"]
        for denied in ["install-marker", "local-keys-state"] + accounts {
            let store = FailingCustodyStore()
            let defaults = defaults()
            store.deniedSave = denied
            XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false)) {
                XCTAssertEqual($0 as? MeshSecretStoreError, .keychain(errSecInteractionNotAllowed))
            }
            let original = try accounts.map { try store.memory.load($0) }
            store.deniedSave = nil
            _ = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
            for (index, account) in accounts.enumerated() {
                let saved = try store.memory.load(account)
                XCTAssertNotNil(saved)
                if let retained = original[index] { XCTAssertTrue(saved == retained) }
            }
        }
    }

    func testLostCustodyStateWithStrayKeysRefusesLegacyUpgrade() throws {
        for removed in [nil, "operations-key", "wrap-key"] as [String?] {
            let store = MeshMemorySecretStore()
            let defaults = defaults()
            _ = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
            try store.remove("local-keys-state")
            if let removed { try store.remove(removed) }
            XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false)) {
                XCTAssertEqual($0 as? DeviceKeysError, .corruptKey)
            }
        }
    }

    func testLegacyUpgradePreservesBothP256Keys() throws {
        let store = MeshMemorySecretStore()
        let defaults = defaults()
        let first = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
        let identity = try first.identityPublicKey()
        let presence = try first.presencePublicKey()
        for account in ["operations-key", "wrap-key", "local-keys-state"] { try store.remove(account) }
        let upgraded = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
        XCTAssertEqual(try upgraded.identityPublicKey(), identity)
        XCTAssertEqual(try upgraded.presencePublicKey(), presence)
        XCTAssertEqual(try store.load("operations-key")?.count, 32)
        XCTAssertEqual(try store.load("wrap-key")?.count, 32)
        XCTAssertFalse(upgraded.wasRestored)
    }

    func testLegacyInstallRefusesMissingP256KeysWithoutReplacingRemainingKeys() throws {
        for missing in [["identity-key"], ["presence-key"], ["identity-key", "presence-key"]] {
            let store = MeshMemorySecretStore()
            let defaults = defaults()
            _ = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
            for account in ["operations-key", "wrap-key", "local-keys-state"] + missing { try store.remove(account) }
            let accounts = [
                "identity-key", "presence-key", "operations-key", "wrap-key", "install-marker", "local-keys-state",
            ]
            let retained = try accounts.map { try store.load($0) }
            XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false)) {
                XCTAssertEqual($0 as? DeviceKeysError, .corruptKey)
            }
            for (index, account) in accounts.enumerated() { XCTAssertTrue(try store.load(account) == retained[index]) }
        }
    }

    func testMarkerlessLegacyKeysWithoutRecordedDefaultsRefuseWithoutMutation() throws {
        for retained in [["identity-key"], ["presence-key"], ["identity-key", "presence-key"]] {
            let store = MeshMemorySecretStore()
            _ = try DeviceKeys(store: store, defaults: defaults(), preferHardware: false)
            let accounts = [
                "identity-key", "presence-key", "operations-key", "wrap-key", "install-marker", "local-keys-state",
            ]
            for account in accounts where !retained.contains(account) { try store.remove(account) }
            let original = try accounts.map { try store.load($0) }
            XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults(), preferHardware: false)) {
                XCTAssertEqual($0 as? DeviceKeysError, .corruptKey)
            }
            for (index, account) in accounts.enumerated() { XCTAssertTrue(try store.load(account) == original[index]) }
        }
    }

    func testMarkerlessReadyOrMalformedStateRefusesWithoutMutation() throws {
        let marker = Data(UUID().uuidString.utf8)
        for state in [Data([2]) + marker, Data(), Data([0xFF]), Data([1]) + Data("invalid".utf8)] {
            let store = MeshMemorySecretStore()
            let defaults = defaults()
            try store.save(state, account: "local-keys-state")
            XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false)) {
                XCTAssertEqual($0 as? DeviceKeysError, .corruptKey)
            }
            XCTAssertEqual(try store.load("local-keys-state"), state)
            for account in ["identity-key", "presence-key", "operations-key", "wrap-key", "install-marker"] {
                XCTAssertNil(try store.load(account))
            }
            XCTAssertNil(defaults.string(forKey: "\(MeshKeychainStore.defaultService).install-id"))
        }
    }

    func testRestoreReplacesAllKeysAndRemainsPendingAcrossFailedInitialization() throws {
        let accounts = ["identity-key", "presence-key", "operations-key", "wrap-key"]
        let store = FailingCustodyStore()
        let defaults = defaults()
        _ = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
        let original = try accounts.map { try store.load($0) }
        try store.remove("install-marker")
        store.deniedSave = "wrap-key"
        XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false))
        let partial = try accounts.map { try store.load($0) }
        store.deniedSave = nil
        let restored = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
        XCTAssertTrue(restored.wasRestored)
        for (index, account) in accounts.enumerated() {
            let saved = try store.load(account)
            XCTAssertTrue(saved != original[index])
            if let retained = partial[index] { XCTAssertTrue(saved == retained) }
        }
        let reopened = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
        XCTAssertTrue(reopened.wasRestored)
        reopened.acknowledgeRestore()
        XCTAssertFalse(try DeviceKeys(store: store, defaults: defaults, preferHardware: false).wasRestored)
    }

    func testCurvePublicKeysMatchNormativeAliceVector() throws {
        let store = MeshMemorySecretStore()
        let keys = try DeviceKeys(store: store, defaults: defaults(), preferHardware: false)
        let operations = hex("37a6db180b13765d86ecf35cb5ed52d2a4aa7fb3ece91194f61e7f645e82c3c6")
        let wrap = hex("934e3161ec9672a79552d2db56e2ac25fa5377388f3eb0ea915c9df63ba3a676")
        try store.save(operations, account: "operations-key")
        try store.save(wrap, account: "wrap-key")
        XCTAssertTrue(try keys.operationsSecret() == operations)
        XCTAssertTrue(try keys.wrapSecret() == wrap)
        XCTAssertEqual(base64URL(try keys.operationsPublicKey()), "A-bOg5JENH2roJm7U8gSOC3gdfyOewgcxMLOj2EGuFQ")
        XCTAssertEqual(base64URL(try keys.wrapPublicKey()), "LXXo9gVNFVgFIgpdAegbV-UESe0qFOG1SoskAf9-Pw8")
        XCTAssertFalse(keys.hardwareBacked)
    }

    func testGeneratedOperationsPublicKeyMatchesRustKernel() throws {
        let keys = try DeviceKeys(store: MeshMemorySecretStore(), defaults: defaults(), preferHardware: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kernel = try KernelService(dataDirectory: directory, localOnly: true)
        XCTAssertEqual(
            base64URL(try keys.operationsPublicKey()),
            try kernel.operationsPublicKey(secret: keys.operationsSecret()))
    }

    func testAllLocalKeysAndMarkerSurviveOrdinaryReopenAndClearedDefaults() throws {
        let store = MeshMemorySecretStore()
        let recorded = defaults()
        let first = try DeviceKeys(store: store, defaults: recorded, preferHardware: false)
        let operations = try first.operationsSecret()
        let wrap = try first.wrapSecret()
        let marker = try first.installMarker()
        XCTAssertEqual(operations.count, 32)
        XCTAssertEqual(wrap.count, 32)
        XCTAssertTrue(operations != wrap)
        XCTAssertEqual(try first.operationsPublicKey().count, 32)
        XCTAssertEqual(try first.wrapPublicKey().count, 32)
        XCTAssertEqual(try store.load("install-marker"), marker)
        for reopenedDefaults in [recorded, defaults()] {
            let reopened = try DeviceKeys(store: store, defaults: reopenedDefaults, preferHardware: false)
            XCTAssertTrue(try reopened.operationsSecret() == operations)
            XCTAssertTrue(try reopened.wrapSecret() == wrap)
            XCTAssertEqual(try reopened.operationsPublicKey(), try first.operationsPublicKey())
            XCTAssertEqual(try reopened.wrapPublicKey(), try first.wrapPublicKey())
            XCTAssertEqual(try reopened.installMarker(), marker)
            XCTAssertFalse(reopened.wasRestored)
        }
        for value in recorded.dictionaryRepresentation().values {
            XCTAssertFalse(value as? Data == operations)
            XCTAssertFalse(value as? Data == wrap)
            XCTAssertFalse(value as? String == base64URL(operations))
            XCTAssertFalse(value as? String == base64URL(wrap))
        }
    }

    func testFailedReadyWriteRetainsAllKeysForRetry() throws {
        let store = FailingCustodyStore()
        let defaults = defaults()
        store.deniedSave = "local-keys-state"
        store.deniedSaveOccurrence = 2
        XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false)) {
            XCTAssertEqual($0 as? MeshSecretStoreError, .keychain(errSecInteractionNotAllowed))
        }
        let accounts = ["identity-key", "presence-key", "operations-key", "wrap-key", "install-marker"]
        let original = try accounts.map { try XCTUnwrap(store.load($0)) }
        store.deniedSave = nil
        let reopened = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
        XCTAssertFalse(reopened.wasRestored)
        for (index, account) in accounts.enumerated() { XCTAssertTrue(try store.load(account) == original[index]) }
        XCTAssertEqual(try reopened.installMarker(), original.last)
    }

    func testReadAPIsRefuseMissingOrMalformedSecretsAfterInitialization() throws {
        for account in ["operations-key", "wrap-key"] {
            for damaged in [nil, Data(), Data(repeating: 1, count: 31), Data(repeating: 1, count: 33)] as [Data?] {
                let store = MeshMemorySecretStore()
                let keys = try DeviceKeys(store: store, defaults: defaults(), preferHardware: false)
                if let damaged { try store.save(damaged, account: account) } else { try store.remove(account) }
                let reads =
                    account == "operations-key"
                    ? [keys.operationsSecret, keys.operationsPublicKey] : [keys.wrapSecret, keys.wrapPublicKey]
                for read in reads {
                    XCTAssertThrowsError(try read()) { XCTAssertEqual($0 as? DeviceKeysError, .corruptKey) }
                }
            }
        }
    }

    func testMissingMarkerAndDamagedCustodyStateRefuseHostReads() throws {
        for account in ["install-marker", "local-keys-state"] {
            for damaged in [nil, Data(), Data([0xFF]), Data(UUID().uuidString.utf8)] as [Data?] {
                let store = MeshMemorySecretStore()
                let keys = try DeviceKeys(store: store, defaults: defaults(), preferHardware: false)
                if let damaged { try store.save(damaged, account: account) } else { try store.remove(account) }
                for read in [keys.installMarker, keys.operationsSecret, keys.wrapSecret] {
                    XCTAssertThrowsError(try read()) { XCTAssertEqual($0 as? DeviceKeysError, .corruptKey) }
                }
            }
        }
    }

    func testStoreReadDenialPropagatesWithoutRegeneratingSecrets() throws {
        let store = FailingCustodyStore()
        let defaults = defaults()
        let keys = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
        let original = try keys.operationsSecret()
        store.deniedLoad = "operations-key"
        XCTAssertThrowsError(try keys.operationsSecret()) {
            XCTAssertEqual($0 as? MeshSecretStoreError, .keychain(errSecInteractionNotAllowed))
        }
        XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false)) {
            XCTAssertEqual($0 as? MeshSecretStoreError, .keychain(errSecInteractionNotAllowed))
        }
        store.deniedLoad = nil
        XCTAssertTrue(try keys.operationsSecret() == original)
    }

    func testRestoreDeletionFailureRetainsPendingStateUntilExplicitAcknowledgment() throws {
        let service = "custody-remove-failure"
        let store = FailingCustodyStore()
        let defaults = defaults()
        _ = try DeviceKeys(service: service, store: store, defaults: defaults, preferHardware: false)
        try store.remove("install-marker")
        store.deniedRemove = "operations-key"
        XCTAssertThrowsError(try DeviceKeys(service: service, store: store, defaults: defaults, preferHardware: false))
        {
            XCTAssertEqual($0 as? MeshSecretStoreError, .keychain(errSecInteractionNotAllowed))
        }
        XCTAssertTrue(defaults.bool(forKey: "\(service).restore-pending"))
        store.deniedRemove = nil
        let restored = try DeviceKeys(service: service, store: store, defaults: defaults, preferHardware: false)
        XCTAssertTrue(restored.wasRestored)
        XCTAssertEqual(try restored.operationsSecret().count, 32)
        XCTAssertEqual(try restored.wrapSecret().count, 32)
    }

    func testServicesKeepMarkersAndRestoreStateIsolated() throws {
        let defaults = defaults()
        let firstStore = MeshMemorySecretStore()
        let otherStore = MeshMemorySecretStore()
        let first = try DeviceKeys(service: "first", store: firstStore, defaults: defaults, preferHardware: false)
        let other = try DeviceKeys(service: "other", store: otherStore, defaults: defaults, preferHardware: false)
        let otherOperations = try other.operationsSecret()
        XCTAssertNotEqual(try first.installMarker(), try other.installMarker())
        XCTAssertNotEqual(try first.operationsPublicKey(), try other.operationsPublicKey())
        try firstStore.remove("install-marker")
        let restored = try DeviceKeys(service: "first", store: firstStore, defaults: defaults, preferHardware: false)
        let reopened = try DeviceKeys(service: "other", store: otherStore, defaults: defaults, preferHardware: false)
        XCTAssertTrue(restored.wasRestored)
        XCTAssertFalse(reopened.wasRestored)
        XCTAssertTrue(try reopened.operationsSecret() == otherOperations)
        XCTAssertEqual(try reopened.installMarker(), try other.installMarker())
    }

    func testMalformedTaggedP256KeysRefuseInitialization() throws {
        for account in ["identity-key", "presence-key"] {
            let store = MeshMemorySecretStore()
            let defaults = defaults()
            _ = try DeviceKeys(store: store, defaults: defaults, preferHardware: false)
            let damaged = Data([2, 0])
            try store.save(damaged, account: account)
            XCTAssertThrowsError(try DeviceKeys(store: store, defaults: defaults, preferHardware: false)) {
                XCTAssertEqual($0 as? DeviceKeysError, .corruptKey)
            }
            XCTAssertTrue(try store.load(account) == damaged)
        }
    }
}
