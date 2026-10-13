// Account-and-server-scoped Ed25519 custody and possession-bound mesh enrollment for Apple clients.
// AppModel supplies current owner/navigation fences; the host validates approval and attenuated IAM.

import CryptoKit
import Foundation
import Security

public enum MeshEnrollmentError: Error { case invalid, unavailable, retired, storage }

public struct MeshEnrollmentScope: Equatable, Sendable {
    public let server: URL
    public let account: ConversationAccount
    public let storageKey: String

    public init(server: URL, account: ConversationAccount) throws {
        guard var parts = URLComponents(url: server, resolvingAgainstBaseURL: false),
            parts.scheme == "https", let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            ["", "/"].contains(parts.percentEncodedPath), (parts.port ?? 443) > 0,
            (parts.port ?? 443) <= 65535
        else { throw MeshEnrollmentError.invalid }
        parts.host = host.lowercased()
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let origin = parts.url else { throw MeshEnrollmentError.invalid }
        self.server = origin
        self.account = account
        storageKey = SHA256.hash(
            data: Data([origin.absoluteString, account.issuer, account.subject].joined(separator: "\0").utf8)
        )
        .map { String(format: "%02x", $0) }.joined()
    }
}

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
    private let service: String
    public init(service: String = "com.personalailabs.astraldeep.mesh") { self.service = service }

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
        guard status == errSecSuccess, let data = result as? Data else { throw MeshEnrollmentError.storage }
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
        guard status == errSecItemNotFound else { throw MeshEnrollmentError.storage }
        guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
        else { throw MeshEnrollmentError.storage }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MeshEnrollmentError.storage }
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
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw MeshEnrollmentError.storage }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { throw MeshEnrollmentError.storage }
            if account != key { try remove(account) }
        }
    }
}

@MainActor public final class MeshEnrollmentCustody {
    public let scope: MeshEnrollmentScope
    private let storage: any MeshKeyStorage
    private struct Record: Codable {
        var seed: Data
        var memberID: String?
    }

    public init(scope: MeshEnrollmentScope, storage: any MeshKeyStorage) {
        self.scope = scope
        self.storage = storage
    }

    private func record(create: Bool, current: () -> Bool) throws -> Record {
        guard current() else { throw MeshEnrollmentError.retired }
        try storage.retainOnly(scope.storageKey)
        if let data = try storage.load(scope.storageKey) {
            guard data.count <= 2048, let value = try? JSONDecoder().decode(Record.self, from: data),
                value.seed.count == 32
            else { throw MeshEnrollmentError.storage }
            return value
        }
        guard create else { throw MeshEnrollmentError.invalid }
        let value = Record(seed: Curve25519.Signing.PrivateKey().rawRepresentation)
        guard current() else { throw MeshEnrollmentError.retired }
        try storage.save(JSONEncoder().encode(value), key: scope.storageKey)
        return value
    }

    private func jwk(_ record: Record) throws -> JSONValue {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: record.seed)
        return .object([
            "kty": .string("OKP"), "crv": .string("Ed25519"),
            "x": .string(Self.encode(key.publicKey.rawRepresentation)),
        ])
    }

    public func publicIdentity(current: () -> Bool) throws -> JSONValue {
        try jwk(record(create: true, current: current))
    }

    nonisolated public static func validatePublicIdentity(_ identity: JSONValue) throws {
        guard Set(identity.objectValue?.keys.map { $0 } ?? []) == ["kty", "crv", "x"],
            identity["kty"] == .string("OKP"), identity["crv"] == .string("Ed25519"),
            let raw = identity["x"]?.stringValue, try decode(raw).count == 32
        else { throw MeshEnrollmentError.invalid }
    }

    public func retire() throws { try storage.remove(scope.storageKey) }

    public func redeem(
        link: String, current: () -> Bool,
        transport: (URLRequest) async throws -> JSONValue = MeshEnrollmentHTTP.request
    ) async throws -> String {
        let record = try record(create: false, current: current)
        let publicKey = try jwk(record)
        guard link.utf8.count <= 8192, let parts = URLComponents(string: link),
            parts.user == nil, parts.password == nil, parts.query == nil, parts.percentEncodedPath == "/enroll",
            let payload = parts.percentEncodedFragment, payload == parts.fragment,
            let url = parts.url,
            try MeshEnrollmentScope(server: url.deletingLastPathComponent().removingFragment, account: scope.account)
                == scope
        else { throw MeshEnrollmentError.invalid }
        let bytes = try Self.decode(payload)
        guard let object = try JSONValue.parse(bytes).objectValue,
            Set(object.keys) == ["v", "o", "i", "t", "c"], object["v"] == .number(1),
            object["o"]?.stringValue == scope.account.subject,
            let invite = object["i"]?.stringValue,
            invite.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
            let token = object["t"]?.stringValue, try Self.decode(token).count == 32,
            let challenge = object["c"]?.stringValue, try Self.decode(challenge).count == 32,
            Self.flatKeyCount(bytes) == 5
        else { throw MeshEnrollmentError.invalid }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: record.seed)
        let signature = try privateKey.signature(for: Self.decode(challenge))
        let body: JSONValue = .object(["payload": .string(payload), "signature": .string(Self.encode(signature))])
        guard current() else { throw MeshEnrollmentError.retired }
        let reply = try await transport(request(path: "/api/mesh/enrollment/redeem", body: body))
        guard current(), reply["token_type"]?.stringValue == "DPoP",
            let access = reply["access_token"]?.stringValue, !access.isEmpty, access.count <= 16384,
            let expires = reply["expires_in"]?.numberValue, expires > 0,
            let member = reply["member"], let memberID = validatedMember(member, key: publicKey)
        else { throw MeshEnrollmentError.invalid }
        let nonceReply = try await transport(
            request(
                path: "/api/mesh/nonce",
                body: .object([
                    "owner_id": .string(scope.account.subject), "member_id": .string(memberID),
                ])))
        guard current(), let nonce = nonceReply["nonce"]?.stringValue, (1...256).contains(nonce.count)
        else { throw MeshEnrollmentError.retired }
        let target = scope.server.appendingPathComponent("api/mesh/me")
        let header: JSONValue = .object(["typ": .string("dpop+jwt"), "alg": .string("EdDSA"), "jwk": publicKey])
        let proofPayload: JSONValue = .object([
            "jti": .string(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")),
            "htm": .string("GET"), "htu": .string(target.absoluteString),
            "iat": .number(Double(Int(Date().timeIntervalSince1970))), "nonce": .string(nonce),
            "ath": .string(Self.encode(Data(SHA256.hash(data: Data(access.utf8))))),
        ])
        let signing = Self.encode(try header.encoded()) + "." + Self.encode(try proofPayload.encoded())
        let proof = signing + "." + Self.encode(try privateKey.signature(for: Data(signing.utf8)))
        var verify = try request(path: "/api/mesh/me", body: nil)
        verify.setValue("DPoP " + access, forHTTPHeaderField: "Authorization")
        verify.setValue(proof, forHTTPHeaderField: "DPoP")
        verify.setValue(nonce, forHTTPHeaderField: "DPoP-Nonce")
        guard current() else { throw MeshEnrollmentError.retired }
        let verified = try await transport(verify)
        guard current(), validatedMember(verified["member"] ?? .null, key: publicKey) == memberID
        else { throw MeshEnrollmentError.invalid }
        var saved = record
        saved.memberID = memberID
        try storage.save(JSONEncoder().encode(saved), key: scope.storageKey)
        return memberID
    }

    private func validatedMember(_ member: JSONValue, key: JSONValue) -> String? {
        guard member["owner_id"]?.stringValue == scope.account.subject, member["device_key"] == key,
            member["status"]?.stringValue == "active", let id = member["member_id"]?.stringValue,
            id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
        else { return nil }
        return id
    }

    private func request(path: String, body: JSONValue?) throws -> URLRequest {
        NoStoreHTTP.request(
            url: scope.server.appendingPathComponent(String(path.dropFirst())),
            method: body == nil ? "GET" : "POST", body: try body?.encoded(), contentType: "application/json")
    }

    private static func flatKeyCount(_ data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8),
            let regex = try? NSRegularExpression(pattern: #"(?:^\s*\{|,)\s*\"(?:[^\"\\]|\\.)*\"\s*:"#)
        else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    nonisolated private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty, value.count <= 8192,
            value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
            let data = Data(
                base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    + String(repeating: "=", count: (4 - value.count % 4) % 4)), encode(data) == value
        else { throw MeshEnrollmentError.invalid }
        return data
    }
}

extension URL {
    fileprivate var removingFragment: URL {
        var parts = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        parts.fragment = nil
        return parts.url!
    }
}

public final class MeshEnrollmentHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static func request(_ request: URLRequest) async throws -> JSONValue {
        let delegate = MeshEnrollmentHTTP()
        let session = URLSession(configuration: NoStoreHTTP.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.url == request.url, response.mimeType == "application/json",
            response.expectedContentLength <= 32768,
            response.value(forHTTPHeaderField: "Set-Cookie") == nil
        else { throw MeshEnrollmentError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 32768 else { throw MeshEnrollmentError.invalid }
            data.append(byte)
        }
        return try JSONValue.parse(data)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
