// Decides the environment, working directory, timeout, program and grantable form of a host command before launch.
// The Mac host builds every spawn from these decisions; the server keeps review and task grants.

#if os(macOS)
    import Darwin
    import Foundation

    public struct ComputerCommandInvocation: Sendable, Equatable {
        public let argv: [String]?
        public let command: String?
        public let argv0: String
        public let grantable: Bool
    }

    public enum ComputerCommandPolicy {
        public static let stdinLimit = 16384
        public static let environmentLimit = 32
        public static let fallbackPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        private static let inheritedNames: Set<String> = ["HOME", "USER", "LANG", "SHELL", "TMPDIR"]
        public static let requestNames: Set<String> = [
            "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TZ", "TERM", "NO_COLOR", "FORCE_COLOR", "CI", "DEBUG",
            "COLUMNS", "LINES",
        ]
        public static let forcedNames: [String: String] = [
            "EDITOR": "/usr/bin/false", "VISUAL": "/usr/bin/false", "GIT_EDITOR": "/usr/bin/false", "PAGER": "cat",
            "GIT_PAGER": "cat",
        ]
        private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh"]
        private static let neverGrantable: Set<String> = [
            "node", "ruby", "perl", "env", "xargs", "osascript", "open", "sudo", "su", "launchctl", "defaults",
            "security", "nice", "nohup", "time", "command", "exec", "caffeinate", "awk", "gawk", "sed", "make", "xcrun",
            "swift", "php", "lua", "tclsh", "script", "expect", "screen", "tmux",
        ]

        public static func forbidden(_ name: String) -> Bool {
            let upper = name.uppercased()
            return upper.hasPrefix("ASTRAL_") || ["TOKEN", "SECRET", "KEY", "PASSWORD"].contains { upper.contains($0) }
        }

        public static func requestable(_ name: String) -> Bool {
            computerFullMatch(name, "^[A-Z][A-Z0-9_]{0,63}$") && !forbidden(name)
                && (requestNames.contains(name) || name.hasPrefix("APP_"))
        }

        public static func environment(
            inherited: [String: String], path: String, additions: [String: String]
        ) throws -> [String: String] {
            guard additions.count <= environmentLimit else {
                throw ComputerHostError("out_of_range", "At most \(environmentLimit) environment variables can be set.")
            }
            var result: [String: String] = [:]
            for (name, value) in inherited
            where (inheritedNames.contains(name) || name.hasPrefix("LC_")) && !forbidden(name) && !value.contains("\0")
            {
                result[name] = value
            }
            result["PATH"] = path
            result["TERM"] = "dumb"
            for (name, value) in additions.sorted(by: { $0.key < $1.key }) {
                guard requestable(name) else {
                    throw ComputerHostError(
                        "env_forbidden",
                        "The environment variable \(name) cannot be set. Commands may set APP_* or "
                            + requestNames.sorted().joined(separator: ", ") + ".")
                }
                guard value.unicodeScalars.count <= 4096,
                    !value.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" })
                else {
                    throw ComputerHostError(
                        "out_of_range", "Environment values are one line of at most 4096 characters.")
                }
                result[name] = value
            }
            result.merge(forcedNames) { $1 }
            return result
        }

        public static func workingDirectory(_ cwd: String, roots: [String]) throws -> String {
            guard cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 1024,
                let resolved = canonical(cwd), let target = identity(resolved, directory: true)
            else {
                throw ComputerHostError(
                    "cwd_outside_workspace",
                    "The working directory does not resolve to a folder in a selected workspace.")
            }
            let anchors = roots.compactMap { canonical($0) }.compactMap { identity($0, directory: true) }
            var candidate = resolved
            var current = target
            while true {
                if anchors.contains(where: { $0 == current }) { return resolved }
                guard candidate != "/" else { break }
                candidate = (candidate as NSString).deletingLastPathComponent
                guard let parent = identity(candidate, directory: true) else { break }
                current = parent
            }
            throw ComputerHostError(
                "cwd_outside_workspace", "The working directory is outside every selected workspace folder.")
        }

        public static func timeout(_ value: Double?, background: Bool) throws -> Double {
            let seconds = value ?? 60
            guard seconds.isFinite, seconds.rounded() == seconds, (1...(background ? 3600 : 600)).contains(seconds)
            else {
                throw ComputerHostError(
                    "out_of_range",
                    background ? "Background timeouts are 1–3600 seconds." : "Timeouts are 1–600 seconds.")
            }
            return seconds
        }

        public static func stdin(_ text: String?) throws -> Data? {
            guard let text else { return nil }
            guard text.utf8.count <= stdinLimit, !text.contains("\0") else {
                throw ComputerHostError("out_of_range", "Command input is limited to 16 KiB of text.")
            }
            return Data(text.utf8)
        }

        public static func invocation(command: String?, argv: [String]?) throws -> ComputerCommandInvocation {
            if let argv {
                guard let first = argv.first, !first.isEmpty, !argv.contains(where: { $0.contains("\0") }) else {
                    throw ComputerHostError("out_of_range", "Invalid argv.")
                }
                let name = basename(first)
                return ComputerCommandInvocation(
                    argv: argv, command: nil, argv0: name, grantable: grantableProgram(name, Array(argv.dropFirst())))
            }
            guard let command, !command.contains("\0"),
                !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ComputerHostError("out_of_range", "Give exactly one of command or argv.") }
            let first =
                tokenize(command)?.first ?? command.split(whereSeparator: \.isWhitespace).first.map(String.init)
                ?? command
            return ComputerCommandInvocation(argv: nil, command: command, argv0: basename(first), grantable: false)
        }

        public static func executable(_ name: String, path: String, cwd: String) -> String? {
            if name.contains("/") {
                let candidate = name.hasPrefix("/") ? name : (cwd as NSString).appendingPathComponent(name)
                return runnable(candidate) ? candidate : nil
            }
            for directory in path.split(separator: ":").map(String.init) where directory.hasPrefix("/") {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if runnable(candidate) { return candidate }
            }
            return nil
        }

        public static func loginPath(_ output: String) -> String? {
            guard
                let line = output.split(whereSeparator: \.isNewline).last.map({
                    $0.trimmingCharacters(in: .whitespaces)
                }), !line.isEmpty, line.utf8.count <= 8192, !line.contains("\0")
            else { return nil }
            let entries = line.split(separator: ":").map(String.init)
            guard !entries.isEmpty, entries.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
            return entries.joined(separator: ":")
        }

        public static func tokenize(_ command: String) -> [String]? {
            var tokens: [String] = []
            var current = ""
            var active = false
            var quote: Character?
            var escaped = false
            for character in command {
                if escaped {
                    current.append(character)
                    escaped = false
                    continue
                }
                if quote == "'" {
                    if character == "'" { quote = nil } else { current.append(character) }
                    continue
                }
                if quote == "\"" {
                    if character == "\"" {
                        quote = nil
                    } else if character == "\\" {
                        escaped = true
                    } else {
                        current.append(character)
                    }
                    continue
                }
                if character == "\\" {
                    escaped = true
                    active = true
                } else if character == "'" || character == "\"" {
                    quote = character
                    active = true
                } else if character.isWhitespace {
                    if active { tokens.append(current) }
                    current = ""
                    active = false
                } else {
                    current.append(character)
                    active = true
                }
            }
            guard quote == nil, !escaped else { return nil }
            if active { tokens.append(current) }
            return tokens
        }

        private static func grantableProgram(_ name: String, _ arguments: [String]) -> Bool {
            let folded = name.lowercased()
            if shells.contains(folded) || neverGrantable.contains(folded) || folded.hasPrefix("python") { return false }
            let findEffects: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete"]
            if folded == "find", arguments.contains(where: findEffects.contains) { return false }
            if folded == "git" {
                if arguments.contains(where: { ["push", "reset", "clean", "rebase"].contains($0) }) { return false }
                if let checkout = arguments.firstIndex(of: "checkout"), arguments[checkout...].contains("--") {
                    return false
                }
            }
            return true
        }

        private static func basename(_ path: String) -> String {
            path.split(separator: "/").last.map(String.init) ?? path
        }

        private static func canonical(_ path: String) -> String? {
            guard let pointer = realpath(path, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }

        private struct Identity: Equatable {
            let device: dev_t
            let inode: ino_t
        }

        private static func identity(_ path: String, directory: Bool) -> Identity? {
            var info = stat()
            guard stat(path, &info) == 0, !directory || info.st_mode & S_IFMT == S_IFDIR else { return nil }
            return Identity(device: info.st_dev, inode: info.st_ino)
        }

        private static func runnable(_ path: String) -> Bool {
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
        }
    }
#endif
