// Performs bounded file operations relative to one explicitly selected directory descriptor.
// Every traversal rejects symlinks and every mutation rechecks the host's current effect authority.

#if os(macOS)
    import Darwin
    import Foundation

    public final class ComputerWorkspace: @unchecked Sendable {
        public let root: String
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
            self.root = canonical
            descriptor = fd
        }
        deinit { Darwin.close(descriptor) }

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
        private func failure() -> ComputerHostError {
            ComputerHostError("failed", "The workspace operation was refused or failed (errno \(errno)).")
        }
        private func regular(_ fd: Int32) throws -> stat {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw ComputerHostError("permission_denied", "Only regular files are supported.")
            }
            return info
        }
        public func read(_ path: String, maximum: Int) throws -> [String: JSONValue] {
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
            guard let text = String(bytes: bytes.prefix(min(used, maximum)), encoding: .utf8), !text.contains("\0")
            else {
                throw ComputerHostError("unsupported", "The selected file is not UTF-8 text.")
            }
            return [
                "path": .string(path), "text": .string(text),
                "truncated": .bool(used > maximum), "size": .number(Double(info.st_size)),
            ]
        }
        public func list(_ path: String) throws -> [String: JSONValue] {
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
            let bytes = Array(content.utf8)
            guard bytes.count <= 262144 else { throw ComputerHostError("out_of_range", "The write exceeds 256 KiB.") }
            let (parent, name) = try parent(path)
            defer { Darwin.close(parent) }
            var existing = stat()
            if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG else {
                    throw ComputerHostError("permission_denied", "Only regular files can be replaced.")
                }
            } else if errno != ENOENT {
                throw failure()
            }
            try authorize()
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
            guard fsync(fd) == 0 else { throw failure() }
            try authorize()
            guard renameatx_np(parent, temporary, parent, name, overwrite ? 0 : UInt32(RENAME_EXCL)) == 0 else {
                throw failure()
            }
        }
        public func delete(_ path: String, authorize: () throws -> Void) throws {
            let (parent, name) = try parent(path)
            defer { Darwin.close(parent) }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
            guard [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(info.st_mode & S_IFMT) else {
                throw ComputerHostError("permission_denied", "Only files and empty directories can be deleted.")
            }
            try authorize()
            guard unlinkat(parent, name, info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
                throw failure()
            }
        }
    }
#endif
