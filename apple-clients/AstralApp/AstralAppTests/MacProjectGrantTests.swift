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
