// Keeps the one sent-but-unsettled chat message per server and account (Keychain on-device, in-memory for
// tests) so quitting mid-turn does not lose it. AppModel saves it on send, restores it into its own chat on the
// next launch, and clears it when the turn settles, on sign-out, account removal or account change.

import AstralCore
import CryptoKit
import Foundation
import Security

struct UnsentChatMessage: Codable, Sendable, Equatable {
    let chatId: String?
    let requestGeneration: String
    let text: String

    init(chatId: String?, requestGeneration: String, text: String) {
        self.chatId = chatId
        self.requestGeneration = requestGeneration
        self.text = text
    }

    init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data), !decoded.requestGeneration.isEmpty,
            !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            decoded.chatId?.isEmpty != true
        else { return nil }
        self = decoded
    }
}

struct UnsentMessageScope: Equatable, Sendable {
    let storageKey: String

    init(server: URL, account: ConversationAccount) {
        storageKey = SHA256.hash(
            data: Data([server.absoluteString, account.issuer, account.subject].joined(separator: "\0").utf8)
        )
        .map { String(format: "%02x", $0) }.joined()
    }
}

protocol UnsentMessageStorage: Sendable {
    func load(_ scope: UnsentMessageScope) -> UnsentChatMessage?
    func save(_ message: UnsentChatMessage, for scope: UnsentMessageScope)
    func remove(_ scope: UnsentMessageScope)
    func retainOnly(_ scope: UnsentMessageScope?)
}

final class InMemoryUnsentMessageStore: UnsentMessageStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String: UnsentChatMessage] = [:]

    func load(_ scope: UnsentMessageScope) -> UnsentChatMessage? {
        lock.withLock { messages[scope.storageKey] }
    }

    func save(_ message: UnsentChatMessage, for scope: UnsentMessageScope) {
        lock.withLock { messages[scope.storageKey] = message }
    }

    func remove(_ scope: UnsentMessageScope) {
        lock.withLock { _ = messages.removeValue(forKey: scope.storageKey) }
    }

    func retainOnly(_ scope: UnsentMessageScope?) {
        lock.withLock { messages = messages.filter { $0.key == scope?.storageKey } }
    }
}

final class KeychainUnsentMessageStore: UnsentMessageStorage, @unchecked Sendable {
    let service: String

    init(service: String = KeychainServices.name("unsent-message")) {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func load(_ scope: UnsentMessageScope) -> UnsentChatMessage? {
        var lookup = query(scope.storageKey)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &out) == errSecSuccess, let data = out as? Data
        else { return nil }
        return UnsentChatMessage(data: data)
    }

    func save(_ message: UnsentChatMessage, for scope: UnsentMessageScope) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        SecItemDelete(query(scope.storageKey) as CFDictionary)
        var add = query(scope.storageKey)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func remove(_ scope: UnsentMessageScope) {
        SecItemDelete(query(scope.storageKey) as CFDictionary)
    }

    func retainOnly(_ scope: UnsentMessageScope?) {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &out) == errSecSuccess,
            let items = out as? [[String: Any]]
        else { return }
        for item in items {
            guard let key = item[kSecAttrAccount as String] as? String, key != scope?.storageKey else { continue }
            SecItemDelete(query(key) as CFDictionary)
        }
    }
}
