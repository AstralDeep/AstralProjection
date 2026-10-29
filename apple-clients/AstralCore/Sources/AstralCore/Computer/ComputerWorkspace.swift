// Performs bounded file operations relative to one explicitly selected directory descriptor.
// Every traversal rejects symlinks and every mutation rechecks the host's current effect authority.

#if os(macOS)
    import Darwin
    import Foundation

    public struct ComputerWorkspaceIdentity: Codable, Equatable, Sendable {
        private let device: dev_t
        private let inode: ino_t
        private let generation: UInt32

        fileprivate init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            generation = info.st_gen
        }
    }

    public final class ComputerWorkspace: @unchecked Sendable {
        public let root: String
        public let rootIdentity: ComputerWorkspaceIdentity
        private let descriptor: Int32
        public init(root: String) throws {
            let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            let forbidden = [
                "/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/Users",
                FileManager.default.homeDirectoryForCurrentUser.path,
            ]
            let protected: Set<String> = [".ssh", ".aws", ".gnupg", ".azure", ".config", "keychains"]
            let folded = canonical.lowercased()
            guard !forbidden.map({ $0.lowercased() }).contains(folded), !canonical.contains("\0"),
                !folded.split(separator: "/").contains(where: { protected.contains(String($0)) }),
                !["/system/", "/library/", "/applications/", "/usr/", "/bin/", "/sbin/", "/private/etc/"].contains(
                    where: folded.hasPrefix)
            else {
                throw ComputerHostError("permission_denied", "Select a dedicated workspace folder.")
            }
            let fd = Darwin.open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                throw ComputerHostError("permission_denied", "The selected workspace cannot be opened.")
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(fd)
                throw ComputerHostError("permission_denied", "The selected workspace identity cannot be established.")
            }
            self.root = canonical
            rootIdentity = ComputerWorkspaceIdentity(info)
            descriptor = fd
        }
        deinit { Darwin.close(descriptor) }

        public func matchesRoot(_ path: String) -> Bool {
            guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else { return false }
            let candidate = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard candidate >= 0 else { return false }
            defer { Darwin.close(candidate) }
            var held = stat()
            var current = stat()
            return fstat(descriptor, &held) == 0 && fstat(candidate, &current) == 0
                && held.st_mode & S_IFMT == S_IFDIR && current.st_mode & S_IFMT == S_IFDIR
                && ComputerWorkspaceIdentity(held) == ComputerWorkspaceIdentity(current)
        }

        private func components(_ path: String) throws -> [String] {
            guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0"),
                !path.split(separator: "/").contains("..")
            else { throw ComputerHostError("permission_denied", "The path is outside the workspace.") }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard normalized == root || normalized.hasPrefix(root + "/") else {
                throw ComputerHostError("permission_denied", "The path is outside the selected workspace.")
            }
            let parts = normalized.dropFirst(root.count).split(separator: "/").map(String.init)
            let protected: Set<String> = [".ssh", ".aws", ".gnupg", ".azure", ".config", "keychains"]
            guard !parts.contains(where: { protected.contains($0.lowercased()) }) else {
                throw ComputerHostError("permission_denied", "Credential directories are unavailable to file tools.")
            }
            return parts
        }
        private func directory(_ parts: [String]) throws -> Int32 {
            var fd = Darwin.openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure() }
            for part in parts {
                let child = Darwin.openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                Darwin.close(fd)
                guard child >= 0 else { throw failure() }
                fd = child
            }
            return fd
        }
        private func parent(_ path: String) throws -> (Int32, String) {
            let parts = try components(path)
            guard let name = parts.last else {
                throw ComputerHostError("permission_denied", "The workspace root cannot be modified.")
            }
            return (try directory(Array(parts.dropLast())), name)
        }
        private func parentForWrite(
            _ path: String, begin: () -> Void, authorize: () throws -> Void
        ) throws -> (Int32, String) {
            let parts = try components(path)
            guard let name = parts.last else {
                throw ComputerHostError("permission_denied", "The workspace root cannot be modified.")
            }
            var fd = Darwin.openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure() }
            for part in parts.dropLast() {
                var child = Darwin.openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT {
                    do {
                        try authorize()
                    } catch {
                        Darwin.close(fd)
                        throw error
                    }
                    begin()
                    if mkdirat(fd, part, mode_t(0o700)) != 0, errno != EEXIST {
                        let error = failure()
                        Darwin.close(fd)
                        throw error
                    }
                    child = Darwin.openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if child < 0 {
                    let error = failure()
                    Darwin.close(fd)
                    throw error
                }
                Darwin.close(fd)
                fd = child
            }
            return (fd, name)
        }
        private func failure() -> ComputerHostError {
            let code = errno == ENOENT ? "not_found" : "failed"
            return ComputerHostError(code, "The workspace operation was refused or failed (errno \(errno)).")
        }
        private func preEffect<T>(_ operation: (_ begin: () -> Void) throws -> T) throws -> T {
            var started = false
            do {
                return try operation { started = true }
            } catch let error as ComputerHostError {
                throw ComputerHostError(error.code, error.message, effectState: started ? nil : "not_started")
            }
        }
        private func regular(_ fd: Int32) throws -> stat {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw ComputerHostError("permission_denied", "Only regular files are supported.")
            }
            return info
        }
        public func read(_ path: String, maximum: Int) throws -> [String: JSONValue] {
            return try preEffect { _ in try readFile(path, maximum: maximum) }
        }
        private func readFile(_ path: String, maximum: Int) throws -> [String: JSONValue] {
            guard (1...262144).contains(maximum) else {
                throw ComputerHostError("out_of_range", "The read limit is invalid.")
            }
            let (parent, name) = try parent(path)
            defer { Darwin.close(parent) }
            let fd = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw failure() }
            defer { Darwin.close(fd) }
            let info = try regular(fd)
            var bytes = [UInt8](repeating: 0, count: maximum + 1)
            var used = 0
            while used < bytes.count {
                let n = bytes.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress!.advanced(by: used), $0.count - used)
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw failure()
                }
                if n == 0 { break }
                used += n
            }
            let end = used > maximum ? Self.scalarBoundary(bytes, maximum) : used
            guard let text = String(bytes: bytes.prefix(end), encoding: .utf8), !text.contains("\0")
            else {
                throw ComputerHostError("unsupported", "The selected file is not UTF-8 text.")
            }
            return [
                "path": .string(path), "text": .string(text),
                "truncated": .bool(used > maximum), "size": .number(Double(info.st_size)),
            ]
        }
        static func scalarBoundary(_ bytes: [UInt8], _ end: Int) -> Int {
            var start = end
            while start > 0, start > end - 4, bytes[start - 1] & 0xC0 == 0x80 { start -= 1 }
            guard start > 0 else { return end }
            let lead = bytes[start - 1]
            let width = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            return start - 1 + width > end ? start - 1 : end
        }
        private func preserve(from source: Int32, to target: Int32, mode: mode_t) throws {
            guard fchmod(target, mode & 0o1777) == 0 else { throw failure() }
            let size = flistxattr(source, nil, 0, 0)
            guard size >= 0 else { throw failure() }
            guard size > 0 else { return }
            var names = [CChar](repeating: 0, count: size)
            let listed = flistxattr(source, &names, size, 0)
            guard listed >= 0 else { throw failure() }
            for raw in names.prefix(listed).split(separator: 0, omittingEmptySubsequences: true) {
                let name = Array(raw) + [0]
                let length = fgetxattr(source, name, nil, 0, 0, 0)
                guard length >= 0 else { throw failure() }
                var value = [UInt8](repeating: 0, count: length)
                let read = fgetxattr(source, name, &value, length, 0, 0)
                guard read >= 0, fsetxattr(target, name, value, read, 0, 0) == 0 else { throw failure() }
            }
        }
        public func list(_ path: String) throws -> [String: JSONValue] {
            return try preEffect { _ in try listDirectory(path) }
        }
        private func listDirectory(_ path: String) throws -> [String: JSONValue] {
            let fd = try directory(components(path))
            guard let stream = fdopendir(fd) else {
                Darwin.close(fd)
                throw failure()
            }
            defer { closedir(stream) }
            var entries: [JSONValue] = []
            while let entry = readdir(stream), entries.count < 500 {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                    [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(info.st_mode & S_IFMT)
                else { continue }
                entries.append(
                    .object([
                        "name": .string(name), "is_dir": .bool(info.st_mode & S_IFMT == S_IFDIR),
                        "size": .number(Double(info.st_size)), "modified": .number(Double(info.st_mtimespec.tv_sec)),
                    ]))
            }
            return ["path": .string(path), "entries": .array(entries), "count": .number(Double(entries.count))]
        }
        public func write(_ path: String, content: String, overwrite: Bool, authorize: () throws -> Void) throws {
            try preEffect { begin in
                try writeFile(path, content: content, overwrite: overwrite, begin: begin, authorize: authorize)
            }
        }
        private func writeFile(
            _ path: String, content: String, overwrite: Bool, begin: () -> Void, authorize: () throws -> Void
        ) throws {
            let bytes = Array(content.utf8)
            guard bytes.count <= 262144 else { throw ComputerHostError("out_of_range", "The write exceeds 256 KiB.") }
            let (parent, name) = try parentForWrite(path, begin: begin, authorize: authorize)
            defer { Darwin.close(parent) }
            var existing = stat()
            var original: Int32 = -1
            if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG else {
                    throw ComputerHostError("permission_denied", "Only regular files can be replaced.")
                }
                guard overwrite else { throw alreadyExists() }
                if overwrite {
                    original = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard original >= 0 else { throw failure() }
                    guard fstat(original, &existing) == 0, existing.st_mode & S_IFMT == S_IFREG else {
                        Darwin.close(original)
                        throw ComputerHostError("permission_denied", "Only regular files can be replaced.")
                    }
                }
            } else if errno != ENOENT {
                throw failure()
            }
            defer { if original >= 0 { Darwin.close(original) } }
            try authorize()
            begin()
            let temporary = ".astral-" + UUID().uuidString.lowercased()
            let fd = Darwin.openat(
                parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw failure() }
            defer {
                Darwin.close(fd)
                _ = unlinkat(parent, temporary, 0)
            }
            var offset = 0
            while offset < bytes.count {
                try authorize()
                let n = bytes.withUnsafeBytes {
                    Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw failure()
                }
                guard n > 0 else { throw failure() }
                offset += n
            }
            if original >= 0 { try preserve(from: original, to: fd, mode: existing.st_mode) }
            guard fsync(fd) == 0 else { throw failure() }
            try authorize()
            if renameatx_np(parent, temporary, parent, name, overwrite ? 0 : UInt32(RENAME_EXCL)) != 0 {
                if !overwrite && errno == EEXIST { throw alreadyExists() }
                throw failure()
            }
        }
        private func alreadyExists() -> ComputerHostError {
            ComputerHostError("already_exists", "File exists; retry with if_exists=overwrite to replace it")
        }
        public func delete(_ path: String, authorize: () throws -> Void) throws {
            try preEffect { begin in try deletePath(path, begin: begin, authorize: authorize) }
        }
        private func deletePath(_ path: String, begin: () -> Void, authorize: () throws -> Void) throws {
            let (parent, name) = try parent(path)
            defer { Darwin.close(parent) }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
            guard [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(info.st_mode & S_IFMT) else {
                throw ComputerHostError("permission_denied", "Only files and empty directories can be deleted.")
            }
            try authorize()
            begin()
            guard unlinkat(parent, name, info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
                throw failure()
            }
        }
    }
#endif
