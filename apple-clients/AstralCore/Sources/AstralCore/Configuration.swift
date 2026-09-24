// Resolves the backend URL and realm from a runtime override, then Info.plist, then compiled-in fallbacks —
// headless tests and a malformed override still resolve. Read throughout AppModel and the Views layer.

import Foundation

public enum AstralConfig {
    static let serverBaseURLInfoKey = "ASTRALServerBaseURL"
    static let keycloakAuthorityInfoKey = "ASTRALKeycloakAuthority"

    public static let serverOverrideDefaultsKey = "serverBase"
    public static let authorityOverrideDefaultsKey = "authority"

    public static let fallbackServerBaseURL = "https://sandbox.ai.uky.edu"
    public static let fallbackKeycloakAuthority = "https://iam.ai.uky.edu/realms/Astral"

    public static var serverBaseURL: String { resolvedServerBaseURL() }

    public static var keycloakAuthority: String { resolvedKeycloakAuthority() }

    public static func resolvedServerBaseURL(
        bundle: Bundle = .main,
        override: String? = nil
    ) -> String {
        resolve(
            override: override,
            infoValue: bundle.object(forInfoDictionaryKey: serverBaseURLInfoKey) as? String,
            fallback: fallbackServerBaseURL)
    }

    public static func resolvedKeycloakAuthority(
        bundle: Bundle = .main,
        override: String? = nil
    ) -> String {
        resolve(
            override: override,
            infoValue: bundle.object(forInfoDictionaryKey: keycloakAuthorityInfoKey) as? String,
            fallback: fallbackKeycloakAuthority)
    }

    // Also rejects unsubstituted build placeholders like $(...)
    static func resolve(override: String?, infoValue: String?, fallback: String) -> String {
        usableEndpoint(override) ?? usableEndpoint(infoValue) ?? fallback
    }

    public static func usableEndpoint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host,
            !host.isEmpty
        else { return nil }
        return trimmed
    }

    public static let iosClientId = "astral-mobile"
    public static let macosClientId = "astral-desktop"
    public static let watchClientId = "astral-watch"

    public static let redirectScheme = "com.personalailabs.astraldeep"
    public static let redirectURI = "com.personalailabs.astraldeep:/oauth2redirect"
}
