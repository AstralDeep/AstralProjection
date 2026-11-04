// Binds the AstralCore checkpoint store to the signed-in owner and server scope and runs the three checkpoint
// verbs with grant and root-identity verification. MacComputerHost snapshots the affected root before the first
// mutating action of a turn, and the owner's restore UI reviews the same diff before restoring.

#if os(macOS)
    import AstralCore
    import Foundation
    import os

    struct MacCheckpointSummary: Equatable, Sendable {
        let id: String
        let turnId: String
        let rootPath: String
        let fileCount: Int
        let capturedBytes: Int
        let createdAt: Double
        let currentTurn: Bool
    }

    struct MacCheckpointRestorePreview: Equatable, Sendable, Identifiable {
        let summary: MacCheckpointSummary
        let changes: [ComputerCheckpointChange]
        let extras: [String]

        var id: String { summary.id }
    }

    final class MacComputerCheckpoints: @unchecked Sendable {
        static let verbs: Set<String> = ["list_checkpoints", "diff_checkpoint", "restore_checkpoint"]
        private static let log = Logger(subsystem: "com.personalailabs.astraldeep", category: "computer.checkpoints")
        private let lock = NSLock()
        private let directory: URL
        private let limits: ComputerCheckpointStore.Limits
        private var scope: String?
        private var store: ComputerCheckpointStore?

        init(directory: URL = Self.defaultDirectory, limits: ComputerCheckpointStore.Limits = .standard) {
            self.directory = directory
            self.limits = limits
        }

        static var defaultDirectory: URL {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return support
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "AstralDeep", isDirectory: true)
                .appendingPathComponent("ComputerCheckpoints", isDirectory: true)
        }

        private func withStore<T>(_ body: (ComputerCheckpointStore) throws -> T) rethrows -> T? {
            lock.lock()
            let current = store
            lock.unlock()
            guard let current else { return nil }
            return try body(current)
        }

        func bind(_ owner: String?) {
            lock.lock()
            defer { lock.unlock() }
            guard scope != owner else { return }
            scope = owner
            store = nil
            guard let owner else { return }
            do {
                store = try ComputerCheckpointStore(directory: directory, scope: owner, limits: limits)
            } catch {
                Self.log.error("checkpoint store unavailable: \(error.localizedDescription)")
            }
        }

        func noteActivity() {
            _ = withStore { $0.noteActivity() }
        }

        func endTurn() {
            _ = withStore { $0.endTurn() }
        }

        func snapshotBeforeMutation(root: ComputerWorkspace, authorize: () throws -> Void) throws {
            guard let checkpointStore = withStore({ $0 }) else { return }
            try authorize()
            let turn = checkpointStore.noteActivity()
            if let record = try checkpointStore.snapshotIfNeeded(turnId: turn, root: root) {
                Self.log.info(
                    "checkpoint.created turn=\(record.turnId, privacy: .private) root=\(record.rootIdentityDigest, privacy: .public) tree=\(record.treeHash, privacy: .public) files=\(record.fileCount)")
            }
        }

        private static func deniedRoot(workspaces: [ComputerWorkspace]) -> ComputerHostError {
            let message =
                workspaces.isEmpty
                ? "The folder grant for that checkpoint was revoked, so the request was refused."
                : "The folder identity changed since that checkpoint was taken, so the request was refused."
            return ComputerHostError("permission_denied", message)
        }

        func listCheckpoints(
            workspaces: [ComputerWorkspace], authorize: () throws -> Void
        ) throws -> [String: JSONValue] {
            try authorize()
            guard let store = withStore({ $0 }) else {
                return ["checkpoints": .array([])]
            }
            let granted = Set(workspaces.map { $0.rootIdentity.digest })
            let current = store.currentTurnId
            let rows: [JSONValue] = store.records().filter { granted.contains($0.rootIdentityDigest) }.map { record in
                .object([
                    "checkpoint_id": .string(record.id), "turn_id": .string(record.turnId),
                    "root_path": .string(record.rootPath), "tree_hash": .string(record.treeHash),
                    "file_count": .number(Double(record.fileCount)),
                    "captured_bytes": .number(Double(record.capturedBytes)),
                    "created_at": .number(record.createdAt),
                    "current_turn": .bool(record.turnId == current),
                    "skipped_count": .number(Double(record.skipped.count)),
                ])
            }
            return ["checkpoints": .array(rows)]
        }

        func diffCheckpoint(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace], authorize: () throws -> Void
        ) throws -> [String: JSONValue] {
            try authorize()
            let id = request.args["checkpoint_id"]!.stringValue!
            let path = request.args["path"]?.stringValue
            guard let store = withStore({ $0 }) else {
                throw ComputerHostError("not_found", "No checkpoint with that checkpoint_id exists on this Mac.")
            }
            guard let record = store.record(id) else {
                throw ComputerHostError("not_found", "No checkpoint with that checkpoint_id exists on this Mac.")
            }
            guard let root = workspaces.first(where: { $0.rootIdentity.digest == record.rootIdentityDigest }) else {
                throw Self.deniedRoot(workspaces: workspaces)
            }
            let diff = try store.diff(id, root: root)
            let changes = diff.changes.filter { path == nil || $0.path == path }
            return [
                "checkpoint_id": .string(record.id), "root_path": .string(record.rootPath),
                "changes": .array(
                    changes.map { change in
                        .object([
                            "path": .string(change.path), "state": .string(change.state),
                            "added_lines": change.addedLines.map { .number(Double($0)) } ?? .null,
                            "removed_lines": change.removedLines.map { .number(Double($0)) } ?? .null,
                        ])
                    }),
                "extras": .array(diff.extras.map(JSONValue.string)),
                "extras_complete": .bool(diff.extrasComplete),
            ]
        }

        func restoreCheckpoint(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace], authorize: () throws -> Void
        ) throws -> [String: JSONValue] {
            try authorize()
            let id = request.args["checkpoint_id"]!.stringValue!
            let path = request.args["path"]?.stringValue
            let outcome = try restore(id, path: path, workspaces: workspaces, authorize: authorize)
            return [
                "checkpoint_id": .string(id),
                "restored": .array(outcome.restored.map(JSONValue.string)),
                "failed": .array(
                    outcome.failed.map { failure in
                        .object(["path": .string(failure.path), "code": .string(failure.code)])
                    }),
                "not_attempted": .array(outcome.notAttempted.map(JSONValue.string)),
            ]
        }

        private func restore(
            _ id: String, path: String?, workspaces: [ComputerWorkspace], authorize: () throws -> Void
        ) throws -> ComputerCheckpointRestoreOutcome {
            guard let store = withStore({ $0 }) else {
                throw ComputerHostError("not_found", "No checkpoint with that checkpoint_id exists on this Mac.")
            }
            guard let record = store.record(id) else {
                throw ComputerHostError("not_found", "No checkpoint with that checkpoint_id exists on this Mac.")
            }
            guard let root = workspaces.first(where: { $0.rootIdentity.digest == record.rootIdentityDigest }) else {
                throw Self.deniedRoot(workspaces: workspaces)
            }
            let outcome = try store.restore(id, root: root, path: path, authorize: authorize)
            Self.log.info(
                "checkpoint.restored restored=\(outcome.restored.count) skipped=\(outcome.failed.count + outcome.notAttempted.count)")
            return outcome
        }

        func summaries(workspaces: [ComputerWorkspace]) -> [MacCheckpointSummary] {
            let granted = Set(workspaces.map { $0.rootIdentity.digest })
            guard let store = withStore({ $0 }) else { return [] }
            let current = store.currentTurnId
            return store.records().filter { granted.contains($0.rootIdentityDigest) }.map { record in
                MacCheckpointSummary(
                    id: record.id, turnId: record.turnId, rootPath: record.rootPath, fileCount: record.fileCount,
                    capturedBytes: record.capturedBytes, createdAt: record.createdAt,
                    currentTurn: record.turnId == current)
            }
        }

        func preview(
            checkpointId: String, workspaces: [ComputerWorkspace]
        ) throws -> MacCheckpointRestorePreview {
            guard let store = withStore({ $0 }) else {
                throw ComputerHostError("not_found", "No checkpoint with that checkpoint_id exists on this Mac.")
            }
            guard let record = store.record(checkpointId) else {
                throw ComputerHostError("not_found", "No checkpoint with that checkpoint_id exists on this Mac.")
            }
            guard let root = workspaces.first(where: { $0.rootIdentity.digest == record.rootIdentityDigest }) else {
                throw Self.deniedRoot(workspaces: workspaces)
            }
            let diff = try store.diff(checkpointId, root: root)
            let current = store.currentTurnId
            return MacCheckpointRestorePreview(
                summary: MacCheckpointSummary(
                    id: record.id, turnId: record.turnId, rootPath: record.rootPath, fileCount: record.fileCount,
                    capturedBytes: record.capturedBytes, createdAt: record.createdAt,
                    currentTurn: record.turnId == current),
                changes: diff.changes, extras: diff.extras)
        }

        func restore(checkpointId: String, workspaces: [ComputerWorkspace]) throws
            -> ComputerCheckpointRestoreOutcome
        {
            try restore(checkpointId, path: nil, workspaces: workspaces, authorize: {})
        }
    }

#endif
