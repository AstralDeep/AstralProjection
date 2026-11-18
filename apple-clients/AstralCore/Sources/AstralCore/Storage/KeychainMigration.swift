// Moves each store's legacy file-based Keychain items into the data-protection Keychain once per service on macOS.
// The Keychain-backed stores call it before their first access, and nothing queries the legacy Keychain after.

import Foundation
import Security

public enum KeychainAccessibility: Sendable { case whenUnlocked, afterFirstUnlock }

public struct KeychainBackendError: Error, Equatable, Sendable {
    public let status: Int32
    public init(status: Int32) { self.status = status }
}

public struct KeychainMigrationError: Error, Equatable, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
}

public protocol KeychainBackend: Sendable {
    func accounts(service: String) throws -> [String]
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, value: Data, accessibility: KeychainAccessibility) throws
    func delete(service: String, account: String) throws
}

public protocol KeychainMigrationMarker: Sendable {
    func isMigrated(_ service: String) -> Bool
    func markMigrated(_ service: String)
}

public struct DefaultsKeychainMigrationMarker: KeychainMigrationMarker, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ service: String) -> String { service + ".protected-keychain-migrated" }
    public func isMigrated(_ service: String) -> Bool { defaults.bool(forKey: key(service)) }
    public func markMigrated(_ service: String) { defaults.set(true, forKey: key(service)) }
}

public final class LegacyKeychainMigrator: @unchecked Sendable {
    private let legacy: KeychainBackend
    private let protected: KeychainBackend
    private let marker: KeychainMigrationMarker
    private let lock = NSLock()
    private var finished: Set<String> = []

    public init(legacy: KeychainBackend, protected: KeychainBackend, marker: KeychainMigrationMarker) {
        self.legacy = legacy
        self.protected = protected
        self.marker = marker
    }

    public func ensureMigrated(service: String, accessibility: KeychainAccessibility) throws {
        lock.lock()
        defer { lock.unlock() }
        if finished.contains(service) { return }
        if marker.isMigrated(service) {
            finished.insert(service)
            return
        }
        let accounts = try step("enumerate") { try legacy.accounts(service: service) }
        for account in accounts { try move(service: service, account: account, accessibility: accessibility) }
        marker.markMigrated(service)
        finished.insert(service)
    }

    private func move(service: String, account: String, accessibility: KeychainAccessibility) throws {
        guard let value = try step("read", { try legacy.read(service: service, account: account) }) else { return }
        let existing = try step("check") { try protected.read(service: service, account: account) }
        if existing == nil {
            try step("write") {
                try protected.write(service: service, account: account, value: value, accessibility: accessibility)
            }
            let copy = try step("verify") { try protected.read(service: service, account: account) }
            guard copy == value else { throw KeychainMigrationError(code: "verify") }
        }
        try step("delete") { try legacy.delete(service: service, account: account) }
    }

    private func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as KeychainBackendError {
            throw KeychainMigrationError(code: "\(name)-\(error.status)")
        } catch {
            throw KeychainMigrationError(code: name)
        }
    }
}

#if os(macOS)
    public struct SecItemKeychainBackend: KeychainBackend {
        private let dataProtection: Bool
        public init(dataProtection: Bool) { self.dataProtection = dataProtection }

        private func query(_ service: String, _ account: String?) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            if let account { query[kSecAttrAccount as String] = account }
            if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
            return query
        }

        public func accounts(service: String) throws -> [String] {
            var query = query(service, nil)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess, let items = result as? [[String: Any]] else {
                throw KeychainBackendError(status: status)
            }
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        }

        public func read(service: String, account: String) throws -> Data? {
            var query = query(service, account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainBackendError(status: status) }
            return result as? Data
        }

        public func write(service: String, account: String, value: Data, accessibility: KeychainAccessibility) throws {
            var add = query(service, account)
            add[kSecValueData as String] = value
            switch accessibility {
            case .whenUnlocked: add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .afterFirstUnlock: add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainBackendError(status: status) }
        }

        public func delete(service: String, account: String) throws {
            let status = SecItemDelete(query(service, account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainBackendError(status: status)
            }
        }
    }

    extension LegacyKeychainMigrator {
        public static let shared = LegacyKeychainMigrator(
            legacy: SecItemKeychainBackend(dataProtection: false),
            protected: SecItemKeychainBackend(dataProtection: true),
            marker: DefaultsKeychainMigrationMarker())
    }
#endif
