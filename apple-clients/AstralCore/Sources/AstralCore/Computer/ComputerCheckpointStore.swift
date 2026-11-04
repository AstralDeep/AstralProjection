// Stores content-addressed per-turn snapshots of granted workspace roots so owner-initiated restores can undo
// agent file changes without touching the project's own git history. Capture refuses excluded paths, never
// follows links, and enforces per-file, per-snapshot and per-root count caps before any effect runs.

#if os(macOS)
    import CryptoKit
    import Darwin
    import Foundation

    public struct ComputerCheckpointFile: Sendable, Equatable {
        public let path: String
        public let digest: String
        public let mode: Int
        public let size: Int
    }

    public struct ComputerCheckpointSkipped: Sendable, Equatable {
        public let path: String
        public let reason: String
    }

    public struct ComputerCheckpointRecord: Sendable, Equatable {
        public let id: String
        public let turnId: String
        public let rootPath: String
        public let rootIdentityDigest: String
        public let treeHash: String
        public let fileCount: Int
        public let capturedBytes: Int
        public let createdAt: Double
        public let files: [ComputerCheckpointFile]
        public let skipped: [ComputerCheckpointSkipped]
    }

    public struct ComputerCheckpointChange: Sendable, Equatable {
        public let path: String
        public let state: String
        public let addedLines: Int?
        public let removedLines: Int?
    }

    public struct ComputerCheckpointDiff: Sendable, Equatable {
        public let record: ComputerCheckpointRecord
        public let changes: [ComputerCheckpointChange]
        public let extras: [String]
        public let extrasComplete: Bool
    }

    public struct ComputerCheckpointFailure: Sendable, Equatable {
        public let path: String
        public let code: String
    }

    public struct ComputerCheckpointRestoreOutcome: Sendable, Equatable {
        public let restored: [String]
        public let failed: [ComputerCheckpointFailure]
        public let notAttempted: [String]
    }

    public final class ComputerCheckpointStore: @unchecked Sendable {
        public struct Limits: Sendable, Equatable {
            public let fileBytes: Int
            public let snapshotBytes: Int
            public let count: Int
            public let entries: Int
            public static let standard = Limits(
                fileBytes: 8_388_608, snapshotBytes: 268_435_456, count: 12, entries: 20_000)
        }

        private struct FileDocument: Codable {
            var path: String
            var digest: String
            var mode: Int
            var size: Int
        }
        private struct SkippedDocument: Codable {
            var path: String
            var reason: String
        }
        private struct IndexDocument: Codable {
            var version: Int
            var checkpointId: String
            var turnId: String
            var scope: String
            var rootPath: String
            var rootIdentity: String
            var treeHash: String
            var fileCount: Int
            var capturedBytes: Int
            var createdAt: Double
            var files: [FileDocument]
            var skipped: [SkippedDocument]

            enum CodingKeys: String, CodingKey {
                case version
                case checkpointId = "checkpoint_id"
                case turnId = "turn_id"
                case scope
                case rootPath = "root_path"
                case rootIdentity = "root_identity"
                case treeHash = "tree_hash"
                case fileCount = "file_count"
                case capturedBytes = "captured_bytes"
                case createdAt = "created_at"
                case files, skipped
            }
        }

        private let lock = NSLock()
        private let scopeTag: String
        private let checkpointsDirectory: URL
        private let blobsDirectory: URL
        private let limits: Limits
        private let turnGap: Double
        private let now: @Sendable () -> Double
        private var turnId: String?
        private var turnActivity: Double = 0

        public init(
            directory: URL, scope: String, limits: Limits = .standard, turnGapSeconds: Double = 90,
            now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
        ) throws {
            guard limits.fileBytes >= 1, limits.snapshotBytes >= 1, limits.count >= 1, limits.entries >= 1,
                turnGapSeconds.isFinite, turnGapSeconds >= 0
            else { throw ComputerHostError("out_of_range", "The checkpoint store limits are invalid.") }
            scopeTag = Self.digest(Data(scope.utf8))
            let scoped = directory.appendingPathComponent(String(scopeTag.prefix(16)), isDirectory: true)
            checkpointsDirectory = scoped.appendingPathComponent("checkpoints", isDirectory: true)
            blobsDirectory = scoped.appendingPathComponent("blobs", isDirectory: true)
            self.limits = limits
            turnGap = turnGapSeconds
            self.now = now
            for url in [scoped, checkpointsDirectory, blobsDirectory] {
                try Self.prepareDirectory(url)
            }
        }

        private static func prepareDirectory(_ url: URL) throws {
            let manager = FileManager.default
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            guard chmod(url.path, 0o700) == 0 else {
                throw ComputerHostError("failed", "The checkpoint store directory is not usable.")
            }
        }

        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func digest(_ bytes: [UInt8]) -> String {
            digest(Data(bytes))
        }

        public func noteActivity() -> String {
            lock.lock()
            defer { lock.unlock() }
            let time = now()
            if let turnId, time - turnActivity <= turnGap {
                turnActivity = time
                return turnId
            }
            let fresh = UUID().uuidString.lowercased()
            turnId = fresh
            turnActivity = time
            return fresh
        }

        public func endTurn() {
            lock.lock()
            defer { lock.unlock() }
            turnId = nil
        }

        public var currentTurnId: String? {
            lock.lock()
            defer { lock.unlock() }
            return turnId
        }

        public func snapshotIfNeeded(turnId: String, root: ComputerWorkspace) throws -> ComputerCheckpointRecord? {
            lock.lock()
            defer { lock.unlock() }
            let existing = recordsLocked().first {
                $0.turnId == turnId && $0.rootIdentityDigest == root.rootIdentity.digest
            }
            if existing != nil { return nil }
            return try captureLocked(turnId: turnId, root: root)
        }

        private func captureLocked(turnId: String, root: ComputerWorkspace) throws -> ComputerCheckpointRecord {
            var files: [ComputerCheckpointFile] = []
            var skipped: [ComputerCheckpointSkipped] = []
            var captured = 0
            do {
                try root.walkTree(limit: limits.entries) { entry in
                    switch entry.kind {
                    case .directory: break
                    case .excluded, .protected:
                        skipped.append(ComputerCheckpointSkipped(path: entry.path, reason: "excluded"))
                    case .repository:
                        skipped.append(ComputerCheckpointSkipped(path: entry.path, reason: "repository"))
                    case .symlink:
                        skipped.append(ComputerCheckpointSkipped(path: entry.path, reason: "symlink"))
                    case .other:
                        skipped.append(ComputerCheckpointSkipped(path: entry.path, reason: "unsupported"))
                    case .regular:
                        if entry.linked {
                            skipped.append(ComputerCheckpointSkipped(path: entry.path, reason: "hard_link"))
                            return
                        }
                        if entry.size > limits.fileBytes {
                            skipped.append(ComputerCheckpointSkipped(path: entry.path, reason: "oversize"))
                            return
                        }
                        do {
                            let capturedFile = try root.captureBytes(
                                root.root + "/" + entry.path, maximum: limits.fileBytes)
                            let digest = Self.digest(capturedFile.bytes)
                            try Self.storeBlob(directory: blobsDirectory, digest: digest, bytes: capturedFile.bytes)
                            files.append(
                                ComputerCheckpointFile(
                                    path: entry.path, digest: digest, mode: Int(capturedFile.mode),
                                    size: capturedFile.bytes.count))
                            captured += capturedFile.bytes.count
                            guard captured <= limits.snapshotBytes else {
                                throw ComputerHostError(
                                    "capacity_exceeded",
                                    "The workspace snapshot exceeds the \(limits.snapshotBytes)-byte cap, so this "
                                        + "change was refused before it ran.",
                                    effectState: "not_started")
                            }
                        } catch let error as ComputerHostError where error.code == "capacity_exceeded" {
                            throw error
                        } catch {
                            skipped.append(ComputerCheckpointSkipped(path: entry.path, reason: "unreadable"))
                        }
                    }
                }
            } catch {
                Self.collectBlobs(directory: blobsDirectory, referenced: Set(files.map(\.digest)))
                throw error
            }
            pruneLocked(rootDigest: root.rootIdentity.digest, keepingTurn: turnId)
            let sorted = files.sorted { $0.path < $1.path }
            let record = ComputerCheckpointRecord(
                id: UUID().uuidString.lowercased(), turnId: turnId, rootPath: root.root,
                rootIdentityDigest: root.rootIdentity.digest, treeHash: Self.treeHash(sorted), fileCount: sorted.count,
                capturedBytes: captured, createdAt: now(), files: sorted, skipped: skipped.sorted { $0.path < $1.path })
            try Self.writeIndex(
                IndexDocument(
                    version: 1, checkpointId: record.id, turnId: turnId, scope: scopeTag, rootPath: record.rootPath,
                    rootIdentity: record.rootIdentityDigest, treeHash: record.treeHash, fileCount: record.fileCount,
                    capturedBytes: record.capturedBytes, createdAt: record.createdAt,
                    files: record.files.map {
                        FileDocument(path: $0.path, digest: $0.digest, mode: $0.mode, size: $0.size)
                    },
                    skipped: record.skipped.map { SkippedDocument(path: $0.path, reason: $0.reason) }),
                to: checkpointsDirectory.appendingPathComponent(record.id + ".json"))
            Self.collectBlobs(directory: blobsDirectory, referenced: Self.referencedDigests(recordsLocked()))
            return record
        }

        private static func treeHash(_ files: [ComputerCheckpointFile]) -> String {
            let canonical =
                files
                .map { "\($0.path)\n\($0.digest)\n\(String($0.mode, radix: 8))\n\($0.size)" }
                .joined(separator: "\n")
            return digest(Data(canonical.utf8))
        }

        private static func storeBlob(directory: URL, digest: String, bytes: [UInt8]) throws {
            guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw ComputerHostError("failed", "The checkpoint content digest is invalid.")
            }
            let url = directory.appendingPathComponent(digest)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            let temporary = directory.appendingPathComponent(".blob-" + UUID().uuidString.lowercased())
            guard FileManager.default.createFile(
                atPath: temporary.path, contents: Data(bytes), attributes: [.posixPermissions: 0o600])
            else {
                throw ComputerHostError("failed", "The checkpoint store could not record content.")
            }
            _ = chmod(temporary.path, 0o600)
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                if FileManager.default.fileExists(atPath: url.path) { return }
                throw ComputerHostError("failed", "The checkpoint store could not record content.")
            }
        }

        private static func readBlob(directory: URL, digest: String) throws -> [UInt8] {
            guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw ComputerHostError("not_found", "The checkpoint content is missing.")
            }
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(digest).path)
            else {
                throw ComputerHostError("not_found", "The checkpoint content is missing.")
            }
            return Array(data)
        }

        private static func referencedDigests(_ records: [ComputerCheckpointRecord]) -> Set<String> {
            Set(records.flatMap { $0.files.map(\.digest) })
        }

        private static func collectBlobs(directory: URL, referenced: Set<String>) {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in urls where !referenced.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        private static func writeIndex(_ document: IndexDocument, to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(
                ".index-" + UUID().uuidString.lowercased())
            guard FileManager.default.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
            else {
                throw ComputerHostError("failed", "The checkpoint record could not be written.")
            }
            _ = chmod(temporary.path, 0o600)
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw ComputerHostError("failed", "The checkpoint record could not be written.")
            }
        }

        public func records() -> [ComputerCheckpointRecord] {
            lock.lock()
            defer { lock.unlock() }
            return recordsLocked()
        }

        public func record(_ id: String) -> ComputerCheckpointRecord? {
            lock.lock()
            defer { lock.unlock() }
            return recordLocked(id)
        }

        private func recordsLocked() -> [ComputerCheckpointRecord] {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: checkpointsDirectory, includingPropertiesForKeys: nil)) ?? []
            return urls
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> ComputerCheckpointRecord? in
                    guard let data = FileManager.default.contents(atPath: url.path),
                        let document = try? JSONDecoder().decode(IndexDocument.self, from: data),
                        document.version == 1, document.scope == scopeTag,
                        document.checkpointId == url.deletingPathExtension().lastPathComponent,
                        document.files.allSatisfy({ Self.validRelativePath($0.path) })
                    else { return nil }
                    return ComputerCheckpointRecord(
                        id: document.checkpointId, turnId: document.turnId, rootPath: document.rootPath,
                        rootIdentityDigest: document.rootIdentity, treeHash: document.treeHash,
                        fileCount: document.fileCount, capturedBytes: document.capturedBytes,
                        createdAt: document.createdAt,
                        files: document.files.map {
                            ComputerCheckpointFile(path: $0.path, digest: $0.digest, mode: $0.mode, size: $0.size)
                        },
                        skipped: document.skipped.map {
                            ComputerCheckpointSkipped(path: $0.path, reason: $0.reason)
                        })
                }
                .sorted { $0.createdAt > $1.createdAt }
        }

        private static func validRelativePath(_ path: String) -> Bool {
            !path.isEmpty && !path.hasPrefix("/")
            && path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
        }

        private func recordLocked(_ id: String) -> ComputerCheckpointRecord? {
            guard id.range(of: "^[0-9a-f-]{36}$", options: .regularExpression) != nil else { return nil }
            return recordsLocked().first { $0.id == id }
        }

        private func pruneLocked(rootDigest: String, keepingTurn: String) {
            var roots = recordsLocked().filter { $0.rootIdentityDigest == rootDigest }
            while roots.count >= limits.count {
                guard
                    let oldest = roots
                        .filter({ $0.turnId != keepingTurn })
                        .min(by: { $0.createdAt < $1.createdAt })
                else { break }
                try? FileManager.default.removeItem(
                    at: checkpointsDirectory.appendingPathComponent(oldest.id + ".json"))
                roots.removeAll { $0.id == oldest.id }
            }
        }

        public func diff(_ id: String, root: ComputerWorkspace) throws -> ComputerCheckpointDiff {
            lock.lock()
            defer { lock.unlock() }
            guard let record = recordLocked(id) else {
                throw ComputerHostError("not_found", "No checkpoint with that checkpoint_id exists.")
            }
            guard record.rootIdentityDigest == root.rootIdentity.digest else {
                throw ComputerHostError(
                    "permission_denied", "The folder identity changed since this checkpoint was taken.")
            }
            var changes: [ComputerCheckpointChange] = []
            for file in record.files {
                let current = Result { try root.captureBytes(root.root + "/" + file.path, maximum: limits.fileBytes) }
                switch current {
                case .success(let value):
                    let digest = Self.digest(value.bytes)
                    guard digest != file.digest else { continue }
                    var lines: (added: Int, removed: Int)?
                    if let previous = try? Self.readBlob(directory: blobsDirectory, digest: file.digest) {
                        lines = Self.lineCounts(previous: previous, current: value.bytes)
                    }
                    changes.append(
                        ComputerCheckpointChange(
                            path: file.path, state: "changed", addedLines: lines?.added,
                            removedLines: lines?.removed))
                case .failure(let error):
                    let missing = (error as? ComputerHostError)?.code == "not_found"
                    changes.append(
                        ComputerCheckpointChange(
                            path: file.path, state: missing ? "missing" : "changed", addedLines: nil,
                            removedLines: nil))
                }
            }
            var extras: [String] = []
            var extrasComplete = true
            let known = Set(record.files.map(\.path))
            do {
                try root.walkTree(limit: limits.entries) { entry in
                    if entry.kind == .regular, !known.contains(entry.path) { extras.append(entry.path) }
                }
            } catch { extrasComplete = false }
            return ComputerCheckpointDiff(
                record: record, changes: changes.sorted { $0.path < $1.path },
                extras: extras.sorted(), extrasComplete: extrasComplete)
        }

        static func lineCounts(previous: [UInt8], current: [UInt8]) -> (added: Int, removed: Int)? {
            guard let before = String(bytes: previous, encoding: .utf8),
                let after = String(bytes: current, encoding: .utf8),
                !before.contains("\0"), !after.contains("\0")
            else { return nil }
            let older = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let newer = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let budget = 4_000
            guard older.count <= budget, newer.count <= budget, older.count * newer.count <= 16_000_000
            else { return nil }
            var upper = [Int32](repeating: 0, count: newer.count + 1)
            var lower = [Int32](repeating: 0, count: newer.count + 1)
            for index in 1...older.count {
                lower[0] = 0
                for column in 1...newer.count {
                    lower[column] =
                        older[index - 1] == newer[column - 1]
                        ? upper[column - 1] + 1 : max(upper[column], lower[column - 1])
                }
                swap(&upper, &lower)
            }
            let shared = Int(upper[newer.count])
            return (newer.count - shared, older.count - shared)
        }

        public func restore(
            _ id: String, root: ComputerWorkspace, path: String?, authorize: () throws -> Void
        ) throws -> ComputerCheckpointRestoreOutcome {
            lock.lock()
            defer { lock.unlock() }
            guard let record = recordLocked(id) else {
                throw ComputerHostError("not_found", "No checkpoint with that checkpoint_id exists.")
            }
            guard record.rootIdentityDigest == root.rootIdentity.digest else {
                throw ComputerHostError(
                    "permission_denied", "The folder identity changed since this checkpoint was taken.")
            }
            var targets = record.files
            if let path {
                guard let chosen = targets.first(where: { $0.path == path }) else {
                    throw ComputerHostError("not_found", "That checkpoint does not include \(path).")
                }
                targets = [chosen]
            }
            var restored: [String] = []
            for (index, file) in targets.enumerated() {
                do {
                    try authorize()
                    let bytes = try Self.readBlob(directory: blobsDirectory, digest: file.digest)
                    try root.restoreBytes(
                        root.root + "/" + file.path, bytes: bytes, mode: mode_t(file.mode), authorize: authorize)
                    restored.append(file.path)
                } catch {
                    let code = (error as? ComputerHostError)?.code ?? "failed"
                    return ComputerCheckpointRestoreOutcome(
                        restored: restored, failed: [ComputerCheckpointFailure(path: file.path, code: code)],
                        notAttempted: targets[(index + 1)...].map(\.path))
                }
            }
            return ComputerCheckpointRestoreOutcome(restored: restored, failed: [], notAttempted: [])
        }
    }

#endif
