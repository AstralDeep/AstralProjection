// Matches workspace-relative path components against the host-wide patterns that hide secrets from Astral's tools.
// ComputerWorkspace refuses or omits matches, ComputerCommandPolicy checks command text and working directories,
// and the computer host descriptor reports the same patterns to the server.

import Foundation

public struct ComputerWorkspaceExclusions: Sendable, Equatable {
    public static let maximumPatterns = 32
    public static let maximumPatternLength = 128
    public static let defaults = ComputerWorkspaceExclusions(
        checked: [
            "private/", ".env*", "*.pem", "*.key", "*.p8", "*.p12", "credentials*.json", "realm-export.json",
            "id_rsa*", "id_ed25519*", "*.keychain*",
        ])
    public static let none = ComputerWorkspaceExclusions(checked: [])
    public let patterns: [String]
    private let names: [String]

    public init(patterns: [String]) throws {
        guard Self.valid(patterns),
            patterns.allSatisfy({ !$0.trimmingTrailingSlashes.contains("/") })
        else {
            throw ComputerHostError("out_of_range", "Workspace exclusions must be up to 32 unique name patterns.")
        }
        self.init(checked: patterns)
    }

    private init(checked patterns: [String]) {
        self.patterns = patterns
        names = patterns.map(\.trimmingTrailingSlashes)
    }

    public static func valid(_ patterns: [String]) -> Bool {
        patterns.count <= maximumPatterns && Set(patterns).count == patterns.count
            && patterns.allSatisfy { pattern in
                let scalars = pattern.unicodeScalars
                return scalars.count <= maximumPatternLength
                    && !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !scalars.contains(where: { $0.value < 32 || $0.value == 127 })
                    && !pattern.trimmingTrailingSlashes.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            }
    }

    public func pattern(matchingName name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else { return nil }
        for (index, value) in names.enumerated() where fnmatch(value, name, FNM_CASEFOLD) == 0 {
            return patterns[index]
        }
        return nil
    }

    public func pattern<S: StringProtocol>(matchingComponents components: [S]) -> String? {
        for component in components {
            if let hit = pattern(matchingName: String(component)) { return hit }
        }
        return nil
    }
}

extension String {
    fileprivate var trimmingTrailingSlashes: String {
        var value = Substring(self)
        while value.count > 1, value.hasSuffix("/") { value = value.dropLast() }
        return String(value)
    }
}
