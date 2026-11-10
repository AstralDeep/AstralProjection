// Resolves the exact effect a Mac host approval covers: the executable's real path and SHA-256, the working
// folder identity, or the granted folder behind a file verb, as a canonical digest the receipt binds and the
// host re-checks immediately before the effect runs.

#if os(macOS)
    import CryptoKit
    import Darwin
    import Foundation

    public struct ComputerCommandPlan: Sendable, Equatable {
        public static let wireType = "computer.exec-plan/v1"
        static let maximumExecutableBytes: UInt64 = 1 << 30
        public let cwd: String
        public let cwdIdentity: String
        public let executable: String
        public let executableDigest: String
        public let digest: String
        public let command: String?
        public let argv: [String]?

        public var json: JSONValue {
            .object([
                "cwd": .string(cwd), "cwd_identity": .string(cwdIdentity), "executable": .string(executable),
                "executable_sha256": .string(executableDigest), "plan_digest": .string(digest),
            ])
        }

        public static func resolve(
            command: String?, argv: [String]?, cwd: String, roots: [String], path: String,
            driftOnFailure: Bool = false
        ) throws -> ComputerCommandPlan {
            func failure(_ message: String, code: String) -> ComputerHostError {
                driftOnFailure ? drift(message) : ComputerHostError(code, message)
            }
            let resolvedCwd: String
            do {
                resolvedCwd = try ComputerCommandPolicy.workingDirectory(cwd, roots: roots)
            } catch {
                throw failure(
                    "The working folder no longer resolves to a selected workspace.", code: "cwd_outside_workspace")
            }
            let candidate: String
            if let argv, let first = argv.first {
                guard let found = ComputerCommandPolicy.executable(first, path: path, cwd: resolvedCwd) else {
                    throw failure(
                        "The approved program no longer resolves to the same executable.", code: "not_found")
                }
                candidate = found
            } else if argv == nil {
                candidate = "/bin/zsh"
            } else {
                throw ComputerHostError("out_of_range", "Invalid argv.")
            }
            let resolved = try resolveExecutable(candidate, driftOnFailure: driftOnFailure)
            guard let identity = ComputerWorkspaceIdentity.at(resolvedCwd, directory: true) else {
                throw failure(
                    "The working folder identity could not be read.", code: "plan_unresolved")
            }
            let plan: ComputerLetsValue = .object([
                "cwd": .string(resolvedCwd),
                "cwd_identity": .string(identity.digest),
                "executable": .string(resolved.path),
                "executable_sha256": .string(resolved.digest),
                "type": .string(wireType),
            ])
            self.init(
                cwd: resolvedCwd, cwdIdentity: identity.digest, executable: resolved.path,
                executableDigest: resolved.digest, digest: try planDigest(plan), command: command, argv: argv)
        }

        static func drift(_ message: String) -> ComputerHostError {
            ComputerHostError("plan_drift", message)
        }

        static func planDigest(_ value: ComputerLetsValue) throws -> String {
            let bytes = try ComputerLetsCanonical.canonical(value)
            let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return "sha256:\(hex)"
        }

        static func resolveExecutable(
            _ candidate: String, driftOnFailure: Bool = false
        ) throws -> (path: String, digest: String) {
            func refusal() -> ComputerHostError {
                driftOnFailure
                    ? drift("The approved executable is no longer readable, so it cannot be re-verified.")
                    : ComputerHostError(
                        "plan_unresolved", "The executable could not be read, so the command cannot be reviewed.")
            }
            guard let pointer = realpath(candidate, nil) else { throw refusal() }
            defer { free(pointer) }
            let resolved = String(cString: pointer)
            let descriptor = open(resolved, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw refusal() }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
                UInt64(info.st_size) <= maximumExecutableBytes
            else { throw refusal() }
            let bufferSize = 1 << 20
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            var hasher = SHA256()
            var remaining = UInt64(info.st_size)
            while remaining > 0 {
                let requested = Int(min(UInt64(bufferSize), remaining))
                let readCount = read(descriptor, buffer, requested)
                if readCount < 0 && errno == EINTR { continue }
                guard readCount > 0 else { throw refusal() }
                hasher.update(data: UnsafeRawBufferPointer(start: buffer, count: readCount))
                remaining -= UInt64(readCount)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (resolved, "sha256:\(hex)")
        }

        init(
            cwd: String, cwdIdentity: String, executable: String, executableDigest: String, digest: String,
            command: String?, argv: [String]?
        ) {
            self.cwd = cwd
            self.cwdIdentity = cwdIdentity
            self.executable = executable
            self.executableDigest = executableDigest
            self.digest = digest
            self.command = command
            self.argv = argv
        }
    }

    // The evidence digest binds verb, path and root; the root identity stays host-side grant state, so the
    // server can mint the digest from what it reviewed while the Mac still refuses a replaced folder.
    public struct ComputerFilePlan: Sendable, Equatable {
        public static let wireType = "computer.file-plan/v1"
        public let verb: String
        public let path: String
        public let root: String
        public let rootIdentity: String
        public let digest: String

        public init(verb: String, path: String, root: String, rootIdentity: String) throws {
            guard verb == "write_file" || verb == "delete_path", path.hasPrefix("/"), root.hasPrefix("/"), root != "/",
                path == root || path.hasPrefix(root + "/")
            else {
                throw ComputerHostError("out_of_range", "The file effect plan is invalid.")
            }
            self.verb = verb
            self.path = path
            self.root = root
            self.rootIdentity = rootIdentity
            digest = try ComputerCommandPlan.planDigest(
                .object([
                    "path": .string(path), "root": .string(root), "type": .string(Self.wireType),
                    "verb": .string(verb),
                ]))
        }

        public func matchesEvidence(_ evidence: String?) -> Bool {
            evidence == digest
        }

        public func recheck() throws {
            guard let identity = ComputerWorkspaceIdentity.at(root, directory: true), identity.digest == rootIdentity
            else {
                throw ComputerCommandPlan.drift("The approved folder changed after review.")
            }
        }
    }
#endif
