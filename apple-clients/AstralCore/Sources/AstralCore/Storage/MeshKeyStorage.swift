// Keychain and in-memory byte storage keyed by account, used by the mesh push coordinator and the push service for their keys.
// Callers choose the service name; nothing here reads or deletes items it was not asked to.

import Foundation
import Security

public enum MeshKeyStorageError: Error { case storage }

public protocol MeshKeyStorage: Sendable {
    func load(_ key: String) throws -> Data?
    func save(_ value: Data, key: String) throws
    func remove(_ key: String) throws
    func retainOnly(_ key: String?) throws
}

public final class InMemoryMeshKeyStorage: MeshKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func load(_ key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
    public func save(_ value: Data, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
    public func remove(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
    public func retainOnly(_ key: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        values = values.filter { $0.key == key }
    }
}

public final class KeychainMeshKeyStorage: MeshKeyStorage, @unchecked Sendable {
    public let service: String
    public init(service: String = KeychainServices.name("mesh")) { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func load(_ key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MeshKeyStorageError.storage }
        return data
    }

    public func save(_ value: Data, key: String) throws {
        let query = query(key)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw MeshKeyStorageError.storage }
        guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
        else { throw MeshKeyStorageError.storage }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MeshKeyStorageError.storage }
    }

    public func retainOnly(_ key: String?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw MeshKeyStorageError.storage }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { throw MeshKeyStorageError.storage }
            if account != key { try remove(account) }
        }
    }
}
