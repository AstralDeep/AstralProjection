// Exercises the host command policy against real temporary folders, symlinks and executables.
// Environment, timeout, program and grantable-form decisions are checked without launching a process.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    final class ComputerCommandPolicyTests: XCTestCase {
        private func folder() throws -> URL {
            let created = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: created) }
            let pointer = try XCTUnwrap(realpath(created.path, nil))
            defer { free(pointer) }
            return URL(fileURLWithPath: String(cString: pointer))
        }
        private func code(_ work: () throws -> Any) -> String? {
            do {
                _ = try work()
                return nil
            } catch { return (error as? ComputerHostError)?.code }
        }

        func testEnvironmentKeepsOnlyTheLoginAllowlistAndForcesDumbTerminal() throws {
            let inherited = [
                "PATH": "/inherited", "HOME": "/Users/sam", "USER": "sam", "LANG": "en_US.UTF-8", "LC_ALL": "C",
                "LC_CTYPE": "UTF-8", "TMPDIR": "/tmp/x", "SHELL": "/bin/zsh", "TERM": "xterm-256color",
                "ASTRAL_TOKEN": "secret", "GITHUB_TOKEN": "secret", "SSH_AUTH_SOCK": "/tmp/agent", "DYLD_X": "y",
            ]
            let env = try ComputerCommandPolicy.environment(
                inherited: inherited, path: "/usr/bin:/bin", additions: ["FOO": "bar", "HOME": "/override"])
            XCTAssertEqual(
                env,
                [
                    "PATH": "/usr/bin:/bin", "HOME": "/override", "USER": "sam", "LANG": "en_US.UTF-8", "LC_ALL": "C",
                    "LC_CTYPE": "UTF-8", "TMPDIR": "/tmp/x", "SHELL": "/bin/zsh", "TERM": "dumb", "FOO": "bar",
                ])
        }

        func testForbiddenEnvironmentNamesAreRefusedCaseInsensitively() throws {
            for name in [
                "ASTRAL_SESSION", "astral_x", "API_TOKEN", "MY_SECRET", "AWS_ACCESS_KEY_ID", "db_password", "KEYCHAIN",
                "Token",
            ] {
                XCTAssertEqual(
                    code {
                        try ComputerCommandPolicy.environment(inherited: [:], path: "/bin", additions: [name: "v"])
                    }, "env_forbidden", name)
            }
            XCTAssertEqual(
                code { try ComputerCommandPolicy.environment(inherited: [:], path: "/bin", additions: ["1BAD": "v"]) },
                "out_of_range")
            XCTAssertEqual(
                code { try ComputerCommandPolicy.environment(inherited: [:], path: "/bin", additions: ["A": "a\0b"]) },
                "out_of_range")
            let many = Dictionary(uniqueKeysWithValues: (0..<33).map { ("V\($0)", "x") })
            XCTAssertEqual(
                code { try ComputerCommandPolicy.environment(inherited: [:], path: "/bin", additions: many) },
                "out_of_range")
            XCTAssertFalse(ComputerCommandPolicy.forbidden("PATH"))
            XCTAssertTrue(ComputerCommandPolicy.forbidden("MONKEY_BUSINESS"))
        }

        func testWorkingDirectoryMustResolveInsideAGrantedRoot() throws {
            let root = try folder()
            let outside = try folder()
            let nested = root.appendingPathComponent("a/b")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            XCTAssertEqual(try ComputerCommandPolicy.workingDirectory(root.path, roots: [root.path]), root.path)
            XCTAssertEqual(try ComputerCommandPolicy.workingDirectory(nested.path, roots: [root.path]), nested.path)
            XCTAssertEqual(
                try ComputerCommandPolicy.workingDirectory(root.path + "/a/../a/b", roots: [root.path]), nested.path)
            XCTAssertEqual(
                code { try ComputerCommandPolicy.workingDirectory(outside.path, roots: [root.path]) },
                "cwd_outside_workspace")
            XCTAssertEqual(
                code { try ComputerCommandPolicy.workingDirectory(nested.path, roots: []) }, "cwd_outside_workspace")
            XCTAssertEqual(
                code { try ComputerCommandPolicy.workingDirectory(root.path + "/missing", roots: [root.path]) },
                "cwd_outside_workspace")
            XCTAssertEqual(
                code { try ComputerCommandPolicy.workingDirectory("relative", roots: [root.path]) },
                "cwd_outside_workspace")
            let file = root.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            XCTAssertEqual(
                code { try ComputerCommandPolicy.workingDirectory(file.path, roots: [root.path]) },
                "cwd_outside_workspace")
        }

        func testSymlinkEscapesAndPrefixLookalikesAreRefused() throws {
            let root = try folder()
            let outside = try folder()
            let link = root.appendingPathComponent("escape")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertEqual(
                code { try ComputerCommandPolicy.workingDirectory(link.path, roots: [root.path]) },
                "cwd_outside_workspace")
            let sibling = URL(fileURLWithPath: root.path + "-sibling")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: sibling) }
            XCTAssertEqual(
                code { try ComputerCommandPolicy.workingDirectory(sibling.path, roots: [root.path]) },
                "cwd_outside_workspace")
            let inside = root.appendingPathComponent("inside")
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            let alias = outside.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inside)
            XCTAssertEqual(try ComputerCommandPolicy.workingDirectory(alias.path, roots: [root.path]), inside.path)
            let rootAlias = outside.appendingPathComponent("root-alias")
            try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: root)
            XCTAssertEqual(
                try ComputerCommandPolicy.workingDirectory(inside.path, roots: [rootAlias.path]), inside.path)
        }

        func testTimeoutAndStdinBounds() throws {
            XCTAssertEqual(try ComputerCommandPolicy.timeout(nil, background: false), 60)
            XCTAssertEqual(try ComputerCommandPolicy.timeout(600, background: false), 600)
            XCTAssertEqual(try ComputerCommandPolicy.timeout(3600, background: true), 3600)
            for (value, background) in [(0.0, false), (601, false), (3601, true), (1.5, true), (.nan, false)] {
                XCTAssertEqual(
                    code { try ComputerCommandPolicy.timeout(value, background: background) }, "out_of_range",
                    "\(value)")
            }
            XCTAssertNil(try ComputerCommandPolicy.stdin(nil))
            XCTAssertEqual(
                try ComputerCommandPolicy.stdin(String(repeating: "a", count: 16384))?.count, 16384)
            XCTAssertEqual(
                code { try ComputerCommandPolicy.stdin(String(repeating: "é", count: 8193)) }, "out_of_range")
        }

        func testArgv0AndGrantableForm() throws {
            func invocation(_ command: String) throws -> ComputerCommandInvocation {
                try ComputerCommandPolicy.invocation(command: command, argv: nil)
            }
            let argv = try ComputerCommandPolicy.invocation(command: nil, argv: ["/usr/bin/wc", "-l", "a;b|c"])
            XCTAssertEqual(argv.argv0, "wc")
            XCTAssertTrue(argv.grantable)
            let simple = try invocation("wc -l 'notes file.md'")
            XCTAssertEqual(simple.argv0, "wc")
            XCTAssertTrue(simple.grantable)
            for compound in [
                "wc -l $(ls)", "wc `ls`", "cat a | wc", "ls; rm x", "a && b", "a || b", "echo > out", "echo >> out",
                "wc < in", "ls\nrm x", "sleep 5 &", "FOO=1 wc -l x", "wc 'unbalanced",
            ] {
                XCTAssertFalse(try invocation(compound).grantable, compound)
            }
            for never in [
                "sh -c ls", "bash x", "/bin/zsh -c ls", "fish", "python3 x.py", "python", "node x", "ruby x",
                "perl x", "env FOO=1 ls", "xargs rm", "osascript -e x", "open .", "sudo ls", "su", "launchctl list",
                "defaults read", "security find", "find . -delete", "git push",
                "git reset --hard", "git clean -fd", "git rebase main", "git checkout -- file",
            ] {
                XCTAssertFalse(try invocation(never).grantable, never)
            }
            XCTAssertTrue(try invocation("find . -name x").grantable)
            XCTAssertTrue(try invocation("git status").grantable)
            XCTAssertTrue(try invocation("git checkout main").grantable)
            XCTAssertFalse(try ComputerCommandPolicy.invocation(command: nil, argv: ["bash", "-c", "ls"]).grantable)
            let find = try ComputerCommandPolicy.invocation(command: nil, argv: ["find", ".", "-exec", "rm", "{}", ";"])
            XCTAssertFalse(find.grantable)
            XCTAssertEqual(code { try ComputerCommandPolicy.invocation(command: "   ", argv: nil) }, "out_of_range")
            XCTAssertEqual(code { try ComputerCommandPolicy.invocation(command: nil, argv: [""]) }, "out_of_range")
            XCTAssertEqual(code { try ComputerCommandPolicy.invocation(command: nil, argv: []) }, "out_of_range")
        }

        func testTokenizerHonorsQuotesAndEscapes() {
            XCTAssertEqual(
                ComputerCommandPolicy.tokenize(#"a "b c" 'd e' f\ g "h\"i" ''"#),
                ["a", "b c", "d e", "f g", #"h"i"#, ""])
            XCTAssertNil(ComputerCommandPolicy.tokenize(#"a "b"#))
            XCTAssertNil(ComputerCommandPolicy.tokenize(#"a \"#))
            XCTAssertEqual(ComputerCommandPolicy.tokenize("  "), [])
        }

        func testExecutableResolutionUsesOnlyAbsolutePathEntries() throws {
            let root = try folder()
            let tool = root.appendingPathComponent("tool")
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let plain = root.appendingPathComponent("plain")
            try Data("x".utf8).write(to: plain)
            XCTAssertEqual(ComputerCommandPolicy.executable("tool", path: "relative:" + root.path, cwd: "/"), tool.path)
            XCTAssertNil(ComputerCommandPolicy.executable("tool", path: "relative", cwd: root.path))
            XCTAssertNil(ComputerCommandPolicy.executable("plain", path: root.path, cwd: "/"))
            XCTAssertEqual(ComputerCommandPolicy.executable("./tool", path: "", cwd: root.path), root.path + "/./tool")
            XCTAssertEqual(ComputerCommandPolicy.executable("/bin/echo", path: "", cwd: "/"), "/bin/echo")
            XCTAssertNil(ComputerCommandPolicy.executable("missing-tool", path: "/bin:/usr/bin", cwd: "/"))
        }

        func testLoginPathParsesTheLastAbsoluteLine() {
            XCTAssertEqual(
                ComputerCommandPolicy.loginPath("Welcome\n/opt/homebrew/bin:/usr/bin:/bin\n"),
                "/opt/homebrew/bin:/usr/bin:/bin")
            XCTAssertNil(ComputerCommandPolicy.loginPath(""))
            XCTAssertNil(ComputerCommandPolicy.loginPath("bin:/usr/bin"))
            XCTAssertNil(ComputerCommandPolicy.loginPath(String(repeating: "/a:", count: 3000)))
        }
    }
#endif
