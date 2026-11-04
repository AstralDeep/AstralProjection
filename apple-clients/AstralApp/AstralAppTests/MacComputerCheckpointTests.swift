// Tests the Mac host's checkpoint wiring: a turn checkpoint precedes every mutating file effect and command,
// capacity refusals happen before effects run, and the owner's restore path honors grants and root identity.

#if os(macOS)
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerCheckpointTests: XCTestCase {
        private var counter = 0
        private var sent: [JSONValue] = []

        private func folder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }

        private func makeHost(
            roots: [URL] = [], limits: ComputerCheckpointStore.Limits = .standard,
            commands: MacComputerCommands? = nil
        ) throws -> (host: MacComputerHost, storeDirectory: URL) {
            let suite = "checkpoint-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
            let grants = MacComputerWorkspaceGrantIO(
                chooseDirectories: { roots },
                resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
                makeBookmark: { Data($0.path.utf8) }, startAccess: { _ in true }, stopAccess: { _ in })
            let files = MacComputerFiles(defaults: defaults, grants: grants)
            files.bind("checkpoint-owner")
            if !roots.isEmpty { files.choose() }
            let storeDirectory = try folder()
            let checkpoints = MacComputerCheckpoints(directory: storeDirectory, limits: limits)
            let system = MacComputerTestSystem()
            let host = MacComputerHost(
                available: true, defaults: defaults, files: files,
                driver: MacComputerDriver(marker: 7, system: system, overlay: nil, bypass: { false }),
                monitor: MacComputerTaskMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: system,
                panelPresenter: { _ in },
                commands: commands
                    ?? MacComputerCommands(
                        spawner: MacComputerFakeSpawner(), clock: MacComputerFakeClock { $0 >= 20 }, inherited: [:],
                        loginPath: { "/usr/bin:/bin" }),
                checkpoints: checkpoints, appActivator: {}, authority: ComputerHostAuthority())
            host.bind(owner: "checkpoint-owner") { [weak self] text in
                if let frame = try? JSONValue.parse(Data(text.utf8)) { self?.sent.append(frame) }
                return true
            }
            host.setEnabled(true)
            addTeardownBlock { host.applicationWillTerminate() }
            return (host, storeDirectory)
        }

        private func frame(_ value: JSONValue) throws -> InboundFrame {
            try XCTUnwrap(InboundFrame.parse(String(decoding: value.encoded(), as: UTF8.self)))
        }

        private func startSession(_ host: MacComputerHost) throws -> String {
            let id = UUID().uuidString.lowercased()
            let payload: [String: JSONValue] = [
                "type": .string("computer_session"),
                "host_id": .string(try XCTUnwrap(host.descriptor).hostId), "session_id": .string(id),
                "state": .string("active"), "controller_label": .string("Test controller"),
            ]
            XCTAssertTrue(host.consume(try frame(.object(payload))))
            return id
        }

        private func send(
            _ host: MacComputerHost, _ session: String, _ verb: String, _ args: [String: JSONValue]
        ) async throws -> JSONValue {
            counter += 1
            let id = "creq_" + String(format: "%032x", counter)
            let request = try frame(
                .object([
                    "type": .string("computer_request"), "request_id": .string(id), "session_id": .string(session),
                    "verb": .string(verb), "args": .object(args), "deadline_ms": .number(30000),
                ]))
            XCTAssertTrue(host.consume(request))
            for _ in 0..<2000 {
                if let payload = sent.first(where: { $0["payload"]?["request_id"] == .string(id) })?["payload"] {
                    return payload
                }
                _ = await host.flushCurrentSends()
                await Task.yield()
            }
            XCTFail("No computer response for \(verb)")
            return .object([:])
        }

        private func checkpointRequest(_ verb: String, _ args: [String: JSONValue]) throws -> ComputerHostRequest {
            try ComputerHostRequest(
                json: .object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(repeating: "b", count: 32)),
                    "session_id": .string("88888888-8888-4888-8888-888888888888"), "verb": .string(verb),
                    "args": .object(args), "deadline_ms": .number(30000),
                ]))
        }

        func testCheckpointVerbsStayUnadvertisedUntilServerRegistration() throws {
            let root = try folder().resolvingSymlinksInPath()
            let (host, _) = try makeHost(roots: [root])
            let verbs = try XCTUnwrap(host.descriptor).verbs
            XCTAssertTrue(verbs.contains("write_file"))
            for verb in MacComputerCheckpoints.verbs {
                XCTAssertFalse(verbs.contains(verb), verb)
            }
            XCTAssertTrue(MacComputerCheckpoints.verbs.isSubset(of: ComputerHostRequest.verbs))
        }

        func testEndingTheSessionClosesTheTurnSoTheCheckpointBecomesRestorableHistory() async throws {
            let root = try folder().resolvingSymlinksInPath()
            try Data("before".utf8).write(to: root.appendingPathComponent("seeded.txt"))
            let (host, _) = try makeHost(roots: [root])
            let canonical = try XCTUnwrap(host.files.roots.first)
            let session = try startSession(host)
            _ = try await send(
                host, session, "write_file",
                ["path": canonical + "/seeded.txt", "content": "after", "if_exists": .string("overwrite")])
            XCTAssertTrue(try XCTUnwrap(host.checkpointSummaries(root: canonical).first).currentTurn)

            host.stop()
            XCTAssertFalse(try XCTUnwrap(host.checkpointSummaries(root: canonical).first).currentTurn)
            XCTAssertEqual(host.checkpointSummaries(root: canonical).count, 1)
        }

        func testWriteFileTakesATurnCheckpointBeforeTheEffectAndOwnerRestoreUndoesIt() async throws {
            let root = try folder().resolvingSymlinksInPath()
            try Data("before".utf8).write(to: root.appendingPathComponent("seeded.txt"))
            let (host, _) = try makeHost(roots: [root])
            let canonical = try XCTUnwrap(host.files.roots.first)
            let session = try startSession(host)
            let response = try await send(
                host, session, "write_file",
                ["path": canonical + "/seeded.txt", "content": "after", "if_exists": .string("overwrite")])
            XCTAssertEqual(response["ok"], .bool(true))

            let summaries = host.checkpointSummaries(root: canonical)
            XCTAssertEqual(summaries.count, 1)
            XCTAssertTrue(summaries.first?.currentTurn == true)
            XCTAssertEqual(summaries.first?.fileCount, 1)

            try Data("hand edit".utf8).write(to: root.appendingPathComponent("seeded.txt"))
            try Data("fresh".utf8).write(to: root.appendingPathComponent("created.txt"))
            let message = await host.restoreCheckpointFiles(try XCTUnwrap(summaries.first).id)
            XCTAssertEqual(message, "Restored 1 file from the checkpoint.")
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent("seeded.txt"), encoding: .utf8), "before")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("created.txt")), Data("fresh".utf8))
        }

        func testOwnerRestorePreviewShowsWhatWillBeOverwritten() async throws {
            let root = try folder().resolvingSymlinksInPath()
            try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent("notes.md"))
            let (host, _) = try makeHost(roots: [root])
            let canonical = try XCTUnwrap(host.files.roots.first)
            let session = try startSession(host)
            let overwrite: [String: JSONValue] = [
                "path": canonical + "/notes.md",
                "content": "one\nx\ny\ntwo\nthree\n",
                "if_exists": .string("overwrite"),
            ]
            _ = try await send(host, session, "write_file", overwrite)
            try Data("added later".utf8).write(to: root.appendingPathComponent("extra.txt"))

            let summary = try XCTUnwrap(host.checkpointSummaries(root: canonical).first)
            let preview = try XCTUnwrap(host.checkpointRestorePreview(checkpointId: summary.id))
            XCTAssertEqual(preview.summary.id, summary.id)
            XCTAssertEqual(preview.changes.map(\.path), ["notes.md"])
            XCTAssertEqual(preview.changes.first?.state, "changed")
            XCTAssertEqual(preview.changes.first?.addedLines, 3)
            XCTAssertEqual(preview.changes.first?.removedLines, 0)
            XCTAssertEqual(preview.extras, ["extra.txt"])
        }

        func testCheckpointCapacityRefusesTheWriteBeforeAnyEffect() async throws {
            let root = try folder().resolvingSymlinksInPath()
            try Data(repeating: 0x41, count: 6).write(to: root.appendingPathComponent("seeded.txt"))
            let (host, _) = try makeHost(
                roots: [root],
                limits: ComputerCheckpointStore.Limits(fileBytes: 8, snapshotBytes: 4, count: 2, entries: 100))
            let canonical = try XCTUnwrap(host.files.roots.first)
            let session = try startSession(host)
            let response = try await send(
                host, session, "write_file",
                ["path": canonical + "/created.txt", "content": "payload", "if_exists": .string("overwrite")])
            XCTAssertEqual(response["ok"], .bool(false))
            XCTAssertEqual(response["error"]?["code"], .string("capacity_exceeded"))
            XCTAssertEqual(response["error"]?["effect_state"], .string("not_started"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: canonical + "/created.txt"))
            XCTAssertTrue(host.checkpointSummaries(root: canonical).isEmpty)
        }

        func testRunCommandTakesTheCheckpointBeforeSpawning() async throws {
            let root = try folder().resolvingSymlinksInPath()
            try Data("before".utf8).write(to: root.appendingPathComponent("seeded.txt"))
            let spawner = MacComputerFakeSpawner()
            spawner.failure = ComputerHostError("failed", "The command could not start.")
            let (host, _) = try makeHost(
                roots: [root],
                commands: MacComputerCommands(
                    spawner: spawner, clock: MacComputerFakeClock { $0 >= 20 }, inherited: [:],
                    loginPath: { "/usr/bin:/bin" }))
            let canonical = try XCTUnwrap(host.files.roots.first)
            let session = try startSession(host)
            let response = try await send(
                host, session, "run_command", ["command": .string("echo hi"), "cwd": .string(canonical)])
            XCTAssertEqual(response["ok"], .bool(false))
            XCTAssertEqual(host.checkpointSummaries(root: canonical).count, 1)
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent("seeded.txt"), encoding: .utf8), "before")
        }

        func testRestoreVerbDeniesRevokedGrantsAndChangedIdentities() throws {
            let root = try folder().resolvingSymlinksInPath()
            let other = try folder().resolvingSymlinksInPath()
            let workspace = try ComputerWorkspace(root: root.path)
            let storeDirectory = try folder()
            let store = try ComputerCheckpointStore(directory: storeDirectory, scope: "checkpoint-owner")
            try workspace.write(workspace.root + "/file.txt", content: "before", overwrite: false, authorize: {})
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))
            let checkpoints = MacComputerCheckpoints(directory: storeDirectory)
            checkpoints.bind("checkpoint-owner")
            let request = try checkpointRequest("restore_checkpoint", ["checkpoint_id": .string(record.id)])

            XCTAssertThrowsError(
                try checkpoints.restoreCheckpoint(request, workspaces: [], authorize: {})
            ) { error in
                XCTAssertEqual((error as? ComputerHostError)?.code, "permission_denied")
            }
            let replacement = try ComputerWorkspace(root: other.path)
            XCTAssertThrowsError(
                try checkpoints.restoreCheckpoint(request, workspaces: [replacement], authorize: {})
            ) { error in
                XCTAssertEqual((error as? ComputerHostError)?.code, "permission_denied")
            }
            let response = try checkpoints.restoreCheckpoint(request, workspaces: [workspace], authorize: {})
            XCTAssertEqual(response["restored"], .array([.string("file.txt")]))
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8), "before")
        }

        func testDiffAndListVerbsReportCheckpointsForGrantedRootsOnly() throws {
            let root = try folder().resolvingSymlinksInPath()
            let workspace = try ComputerWorkspace(root: root.path)
            let storeDirectory = try folder()
            let store = try ComputerCheckpointStore(directory: storeDirectory, scope: "checkpoint-owner")
            try workspace.write(workspace.root + "/file.txt", content: "before", overwrite: false, authorize: {})
            let record = try XCTUnwrap(try store.snapshotIfNeeded(turnId: store.noteActivity(), root: workspace))
            let checkpoints = MacComputerCheckpoints(directory: storeDirectory)
            checkpoints.bind("checkpoint-owner")

            let listed = try checkpoints.listCheckpoints(workspaces: [workspace], authorize: {})
            XCTAssertEqual(listed["checkpoints"]?.arrayValue?.count, 1)
            XCTAssertEqual(listed["checkpoints"]?.arrayValue?.first?["checkpoint_id"], .string(record.id))
            let denied = try checkpoints.listCheckpoints(workspaces: [], authorize: {})
            XCTAssertEqual(denied["checkpoints"]?.arrayValue?.count, 0)

            try Data("after".utf8).write(to: root.appendingPathComponent("file.txt"))
            let diffRequest = try checkpointRequest("diff_checkpoint", ["checkpoint_id": .string(record.id)])
            let diff = try checkpoints.diffCheckpoint(diffRequest, workspaces: [workspace], authorize: {})
            XCTAssertEqual(diff["changes"]?.arrayValue?.first?["state"], .string("changed"))
            XCTAssertThrowsError(
                try checkpoints.diffCheckpoint(diffRequest, workspaces: [], authorize: {})
            ) { error in
                XCTAssertEqual((error as? ComputerHostError)?.code, "permission_denied")
            }
        }

        func testOwnerRestoreRequiresASignedInOwnerAndMatchingScope() async throws {
            let root = try folder().resolvingSymlinksInPath()
            try Data("before".utf8).write(to: root.appendingPathComponent("seeded.txt"))
            let (host, _) = try makeHost(roots: [root])
            let canonical = try XCTUnwrap(host.files.roots.first)
            let session = try startSession(host)
            _ = try await send(
                host, session, "write_file",
                ["path": canonical + "/seeded.txt", "content": "after", "if_exists": .string("overwrite")])
            let summary = try XCTUnwrap(host.checkpointSummaries(root: canonical).first)

            host.signedOut()
            let message = await host.restoreCheckpointFiles(summary.id)
            XCTAssertEqual(message, "Sign in to restore files on this Mac.")
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent("seeded.txt"), encoding: .utf8), "after")
            XCTAssertTrue(host.checkpointSummaries(root: canonical).isEmpty)
        }
    }

#endif
