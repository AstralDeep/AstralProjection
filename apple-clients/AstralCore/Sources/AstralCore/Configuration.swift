// Resolves the backend URL from a runtime override, then Info.plist, then compiled-in fallbacks —
// headless tests and a malformed override still resolve. Read throughout AppModel and the Views layer.

import Foundation

public enum KeychainServices {
    public static let productionBundleIdentifier = "com.personalailabs.astraldeep"

    public static func name(_ suffix: String, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        let base = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? productionBundleIdentifier
        return base + "." + suffix
    }
}

public enum AstralConfig {
    static let serverBaseURLInfoKey = "ASTRALServerBaseURL"

    public static let serverOverrideDefaultsKey = "serverBase"

    public static let fallbackServerBaseURL = "https://sandbox.ai.uky.edu"

    public static var serverBaseURL: String { resolvedServerBaseURL() }

    public static var meshPushPublisherURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ASTRALMeshPushPublisherURL") as? String,
            let url = URL(string: raw), MeshPushRest(publisherURL: url) != nil
        else { return nil }
        return url
    }

    public static func resolvedServerBaseURL(
        bundle: Bundle = .main,
        override: String? = nil
    ) -> String {
        resolve(
            override: override,
            infoValue: bundle.object(forInfoDictionaryKey: serverBaseURLInfoKey) as? String,
            fallback: fallbackServerBaseURL)
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
}
