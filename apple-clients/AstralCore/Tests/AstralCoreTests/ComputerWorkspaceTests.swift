// Exercises actual descriptor-relative workspace IO, atomic overwrite policy, and symlink denials.
// The native host grants selected roots to this filesystem boundary rather than trusting path strings.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    final class ComputerWorkspaceTests: XCTestCase {
        func testWriteCreatesNestedParentDirectoriesInsideWorkspace() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("minecraft/src/main.py").path

            try workspace.write(path, content: "print('hello')", overwrite: false, authorize: {})

            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "print('hello')")
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("minecraft/src").path))
            XCTAssertThrowsError(try workspace.write(path, content: "changed", overwrite: false, authorize: {}))
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "print('hello')")
            try workspace.write(path, content: "updated", overwrite: true, authorize: {})
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "updated")
        }

        func testNestedWriteDenialAndInvalidContentCreateNoDirectories() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("new/nested/file.txt").path

            XCTAssertThrowsError(
                try workspace.write(path, content: "blocked", overwrite: false) {
                    throw ComputerHostError("permission_denied", "revoked")
                }
            ) { error in
                XCTAssertEqual((error as? ComputerHostError)?.effectState, "not_started")
            }
            XCTAssertThrowsError(
                try workspace.write(
                    path, content: String(repeating: "x", count: 262145), overwrite: false, authorize: {}))
            XCTAssertThrowsError(
                try workspace.write(
                    root.path + "/../escaped/nested/file.txt", content: "blocked", overwrite: false, authorize: {})
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.deletingLastPathComponent().appendingPathComponent("escaped").path))
        }

        func testNestedWriteAuthorityRevocationAfterParentCreationReportsUncertainEffect() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("first/second/file.txt").path
            var checks = 0

            XCTAssertThrowsError(
                try workspace.write(path, content: "blocked", overwrite: false) {
                    checks += 1
                    if checks == 2 { throw ComputerHostError("permission_denied", "revoked") }
                }
            ) { error in
                XCTAssertNil((error as? ComputerHostError)?.effectState)
            }

            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("first").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("first/second").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }

        func testSymlinkInsertedBeforeMissingParentCreationIsNotFollowed() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("missing/child/file.txt").path

            XCTAssertThrowsError(
                try workspace.write(path, content: "blocked", overwrite: false) {
                    try FileManager.default.createSymbolicLink(
                        at: root.appendingPathComponent("missing"), withDestinationURL: outside)
                }
            ) { error in
                XCTAssertNil((error as? ComputerHostError)?.effectState)
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("child").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("file.txt").path))
        }

        func testMissingReadAndPreEffectWriteDenialCarryTypedOutcomes() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("missing.txt").path
            XCTAssertThrowsError(try workspace.read(path, maximum: 100)) { error in
                XCTAssertEqual((error as? ComputerHostError)?.code, "not_found")
                XCTAssertEqual((error as? ComputerHostError)?.effectState, "not_started")
                XCTAssertEqual((error as? ComputerHostError)?.responseError["effect_state"], .string("not_started"))
            }
            XCTAssertThrowsError(
                try workspace.write(path, content: "new", overwrite: false) {
                    throw ComputerHostError("permission_denied", "revoked")
                }
            ) { error in
                XCTAssertEqual((error as? ComputerHostError)?.effectState, "not_started")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }

        func testDenialAfterTemporaryWriteRetainsUncertainOutcome() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("target.txt").path
            var calls = 0
            XCTAssertThrowsError(
                try workspace.write(path, content: "new", overwrite: false) {
                    calls += 1
                    if calls == 3 { throw ComputerHostError("permission_denied", "revoked") }
                }
            ) { error in
                XCTAssertNil((error as? ComputerHostError)?.effectState)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }

        func testReviewedCreateRefusesAFileCreatedAfterReview() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let file = root.appendingPathComponent("target.txt")
            XCTAssertThrowsError(try workspace.read(file.path, maximum: 100))
            try Data("competing".utf8).write(to: file)
            XCTAssertThrowsError(try workspace.write(file.path, content: "reviewed", overwrite: false, authorize: {}))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "competing")
        }

        func testReviewedCreateRefusesACompetingFileBeforeRename() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let file = root.appendingPathComponent("target.txt")
            XCTAssertThrowsError(try workspace.read(file.path, maximum: 100)) { error in
                XCTAssertEqual((error as? ComputerHostError)?.code, "not_found")
            }
            var checks = 0
            XCTAssertThrowsError(
                try workspace.write(file.path, content: "reviewed", overwrite: false) {
                    checks += 1
                    if checks == 3 { try Data("competing".utf8).write(to: file) }
                })
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "competing")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["target.txt"])
        }

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

        func testRefusedExistingFileExplainsHowToOverwrite() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("existing.txt").path
            try workspace.write(path, content: "original", overwrite: false, authorize: {})

            XCTAssertThrowsError(try workspace.write(path, content: "replacement", overwrite: false, authorize: {})) {
                error in
                XCTAssertEqual((error as? ComputerHostError)?.code, "already_exists")
                XCTAssertEqual(
                    (error as? ComputerHostError)?.message,
                    "File exists; retry with if_exists=overwrite to replace it")
            }
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "original")
        }

        func testTruncatedReadEndsOnTheLastCompleteScalar() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("text.txt").path
            try Data("aé🧭z".utf8).write(to: URL(fileURLWithPath: path))
            for (maximum, expected, truncated) in [
                (1, "a", true), (2, "a", true), (3, "aé", true), (4, "aé", true), (6, "aé", true), (7, "aé🧭", true),
                (8, "aé🧭z", false), (100, "aé🧭z", false),
            ] {
                let read = try workspace.read(path, maximum: maximum)
                XCTAssertEqual(read["text"], .string(expected), "\(maximum)")
                XCTAssertEqual(read["truncated"], .bool(truncated), "\(maximum)")
            }
            try Data([0x61, 0xff, 0x62, 0x63]).write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try workspace.read(path, maximum: 3))
            XCTAssertEqual(ComputerWorkspace.scalarBoundary([0xe2, 0x80], 2), 0)
            XCTAssertEqual(ComputerWorkspace.scalarBoundary([0x80, 0x80], 2), 2)
        }

        func testOverwriteKeepsModeAndExtendedAttributesButNotSetID() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try ComputerWorkspace(root: root.path)
            let path = root.appendingPathComponent("script.sh").path
            try workspace.write(path, content: "echo one", overwrite: false, authorize: {})
            XCTAssertEqual(chmod(path, 0o4751), 0)
            let value = Array("synthetic".utf8)
            XCTAssertEqual(setxattr(path, "com.example.tag", value, value.count, 0, 0), 0)
            try workspace.write(path, content: "echo two", overwrite: true, authorize: {})
            var info = stat()
            XCTAssertEqual(stat(path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, 0o751)
            var buffer = [UInt8](repeating: 0, count: 64)
            let length = getxattr(path, "com.example.tag", &buffer, buffer.count, 0, 0)
            XCTAssertEqual(Array(buffer.prefix(max(0, length))), value)
            XCTAssertEqual(try workspace.read(path, maximum: 100)["text"], .string("echo two"))
            let fresh = root.appendingPathComponent("fresh.txt").path
            try workspace.write(fresh, content: "new", overwrite: true, authorize: {})
            XCTAssertEqual(stat(fresh, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, 0o600)
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(entries.contains { $0.hasPrefix(".astral-") })
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

        func testDefaultExclusionsRefuseEveryFileVerbAndListingsOmitAndCountThem() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let manager = FileManager.default
            for directory in ["private", "src/private", "src/lib"] {
                try manager.createDirectory(
                    at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            }
            let hidden = [
                "private/notes.md", "src/private/plan.md", ".env", "src/.env.local", "server.pem", "deploy.key",
                "AuthKey.p8", "cert.p12", "credentials-prod.json", "realm-export.json", "id_rsa", "id_ed25519.pub",
                "login.keychain-db",
            ]
            for path in hidden + ["README.md", "src/lib/main.swift", "environment.txt", "keys.txt"] {
                try Data("secret".utf8).write(to: root.appendingPathComponent(path))
            }
            let workspace = try ComputerWorkspace(root: root.path)
            XCTAssertEqual(workspace.exclusions, .defaults)
            func code(_ work: () throws -> Any) -> ComputerHostError? {
                do {
                    _ = try work()
                    return nil
                } catch { return error as? ComputerHostError }
            }
            for path in hidden + ["private", "PRIVATE/notes.md", ".ENV", "src/Private/x.md"] {
                let full = workspace.root + "/" + path
                for refusal in [
                    code { try workspace.read(full, maximum: 100) },
                    code { try workspace.write(full, content: "x", overwrite: true, authorize: {}) },
                    code { try workspace.delete(full, authorize: {}) },
                ] {
                    XCTAssertEqual(refusal?.code, "excluded_path", path)
                    XCTAssertEqual(refusal?.effectState, "not_started", path)
                }
            }
            let message = code { try workspace.read(workspace.root + "/src/private/plan.md", maximum: 10) }?.message
            XCTAssertEqual(
                message,
                "src/private/plan.md is excluded from Astral's file and command tools by the workspace pattern "
                    + "private/.")
            XCTAssertEqual(
                code { try workspace.list(workspace.root + "/private") }?.code, "excluded_path")
            XCTAssertEqual(
                code {
                    try workspace.write(
                        workspace.root + "/private/new/file.txt", content: "x", overwrite: false, authorize: {})
                }?.code, "excluded_path")
            XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("private/new").path))
            for path in hidden { XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent(path).path)) }
            let listing = try workspace.list(workspace.root)
            let names = Set(listing["entries"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
            XCTAssertEqual(names, ["README.md", "src", "environment.txt", "keys.txt"])
            XCTAssertEqual(listing["count"], .number(4))
            XCTAssertEqual(listing["excluded"], .number(11))
            let nested = try workspace.list(workspace.root + "/src")
            XCTAssertEqual(nested["entries"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["lib"])
            XCTAssertEqual(nested["excluded"], .number(2))
            XCTAssertEqual(try workspace.list(workspace.root + "/src/lib")["excluded"], .number(0))
            XCTAssertEqual(try workspace.read(workspace.root + "/keys.txt", maximum: 100)["text"], .string("secret"))
            try workspace.write(workspace.root + "/src/lib/new.swift", content: "ok", overwrite: false, authorize: {})
            try workspace.delete(workspace.root + "/src/lib/new.swift", authorize: {})
            let open = try ComputerWorkspace(root: root.path, exclusions: .none)
            XCTAssertEqual(try open.read(open.root + "/private/notes.md", maximum: 100)["text"], .string("secret"))
            XCTAssertEqual(try open.list(open.root)["excluded"], .number(0))
        }

        func testExclusionPatternsValidateLikeTheServerAndMatchNamesCaseInsensitively() throws {
            let defaults = ComputerWorkspaceExclusions.defaults
            XCTAssertEqual(
                defaults.patterns,
                [
                    "private/", ".env*", "*.pem", "*.key", "*.p8", "*.p12", "credentials*.json", "realm-export.json",
                    "id_rsa*", "id_ed25519*", "*.keychain*",
                ])
            XCTAssertEqual(defaults.pattern(matchingName: "Private"), "private/")
            XCTAssertEqual(defaults.pattern(matchingName: ".env.production"), ".env*")
            XCTAssertEqual(defaults.pattern(matchingName: "credentials.json"), "credentials*.json")
            XCTAssertEqual(defaults.pattern(matchingComponents: ["a", "b", "id_rsa.pub"]), "id_rsa*")
            for name in ["privately", "env", "pem", "keys", "credentials.yaml", "realm.json", ".", "..", ""] {
                XCTAssertNil(defaults.pattern(matchingName: name), name)
            }
            XCTAssertEqual(
                try ComputerWorkspaceExclusions(patterns: ["build/", "*.log"]).patterns, ["build/", "*.log"])
            let invalid: [[String]] = [
                ["a/b"], ["/"], ["  "], ["a", "a"], ["x\n"], [String(repeating: "p", count: 129)],
                (0...32).map { "p\($0)" },
            ]
            for patterns in invalid {
                XCTAssertThrowsError(try ComputerWorkspaceExclusions(patterns: patterns), "\(patterns)")
            }
            XCTAssertTrue(ComputerWorkspaceExclusions.valid((0..<32).map { "p\($0)" }))
            XCTAssertFalse(ComputerWorkspaceExclusions.valid(["///"]))
        }
    }

#endif
