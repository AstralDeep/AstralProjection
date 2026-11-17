// Verifies the connection Keychain store: item attributes, strict error mapping, empty-value refusal, and its isolation from the mesh device items.
// Tests that reach the real Keychain skip on a host without Keychain entitlement.

import AstralCore
import AstralKernel
import Security
import XCTest

@testable import AstralDeep

final class ConnectionKeychainTests: XCTestCase {
    private let id = String(repeating: "ab", count: 16)

    private func account(_ id: String, issuer: String) -> String {
        "astral.connection/v1/" + id + "/" + String(repeating: issuer, count: 64)
    }

    private func live() throws -> (ConnectionKeychain, String) {
        let service = "com.personalailabs.astraldeep.connection-credentials.test." + UUID().uuidString
        let store = ConnectionKeychain(service: service)
        do { _ = try store.get(account: "probe") } catch HostKeystoreError.Failed(let message)
            where message.contains(String(errSecMissingEntitlement))
        {
            throw XCTSkip("Keychain needs a signed host; unsigned test builds have none")
        }
        addTeardownBlock {
            for issuer in ["a", "b"] { try? store.remove(account: self.account(self.id, issuer: issuer)) }
        }
        return (store, service)
    }

    func testNewItemsAreThisDeviceOnlyAfterFirstUnlockAndNeverSynchronize() {
        let query = ConnectionKeychain.addQuery(service: "s", account: "a", secret: Data([1]))
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "s")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "a")
        XCTAssertEqual(query[kSecValueData as String] as? Data, Data([1]))
        let lookup = ConnectionKeychain.itemQuery(service: "s", account: "a")
        XCTAssertEqual(lookup[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(lookup[kSecValueData as String])
    }

    func testServiceNameIsBundleScopedAndSeparateFromTheMeshDeviceItems() {
        XCTAssertEqual(ConnectionKeychain.defaultService, KeychainServices.name("connection-credentials-v1"))
        XCTAssertNotEqual(ConnectionKeychain.defaultService, MeshKeychainStore.defaultService)
    }

    func testHostErrorsRefuseAndLockedDevicesReportUnavailable() {
        for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed, errSecUserCanceled] {
            guard case .Unavailable(let message) = ConnectionKeychain.failure(status) else {
                return XCTFail("\(status)")
            }
            XCTAssertEqual(message, "keychain status \(status)")
        }
        for status in [errSecMissingEntitlement, errSecParam, errSecIO, errSecDecode, errSecAllocate] {
            guard case .Failed(let message) = ConnectionKeychain.failure(status) else { return XCTFail("\(status)") }
            XCTAssertEqual(message, "keychain status \(status)")
        }
    }

    func testEmptyValuesAndBadAccountsAreRefusedBeforeTheKeychain() {
        let store = ConnectionKeychain(service: "never.used")
        XCTAssertThrowsError(try store.put(account: "a", secret: Data()))
        XCTAssertThrowsError(try store.put(account: "", secret: Data([1])))
        XCTAssertThrowsError(try store.get(account: ""))
        XCTAssertThrowsError(try store.remove(account: ""))
        let long = String(repeating: "x", count: ConnectionKeychain.maxAccountLength + 1)
        XCTAssertThrowsError(try store.put(account: long, secret: Data([1])))
        XCTAssertThrowsError(try store.get(account: long))
    }

    func testDescriptionsAndErrorsNeverCarryTheSecret() {
        let store = ConnectionKeychain(service: "never.used")
        XCTAssertFalse(String(describing: store).contains("never.used"))
        XCTAssertThrowsError(try store.put(account: "", secret: Data("TOPSECRET".utf8))) {
            XCTAssertFalse(String(describing: $0).contains("TOPSECRET"))
            XCTAssertFalse($0.localizedDescription.contains("TOPSECRET"))
        }
    }

    func testRoundTripReplaceRemoveAndAbsent() throws {
        let (store, _) = try live()
        let name = account(id, issuer: "a")
        XCTAssertNil(try store.get(account: name))
        try store.put(account: name, secret: Data("one".utf8))
        XCTAssertEqual(try store.get(account: name), Data("one".utf8))
        try store.put(account: name, secret: Data("two".utf8))
        XCTAssertEqual(try store.get(account: name), Data("two".utf8))
        try store.remove(account: name)
        XCTAssertNil(try store.get(account: name))
        XCTAssertNoThrow(try store.remove(account: name))
    }

    func testTwoIssuersForOneConnectionDoNotCollide() throws {
        let (store, _) = try live()
        let first = account(id, issuer: "a")
        let second = account(id, issuer: "b")
        try store.put(account: first, secret: Data("first".utf8))
        try store.put(account: second, secret: Data("second".utf8))
        XCTAssertEqual(try store.get(account: first), Data("first".utf8))
        XCTAssertEqual(try store.get(account: second), Data("second".utf8))
        try store.remove(account: first)
        XCTAssertNil(try store.get(account: first))
        XCTAssertEqual(try store.get(account: second), Data("second".utf8))
    }

    func testStoredItemsReadBackAsThisDeviceOnlyAndNotSynchronizable() throws {
        let (store, service) = try live()
        let name = account(id, issuer: "a")
        try store.put(account: name, secret: Data("x".utf8))
        var query = ConnectionKeychain.itemQuery(service: service, account: name)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        #if os(macOS)
            query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let attributes = result as? [String: Any] else {
            throw XCTSkip("The item is in the legacy macOS keychain here (status \(status))")
        }
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let synchronizable = attributes[kSecAttrSynchronizable as String]
        XCTAssertTrue(synchronizable == nil || (synchronizable as? Bool) == false)
    }

    func testConnectionItemsLeaveTheMeshDeviceItemsUnchanged() throws {
        let service = "com.personalailabs.astraldeep.mesh-device-v2.test." + UUID().uuidString
        let mesh = MeshKeychainStore(service: service)
        let accounts = ["identity-key", "presence-key", "install-marker"]
        let before = Dictionary(uniqueKeysWithValues: accounts.map { ($0, Data($0.utf8) + Data([7])) })
        do {
            for (name, value) in before { try mesh.save(value, account: name) }
        } catch MeshSecretStoreError.keychain(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain needs a signed host; unsigned test builds have none")
        }
        addTeardownBlock { for name in accounts { try? mesh.remove(name) } }
        let (connections, _) = try live()
        for name in accounts {
            try connections.put(account: name, secret: Data("other".utf8))
            try connections.remove(account: name)
        }
        for (name, value) in before { XCTAssertEqual(try mesh.load(name), value, name) }
        XCTAssertNil(try connections.get(account: "identity-key"))
    }
}
