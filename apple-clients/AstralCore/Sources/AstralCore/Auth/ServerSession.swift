// Binds fresh native PKCE grants to protected, exact-server session custody.
// AppModel fences storage and socket publication; refresh and logout retain the server cookie.

import CryptoKit
import Foundation

public enum ServerSessionError: Error { case invalid, unavailable, retired, storage }
public enum ServerSessionLogoutOutcome: Sendable { case revoked, queued, unconfirmed }

public struct ServerSessionScope: Codable, Equatable, Sendable {
    public let server: URL
    public let issuer: String
    public let clientID: String
    public let redirectURI: String
    public var storageKey: String {
        SHA256.hash(data: Data([server.absoluteString, issuer, clientID, redirectURI].joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public init(server: URL, oidc: OIDCConfig) throws {
        guard let issuer = URLComponents(url: oidc.authority, resolvingAgainstBaseURL: false),
            issuer.scheme == "https", issuer.host != nil, issuer.user == nil, issuer.password == nil,
            issuer.query == nil, issuer.fragment == nil, !oidc.authority.absoluteString.hasSuffix("/"),
            ["astral-mobile", "astral-desktop"].contains(oidc.clientId),
            oidc.redirectURI == "com.personalailabs.astraldeep:/oauth2redirect"
        else { throw ServerSessionError.invalid }
        let account = ConversationAccount(issuer: oidc.authority.absoluteString, subject: "scope")!
        self.server = try MeshEnrollmentScope(server: server, account: account).server
        self.issuer = oidc.authority.absoluteString
        clientID = oidc.clientId
        redirectURI = oidc.redirectURI
    }
}

public struct ServerSession: Codable, Equatable, Sendable {
    public let scope: ServerSessionScope
    public let owner: String
    public let accessToken: String
    public let cookie: String
    public let cookieExpiresAt: Date
    public var pushIncarnation: String {
        SHA256.hash(data: Data((scope.storageKey + "\u{0}" + cookie).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public var tokenSet: TokenSet {
        let set = TokenSet(accessToken: accessToken, refreshToken: nil, expiresIn: 0)
        let expiry = min(set.claims?["exp"]?.numberValue ?? 0, cookieExpiresAt.timeIntervalSince1970)
        return TokenSet(accessToken: accessToken, refreshToken: nil, expiresIn: expiry - Date().timeIntervalSince1970)
    }

    public init(scope: ServerSessionScope, owner: String, accessToken: String, cookie: String, cookieExpiresAt: Date)
        throws
    {
        self.scope = scope
        self.owner = owner
        self.accessToken = accessToken
        self.cookie = cookie
        self.cookieExpiresAt = cookieExpiresAt
        try validate(scope: scope)
    }

    public func validate(scope expected: ServerSessionScope, now: Date = Date()) throws {
        guard scope == expected, !owner.isEmpty, owner.utf8.count <= 256, accessToken.utf8.count <= 16384,
            accessToken.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression)
                != nil,
            cookie.range(of: "^astral_session=[A-Za-z0-9._~=-]{1,4096}$", options: .regularExpression) != nil,
            tokenSet.claims?["iss"] == .string(scope.issuer), tokenSet.claims?["sub"] == .string(owner),
            tokenSet.claims?["azp"] == .string(scope.clientID)
        else { throw ServerSessionError.invalid }
        guard cookieExpiresAt > now, let expiry = tokenSet.claims?["exp"]?.numberValue,
            expiry.isFinite, expiry > now.timeIntervalSince1970
        else { throw ServerSessionError.retired }
    }

    public func socketHeaders(url: URL, token: String, now: Date = Date()) throws -> [String: String] {
        try validate(scope: scope, now: now)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "wss",
            parts.percentEncodedPath == "/ws", parts.query == nil, parts.fragment == nil,
            parts.user == nil, parts.password == nil, token == accessToken
        else { throw ServerSessionError.invalid }
        parts.scheme = "https"
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard parts.url == scope.server else { throw ServerSessionError.invalid }
        return ["Cookie": cookie, "Origin": scope.server.absoluteString]
    }
}

public struct ServerSessionReply: Sendable {
    public let body: JSONValue
    public let cookies: [String]
    public init(body: JSONValue, cookies: [String] = []) {
        self.body = body
        self.cookies = cookies
    }
}

public struct ServerSessionTransport: Sendable {
    public let scope: ServerSessionScope
    private let transport: @Sendable (URLRequest) async throws -> ServerSessionReply

    public init(
        scope: ServerSessionScope,
        transport: @escaping @Sendable (URLRequest) async throws -> ServerSessionReply = {
            try await ServerSessionHTTP.request($0)
        }
    ) {
        self.scope = scope
        self.transport = transport
    }

    public func exchange(code: String, verifier: String) async throws -> ServerSession {
        guard !code.isEmpty, code.utf8.count <= 4096,
            code.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }),
            verifier.range(of: "^[A-Za-z0-9._~-]{43,128}$", options: .regularExpression) != nil
        else { throw ServerSessionError.invalid }
        let fields = [
            "session_custody": "server_v1", "grant_type": "authorization_code", "client_id": scope.clientID,
            "code": code, "code_verifier": verifier, "redirect_uri": scope.redirectURI,
        ]
        var request = NoStoreHTTP.request(
            url: scope.server.appendingPathComponent("auth/token"), method: "POST",
            body: Data(formEncode(fields).utf8), contentType: "application/x-www-form-urlencoded")
        request.setValue("server_v1", forHTTPHeaderField: "X-Astral-Session-Custody")
        let reply = try await transport(request)
        guard
            Set(reply.body.objectValue?.keys.map { $0 } ?? []) == [
                "authenticated", "access_token", "token_type", "expires_in", "user_id", "resumed",
            ],
            reply.body["authenticated"] == .bool(true), reply.body["resumed"] == .bool(false),
            reply.body["token_type"] == .string("Bearer"), let seconds = reply.body["expires_in"]?.numberValue,
            seconds.isFinite, seconds > 0, let owner = reply.body["user_id"]?.stringValue,
            let access = reply.body["access_token"]?.stringValue
        else { throw ServerSessionError.invalid }
        let cookie = try Self.issuedCookie(reply.cookies)
        return try ServerSession(
            scope: scope, owner: owner, accessToken: access, cookie: cookie.0, cookieExpiresAt: cookie.1)
    }

    public func refresh(_ session: ServerSession) async throws -> ServerSession {
        guard session.scope == scope, session.cookieExpiresAt > Date() else { throw ServerSessionError.retired }
        var request = NoStoreHTTP.request(url: scope.server.appendingPathComponent("auth/session"))
        request.setValue(session.cookie, forHTTPHeaderField: "Cookie")
        let reply = try await transport(request)
        guard reply.cookies.isEmpty else { throw ServerSessionError.invalid }
        guard reply.body["authenticated"] == .bool(true) else { throw ServerSessionError.retired }
        guard
            Set(reply.body.objectValue?.keys.map { $0 } ?? []) == [
                "authenticated", "access_token", "resumed", "user_id",
            ],
            reply.body["resumed"]?.boolValue != nil, reply.body["user_id"] == .string(session.owner),
            let access = reply.body["access_token"]?.stringValue
        else { throw ServerSessionError.invalid }
        return try ServerSession(
            scope: scope, owner: session.owner, accessToken: access, cookie: session.cookie,
            cookieExpiresAt: session.cookieExpiresAt)
    }

    public func logout(_ session: ServerSession) async throws -> Bool {
        try await logoutOutcome(session) != .unconfirmed
    }

    public func logoutOutcome(_ session: ServerSession) async throws -> ServerSessionLogoutOutcome {
        let current: ServerSession
        if session.tokenSet.claims?["exp"]?.numberValue.map({ $0 <= Date().timeIntervalSince1970 }) == true {
            current = try await refresh(session)
        } else {
            current = session
        }
        try current.validate(scope: scope)
        var request = NoStoreHTTP.request(
            url: scope.server.appendingPathComponent("api/auth/logout"), method: "POST",
            body: Data("{\"session_custody\":\"server_v1\"}".utf8), contentType: "application/json")
        request.setValue("server_v1", forHTTPHeaderField: "X-Astral-Session-Custody")
        request.setValue(current.cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Bearer " + current.accessToken, forHTTPHeaderField: "Authorization")
        let reply = try await transport(request)
        guard Set(reply.body.objectValue?.keys.map { $0 } ?? []) == ["outcome", "revoked", "queued"] else {
            throw ServerSessionError.invalid
        }
        switch (reply.body["outcome"], reply.body["revoked"], reply.body["queued"]) {
        case (.string("revoked"), .bool(true), .bool(false)): return .revoked
        case (.string("queued"), .bool(false), .bool(true)): return .queued
        case (.string("unconfirmed"), .bool(false), .bool(false)): return .unconfirmed
        default: throw ServerSessionError.invalid
        }
    }

    static func issuedCookie(_ headers: [String], now: Date = Date()) throws -> (String, Date) {
        guard headers.count == 1, headers[0].utf8.count <= 4608 else { throw ServerSessionError.invalid }
        let parts = headers[0].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let cookie = parts.first,
            cookie.range(of: "^astral_session=[A-Za-z0-9._~=-]{1,4096}$", options: .regularExpression) != nil
        else { throw ServerSessionError.invalid }
        var attributes: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pair[0].lowercased()
            guard attributes[name] == nil else { throw ServerSessionError.invalid }
            attributes[name] = pair.count == 2 ? String(pair[1]) : ""
        }
        guard Set(attributes.keys) == ["path", "httponly", "secure", "samesite", "max-age"],
            attributes["path"] == "/", attributes["httponly"] == "", attributes["secure"] == "",
            attributes["samesite"]?.lowercased() == "lax", let raw = attributes["max-age"],
            raw.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil,
            let seconds = TimeInterval(raw), seconds.isFinite, seconds <= 31_536_000
        else { throw ServerSessionError.invalid }
        return (cookie, now.addingTimeInterval(seconds))
    }
}

public enum ServerSessionHTTP {
    private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) { completionHandler(nil) }
    }

    public static func request(_ request: URLRequest) async throws -> ServerSessionReply {
        let session = URLSession(
            configuration: NoStoreHTTP.configuration(), delegate: RedirectRefusal(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ServerSessionError.invalid }
            if [401, 403].contains(response.statusCode) { throw ServerSessionError.retired }
            guard response.statusCode == 200, response.url == request.url,
                response.mimeType?.lowercased() == "application/json", response.expectedContentLength <= 32768
            else { throw ServerSessionError.invalid }
            var data = Data()
            for try await byte in stream {
                guard data.count < 32768 else { throw ServerSessionError.invalid }
                data.append(byte)
            }
            let cookies = response.value(forHTTPHeaderField: "Set-Cookie").map { [$0] } ?? []
            return ServerSessionReply(body: try JSONValue.parse(data), cookies: cookies)
        } catch let error as ServerSessionError { throw error } catch { throw ServerSessionError.unavailable }
    }
}
