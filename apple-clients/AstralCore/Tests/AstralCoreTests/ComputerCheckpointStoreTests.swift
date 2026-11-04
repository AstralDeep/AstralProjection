// Exercises the content-addressed checkpoint store against a real workspace: round-trips, exclusions, link
// refusals, caps, turn windows, pruning, diffs, and restore denials and interruptions.

#if os(macOS)
    import CryptoKit
    import XCTest

    @testable import AstralCore

    final class ComputerCheckpointStoreTests: XCTestCase {
        static let scope = "test-owner|https://example.test"

        final class MutableClock: @unchecked Sendable {
            var time: Double
            init(_ time: Double = 1_000_000) { self.time = time }
            func now() -> Double { time }
        }

        private func makeFolder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }

        private func makeStore(
            _ directory: URL? = nil, limits: ComputerCheckpointStore.Limits = .standard, clock: MutableClock? = nil
        ) throws -> ComputerCheckpointStore {
            try ComputerCheckpointStore(
                directory: directory ?? try makeFolder(), scope: "test-owner|https://example.test", limits: limits,
                turnGapSeconds: 90, now: { clock?.now() ?? 1_000_000 })
        }

        private func scopedDirectory(_ directory: URL) -> URL {
            let digest = SHA256.hash(data: Data(Self.scope.utf8)).map { String(format: "%02x", $0) }.joined()
            return directory.appendingPathComponent(String(digest.prefix(16)), isDirectory: true)
        }

        private func mode(of path: String) -> mode_t {
            var info = stat()
            guard stat(path, &info) == 0 else { return 0 }
            return info.st_mode & 0o7777
        }

        func testSnapshotAndRestoreRoundTripContentAndPermissions() throws {
            let folder = try makeFolder()
            let workspace = try ComputerWorkspace(root: folder.path)
            let text = workspace.root + "/notes.md"
            try workspace.write(text, content: "first\nsecond\n", overwrite: false, authorize: {})
            XCTAssertEqual(chmod(text, 0o640), 0)
            let binary = workspace.root + "/blob.bin"
            let payload = Data([0x00, 0x01, 0xFE, 0xFF, 0x7F, 0x80] + Array(repeating: 0x42, count: 1000))
            try payload.write(to: URL(fileURLWithPath: binary))
            XCTAssertEqual(chmod(binary, 0o750), 0)

            let store = try makeStore()
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))
            XCTAssertEqual(record.fileCount, 2)
            XCTAssertEqual(record.files.map(\.path), ["blob.bin", "notes.md"])

            try workspace.write(text, content: "changed", overwrite: true, authorize: {})
            try Data([0x99]).write(to: URL(fileURLWithPath: binary))
            XCTAssertEqual(chmod(binary, 0o777), 0)

            let outcome = try store.restore(record.id, root: workspace, path: nil, authorize: {})
            XCTAssertEqual(outcome.restored, ["blob.bin", "notes.md"])
            XCTAssertTrue(outcome.failed.isEmpty)
            XCTAssertEqual(try String(contentsOfFile: text, encoding: .utf8), "first\nsecond\n")
            XCTAssertEqual(mode(of: text), 0o640)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: binary)), payload)
            XCTAssertEqual(mode(of: binary), 0o750)
        }

        func testExcludedPathsOverCapFilesAndLinksAreNeverStored() throws {
            let folder = try makeFolder()
            let outside = try makeFolder()
            try Data("outside".utf8).write(to: outside.appendingPathComponent("target.txt"))
            for path in ["private/secret.txt", "nested"] {
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            try Data("hidden".utf8).write(to: folder.appendingPathComponent(".env"))
            try Data("secret".utf8).write(to: folder.appendingPathComponent("private/secret.txt"))
            try Data("key".utf8).write(to: folder.appendingPathComponent("server.pem"))
            try Data("kept".utf8).write(to: folder.appendingPathComponent("normal.txt"))
            try Data(repeating: 0x21, count: 12).write(to: folder.appendingPathComponent("big.bin"))
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent("link.txt"), withDestinationURL: outside.appendingPathComponent("target.txt"))
            try Data("paired".utf8).write(to: folder.appendingPathComponent("dup.txt"))
            try FileManager.default.linkItem(
                at: folder.appendingPathComponent("dup.txt"), to: folder.appendingPathComponent("hard.txt"))

            let workspace = try ComputerWorkspace(root: folder.path)
            let storeDirectory = try makeFolder()
            let store = try makeStore(
                storeDirectory,
                limits: ComputerCheckpointStore.Limits(fileBytes: 8, snapshotBytes: 1_000_000, count: 12, entries: 100))
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))
            XCTAssertEqual(record.files.map(\.path), ["normal.txt"])
            let reasons = Dictionary(uniqueKeysWithValues: record.skipped.map { ($0.path, $0.reason) })
            XCTAssertEqual(reasons[".env"], "excluded")
            XCTAssertEqual(reasons["private"], "excluded")
            XCTAssertEqual(reasons["server.pem"], "excluded")
            XCTAssertEqual(reasons["big.bin"], "oversize")
            XCTAssertEqual(reasons["link.txt"], "symlink")
            XCTAssertEqual(reasons["hard.txt"], "hard_link")
            XCTAssertEqual(reasons["dup.txt"], "hard_link")

            let blobs = try FileManager.default.contentsOfDirectory(
                at: scopedDirectory(storeDirectory).appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
            for blob in blobs {
                let data = try Data(contentsOf: blob)
                XCTAssertNotEqual(data, Data("secret".utf8))
                XCTAssertNotEqual(data, Data("hidden".utf8))
                XCTAssertNotEqual(data, Data("outside".utf8))
            }
            let outcome = try store.restore(record.id, root: workspace, path: nil, authorize: {})
            XCTAssertEqual(try String(contentsOfFile: folder.appendingPathComponent("link.txt").path, encoding: .utf8), "outside")
        }

        func testGitRepositoryContentsAreNeverCaptured() throws {
            let folder = try makeFolder()
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(".git/objects/ab"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/main".utf8).write(to: folder.appendingPathComponent(".git/HEAD"))
            try Data("pack".utf8).write(to: folder.appendingPathComponent(".git/objects/ab/pack"))
            try Data("gitdir: elsewhere".utf8).write(to: folder.appendingPathComponent("nested/.git"))

            let workspace = try ComputerWorkspace(root: folder.path)
            let store = try makeStore()
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))
            XCTAssertEqual(record.files.map(\.path), [])
            XCTAssertEqual(record.skipped.map(\.path), [".git", "nested/.git"])
            XCTAssertEqual(record.skipped.map(\.reason), ["repository", "repository"])
        }

        func testRestoreRefusedAfterTheRootIdentityChanges() throws {
            let folder = try makeFolder()
            let workspace = try ComputerWorkspace(root: folder.path)
            try workspace.write(workspace.root + "/file.txt", content: "original", overwrite: false, authorize: {})
            let store = try makeStore()
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))

            try FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("replaced".utf8).write(to: folder.appendingPathComponent("file.txt"))
            let fresh = try ComputerWorkspace(root: folder.path)
            XCTAssertNotEqual(fresh.rootIdentity.digest, workspace.rootIdentity.digest)
            XCTAssertThrowsError(try store.restore(record.id, root: fresh, path: nil, authorize: {})) { error in
                XCTAssertEqual((error as? ComputerHostError)?.code, "permission_denied")
            }
            XCTAssertEqual(try String(contentsOfFile: folder.appendingPathComponent("file.txt").path, encoding: .utf8), "replaced")
        }

        func testInterruptedRestoreStopsAndReportsWithoutRetrying() throws {
            let folder = try makeFolder()
            let workspace = try ComputerWorkspace(root: folder.path)
            for name in ["a.txt", "b.txt", "c.txt"] {
                try workspace.write(workspace.root + "/" + name, content: "original \(name)", overwrite: false, authorize: {})
            }
            let store = try makeStore()
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))
            for name in ["a.txt", "b.txt", "c.txt"] {
                try workspace.write(workspace.root + "/" + name, content: "edited \(name)", overwrite: true, authorize: {})
            }
            try FileManager.default.removeItem(at: folder.appendingPathComponent("b.txt"))
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("b.txt"))

            let outcome = try store.restore(record.id, root: workspace, path: nil, authorize: {})
            XCTAssertEqual(outcome.restored, ["a.txt"])
            XCTAssertEqual(outcome.failed.map(\.path), ["b.txt"])
            XCTAssertEqual(outcome.failed.map(\.code), ["permission_denied"])
            XCTAssertEqual(outcome.notAttempted, ["c.txt"])
            XCTAssertEqual(try String(contentsOfFile: folder.appendingPathComponent("a.txt").path, encoding: .utf8), "original a.txt")
            XCTAssertTrue(FileManager.default.isDirectory(atPath: folder.appendingPathComponent("b.txt").path))
            XCTAssertEqual(try String(contentsOfFile: folder.appendingPathComponent("c.txt").path, encoding: .utf8), "edited c.txt")
        }

        func testSingleFileRestoreLeavesOtherHandEditsIntact() throws {
            let folder = try makeFolder()
            let workspace = try ComputerWorkspace(root: folder.path)
            for name in ["one.txt", "two.txt"] {
                try workspace.write(workspace.root + "/" + name, content: "checkpointed", overwrite: false, authorize: {})
            }
            let store = try makeStore()
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))
            try workspace.write(workspace.root + "/one.txt", content: "agent edit", overwrite: true, authorize: {})
            try workspace.write(workspace.root + "/two.txt", content: "hand edit", overwrite: true, authorize: {})

            let outcome = try store.restore(record.id, root: workspace, path: "one.txt", authorize: {})
            XCTAssertEqual(outcome.restored, ["one.txt"])
            XCTAssertEqual(try String(contentsOfFile: folder.appendingPathComponent("one.txt").path, encoding: .utf8), "checkpointed")
            XCTAssertEqual(try String(contentsOfFile: folder.appendingPathComponent("two.txt").path, encoding: .utf8), "hand edit")
        }

        func testSnapshotOverTheSizeCapRefusesBeforeAnyEffect() throws {
            let folder = try makeFolder()
            let workspace = try ComputerWorkspace(root: folder.path)
            for name in ["one.txt", "two.txt"] {
                try Data(repeating: 0x41, count: 60).write(to: folder.appendingPathComponent(name))
            }
            let store = try makeStore(
                limits: ComputerCheckpointStore.Limits(fileBytes: 64, snapshotBytes: 100, count: 12, entries: 100))
            XCTAssertThrowsError(
                try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace)
            ) { error in
                let hostError = error as? ComputerHostError
                XCTAssertEqual(hostError?.code, "capacity_exceeded")
                XCTAssertEqual(hostError?.effectState, "not_started")
            }
            XCTAssertTrue(store.records().isEmpty)
        }

        func testPruningRemovesOldestCompletedCheckpointsAndKeepsTheCurrentTurn() throws {
            let folder = try makeFolder()
            let workspace = try ComputerWorkspace(root: folder.path)
            try workspace.write(workspace.root + "/file.txt", content: "v0", overwrite: false, authorize: {})
            let clock = MutableClock()
            let store = try makeStore(
                limits: ComputerCheckpointStore.Limits(fileBytes: 1024, snapshotBytes: 1_000_000, count: 3, entries: 100),
                clock: clock)
            var ids: [String] = []
            for round in 1...4 {
                let turn = store.noteActivity()
                let record = try store.snapshotIfNeeded(turnId: turn, root: workspace)
                if let record { ids.append(record.id) }
                store.endTurn()
                try workspace.write(workspace.root + "/file.txt", content: "v\(round)", overwrite: true, authorize: {})
                clock.time += 1
            }
            let kept = store.records()
            XCTAssertEqual(kept.count, 3)
            XCTAssertEqual(Set(kept.map(\.id)), Set(ids.dropFirst()))
            XCTAssertEqual(kept.map(\.createdAt), kept.map(\.createdAt).sorted(by: >))
        }

        func testTurnWindowOpensANewCheckpointAfterTheIdleGap() throws {
            let folder = try makeFolder()
            let workspace = try ComputerWorkspace(root: folder.path)
            try workspace.write(workspace.root + "/file.txt", content: "v0", overwrite: false, authorize: {})
            let clock = MutableClock()
            let store = try makeStore(clock: clock)

            let firstTurn = store.noteActivity()
            let first = try store.snapshotIfNeeded(turnId: firstTurn, root: workspace)
            XCTAssertNotNil(first)
            clock.time += 30
            XCTAssertEqual(store.noteActivity(), firstTurn)
            XCTAssertNil(try store.snapshotIfNeeded(turnId: firstTurn, root: workspace))
            clock.time += 200
            let secondTurn = store.noteActivity()
            XCTAssertNotEqual(secondTurn, firstTurn)
            let second = try store.snapshotIfNeeded(turnId: secondTurn, root: workspace)
            XCTAssertNotNil(second)
            XCTAssertEqual(store.records().count, 2)
            XCTAssertEqual(Set(store.records().map(\.turnId)), [firstTurn, secondTurn])
            store.endTurn()
            XCTAssertNil(store.currentTurnId)
        }

        func testDiffReportsChangedPathsLineCountsAndExtras() throws {
            let folder = try makeFolder()
            let workspace = try ComputerWorkspace(root: folder.path)
            try workspace.write(workspace.root + "/keep.txt", content: "same", overwrite: false, authorize: {})
            try workspace.write(workspace.root + "/lines.txt", content: "a\nb\nc\n", overwrite: false, authorize: {})
            try workspace.write(workspace.root + "/gone.txt", content: "bye", overwrite: false, authorize: {})
            let store = try makeStore()
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))

            try workspace.write(workspace.root + "/lines.txt", content: "a\nx\ny\nc\nd\n", overwrite: true, authorize: {})
            try FileManager.default.removeItem(at: folder.appendingPathComponent("gone.txt"))
            try Data("brand new".utf8).write(to: folder.appendingPathComponent("new.txt"))

            let diff = try store.diff(record.id, root: workspace)
            XCTAssertEqual(diff.changes.map(\.path), ["gone.txt", "lines.txt"])
            XCTAssertEqual(diff.changes.first?.state, "missing")
            let lines = try XCTUnwrap(diff.changes.last)
            XCTAssertEqual(lines.state, "changed")
            XCTAssertEqual(lines.addedLines, 3)
            XCTAssertEqual(lines.removedLines, 1)
            XCTAssertEqual(diff.extras, ["new.txt"])
        }

        func testLineCountsCoverIdenticalAndOversizedContent() {
            let same = Array("one\ntwo\n".utf8)
            XCTAssertEqual(
                ComputerCheckpointStore.lineCounts(previous: same, current: same), (added: 0, removed: 0))
            XCTAssertEqual(
                ComputerCheckpointStore.lineCounts(previous: same, current: Array("one\ntwo".utf8)),
                (added: 0, removed: 1))
            XCTAssertEqual(
                ComputerCheckpointStore.lineCounts(previous: same, current: Array("one\ntwo\nthree\n".utf8)),
                (added: 1, removed: 0))
            XCTAssertNil(
                ComputerCheckpointStore.lineCounts(
                    previous: Array(repeating: 0xFF, count: 10), current: Array(repeating: 0xFE, count: 10)))
            let huge = Array(repeating: "line\n", count: 4001).joined()
            XCTAssertNil(
                ComputerCheckpointStore.lineCounts(previous: Array(huge.utf8), current: Array(huge.utf8)))
            let binary = Array([0x61, 0x00, 0x62].utf8)
            XCTAssertNil(ComputerCheckpointStore.lineCounts(previous: binary, current: binary))
        }

        func testStoreLayoutIsOwnerOnly() throws {
            let folder = try makeFolder()
            let workspace = try ComputerWorkspace(root: folder.path)
            try workspace.write(workspace.root + "/file.txt", content: "content", overwrite: false, authorize: {})
            let directory = try makeFolder()
            let store = try makeStore(directory: directory)
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))
            let scoped = scopedDirectory(directory)
            XCTAssertEqual(mode(of: scoped.path), 0o700)
            let index = scoped.appendingPathComponent("checkpoints").appendingPathComponent(record.id + ".json").path
            XCTAssertEqual(mode(of: index), 0o600)
            let blob = try XCTUnwrap(
                (try? FileManager.default.contentsOfDirectory(
                    at: scoped.appendingPathComponent("blobs"), includingPropertiesForKeys: nil))?.first)
            XCTAssertEqual(mode(of: blob.path), 0o600)
        }
    }

#endif
