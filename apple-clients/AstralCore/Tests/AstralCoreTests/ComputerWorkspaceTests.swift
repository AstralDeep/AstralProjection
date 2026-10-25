// Exercises actual descriptor-relative workspace IO, atomic overwrite policy, and symlink denials.
// The native host grants selected roots to this filesystem boundary rather than trusting path strings.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    final class ComputerWorkspaceTests: XCTestCase {
        func testCredentialRootsAndInvalidTextAreRejected() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try ComputerWorkspace(root: root.appendingPathComponent(".ssh").path))
            let workspace = try ComputerWorkspace(root: root.path)
            let binary = root.appendingPathComponent("binary")
            try Data([0xff, 0xfe, 0x00]).write(to: binary)
            XCTAssertThrowsError(try workspace.read(binary.path, maximum: 100))
        }

        func testHardLinkedFileIsNotAWorkspaceReadCapability() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outside)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            let link = root.appendingPathComponent("linked")
            try FileManager.default.linkItem(at: outside, to: link)
            let workspace = try ComputerWorkspace(root: root.path)
            XCTAssertThrowsError(try workspace.read(link.path, maximum: 100))
        }
        func testRoundTripRefuseOverwriteAndEmptyDirectoryDeletion() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("hello.txt").path
            try workspace.write(path, content: "first", overwrite: false, authorize: {})
            XCTAssertEqual(try workspace.read(path, maximum: 100)["text"], .string("first"))
            XCTAssertThrowsError(try workspace.write(path, content: "second", overwrite: false, authorize: {}))
            try workspace.write(path, content: "second", overwrite: true, authorize: {})
            XCTAssertEqual(try workspace.list(root.path)["count"], .number(1))
            XCTAssertEqual(try workspace.list(root.path)["count"], .number(1))
            XCTAssertThrowsError(try workspace.delete(root.path, authorize: {}))
            try workspace.delete(path, authorize: {})
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }

        func testSymlinkParentEscapeAndCancellationHaveNoEffect() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("escape"), withDestinationURL: outside)
            let workspace = try ComputerWorkspace(root: root.path)
            XCTAssertThrowsError(
                try workspace.write(root.path + "/escape/secret", content: "bad", overwrite: true, authorize: {}))
            XCTAssertThrowsError(try workspace.read(root.path + "/../secret", maximum: 10))
            XCTAssertThrowsError(
                try workspace.write(
                    root.path + "/cancelled", content: "bad", overwrite: false, authorize: { throw CancellationError() }
                ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/cancelled"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path + "/secret"))
        }
    }

#endif
