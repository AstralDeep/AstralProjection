// Exercises resolved-effect planning against real temporary folders: executable path and SHA-256 binding,
// folder identity, digest stability under drift, unreadable executables and the file-effect plan contract.

#if os(macOS)
    import CryptoKit
    import Darwin
    import Foundation
    import XCTest

    @testable import AstralCore

    final class ComputerCommandPlanTests: XCTestCase {
        private func folder() throws -> String {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("plan-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: base) }
            let root = base.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard let pointer = realpath(root.path, nil) else {
                throw ComputerHostError("failed", "The temporary folder could not be resolved.")
            }
            defer { free(pointer) }
            return String(cString: pointer)
        }

        @discardableResult
        private func script(_ path: String, body: String = "#!/bin/sh\necho synthetic\n") throws -> String {
            guard FileManager.default.createFile(atPath: path, contents: Data(body.utf8)) else {
                throw ComputerHostError("failed", "The synthetic script could not be written.")
            }
            guard chmod(path, 0o755) == 0 else {
                throw ComputerHostError("failed", "The synthetic script could not be made runnable.")
            }
            return path
        }

        private func digest(_ data: Data) -> String {
            "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private func code(_ work: () throws -> Void) -> String? {
            do {
                try work()
                return nil
            } catch { return (error as? ComputerHostError)?.code }
        }

        func testResolveBindsExecutablePathHashAndWorkingFolderIdentity() throws {
            let root = try folder()
            let tool = try script(root + "/tool.sh")
            let body = try Data(contentsOf: URL(fileURLWithPath: tool))
            let plan = try ComputerCommandPlan.resolve(
                command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
            XCTAssertEqual(plan.executable, tool)
            XCTAssertEqual(plan.executableDigest, digest(body))
            XCTAssertEqual(plan.cwd, root)
            XCTAssertEqual(plan.cwdIdentity, ComputerWorkspaceIdentity.at(root, directory: true)?.digest)
            guard case .object(let payload) = plan.json else { return XCTFail("plan payload") }
            XCTAssertEqual(payload["plan_digest"], .string(plan.digest))
            XCTAssertEqual(payload["executable_sha256"], .string(plan.executableDigest))
            let again = try ComputerCommandPlan.resolve(
                command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
            XCTAssertEqual(again.digest, plan.digest)
        }

        func testShellCommandsBindTheZshLauncher() throws {
            let root = try folder()
            let plan = try ComputerCommandPlan.resolve(
                command: "echo synthetic", argv: nil, cwd: root, roots: [root], path: "/usr/bin:/bin")
            guard let pointer = realpath("/bin/zsh", nil) else {
                return XCTFail("/bin/zsh is required on macOS")
            }
            defer { free(pointer) }
            XCTAssertEqual(plan.executable, String(cString: pointer))
            XCTAssertEqual(
                plan.executableDigest,
                digest(try Data(contentsOf: URL(fileURLWithPath: String(cString: pointer)))))
        }

        func testModifyingOrReplacingTheExecutableChangesTheBoundDigest() throws {
            let root = try folder()
            let tool = try script(root + "/tool.sh")
            let original = try ComputerCommandPlan.resolve(
                command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
            try "#!/bin/sh\necho changed\n".write(toFile: tool, atomically: true, encoding: .utf8)
            let modified = try ComputerCommandPlan.resolve(
                command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
            XCTAssertNotEqual(modified.digest, original.digest)
            XCTAssertNotEqual(modified.executableDigest, original.executableDigest)
            try FileManager.default.removeItem(atPath: tool)
            try script(root + "/tool.sh", body: "#!/bin/sh\necho replaced\n")
            let replaced = try ComputerCommandPlan.resolve(
                command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
            XCTAssertNotEqual(replaced.digest, original.digest)
        }

        func testReplacingTheWorkingFolderAtTheSamePathChangesTheBoundDigest() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("plan-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: base) }
            let rootPath = base.appendingPathComponent("workspace", isDirectory: true).path
            try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
            guard let pointer = realpath(rootPath, nil) else { return XCTFail("resolve") }
            defer { free(pointer) }
            let root = String(cString: pointer)
            let tool = try script(root + "/tool.sh")
            let original = try ComputerCommandPlan.resolve(
                command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
            try FileManager.default.removeItem(atPath: rootPath)
            try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
            try script(root + "/tool.sh")
            let replaced = try ComputerCommandPlan.resolve(
                command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
            XCTAssertNotEqual(replaced.cwdIdentity, original.cwdIdentity)
            XCTAssertNotEqual(replaced.digest, original.digest)
        }

        func testUnreadableExecutablesRefusePreparationInsteadOfApproving() throws {
            let root = try folder()
            let tool = try script(root + "/tool.sh")
            guard chmod(tool, 0o000) == 0 else { return XCTFail("chmod") }
            XCTAssertEqual(
                code {
                    try ComputerCommandPlan.resolve(
                        command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
                }, "not_found")
            XCTAssertEqual(
                code {
                    try ComputerCommandPlan.resolveExecutable(tool, driftOnFailure: false)
                }, "plan_unresolved")
            XCTAssertEqual(
                code {
                    try ComputerCommandPlan.resolveExecutable(tool, driftOnFailure: true)
                }, "plan_drift")
            guard chmod(tool, 0o755) == 0 else { return XCTFail("restore chmod") }
        }

        func testExecutablesBeyondTheSizeCapAreRefused() throws {
            let root = try folder()
            let tool = root + "/large.sh"
            guard FileManager.default.createFile(atPath: tool, contents: Data()) else {
                return XCTFail("create")
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tool))
            defer { try? handle.close() }
            try handle.truncate(atOffset: Int64(ComputerCommandPlan.maximumExecutableBytes) + 1)
            XCTAssertEqual(
                code {
                    try ComputerCommandPlan.resolveExecutable(tool, driftOnFailure: false)
                }, "plan_unresolved")
        }

        func testFilePlanBindsVerbPathRootAndRefusesReplacedFolders() throws {
            let root = try folder()
            let plan = try ComputerFilePlan(
                verb: "write_file", path: root + "/notes.md", root: root,
                rootIdentity: ComputerWorkspaceIdentity.at(root, directory: true)?.digest ?? "")
            let twin = try ComputerFilePlan(
                verb: "write_file", path: root + "/notes.md", root: root,
                rootIdentity: ComputerWorkspaceIdentity.at(root, directory: true)?.digest ?? "")
            XCTAssertEqual(plan.digest, twin.digest)
            XCTAssertTrue(plan.matchesEvidence(plan.digest))
            XCTAssertFalse(plan.matchesEvidence(plan.digest + "0"))
            XCTAssertFalse(plan.matchesEvidence(nil))
            let deletion = try ComputerFilePlan(
                verb: "delete_path", path: root + "/notes.md", root: root, rootIdentity: plan.rootIdentity)
            XCTAssertNotEqual(deletion.digest, plan.digest)
            XCTAssertNoThrow(try plan.recheck())
            let rootPath = root
            try FileManager.default.removeItem(atPath: rootPath)
            try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
            XCTAssertEqual(code { try plan.recheck() }, "plan_drift")
        }

        func testFilePlanConstructionRejectsOutsidePathsAndUnknownVerbs() throws {
            let root = try folder()
            let identity = ComputerWorkspaceIdentity.at(root, directory: true)?.digest ?? ""
            for (verb, path) in [("write_file", "/elsewhere/notes.md"), ("list_dir", root + "/x")] {
                XCTAssertThrowsError(
                    try ComputerFilePlan(verb: verb, path: path, root: root, rootIdentity: identity), verb)
            }
            XCTAssertNoThrow(
                try ComputerFilePlan(verb: "write_file", path: root, root: root, rootIdentity: identity))
        }
    }
#endif
