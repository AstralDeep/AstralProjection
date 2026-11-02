// Decides the environment, working directory, timeout, program and grantable form of a host command before launch.
// The Mac host builds every spawn from these decisions; the server keeps review and task grants.
// Working directories must sit in a selected folder, and commands naming an excluded path there are refused.

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
            try workingDirectory(cwd, roots: roots, resolve: canonical)
        }

        static func workingDirectory(_ cwd: String, roots: [String], resolve: (String) -> String?) throws -> String {
            guard cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 1024 else {
                throw ComputerHostError(
                    "cwd_outside_workspace",
                    "The working directory does not resolve to a folder in a selected workspace.")
            }
            let resolvedRoots = roots.compactMap(resolve)
            let requested = lexical(cwd)
            guard (roots.map(lexical) + resolvedRoots).contains(where: { within(requested, $0) }) else {
                throw ComputerHostError(
                    "cwd_outside_workspace", "The working directory is outside every selected workspace folder.")
            }
            guard let resolved = resolve(cwd), let target = identity(resolved, directory: true) else {
                throw ComputerHostError(
                    "cwd_outside_workspace",
                    "The working directory does not resolve to a folder in a selected workspace.")
            }
            let anchors = resolvedRoots.compactMap { identity($0, directory: true) }
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

        public static func refuseExcluded(
            cwd: String, resolvedCwd: String, command: String?, argv: [String]?, roots: [String],
            exclusions: ComputerWorkspaceExclusions
        ) throws {
            guard !exclusions.patterns.isEmpty else { return }
            let anchors = Array(Set(roots.map(lexical) + roots.compactMap(canonical).map(lexical)))
                .filter { $0 != "/" }.sorted { $0.count > $1.count }
            for directory in [lexical(cwd), resolvedCwd] {
                if let pattern = excludedPattern(directory, anchors: anchors, exclusions: exclusions) {
                    throw ComputerHostError(
                        "excluded_path",
                        "The working directory \(String(cwd.prefix(200))) is inside a path excluded by the "
                            + "workspace pattern \(pattern).")
                }
            }
            for (fragment, shell, whole) in contextualFragments(command: command, argv: argv) {
                if let pattern = excludedFragment(
                    fragment, cwd: resolvedCwd, anchors: anchors, exclusions: exclusions, expand: shell, whole: whole)
                {
                    throw ComputerHostError(
                        "excluded_path",
                        "The command names \(String(fragment.prefix(200))), which is excluded from Astral's tools by "
                            + "the workspace pattern \(pattern).")
                }
            }
        }

        private static let fragmentSeparators = CharacterSet(charactersIn: "=,;|&<>()`${}\"'")

        static func fragments(command: String?, argv: [String]?) -> [String] {
            contextualFragments(command: command, argv: argv).map(\.0)
        }

        private static func words(_ text: String) -> [String] {
            tokenize(text) ?? text.components(separatedBy: .whitespacesAndNewlines)
        }

        private static func contextualFragments(command: String?, argv: [String]?) -> [(String, Bool, Bool)] {
            var seen: Set<String> = []
            var result: [(String, Bool, Bool)] = []
            func walk(_ list: [String], shell: Bool, depth: Int) {
                for (index, word) in list.enumerated() {
                    for piece in [word] + word.components(separatedBy: fragmentSeparators)
                    where !piece.isEmpty && seen.insert("\(piece == word)|\(piece)").inserted {
                        result.append((piece, shell, piece == word))
                    }
                    let previous = index > 0 ? list[index - 1] : ""
                    let script =
                        previous == "eval"
                        || (computerFullMatch(previous, "^-[A-Za-z]*c$")
                            && list[..<index].contains { shells.contains(basename($0).lowercased()) })
                    guard depth < 4, script || word.contains("$(") || word.contains("`") else { continue }
                    let inner = word.components(separatedBy: CharacterSet(charactersIn: "`$()")).joined(separator: " ")
                    walk(words(script ? word : inner), shell: true, depth: depth + 1)
                }
            }
            if let argv {
                walk(argv, shell: false, depth: 0)
            } else if let command {
                walk(words(command), shell: true, depth: 0)
            }
            return result
        }

        private static func excludedFragment(
            _ fragment: String, cwd: String, anchors: [String], exclusions: ComputerWorkspaceExclusions, expand: Bool,
            whole: Bool
        ) -> String? {
            var path = fragment
            if path == "~" || path.hasPrefix("~/") {
                path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
            }
            if !path.hasPrefix("/"), let pattern = exclusions.pattern(matchingComponents: path.split(separator: "/")) {
                return pattern
            }
            let absolute = path.hasPrefix("/") ? path : cwd + "/" + path
            if let pattern = excludedPattern(absolute, anchors: anchors, exclusions: exclusions) { return pattern }
            guard expand, fragment.contains(where: { "*?[".contains($0) }),
                whole || fragment.contains(where: { $0.isLetter || $0.isNumber })
            else { return nil }
            for match in expanded(absolute) {
                if let pattern = excludedPattern(match, anchors: anchors, exclusions: exclusions) { return pattern }
            }
            return nil
        }

        private static func excludedPattern(
            _ path: String, anchors: [String], exclusions: ComputerWorkspaceExclusions
        ) -> String? {
            let normalized = lexical(path)
            for candidate in [normalized, resolvedPrefix(normalized)].compactMap({ $0 }) {
                guard let anchor = anchors.first(where: { within(candidate, $0) }) else { continue }
                let parts = candidate.dropFirst(anchor.count).split(separator: "/")
                if let pattern = exclusions.pattern(matchingComponents: parts) { return pattern }
            }
            return nil
        }

        private static func resolvedPrefix(_ path: String) -> String? {
            var head = path
            var tail: [String] = []
            while tail.count <= 256 {
                if let real = canonical(head) {
                    return lexical(([real] + tail.reversed()).joined(separator: "/"))
                }
                guard head != "/", !head.isEmpty else { return nil }
                tail.append((head as NSString).lastPathComponent)
                head = (head as NSString).deletingLastPathComponent
            }
            return nil
        }

        private static func expanded(_ pattern: String) -> [String] {
            var matches = glob_t()
            defer { globfree(&matches) }
            guard glob(pattern, GLOB_BRACE | GLOB_TILDE | GLOB_LIMIT | GLOB_NOSORT, nil, &matches) == 0 else {
                return []
            }
            return (0..<min(Int(matches.gl_pathc), 4096)).compactMap { index in
                matches.gl_pathv[index].map { String(cString: $0) }
            }
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

        private static func lexical(_ path: String) -> String {
            var parts: [Substring] = []
            for part in path.split(separator: "/") where part != "." {
                if part == ".." {
                    _ = parts.popLast()
                } else {
                    parts.append(part)
                }
            }
            return "/" + parts.joined(separator: "/")
        }

        private static func within(_ path: String, _ root: String) -> Bool {
            let base = lexical(root)
            return base == "/" || path == base || path.hasPrefix(base + "/")
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
