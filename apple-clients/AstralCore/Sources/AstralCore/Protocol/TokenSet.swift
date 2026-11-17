// Reads the claims of a bearer token a host hands the client: expiry, subject and display name.
// Conversation continuity and the push owner scope derive the account from it; it never obtains or refreshes a credential.

import Foundation

public struct TokenSet: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public init(
        accessToken: String, refreshToken: String?, expiresIn: TimeInterval,
        now: Date = Date()
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = now.addingTimeInterval(expiresIn)
    }

    public init?(json: JSONValue, now: Date = Date()) {
        guard let access = json["access_token"]?.stringValue else { return nil }
        self.accessToken = access
        self.refreshToken = json["refresh_token"]?.stringValue
        self.expiresAt = now.addingTimeInterval(json["expires_in"]?.numberValue ?? 300)
    }

    public func needsRefresh(now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-60)
    }

    public var claims: JSONValue? {
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONValue.parse(data)
    }

    public var subject: String { claims?["sub"]?.stringValue ?? "unknown" }

    public var displayName: String {
        claims?["name"]?.stringValue
            ?? claims?["preferred_username"]?.stringValue
            ?? subject
    }
}
