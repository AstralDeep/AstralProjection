// Keeps each connection's OAuth credential in the device Keychain for the kernel, which hands it opaque account names and sealed bytes.
// RealMeshKernel installs it at open; items stay on this device, never sync and never join a backup.

import AstralCore
import AstralKernel
import Foundation
import Security

nonisolated final class ConnectionKeychain: AstralKernel.HostKeystore, CustomStringConvertible, @unchecked Sendable {
    static var defaultService: String { KeychainServices.name("connection-credentials-v1") }
    static let maxAccountLength = 256

    private let service: String

    init(service: String = ConnectionKeychain.defaultService) { self.service = service }

    var description: String { "ConnectionKeychain" }

    func get(account: String) throws -> Data? {
        try Self.check(account)
        var query = Self.itemQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = Self.run(query, absentFallsBack: true) { SecItemCopyMatching($0, &$1) }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                throw HostKeystoreError.Failed(message: "keychain returned no credential bytes")
            }
            return data
        case errSecItemNotFound: return nil
        default: throw Self.failure(status)
        }
    }

    func put(account: String, secret: Data) throws {
        try Self.check(account)
        guard !secret.isEmpty else { throw HostKeystoreError.Failed(message: "an empty credential is refused") }
        let update: [String: Any] = [kSecValueData as String: secret]
        let query = Self.itemQuery(service: service, account: account)
        let (updated, _) = Self.run(query, absentFallsBack: true) { query, _ in
            SecItemUpdate(query, update as CFDictionary)
        }
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Self.failure(updated) }
        let add = Self.addQuery(service: service, account: account, secret: secret)
        let (added, _) = Self.run(add, absentFallsBack: false) { query, _ in SecItemAdd(query, nil) }
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else { throw Self.failure(added) }
        let (retried, _) = Self.run(query, absentFallsBack: true) { query, _ in
            SecItemUpdate(query, update as CFDictionary)
        }
        guard retried == errSecSuccess else { throw Self.failure(retried) }
    }

    func remove(account: String) throws {
        try Self.check(account)
        let query = Self.itemQuery(service: service, account: account)
        let (status, _) = Self.run(query, absentFallsBack: true) { query, _ in SecItemDelete(query) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    static func itemQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func addQuery(service: String, account: String, secret: Data) -> [String: Any] {
        var query = itemQuery(service: service, account: account)
        query[kSecValueData as String] = secret
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    static func failure(_ status: OSStatus) -> HostKeystoreError {
        let text = "keychain status \(status)"
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed, errSecUserCanceled:
            return .Unavailable(message: text)
        default:
            return .Failed(message: text)
        }
    }

    private static func check(_ account: String) throws {
        guard !account.isEmpty, account.utf8.count <= maxAccountLength else {
            throw HostKeystoreError.Failed(message: "the credential account name is not valid")
        }
    }

    #if os(macOS)
        private static func run(
            _ query: [String: Any], absentFallsBack: Bool, _ call: (CFDictionary, inout CFTypeRef?) -> OSStatus
        ) -> (OSStatus, CFTypeRef?) {
            var scoped = query
            scoped[kSecUseDataProtectionKeychain as String] = true
            var result: CFTypeRef?
            let status = call(scoped as CFDictionary, &result)
            guard status == errSecMissingEntitlement || (absentFallsBack && status == errSecItemNotFound) else {
                return (status, result)
            }
            var legacy: CFTypeRef?
            return (call(query as CFDictionary, &legacy), legacy)
        }
    #else
        private static func run(
            _ query: [String: Any], absentFallsBack _: Bool, _ call: (CFDictionary, inout CFTypeRef?) -> OSStatus
        ) -> (OSStatus, CFTypeRef?) {
            var result: CFTypeRef?
            return (call(query as CFDictionary, &result), result)
        }
    #endif
}
