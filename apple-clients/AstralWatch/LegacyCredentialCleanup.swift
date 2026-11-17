// Deletes the credential items an earlier watch build stored, on every launch, without reading them or touching the network.
// AstralWatchApp calls it once at start; the watch drift guard allows its one deletion call only in this file.

import Foundation
import Security

struct LegacyCredentialCleanup {
    typealias Deleter = (CFDictionary) -> OSStatus

    static let service = "com.personalailabs.astraldeep.watch"
    static let account = "session"

    static var queries: [[String: Any]] {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let account = item.merging([kSecAttrAccount as String: account]) { $1 }
        let synchronized = [kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        return [account, item, account.merging(synchronized) { $1 }, item.merging(synchronized) { $1 }]
    }

    let delete: Deleter

    init(delete: @escaping Deleter = { SecItemDelete($0) }) {
        self.delete = delete
    }

    @discardableResult
    func run() -> Bool {
        var clean = true
        for query in Self.queries {
            let status = delete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { clean = false }
        }
        return clean
    }
}
