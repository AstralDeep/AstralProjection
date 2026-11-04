// Generates the macOS Seatbelt (SBPL) profile text for one governed command job, purely from its inputs.
// Enforce mode writes only inside granted roots and the per-job directory, keeps protected metadata read-only,
// makes exclusions and keychains unreadable, and permits network only to the loopback egress proxy; shadow mode
// compiles a fully permissive profile so the same launcher path stays validated without blocking.

import CryptoKit
import Foundation

public enum ComputerSandboxProfile {
    public static let launcherPath = "/usr/bin/sandbox-exec"
    public static let probeProgram = "/usr/bin/true"

    public struct Input: Sendable, Equatable {
        public let mode: ComputerSandboxMode
        public let writeRoots: [String]
        public let exclusions: [String]
        public let home: String
        public let bundlePath: String?
        public let supportIdentifier: String
        public let proxyPort: UInt16?

        public init(
            mode: ComputerSandboxMode, writeRoots: [String], exclusions: [String], home: String,
            bundlePath: String?, supportIdentifier: String, proxyPort: UInt16?
        ) {
            self.mode = mode
            self.writeRoots = writeRoots
            self.exclusions = exclusions
            self.home = home
            self.bundlePath = bundlePath
            self.supportIdentifier = supportIdentifier
            self.proxyPort = proxyPort
        }
    }

    static let shellStartupFiles = [
        ".bash_profile", ".bashrc", ".bash_login", ".bash_logout", ".profile", ".zshenv", ".zprofile", ".zshrc",
        ".zlogin", ".zlogout", ".inputrc",
    ]
    static let launchAgentPaths = [
        "/Library/LaunchAgents", "/System/Library/LaunchAgents",
    ]

    public static func generate(_ input: Input) -> String {
        switch input.mode {
        case .shadow:
            return """
            (version 1)
            (allow default)

            """
        case .enforce:
            return enforce(input)
        }
    }

    public static func digest(_ profile: String) -> String {
        SHA256.hash(data: Data(profile.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func regexLiteral(_ pattern: String) -> String {
        "#\"" + pattern.replacingOccurrences(of: "\"", with: "\\x22") + "\""
    }

    static func escapedRegex(_ literal: String) -> String {
        var result = ""
        for character in literal {
            if ".*+?()[]{}|^$".contains(character) {
                result += "[" + String(character) + "]"
            } else {
                result += String(character)
            }
        }
        return result
    }

    static func globRegex(_ pattern: String) -> String {
        var result = ""
        var characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                result += "[^/]*"
            case "?":
                result += "[^/]"
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]") {
                    var body = String(characters[(index + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    result += "[" + body + "]"
                    index = close + 1
                    continue
                }
                result += "[[]"
            default:
                if ".+(){}|^$".contains(character) {
                    result += "[" + String(character) + "]"
                } else {
                    result += String(character)
                }
            }
            index += 1
        }
        return result
    }

    static func readDenials(root: String, patterns: [String]) -> [String] {
        let anchored = "^(?i)" + escapedRegex(root) + "(/[^/]+)*/"
        var rules: [String] = []
        for pattern in patterns {
            let name = String(pattern.dropLast(pattern.hasSuffix("/") ? 1 : 0))
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            if !name.contains(where: { "*?[".contains($0) }) {
                let target = root + "/" + name
                rules.append("(deny file-read* (literal " + quote(target) + "))")
                rules.append("(deny file-read* (subpath " + quote(target) + "))")
                continue
            }
            rules.append("(deny file-read* (regex " + regexLiteral(anchored + globRegex(name) + "(/|$)") + "))")
        }
        return rules
    }

    static func protectedWriteDenials(root: String) -> [String] {
        [
            "(deny file-write* file-set-mode file-set-times file-set-flags file-set-owner (subpath "
                + quote(root + "/.git/hooks") + "))",
            "(deny file-write* file-set-mode file-set-times file-set-flags file-set-owner (literal "
                + quote(root + "/.git/config") + "))",
            "(deny file-write* file-set-mode file-set-times file-set-flags file-set-owner (literal "
                + quote(root + "/.git/config.lock") + "))",
        ]
    }

    static func protectedHomeDenials(home: String, bundlePath: String?, supportIdentifier: String) -> [String] {
        var rules: [String] = []
        for file in shellStartupFiles {
            rules.append(
                "(deny file-write* file-set-mode file-set-times file-set-flags file-set-owner (literal "
                    + quote(home + "/" + file) + "))")
        }
        for directory in launchAgentPaths + [home + "/Library/LaunchAgents"] {
            rules.append(
                "(deny file-write* file-set-mode file-set-times file-set-flags file-set-owner (subpath "
                    + quote(directory) + "))")
        }
        if let bundlePath, !bundlePath.isEmpty {
            rules.append(
                "(deny file-write* file-set-mode file-set-times file-set-flags file-set-owner (subpath "
                    + quote(bundlePath) + "))")
        }
        let support = home + "/Library/Application Support/" + supportIdentifier
        rules.append(
            "(deny file-write* file-set-mode file-set-times file-set-flags file-set-owner (subpath "
                + quote(support) + "))")
        let preferences = home + "/Library/Preferences/" + supportIdentifier + ".plist"
        rules.append(
            "(deny file-write* file-set-mode file-set-times file-set-flags file-set-owner (literal "
                + quote(preferences) + "))")
        return rules
    }

    static func keychainReadDenials(home: String) -> [String] {
        [home + "/Library/Keychains", "/Library/Keychains", "/System/Library/Keychains"].map {
            "(deny file-read* (subpath " + quote($0) + "))"
        }
    }

    private static func enforce(_ input: Input) -> String {
        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "(import \"system.sb\")",
            "",
            "(allow process-exec (subpath \"/\"))",
            "(allow process-exec-meta)",
            "(allow process-info*)",
            "(allow signal)",
            "(allow mach-lookup)",
            "(allow ipc-posix*)",
            "(allow ipc-sysv*)",
            "(allow sysctl-read)",
            "(allow file-read* (subpath \"/\"))",
            "(allow file-ioctl (subpath \"/\"))",
        ]
        if let port = input.proxyPort {
            lines.append("(allow network-outbound (remote ip \"127.0.0.1:\(port)\"))")
            lines.append("(allow network-outbound (remote unix-socket (literal \"/private/var/run/mDNSResponder\")))")
            lines.append("(allow network-bind (local ip \"127.0.0.1:0\"))")
            lines.append("(allow network-inbound (local ip \"127.0.0.1:0\"))")
        }
        lines.append("")
        for root in input.writeRoots where !root.isEmpty {
            lines.append(
                "(allow file-write* file-set-mode file-set-times file-set-flags file-set-owner (subpath "
                    + quote(root) + "))")
        }
        lines.append("")
        for root in input.writeRoots where !root.isEmpty {
            lines.append(contentsOf: protectedWriteDenials(root: root))
        }
        lines.append(contentsOf: protectedHomeDenials(
            home: input.home, bundlePath: input.bundlePath, supportIdentifier: input.supportIdentifier))
        lines.append(contentsOf: keychainReadDenials(home: input.home))
        var exclusions = Set<String>()
        for root in input.writeRoots where !root.isEmpty {
            for rule in readDenials(root: root, patterns: input.exclusions) where exclusions.insert(rule).inserted {
                lines.append(rule)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
