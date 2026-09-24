// Token persistence (Keychain on-device, in-memory for tests) and per-platform refresh strategy: iOS/macOS
// refresh directly against the identity provider, watch refreshes via the backend broker. Backs AppModel and
// most AstralApp test fixtures.

import Foundation

#if canImport(Security)
    import Security
#endif

public protocol TokenStorage: Sendable {
    func load() -> StoredTokens?
    func save(_ tokens: StoredTokens)
    func wipe()
}

public struct StoredTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(from set: TokenSet) {
        self.accessToken = set.accessToken
        self.refreshToken = set.refreshToken
        self.expiresAt = set.expiresAt
    }

    public var tokenSet: TokenSet {
        TokenSet(
            accessToken: accessToken, refreshToken: refreshToken,
            expiresIn: expiresAt.timeIntervalSinceNow)
    }
}

public final class InMemoryTokenStore: TokenStorage, @unchecked Sendable {
    private var tokens: StoredTokens?
    private let lock = NSLock()

    public init() {}

    public func load() -> StoredTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: StoredTokens) {
        lock.lock()
        defer { lock.unlock() }
        self.tokens = tokens
    }

    public func wipe() {
        lock.lock()
        defer { lock.unlock() }
        tokens = nil
    }
}

#if canImport(Security)
    public final class KeychainTokenStore: TokenStorage, @unchecked Sendable {
        private let service: String

        public init(service: String = "com.personalailabs.astraldeep.tokens") {
            self.service = service
        }

        private var query: [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "session",
            ]
        }

        public func load() -> StoredTokens? {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                let data = out as? Data
            else { return nil }
            return try? JSONDecoder().decode(StoredTokens.self, from: data)
        }

        public func save(_ tokens: StoredTokens) {
            guard let data = try? JSONEncoder().encode(tokens) else { return }
            // Delete-then-add — SecItemUpdate can't change existing accessibility
            SecItemDelete(query as CFDictionary)
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }

        public func wipe() {
            SecItemDelete(query as CFDictionary)
        }
    }
#endif

public enum RefreshResult: Sendable {
    case ok(TokenSet)
    case rejected(String)
    case transient(String)
}

public enum RefreshStrategy: Sendable {
    case direct(OIDCConfig)
    case broker(DeviceLoginClient)

    public func refresh(refreshToken: String) async throws -> TokenSet {
        switch self {
        case .direct(let config):
            let request = Self.directRequest(config: config, refreshToken: refreshToken)
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await NoStoreHTTP.session.data(for: request)
            } catch {
                throw DeviceLoginError.transport(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 400 || status == 401 {
                throw DeviceLoginError.rejected("refresh rejected (HTTP \(status))")
            }
            guard status == 200, let json = try? JSONValue.parse(data),
                let tokens = TokenSet(json: json)
            else {
                throw DeviceLoginError.unavailable("refresh failed (HTTP \(status))")
            }
            return tokens
        case .broker(let client):
            return try await client.refresh(refreshToken: refreshToken)
        }
    }

    static func directRequest(config: OIDCConfig, refreshToken: String) -> URLRequest {
        NoStoreHTTP.request(
            url: config.tokenEndpoint,
            method: "POST",
            body: Data(config.refreshRequestBody(refreshToken: refreshToken).utf8),
            contentType: "application/x-www-form-urlencoded")
    }

    public func attempt(refreshToken: String) async -> RefreshResult {
        do {
            var set = try await refresh(refreshToken: refreshToken)
            if set.refreshToken == nil {
                set = TokenSet(
                    accessToken: set.accessToken,
                    refreshToken: refreshToken,
                    expiresIn: set.expiresAt.timeIntervalSinceNow)
            }
            return .ok(set)
        } catch let error as DeviceLoginError {
            switch error {
            case .rejected(let detail):
                return .rejected(detail)
            case .invalidHandle:
                return .rejected("invalid_grant")
            case .unavailable(let detail), .transport(let detail):
                return .transient(detail)
            case .rateLimited:
                return .transient("rate limited")
            }
        } catch {
            return .transient(error.localizedDescription)
        }
    }
}
