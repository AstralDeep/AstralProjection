// Checks selected-directory identity against the descriptor retained by ComputerWorkspace.
// All candidate directories and replacements are task-owned temporary filesystem objects.

#if os(macOS)
    import XCTest
    @testable import AstralCore

    final class ComputerWorkspaceIdentityTests: XCTestCase {
        private func folder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }
        func testSameDirectoryMatchesAfterRenameWithoutChangingSelectedDescriptor() throws {
            let parent = try folder()
            let root = parent.appendingPathComponent("selected")
            let moved = parent.appendingPathComponent("moved")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let workspace = try ComputerWorkspace(root: root.path)
            XCTAssertTrue(workspace.matchesRoot(root.path))
            try FileManager.default.moveItem(at: root, to: moved)
            XCTAssertFalse(workspace.matchesRoot(root.path))
            XCTAssertTrue(workspace.matchesRoot(moved.path))
            try workspace.write(root.path + "/held.txt", content: "held", overwrite: false, authorize: {})
            XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("held.txt")), "held")
            XCTAssertEqual(workspace.root, root.path)
        }
        func testDifferentDirectorySymlinkFileAndMissingPathDoNotMatch() throws {
            let root = try folder()
            let other = try folder()
            let workspace = try ComputerWorkspace(root: root.path)
            let link = other.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            let file = other.appendingPathComponent("file")
            try Data("owned".utf8).write(to: file)
            for path in [other.path, link.path, file.path, other.path + "/missing"] {
                XCTAssertFalse(workspace.matchesRoot(path), path)
            }
            XCTAssertTrue(workspace.matchesRoot(root.path))
            XCTAssertEqual(try String(contentsOf: file), "owned")
        }
        func testMalformedCandidateCannotAliasTheSelectedDirectory() throws {
            let root = try folder()
            let workspace = try ComputerWorkspace(root: root.path)
            for path in ["", "relative", root.path + "\0suffix", root.path + "/" + String(repeating: "x", count: 4097)]
            {
                XCTAssertFalse(workspace.matchesRoot(path))
            }
            XCTAssertTrue(workspace.matchesRoot(root.path))
        }
        func testOpaqueIdentityRoundTripsAndRemainsBoundToTheOpenedDirectory() throws {
            let parent = try folder()
            let root = parent.appendingPathComponent("selected")
            let moved = parent.appendingPathComponent("moved")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let workspace = try ComputerWorkspace(root: root.path)
            let identity = workspace.rootIdentity
            let encoded = try JSONEncoder().encode(identity)
            XCTAssertEqual(try JSONDecoder().decode(ComputerWorkspaceIdentity.self, from: encoded), identity)
            XCTAssertEqual(try ComputerWorkspace(root: root.path).rootIdentity, identity)
            try FileManager.default.moveItem(at: root, to: moved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            XCTAssertEqual(workspace.rootIdentity, identity)
            XCTAssertEqual(try ComputerWorkspace(root: moved.path).rootIdentity, identity)
            XCTAssertNotEqual(try ComputerWorkspace(root: root.path).rootIdentity, identity)
            XCTAssertThrowsError(try JSONDecoder().decode(ComputerWorkspaceIdentity.self, from: Data("{}".utf8)))
        }
    }
#endif
