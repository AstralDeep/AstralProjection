// Exercises project grant durability and isolation using real temporary workspace descriptors.
// Native selection and storage IO are injected to expose revocation and failure ordering.

#if os(macOS)
    import AstralCore
    import Observation
    import XCTest
    @testable import AstralDeep

    @MainActor final class MacProjectGrantTests: XCTestCase {
        let project = "00000000-0000-1000-8000-000000000001"
        let other = "00000000-0000-1000-8000-000000000002"
        func testMissingRetainedRootRevokesTheWholeProjectBeforeSnapshotAndOnReconciliation() throws {
            for reconcile in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .resolvingSymlinksInPath()
                let first = root.appendingPathComponent("first")
                let second = root.appendingPathComponent("second")
                let safe = root.appendingPathComponent("safe")
                for url in [first, second, safe] {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }
                defer { try? FileManager.default.removeItem(at: root) }
                let io = MacComputerTestWorkspaceGrants()
                var bytes: [String: Data] = [:]
                let store = MacProjectGrants(
                    grants: io.port, persistence: .init(read: { bytes[$0] }, write: { bytes[$0] = $1 }))
                store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
                try store.reconcile(projectIds: [project, other])
                io.selection = [first, second]
                try store.choose(project: project)
                io.selection = [safe]
                try store.choose(project: other)
                let saved = try XCTUnwrap(store.manifest)
                let grant = try XCTUnwrap(saved.projects.first { $0.projectId == project })
                let context = try ComputerProjectContext(
                    chatId: "chat", projectId: project, grantRevision: grant.grantRevision,
                    manifestGeneration: saved.generation)
                var revoked: [String] = []
                store.onRevoke = { revoked.append($0) }
                try FileManager.default.removeItem(at: second)
                if reconcile { try store.reconcile(projectIds: [project, other]) }
                XCTAssertThrowsError(try store.snapshot(context: context))
                XCTAssertEqual(revoked, [project])
                XCTAssertTrue(store.roots(project: project).isEmpty)
                XCTAssertEqual(store.roots(project: other), [safe.path])
                XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
                store.bind(server: nil, account: nil, device: "mac")
                XCTAssertEqual(io.started.count, io.stopped.count)
            }
        }
        func testUnavailableWarningSurvivesRepeatedLaunchCancelAndUnrelatedChangesUntilExplicitRepair() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            let missing = root.appendingPathComponent("missing")
            let safe = root.appendingPathComponent("safe")
            for url in [missing, safe] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            var bytes: [String: Data] = [:]
            let persistence = MacProjectGrantPersistence(read: { bytes[$0] }, write: { bytes[$0] = $1 })
            func make() throws -> MacProjectGrants {
                let store = MacProjectGrants(grants: io.port, persistence: persistence)
                store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
                try store.reconcile(projectIds: [project, other])
                return store
            }
            let first = try make()
            io.selection = [missing]
            try first.choose(project: project)
            first.bind(server: nil, account: nil, device: "mac")
            try FileManager.default.removeItem(at: missing)
            for _ in 0..<3 {
                let store = try make()
                XCTAssertEqual(store.unavailableProjects[project], [missing.path])
                XCTAssertTrue(store.roots(project: project).isEmpty)
                io.selection = nil
                try store.choose(project: project)
                XCTAssertEqual(store.unavailableProjects[project], [missing.path])
                io.selection = [safe]
                try store.choose(project: other)
                XCTAssertEqual(store.unavailableProjects[project], [missing.path])
                XCTAssertNil(store.unavailableProjects[other])
                store.bind(server: nil, account: nil, device: "mac")
                XCTAssertTrue(store.unavailableProjects.isEmpty)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
            let repaired = try make()
            io.selection = [safe]
            try repaired.choose(project: project)
            XCTAssertTrue(repaired.unavailableProjects.isEmpty)
            XCTAssertEqual(repaired.roots(project: project), [safe.path])
            repaired.bind(server: nil, account: nil, device: "mac")
            XCTAssertEqual(io.started.count, io.stopped.count)
        }

        func testReplacedFolderNeverInheritsGrantAndPersistenceFailureCannotRestoreLiveAuthority() throws {
            for replacement in ["file", "directory"] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .resolvingSymlinksInPath()
                let selected = root.appendingPathComponent("selected")
                try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let io = MacComputerTestWorkspaceGrants()
                io.selection = [selected]
                var bytes: [String: Data] = [:]
                var fail = false
                let store = MacProjectGrants(
                    grants: io.port,
                    persistence: .init(
                        read: { bytes[$0] },
                        write: {
                            if fail { throw CocoaError(.fileWriteNoPermission) }
                            bytes[$0] = $1
                        }))
                store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
                try store.reconcile(projectIds: [project])
                try store.choose(project: project)
                let manifest = try XCTUnwrap(store.manifest)
                let context = try ComputerProjectContext(
                    chatId: "chat", projectId: project,
                    grantRevision: manifest.projects[0].grantRevision, manifestGeneration: manifest.generation)
                try FileManager.default.moveItem(at: selected, to: root.appendingPathComponent("original"))
                if replacement == "file" {
                    try Data("replacement".utf8).write(to: selected)
                } else {
                    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
                }
                fail = replacement == "directory"
                XCTAssertThrowsError(try store.snapshot(context: context))
                XCTAssertTrue(store.roots(project: project).isEmpty)
                XCTAssertEqual(store.unavailableProjects[project], [selected.path])
                if fail { XCTAssertNil(store.manifest) }
                store.bind(server: nil, account: nil, device: "mac")
                XCTAssertEqual(io.started.count, io.stopped.count)
            }
        }
        func testOldQuarantineDocumentsShowGenericRecoveryAndNoticesRemainScopeIsolated() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var bytes: [String: Data] = [:]
            let store = MacProjectGrants(
                grants: io.port, persistence: .init(read: { bytes[$0] }, write: { bytes[$0] = $1 }))
            let server = URL(string: "https://example.com")!
            let key = MacProjectGrants.scope(server: server, account: "owner", device: "mac")
            store.bind(server: server, account: "owner", device: "mac")
            try store.reconcile(projectIds: [project])
            try store.choose(project: project)
            store.bind(server: nil, account: nil, device: "mac")
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bytes[key])) as? [String: Any])
            var projects = try XCTUnwrap(document["projects"] as? [String: [String: Any]])
            var entry = try XCTUnwrap(projects[project])
            entry["quarantined"] = true
            entry.removeValue(forKey: "unavailable")
            var bookmarks = try XCTUnwrap(entry["bookmarks"] as? [[String: Any]])
            for index in bookmarks.indices { bookmarks[index].removeValue(forKey: "path") }
            entry["bookmarks"] = bookmarks
            projects[project] = entry
            document["projects"] = projects
            bytes[key] = try JSONSerialization.data(withJSONObject: document)
            for scope in [
                (server, "owner", "mac"), (server, "different", "mac"),
                (server, "owner", "different"), (URL(string: "https://other.example.com")!, "owner", "mac"),
            ] {
                store.bind(server: scope.0, account: scope.1, device: scope.2)
                try store.reconcile(projectIds: [project])
                if scope.0 == server && scope.1 == "owner" && scope.2 == "mac" {
                    XCTAssertEqual(store.unavailableProjects[project], [])
                } else {
                    XCTAssertTrue(store.unavailableProjects.isEmpty)
                }
                XCTAssertTrue(store.roots(project: project).isEmpty)
            }
            store.bind(server: server, account: "owner", device: "mac")
            try store.reconcile(projectIds: [project])
            XCTAssertEqual(store.unavailableProjects[project], [])
            try store.clear(project: project)
            store.bind(server: nil, account: nil, device: "mac")
            store.bind(server: server, account: "owner", device: "mac")
            try store.reconcile(projectIds: [project])
            XCTAssertTrue(store.unavailableProjects.isEmpty)
            XCTAssertTrue(store.roots(project: project).isEmpty)
            store.bind(server: nil, account: nil, device: "mac")
            XCTAssertEqual(io.started.count, io.stopped.count)
        }

        func testBookmarksCannotSilentlyFollowRenamedFoldersOrLegacyFoldersMovedToTrash() throws {
            for legacy in [false, true] {
                let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .resolvingSymlinksInPath()
                let original = container.appendingPathComponent("selected")
                let parent = container.appendingPathComponent(legacy ? ".Trash" : "renamed")
                let relocated = parent.appendingPathComponent("selected")
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: container) }
                let io = MacComputerTestWorkspaceGrants()
                io.selection = [original]
                let base = io.port
                var destination: URL?
                let port = MacComputerWorkspaceGrantIO(
                    chooseDirectories: base.chooseDirectories,
                    resolveBookmark: { data in
                        (destination ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
                    },
                    makeBookmark: base.makeBookmark, startAccess: base.startAccess, stopAccess: base.stopAccess)
                var bytes: [String: Data] = [:]
                let persistence = MacProjectGrantPersistence(read: { bytes[$0] }, write: { bytes[$0] = $1 })
                let server = URL(string: "https://example.com")!
                let first = MacProjectGrants(grants: port, persistence: persistence)
                first.bind(server: server, account: "owner", device: "mac")
                try first.reconcile(projectIds: [project])
                try first.choose(project: project)
                first.bind(server: nil, account: nil, device: "mac")
                if legacy {
                    let key = MacProjectGrants.scope(server: server, account: "owner", device: "mac")
                    var document = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: XCTUnwrap(bytes[key])) as? [String: Any])
                    var entries = try XCTUnwrap(document["projects"] as? [String: [String: Any]])
                    var entry = try XCTUnwrap(entries[project])
                    var bookmarks = try XCTUnwrap(entry["bookmarks"] as? [[String: Any]])
                    for index in bookmarks.indices { bookmarks[index].removeValue(forKey: "path") }
                    entry["bookmarks"] = bookmarks
                    entries[project] = entry
                    document["projects"] = entries
                    bytes[key] = try JSONSerialization.data(withJSONObject: document)
                }
                let identity = try ComputerWorkspace(root: original.path).rootIdentity
                try FileManager.default.moveItem(at: original, to: relocated)
                XCTAssertEqual(try ComputerWorkspace(root: relocated.path).rootIdentity, identity)
                destination = relocated
                let restored = MacProjectGrants(grants: port, persistence: persistence)
                restored.bind(server: server, account: "owner", device: "mac")
                try restored.reconcile(projectIds: [project])
                XCTAssertTrue(restored.roots(project: project).isEmpty)
                XCTAssertNotNil(restored.unavailableProjects[project])
                XCTAssertTrue(restored.manifest?.projects.isEmpty == true)
                restored.bind(server: nil, account: nil, device: "mac")
                XCTAssertEqual(io.started.count, io.stopped.count)
            }
        }

        func testBookmarkResolutionFailureUsesDurableRecoveryNoticeWithoutMisleadingGlobalError() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var bytes: [String: Data] = [:]
            let persistence = MacProjectGrantPersistence(read: { bytes[$0] }, write: { bytes[$0] = $1 })
            let server = URL(string: "https://example.com")!
            let original = MacProjectGrants(grants: io.port, persistence: persistence)
            original.bind(server: server, account: "owner", device: "mac")
            try original.reconcile(projectIds: [project])
            try original.choose(project: project)
            original.bind(server: nil, account: nil, device: "mac")
            io.resolveFailure = true
            for _ in 0..<3 {
                let reopened = MacProjectGrants(grants: io.port, persistence: persistence)
                reopened.bind(server: server, account: "owner", device: "mac")
                try reopened.reconcile(projectIds: [project])
                XCTAssertEqual(reopened.unavailableProjects[project], [root.path])
                XCTAssertTrue(reopened.roots(project: project).isEmpty)
                XCTAssertNil(reopened.errorMessage)
                reopened.bind(server: nil, account: nil, device: "mac")
            }
            io.resolveFailure = false
            let repaired = MacProjectGrants(grants: io.port, persistence: persistence)
            repaired.bind(server: server, account: "owner", device: "mac")
            try repaired.reconcile(projectIds: [project])
            try repaired.choose(project: project)
            XCTAssertTrue(repaired.unavailableProjects.isEmpty)
            XCTAssertNil(repaired.errorMessage)
            XCTAssertEqual(repaired.roots(project: project), [root.path])
            repaired.bind(server: nil, account: nil, device: "mac")
            XCTAssertEqual(io.started.count, io.stopped.count)
            let corrupt = MacProjectGrants(
                grants: io.port,
                persistence: .init(
                    read: { _ in Data("invalid stored document".utf8) }, write: { _, _ in }))
            corrupt.bind(server: server, account: "owner", device: "mac")
            XCTAssertNotNil(corrupt.errorMessage)
            XCTAssertTrue(corrupt.unavailableProjects.isEmpty)
        }

        func testRestorationWriteFailureRemainsVisibleAfterQuarantinePersists() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var bytes: [String: Data] = [:]
            var writes = 0
            var failingWrite: Int?
            let persistence = MacProjectGrantPersistence(
                read: { bytes[$0] },
                write: {
                    writes += 1
                    if writes == failingWrite { throw CocoaError(.fileWriteNoPermission) }
                    bytes[$0] = $1
                })
            let server = URL(string: "https://example.com")!
            let original = MacProjectGrants(grants: io.port, persistence: persistence)
            original.bind(server: server, account: "owner", device: "mac")
            try original.reconcile(projectIds: [project])
            try original.choose(project: project)
            original.bind(server: nil, account: nil, device: "mac")
            writes = 0
            failingWrite = 2
            let reopened = MacProjectGrants(grants: io.port, persistence: persistence)
            reopened.bind(server: server, account: "owner", device: "mac")
            try reopened.reconcile(projectIds: [project])
            XCTAssertEqual(writes, 3)
            XCTAssertEqual(reopened.unavailableProjects[project], [root.path])
            XCTAssertTrue(reopened.roots(project: project).isEmpty)
            XCTAssertEqual(reopened.errorMessage, CocoaError(.fileWriteNoPermission).localizedDescription)
            reopened.bind(server: nil, account: nil, device: "mac")
            XCTAssertEqual(io.started.count, io.stopped.count)
        }

        func testFolderRowsObserveSelectionPrimaryChangesAndRemoval() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            let first = root.appendingPathComponent("first")
            let second = root.appendingPathComponent("second")
            for url in [first, second] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [first, second]
            var bytes: [String: Data] = [:]
            let store = MacProjectGrants(
                grants: io.port, persistence: .init(read: { bytes[$0] }, write: { bytes[$0] = $1 }))
            store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
            try store.reconcile(projectIds: [project])
            for change in ["choose", "primary", "remove"] {
                let changed = expectation(description: "folder rows update after \(change)")
                withObservationTracking {
                    _ = store.roots(project: project)
                } onChange: {
                    changed.fulfill()
                }
                switch change {
                case "choose": try store.choose(project: project)
                case "primary": try store.primary(project: project, path: second.path)
                default: try store.remove(project: project, path: first.path)
                }
                await fulfillment(of: [changed], timeout: 1)
            }
            XCTAssertEqual(store.roots(project: project), [second.path])
            store.bind(server: nil, account: nil, device: "mac")
        }
        func testGrantIsolationRevocationAndDurableFailure() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var bytes: [String: Data] = [:]
            var fail = false
            var revoked: [String] = []
            let store = MacProjectGrants(
                grants: io.port,
                persistence: .init(
                    read: { bytes[$0] },
                    write: {
                        if fail { throw CocoaError(.fileWriteNoPermission) }
                        bytes[$0] = $1
                    }))
            store.onRevoke = { revoked.append($0) }
            store.bind(server: URL(string: "https://EXAMPLE.com:443/")!, account: "owner", device: "mac-a")
            try store.reconcile(projectIds: [project, other])
            try store.choose(project: project)
            let grant = try XCTUnwrap(store.manifest?.projects.first)
            XCTAssertEqual(grant.roots.map(\.path), [root.path])
            XCTAssertTrue(store.roots(project: other).isEmpty)
            XCTAssertEqual(revoked, [project])
            fail = true
            XCTAssertThrowsError(try store.choose(project: project))
            XCTAssertTrue(store.errorMessage?.contains("not saved") == true)
            XCTAssertTrue(store.errorMessage?.contains("Restarting may restore") == true)
            XCTAssertThrowsError(try store.remove(project: project, path: root.path))
            XCTAssertTrue(store.roots(project: project).isEmpty)
            XCTAssertNil(store.manifest)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(io.started.count, io.stopped.count)
            fail = false
            try store.choose(project: project)
            XCTAssertGreaterThan(try XCTUnwrap(store.manifest?.projects.first?.grantRevision), grant.grantRevision)
            store.bind(server: URL(string: "https://example.com/")!, account: "owner", device: "mac-b")
            try store.reconcile(projectIds: [project])
            XCTAssertTrue(store.roots(project: project).isEmpty)
            store.bind(server: URL(string: "https://elsewhere.com/")!, account: "owner", device: "mac-a")
            try store.reconcile(projectIds: [project])
            XCTAssertTrue(store.roots(project: project).isEmpty)
            store.bind(server: URL(string: "https://example.com/")!, account: "another", device: "mac-a")
            try store.reconcile(projectIds: [project])
            XCTAssertTrue(store.roots(project: project).isEmpty)
        }
        func testLatePersistenceCannotPublishIntoAnotherAccount() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var bytes: [String: Data] = [:]
            var changeOwner = false
            var store: MacProjectGrants!
            store = MacProjectGrants(
                grants: io.port,
                persistence: .init(
                    read: { bytes[$0] },
                    write: { key, data in
                        bytes[key] = data
                        if changeOwner {
                            changeOwner = false
                            store.bind(server: URL(string: "https://example.com")!, account: "other", device: "mac")
                        }
                    }))
            store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
            try store.reconcile(projectIds: [project])
            changeOwner = true
            XCTAssertThrowsError(try store.choose(project: project))
            try store.reconcile(projectIds: [project])
            XCTAssertTrue(store.roots(project: project).isEmpty)
            XCTAssertTrue(store.manifest!.projects.isEmpty)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(io.started.count, io.stopped.count)
        }
        func testPrimaryReorderRetiresOldSnapshotAndBalancesResources() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            let a = root.appendingPathComponent("a")
            let b = root.appendingPathComponent("b")
            for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [a, b]
            var bytes: [String: Data] = [:]
            let store = MacProjectGrants(
                grants: io.port, persistence: .init(read: { bytes[$0] }, write: { bytes[$0] = $1 }))
            store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
            try store.reconcile(projectIds: [project])
            try store.choose(project: project)
            let old = try XCTUnwrap(store.manifest)
            let context = try ComputerProjectContext(
                chatId: "chat", projectId: project, grantRevision: old.projects[0].grantRevision,
                manifestGeneration: old.generation)
            try store.primary(project: project, path: b.path)
            XCTAssertEqual(store.roots(project: project), [b.path, a.path])
            XCTAssertThrowsError(try store.snapshot(context: context))
            XCTAssertTrue(io.stopped.isEmpty)
            try store.remove(project: project, path: a.path)
            XCTAssertEqual(store.roots(project: project), [b.path])
            store.bind(server: nil, account: nil, device: "mac")
            XCTAssertEqual(io.started.count, io.stopped.count)
        }
        func testFailedRemovalRestartsFromSavedRootsOnlyAfterFreshDurableRevision() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var bytes: [String: Data] = [:]
            var fail = false
            let persistence = MacProjectGrantPersistence(
                read: { bytes[$0] },
                write: {
                    if fail { throw CocoaError(.fileWriteNoPermission) }
                    bytes[$0] = $1
                })
            func make() -> MacProjectGrants {
                let store = MacProjectGrants(grants: io.port, persistence: persistence)
                store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
                return store
            }
            let first = make()
            try first.reconcile(projectIds: [project])
            try first.choose(project: project)
            let saved = try XCTUnwrap(first.manifest)
            let context = try ComputerProjectContext(
                chatId: "chat", projectId: project, grantRevision: saved.projects[0].grantRevision,
                manifestGeneration: saved.generation)
            fail = true
            XCTAssertThrowsError(try first.remove(project: project, path: root.path))
            XCTAssertNil(first.manifest)
            XCTAssertTrue(first.errorMessage?.contains("not saved") == true)
            let denied = make()
            XCTAssertThrowsError(try denied.reconcile(projectIds: [project]))
            XCTAssertNil(denied.manifest)
            fail = false
            let recovered = make()
            try recovered.reconcile(projectIds: [project])
            XCTAssertEqual(recovered.roots(project: project), [root.path])
            XCTAssertGreaterThan(recovered.manifest!.projects[0].grantRevision, saved.projects[0].grantRevision)
            XCTAssertThrowsError(try recovered.snapshot(context: context))
            try recovered.remove(project: project, path: root.path)
            recovered.bind(server: nil, account: nil, device: "mac")
            let removed = make()
            try removed.reconcile(projectIds: [project])
            XCTAssertTrue(removed.roots(project: project).isEmpty)
            XCTAssertEqual(io.started.count, io.stopped.count)
        }
        func testCompleteReconciliationQuarantinesDeletedGrantAndRequiresExplicitRecovery() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var bytes: [String: Data] = [:]
            let store = MacProjectGrants(
                grants: io.port, persistence: .init(read: { bytes[$0] }, write: { bytes[$0] = $1 }))
            store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
            try store.reconcile(projectIds: [project])
            try store.choose(project: project)
            let old = try XCTUnwrap(store.manifest?.projects.first)
            let context = try ComputerProjectContext(
                chatId: "legacy", projectId: project, grantRevision: old.grantRevision,
                manifestGeneration: store.manifest!.generation)
            XCTAssertEqual(try store.snapshot(context: context).count, 1)
            try store.reconcile(projectIds: [])
            XCTAssertTrue(store.manifest!.projects.isEmpty)
            XCTAssertThrowsError(try store.snapshot(context: context))
            try store.reconcile(projectIds: [project])
            XCTAssertTrue(store.roots(project: project).isEmpty)
            try store.choose(project: project)
            XCTAssertGreaterThan(store.manifest!.projects[0].grantRevision, old.grantRevision)
        }
    }
#endif
