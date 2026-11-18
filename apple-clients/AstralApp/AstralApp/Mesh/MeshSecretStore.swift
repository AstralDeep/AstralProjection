// Device-only secret storage for the mesh keys and the restore marker, backed by the Keychain.
// DeviceKeys reads and writes through the protocol so tests can substitute an in-memory store.

import AstralCore
import Foundation
import Security

nonisolated enum MeshSecretStoreError: Error, Equatable {
    case keychain(OSStatus)
    case migration(String)
}

nonisolated protocol MeshSecretStore: Sendable {
    func load(_ account: String) throws -> Data?
    func save(_ value: Data, account: String) throws
    func remove(_ account: String) throws
}

nonisolated final class MeshKeychainStore: MeshSecretStore, @unchecked Sendable {
    static var defaultService: String { KeychainServices.name("mesh-device-v2") }

    private let service: String

    init(service: String = MeshKeychainStore.defaultService) {
        self.service = service
    }

    func load(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = try run(query) { SecItemCopyMatching($0, &$1) }
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw MeshSecretStoreError.keychain(status)
        }
    }

    func save(_ value: Data, account: String) throws {
        let update: [String: Any] = [kSecValueData as String: value]
        let (updateStatus, _) = try run(baseQuery(account)) { query, _ in
            SecItemUpdate(query, update as CFDictionary)
        }
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw MeshSecretStoreError.keychain(updateStatus) }
        var add = baseQuery(account)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let (addStatus, _) = try run(add) { query, _ in SecItemAdd(query, nil) }
        guard addStatus == errSecSuccess else { throw MeshSecretStoreError.keychain(addStatus) }
    }

    func remove(_ account: String) throws {
        let (status, _) = try run(baseQuery(account)) { query, _ in SecItemDelete(query) }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MeshSecretStoreError.keychain(status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    #if os(macOS)
        private func run(
            _ query: [String: Any], _ call: (CFDictionary, inout CFTypeRef?) -> OSStatus
        ) throws -> (OSStatus, CFTypeRef?) {
            do {
                try LegacyKeychainMigrator.shared.ensureMigrated(service: service, accessibility: .whenUnlocked)
            } catch let error as KeychainMigrationError {
                throw MeshSecretStoreError.migration(error.code)
            }
            var scoped = query
            scoped[kSecUseDataProtectionKeychain as String] = true
            var result: CFTypeRef?
            return (call(scoped as CFDictionary, &result), result)
        }
    #else
        private func run(
            _ query: [String: Any], _ call: (CFDictionary, inout CFTypeRef?) -> OSStatus
        ) throws -> (OSStatus, CFTypeRef?) {
            var result: CFTypeRef?
            return (call(query as CFDictionary, &result), result)
        }
    #endif
}
