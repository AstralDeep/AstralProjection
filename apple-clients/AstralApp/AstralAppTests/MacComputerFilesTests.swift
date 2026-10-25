// Verifies owner-scoped workspace grants against real temporary directory descriptors.
// Only directory selection, bookmarks and security-scope access are replaced with inert native IO.

#if os(macOS)
    import AppKit
    import AstralCore
    import Darwin
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerFilesTests: XCTestCase {
        private func folder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }
        private func defaults() -> UserDefaults {
            let name = "workspace-tests-" + UUID().uuidString
            let value = UserDefaults(suiteName: name)!
            addTeardownBlock { value.removePersistentDomain(forName: name) }
            return value
        }
        func testSelectionRequiresOwnerAndCancellationPreservesExistingGrant() throws {
            let root = try folder()
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            let files = MacComputerFiles(defaults: defaults(), grants: io.port)
            files.choose()
            XCTAssertTrue(files.roots.isEmpty)
            XCTAssertEqual(io.choices, 0)
            files.bind("owner-a|server-a")
            files.choose()
            XCTAssertEqual(files.roots, [root.path])
            XCTAssertEqual(try files.snapshot().first?.list(root.path)["count"], .number(0))
            io.selection = nil
            files.choose()
            XCTAssertEqual(files.roots, [root.path])
            XCTAssertEqual(io.choices, 2)
            files.bind(nil)
            XCTAssertEqual(io.stopped, [root])
        }
        func testLiveBookmarkRoundTripUsesOnlyTheSelectedTemporaryDirectory() throws {
            let root = try folder()
            let port = MacComputerWorkspaceGrantIO.live
            let bookmark = try port.makeBookmark(root)
            XCTAssertFalse(bookmark.isEmpty)
            let (restored, stale) = try port.resolveBookmark(bookmark)
            XCTAssertEqual(restored.resolvingSymlinksInPath().path, root.path)
            XCTAssertFalse(stale)
            let accessed = port.startAccess(restored)
            defer { if accessed { port.stopAccess(restored) } }
            let workspace = try ComputerWorkspace(root: restored.path)
            try workspace.write(root.path + "/owned.txt", content: "temporary", overwrite: false, authorize: {})
            XCTAssertEqual(try workspace.read(root.path + "/owned.txt", maximum: 100)["text"], .string("temporary"))
            XCTAssertThrowsError(try port.resolveBookmark(Data([0, 1, 2])))
        }
        func testBookmarksRemainBoundToOwnerAndServerWithBalancedAccess() throws {
            let root = try folder()
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root, root]
            let store = defaults()
            let files = MacComputerFiles(defaults: store, grants: io.port)
            files.bind("owner-a|server-a")
            files.choose()
            XCTAssertEqual(files.roots, [root.path])
            XCTAssertEqual(io.stopped, [root])
            files.bind("owner-a|server-a")
            XCTAssertEqual(io.resolutions, 1)
            files.bind("owner-b|server-a")
            XCTAssertTrue(files.roots.isEmpty)
            files.bind("owner-a|server-b")
            XCTAssertTrue(files.roots.isEmpty)
            files.bind("owner-a|server-a")
            XCTAssertEqual(files.roots, [root.path])
            XCTAssertEqual(io.resolutions, 3)
            let restored = MacComputerFiles(defaults: store, grants: io.port)
            restored.bind("owner-a|server-a")
            XCTAssertEqual(restored.roots, [root.path])
            restored.bind(nil)
            files.bind(nil)
            XCTAssertEqual(io.started.count, io.stopped.count)
        }
        func testStaleAndMalformedBookmarksCannotRestoreAWorkspace() throws {
            let root = try folder()
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            let store = defaults()
            let files = MacComputerFiles(defaults: store, grants: io.port)
            files.bind("owner-a")
            files.choose()
            files.bind(nil)
            for stale in [true, false] {
                io.stale = stale
                io.resolveFailure = !stale
                files.bind("owner-a")
                XCTAssertTrue(files.roots.isEmpty)
                XCTAssertNotNil(files.errorMessage)
                files.bind(nil)
            }
            XCTAssertEqual(io.started, [root])
            XCTAssertEqual(io.stopped, [root])
        }
        func testUnverifiableNewBookmarkReleasesScopeWithoutRetainingOrPersistingGrant() throws {
            let root = try folder()
            for stale in [true, false] {
                let io = MacComputerTestWorkspaceGrants()
                io.selection = [root]
                io.stale = stale
                io.resolveFailure = !stale
                let files = MacComputerFiles(defaults: defaults(), grants: io.port)
                files.bind("owner-a")
                files.choose()
                XCTAssertTrue(files.roots.isEmpty)
                XCTAssertTrue(files.snapshot().isEmpty)
                XCTAssertNotNil(files.errorMessage)
                XCTAssertEqual(io.started, [root])
                XCTAssertEqual(io.stopped, [root])
                files.bind(nil)
                io.stale = false
                io.resolveFailure = false
                files.bind("owner-a")
                XCTAssertTrue(files.roots.isEmpty)
                files.bind(nil)
            }
        }
        func testInvalidSelectedDirectoriesDoNotAcquireGrantAndDoNotDiscardGoodRoots() throws {
            let root = try folder()
            let missing = root.appendingPathComponent("missing")
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [URL(fileURLWithPath: "/"), missing, root]
            let files = MacComputerFiles(defaults: defaults(), grants: io.port)
            files.bind("owner-a")
            files.choose()
            XCTAssertEqual(files.roots, [root.path])
            XCTAssertNotNil(files.errorMessage)
            XCTAssertEqual(io.stopped, [URL(fileURLWithPath: "/"), missing])
            files.bind(nil)
            XCTAssertEqual(io.started.count, io.stopped.count)
        }
        func testOrdinaryDirectoryWithoutScopedAccessDoesNotReleaseAnUnacquiredScope() throws {
            let root = try folder()
            let io = MacComputerTestWorkspaceGrants()
            io.accessed = false
            io.selection = [root, root]
            let files = MacComputerFiles(defaults: defaults(), grants: io.port)
            files.bind("owner-a")
            files.choose()
            XCTAssertEqual(files.roots, [root.path])
            XCTAssertEqual(try files.snapshot().first?.list(root.path)["count"], .number(0))
            files.bind(nil)
            XCTAssertTrue(io.stopped.isEmpty)
        }
        func testRemovingGrantRetainsOnlyOtherDirectoriesAndPersistsTheChange() throws {
            let first = try folder()
            let second = try folder()
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [first, second]
            let store = defaults()
            let files = MacComputerFiles(defaults: store, grants: io.port)
            files.bind("owner-a")
            files.choose()
            files.remove(first.path)
            XCTAssertEqual(files.roots, [second.path])
            XCTAssertEqual(try files.snapshot().first?.list(second.path)["count"], .number(0))
            files.bind(nil)
            files.bind("owner-a")
            XCTAssertEqual(files.roots, [second.path])
            files.remove(second.path)
            XCTAssertTrue(files.roots.isEmpty)
            files.bind(nil)
            files.bind("owner-a")
            XCTAssertTrue(files.roots.isEmpty)
            files.bind(nil)
            XCTAssertEqual(io.started.count, io.stopped.count)
        }
        func testUnpersistableBookmarkDoesNotInventDurableGrant() throws {
            let root = try folder()
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            io.bookmarkFailure = true
            let files = MacComputerFiles(defaults: defaults(), grants: io.port)
            files.bind("owner-a")
            files.choose()
            XCTAssertTrue(files.roots.isEmpty)
            XCTAssertNotNil(files.errorMessage)
            files.bind(nil)
            files.bind("owner-a")
            XCTAssertTrue(files.roots.isEmpty)
            files.bind(nil)
        }
        func testSelectedDescriptorSurvivesPathReplacementWithoutFollowingSymlink() throws {
            let root = try folder()
            let outside = try folder()
            let original = root.appendingPathComponent("original")
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [original]
            let files = MacComputerFiles(defaults: defaults(), grants: io.port)
            files.bind("owner-a")
            files.choose()
            let workspace = try XCTUnwrap(files.snapshot().first)
            let moved = root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
            try workspace.write(original.path + "/selected.txt", content: "selected", overwrite: false, authorize: {})
            XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("selected.txt")), "selected")
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path + "/selected.txt"))
            files.bind(nil)
            XCTAssertEqual(
                try workspace.read(original.path + "/selected.txt", maximum: 100)["text"], .string("selected"))
        }
        func testRemovingReplacedRootRevokesTheCapturedGrantWithoutGrantingItsReplacement() throws {
            let parent = try folder()
            let root = parent.appendingPathComponent("selected")
            let outside = try folder()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            let store = defaults()
            let files = MacComputerFiles(defaults: store, grants: io.port)
            files.bind("owner-a")
            files.choose()
            try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("moved"))
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
            files.remove(root.path)
            XCTAssertTrue(files.roots.isEmpty)
            XCTAssertTrue(files.snapshot().isEmpty)
            files.bind(nil)
            files.bind("owner-a")
            XCTAssertTrue(files.roots.isEmpty)
            files.bind(nil)
        }
        func testRemovingAnotherRootKeepsTheOriginalDescriptorAndBookmark() throws {
            let parent = try folder()
            let root = parent.appendingPathComponent("selected")
            let removed = parent.appendingPathComponent("removed")
            let outside = try folder()
            for url in [root, removed] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root, removed]
            let files = MacComputerFiles(defaults: defaults(), grants: io.port)
            files.bind("owner-a")
            files.choose()
            let captured = try XCTUnwrap(files.snapshot().first)
            let bookmarks = io.bookmarks
            try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("moved"))
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
            files.remove(removed.path)
            XCTAssertEqual(files.roots, [root.path])
            XCTAssertTrue(try XCTUnwrap(files.snapshot().first) === captured)
            XCTAssertEqual(io.bookmarks, bookmarks)
            try captured.write(root.path + "/selected.txt", content: "retained", overwrite: false, authorize: {})
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path + "/selected.txt"))
            files.bind(nil)
        }
        func testBookmarkCapturedAfterPathReplacementCannotGrantTheReplacementOnRestore() throws {
            let parent = try folder()
            let root = parent.appendingPathComponent("selected")
            let outside = try folder()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data("selected".utf8).write(to: root.appendingPathComponent("marker"))
            try Data("replacement".utf8).write(to: outside.appendingPathComponent("marker"))
            let live = MacComputerWorkspaceGrantIO.live
            var replaced = false
            let port = MacComputerWorkspaceGrantIO(
                chooseDirectories: { [root] }, resolveBookmark: live.resolveBookmark,
                makeBookmark: { url in
                    if !replaced {
                        replaced = true
                        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("moved"))
                        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
                    }
                    return try live.makeBookmark(url)
                }, startAccess: live.startAccess, stopAccess: live.stopAccess)
            let files = MacComputerFiles(defaults: defaults(), grants: port)
            files.bind("owner-a")
            files.choose()
            XCTAssertTrue(replaced)
            XCTAssertTrue(files.roots.isEmpty)
            XCTAssertNotNil(files.errorMessage)
            XCTAssertNil(try files.snapshot().first?.read(root.path + "/marker", maximum: 100)["text"])
            files.bind(nil)
            files.bind("owner-a")
            XCTAssertTrue(files.roots.isEmpty)
            XCTAssertNil(try files.snapshot().first?.read(outside.path + "/marker", maximum: 100)["text"])
            files.bind(nil)
            XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("marker")), "replacement")
        }
        func testRestoredBookmarkCannotGrantReplacementInsertedBeforeDirectoryOpen() throws {
            let parent = try folder()
            let root = parent.appendingPathComponent("selected")
            let outside = try folder()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data("selected".utf8).write(to: root.appendingPathComponent("marker"))
            try Data("replacement".utf8).write(to: outside.appendingPathComponent("marker"))
            let live = MacComputerWorkspaceGrantIO.live
            var replace = false
            var replaced = false
            var mutationError: Error?
            let port = MacComputerWorkspaceGrantIO(
                chooseDirectories: { [root] }, resolveBookmark: live.resolveBookmark, makeBookmark: live.makeBookmark,
                startAccess: { url in
                    if replace && !replaced {
                        do {
                            try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("moved"))
                            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
                            replaced = true
                        } catch {
                            mutationError = error
                            return false
                        }
                    }
                    return live.startAccess(url)
                }, stopAccess: live.stopAccess)
            let files = MacComputerFiles(defaults: defaults(), grants: port)
            files.bind("owner-a")
            files.choose()
            XCTAssertEqual(files.roots, [root.path])
            files.bind(nil)
            replace = true
            files.bind("owner-a")
            XCTAssertNil(mutationError)
            XCTAssertTrue(replaced)
            XCTAssertTrue(files.roots.isEmpty)
            XCTAssertNotNil(files.errorMessage)
            XCTAssertNil(try files.snapshot().first?.read(outside.path + "/marker", maximum: 100)["text"])
            files.bind(nil)
            XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("marker")), "replacement")
        }
        func testBookmarkPathABAStillCannotRestoreASeparateDirectoryIdentity() throws {
            let parent = try folder()
            let root = parent.appendingPathComponent("selected")
            let originalParking = parent.appendingPathComponent("original-parking")
            let replacementParking = parent.appendingPathComponent("replacement-parking")
            let replacement = parent.appendingPathComponent("replacement")
            for directory in [root, replacement] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            try Data("selected".utf8).write(to: root.appendingPathComponent("marker"))
            try Data("replacement".utf8).write(to: replacement.appendingPathComponent("marker"))
            let live = MacComputerWorkspaceGrantIO.live
            var stage = 0
            var referenceURL = false
            let port = MacComputerWorkspaceGrantIO(
                chooseDirectories: { [root] },
                resolveBookmark: { data in
                    let resolved = try live.resolveBookmark(data)
                    if stage == 1 {
                        referenceURL = (resolved.0 as NSURL).isFileReferenceURL()
                        try FileManager.default.moveItem(at: root, to: replacementParking)
                        try FileManager.default.moveItem(at: originalParking, to: root)
                        stage = 2
                    }
                    return resolved
                },
                makeBookmark: { url in
                    try FileManager.default.moveItem(at: root, to: originalParking)
                    try FileManager.default.moveItem(at: replacement, to: root)
                    stage = 1
                    return try live.makeBookmark(url)
                }, startAccess: live.startAccess, stopAccess: live.stopAccess)
            let files = MacComputerFiles(defaults: defaults(), grants: port)
            files.bind("owner-a")
            files.choose()
            XCTAssertEqual(stage, 2)
            if let held = files.snapshot().first {
                XCTAssertEqual(try held.read(root.path + "/marker", maximum: 100)["text"], .string("selected"))
            }
            try FileManager.default.moveItem(at: root, to: originalParking)
            try FileManager.default.moveItem(at: replacementParking, to: root)
            files.bind(nil)
            files.bind("owner-a")
            XCTAssertTrue(files.roots.isEmpty, "Resolved bookmark is a file reference URL: \(referenceURL)")
            XCTAssertNotNil(files.errorMessage)
            XCTAssertNil(try files.snapshot().first?.read(root.path + "/marker", maximum: 100)["text"])
            files.bind(nil)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("marker")), "replacement")
        }
        func testLegacyBookmarkDataRequiresSelectionBeforeAnyDirectoryAccess() throws {
            let root = try folder()
            let name = "legacy-grants-" + UUID().uuidString
            let store = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { store.removePersistentDomain(forName: name) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            let files = MacComputerFiles(defaults: store, grants: io.port)
            files.bind("owner-a")
            files.choose()
            let key = try XCTUnwrap(store.persistentDomain(forName: name)?.keys.first)
            files.bind(nil)
            store.set([Data(root.path.utf8)], forKey: key)
            let starts = io.started.count
            files.bind("owner-a")
            XCTAssertTrue(files.roots.isEmpty)
            XCTAssertNotNil(files.errorMessage)
            XCTAssertEqual(io.started.count, starts)
            files.choose()
            XCTAssertEqual(files.roots, [root.path])
            files.bind(nil)
            XCTAssertEqual(io.started.count, io.stopped.count)
        }
        func testCopiedGrantRecordCannotCrossOwnerOrServerBindings() throws {
            let root = try folder()
            let name = "copied-grants-" + UUID().uuidString
            let store = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { store.removePersistentDomain(forName: name) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            let files = MacComputerFiles(defaults: store, grants: io.port)
            files.bind("owner-a|server-a")
            files.choose()
            let firstDomain = try XCTUnwrap(store.persistentDomain(forName: name))
            let firstKey = try XCTUnwrap(firstDomain.keys.first)
            let records = try XCTUnwrap(firstDomain[firstKey] as? [Data])
            files.bind(nil)
            for scope in ["owner-b|server-a", "owner-a|server-b"] {
                let before = Set(try XCTUnwrap(store.persistentDomain(forName: name)).keys)
                files.bind(scope)
                files.choose()
                let after = Set(try XCTUnwrap(store.persistentDomain(forName: name)).keys)
                let key = try XCTUnwrap(after.subtracting(before).first)
                files.bind(nil)
                store.set(records, forKey: key)
                let starts = io.started.count
                files.bind(scope)
                XCTAssertTrue(files.roots.isEmpty)
                XCTAssertNotNil(files.errorMessage)
                XCTAssertEqual(io.started.count, starts)
                files.bind(nil)
            }
            XCTAssertEqual(io.started.count, io.stopped.count)
        }
        func testVersionedGrantRecordsRejectMalformedMetadataAndMismatchedDirectoryIdentity() throws {
            let root = try folder()
            let other = try folder()
            let name = "invalid-grants-" + UUID().uuidString
            let store = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { store.removePersistentDomain(forName: name) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            let files = MacComputerFiles(defaults: store, grants: io.port)
            files.bind("owner-a")
            files.choose()
            let domain = try XCTUnwrap(store.persistentDomain(forName: name))
            let key = try XCTUnwrap(domain.keys.first)
            let data = try XCTUnwrap((domain[key] as? [Data])?.first)
            let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(valid["version"] as? Int, 1)
            XCTAssertEqual(valid["scope_key"] as? String, key)
            files.bind(nil)
            for invalid in 0..<10 {
                var document = valid
                switch invalid {
                case 0: document["version"] = 2
                case 1: document.removeValue(forKey: "identity")
                case 2: document["identity"] = "invalid"
                case 3: document["scope_key"] = "another-scope"
                case 4: document["bookmark"] = "@"
                case 5: document["unexpected"] = true
                case 6: document.removeValue(forKey: "bookmark")
                case 7: document["version"] = "1"
                case 8: document["identity"] = ["device": "invalid", "inode": 0, "generation": 0]
                default:
                    document["identity"] = try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(ComputerWorkspace(root: other.path).rootIdentity))
                }
                store.set([try JSONSerialization.data(withJSONObject: document)], forKey: key)
                files.bind("owner-a")
                XCTAssertTrue(files.roots.isEmpty, "invalid record \(invalid)")
                XCTAssertTrue(files.snapshot().isEmpty)
                XCTAssertNotNil(files.errorMessage)
                files.bind(nil)
                XCTAssertEqual(io.started.count, io.stopped.count)
            }
            store.set([data], forKey: key)
            files.bind("owner-a")
            XCTAssertEqual(files.roots, [root.path])
            files.bind(nil)
        }
        func testChooserCannotPublishAfterOwnerChangesOrReturnsThroughAnotherOwner() throws {
            let root = try folder()
            for returnToOriginal in [false, true] {
                let io = MacComputerTestWorkspaceGrants()
                io.selection = [root]
                let files = MacComputerFiles(defaults: defaults(), grants: io.port)
                files.bind("owner-a")
                io.onChoose = {
                    files.bind("owner-b")
                    if returnToOriginal { files.bind("owner-a") }
                }
                files.choose()
                XCTAssertTrue(files.roots.isEmpty)
                XCTAssertTrue(files.snapshot().isEmpty)
                XCTAssertTrue(io.started.isEmpty)
                files.bind(nil)
                files.bind(returnToOriginal ? "owner-a" : "owner-b")
                XCTAssertTrue(files.roots.isEmpty)
                files.bind(nil)
            }
        }
        func testBookmarkCaptureCannotPublishUnderAChangedScopeEpoch() throws {
            let root = try folder()
            for returnToOriginal in [false, true] {
                let io = MacComputerTestWorkspaceGrants()
                io.selection = [root]
                let files = MacComputerFiles(defaults: defaults(), grants: io.port)
                files.bind("owner-a")
                io.onBookmark = {
                    files.bind("owner-b")
                    if returnToOriginal { files.bind("owner-a") }
                }
                files.choose()
                XCTAssertTrue(files.roots.isEmpty)
                XCTAssertTrue(files.snapshot().isEmpty)
                XCTAssertNil(files.errorMessage)
                XCTAssertEqual(io.started, [root])
                XCTAssertEqual(io.stopped, [root])
                files.bind(nil)
            }
        }
        func testBookmarkRestoreCannotTransferARecordedGrantToAnotherOwner() throws {
            let root = try folder()
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            let files = MacComputerFiles(defaults: defaults(), grants: io.port)
            files.bind("owner-a")
            files.choose()
            files.bind(nil)
            var changed = false
            io.onResolve = {
                if !changed {
                    changed = true
                    files.bind("owner-b")
                }
            }
            files.bind("owner-a")
            XCTAssertTrue(changed)
            XCTAssertTrue(files.roots.isEmpty)
            XCTAssertTrue(files.snapshot().isEmpty)
            XCTAssertEqual(io.started.count, io.stopped.count)
            files.bind(nil)
        }
        func testSelectedRootsPreserveDescriptorBoundariesAtomicWritesAndAuthorityChecks() throws {
            let root = try folder()
            let child = root.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root, child]
            let files = MacComputerFiles(defaults: defaults(), grants: io.port)
            files.bind("owner-a")
            files.choose()
            defer { files.bind(nil) }
            XCTAssertEqual(files.roots, [root.path, child.path])
            let workspace = try XCTUnwrap(files.snapshot().last)
            let path = child.path + "/text.txt"
            try workspace.write(path, content: "original", overwrite: false, authorize: {})
            XCTAssertThrowsError(try workspace.write(path, content: "replacement", overwrite: false, authorize: {}))
            XCTAssertEqual(try workspace.read(path, maximum: 3)["text"], .string("ori"))
            XCTAssertEqual(try workspace.read(path, maximum: 3)["truncated"], .bool(true))
            var calls = 0
            XCTAssertThrowsError(
                try workspace.write(path, content: "replacement", overwrite: true) {
                    calls += 1
                    if calls == 3 { throw ComputerHostError("cancelled", "Authority revoked") }
                })
            XCTAssertEqual(try String(contentsOfFile: path), "original")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: child.path), ["text.txt"])
            XCTAssertThrowsError(try workspace.read(root.path + "/outside.txt", maximum: 10))
            XCTAssertThrowsError(try workspace.write(child.path, content: "x", overwrite: true, authorize: {}))
            XCTAssertThrowsError(
                try workspace.write(
                    path, content: String(repeating: "x", count: 262145), overwrite: true, authorize: {}))
            try workspace.delete(path, authorize: {})
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
        func testSelectedWorkspaceRejectsSymlinksHardlinksAndCredentialSubdirectories() throws {
            let root = try folder()
            let outside = try folder().appendingPathComponent("outside.txt")
            try Data("outside".utf8).write(to: outside)
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            let files = MacComputerFiles(defaults: defaults(), grants: io.port)
            files.bind("owner-a")
            files.choose()
            defer { files.bind(nil) }
            let workspace = try XCTUnwrap(files.snapshot().first)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertThrowsError(try workspace.read(link.path, maximum: 10))
            XCTAssertThrowsError(try workspace.write(link.path, content: "changed", overwrite: true, authorize: {}))
            XCTAssertThrowsError(try workspace.delete(link.path, authorize: {}))
            let hardlink = root.appendingPathComponent("hardlink")
            try FileManager.default.linkItem(at: outside, to: hardlink)
            XCTAssertThrowsError(try workspace.read(hardlink.path, maximum: 10))
            XCTAssertThrowsError(try workspace.read(root.path + "/.ssh/id_test", maximum: 10))
            XCTAssertEqual(try String(contentsOf: outside), "outside")
        }
    }

    @MainActor
    final class MacComputerTestWorkspaceGrants {
        var selection: [URL]?
        var choices = 0
        var onChoose: (() -> Void)?
        var onBookmark: (() -> Void)?
        var onResolve: (() -> Void)?
        var resolutions = 0
        var stale = false
        var resolveFailure = false
        var bookmarkFailure = false
        var bookmarks: [URL] = []
        var accessed = true
        var started: [URL] = []
        var stopped: [URL] = []
        var port: MacComputerWorkspaceGrantIO {
            MacComputerWorkspaceGrantIO(
                chooseDirectories: {
                    self.choices += 1
                    self.onChoose?()
                    return self.selection
                },
                resolveBookmark: {
                    self.resolutions += 1
                    self.onResolve?()
                    if self.resolveFailure { throw CocoaError(.fileReadCorruptFile) }
                    return (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), self.stale)
                },
                makeBookmark: {
                    self.bookmarks.append($0)
                    self.onBookmark?()
                    if self.bookmarkFailure { throw CocoaError(.fileWriteUnknown) }
                    return Data($0.path.utf8)
                },
                startAccess: {
                    self.started.append($0)
                    return self.accessed
                },
                stopAccess: { self.stopped.append($0) })
        }
    }
#endif
