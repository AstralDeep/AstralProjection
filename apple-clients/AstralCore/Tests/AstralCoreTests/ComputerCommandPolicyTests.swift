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
                inherited: inherited, path: "/usr/bin:/bin",
                additions: ["APP_MODE": "test", "LANG": "en_GB.UTF-8", "NO_COLOR": "1", "TERM": "xterm"])
            XCTAssertEqual(
                env,
                [
                    "PATH": "/usr/bin:/bin", "HOME": "/Users/sam", "USER": "sam", "LANG": "en_GB.UTF-8", "LC_ALL": "C",
                    "LC_CTYPE": "UTF-8", "TMPDIR": "/tmp/x", "SHELL": "/bin/zsh", "TERM": "xterm", "APP_MODE": "test",
                    "NO_COLOR": "1", "EDITOR": "/usr/bin/false", "VISUAL": "/usr/bin/false",
                    "GIT_EDITOR": "/usr/bin/false", "PAGER": "cat", "GIT_PAGER": "cat",
                ])
            let longest = "APP_" + String(repeating: "A", count: 60)
            let named = ComputerCommandPolicy.requestNames.union(["APP_", "APP_X1", longest])
            for name in named {
                XCTAssertTrue(ComputerCommandPolicy.requestable(name), name)
            }
        }

        func testRequestEnvironmentIsAnAllowlistAndForbiddenNamesStayRefused() throws {
            for name in [
                "ASTRAL_SESSION", "astral_x", "API_TOKEN", "MY_SECRET", "AWS_ACCESS_KEY_ID", "db_password", "KEYCHAIN",
                "Token", "FOO", "HOME", "PATH", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "SHELL", "lang", "app_mode",
                "APP_TOKEN", "APP_API_KEY", "APP_" + String(repeating: "A", count: 61), "1BAD", "_APP", "LC_NUMERIC",
                "EDITOR", "VISUAL", "GIT_EDITOR", "PAGER", "GIT_PAGER", "LESS", "MANPAGER",
            ] {
                XCTAssertEqual(
                    code {
                        try ComputerCommandPolicy.environment(inherited: [:], path: "/bin", additions: [name: "v"])
                    }, "env_forbidden", name)
            }
            for value in ["a\0b", "line\nbreak", "carriage\rreturn", String(repeating: "v", count: 4097)] {
                XCTAssertEqual(
                    code {
                        try ComputerCommandPolicy.environment(inherited: [:], path: "/bin", additions: ["APP_V": value])
                    }, "out_of_range")
            }
            XCTAssertNoThrow(
                try ComputerCommandPolicy.environment(
                    inherited: [:], path: "/bin", additions: ["APP_V": String(repeating: "v", count: 4096)]))
            let many = Dictionary(uniqueKeysWithValues: (0..<33).map { ("APP_V\($0)", "x") })
            XCTAssertEqual(
                code { try ComputerCommandPolicy.environment(inherited: [:], path: "/bin", additions: many) },
                "out_of_range")
            XCTAssertFalse(ComputerCommandPolicy.forbidden("PATH"))
            XCTAssertTrue(ComputerCommandPolicy.forbidden("MONKEY_BUSINESS"))
        }

        func testEditorsAndPagersAreForcedInertWhateverTheBaseHolds() throws {
            let env = try ComputerCommandPolicy.environment(
                inherited: ["EDITOR": "vim", "VISUAL": "code -w", "PAGER": "less", "GIT_PAGER": "delta", "HOME": "/h"],
                path: "/bin", additions: ["APP_EDITOR": "nano"])
            for (name, value) in ComputerCommandPolicy.forcedNames { XCTAssertEqual(env[name], value, name) }
            XCTAssertEqual(env["APP_EDITOR"], "nano")
            XCTAssertEqual(
                Set(ComputerCommandPolicy.forcedNames.keys), ["EDITOR", "VISUAL", "GIT_EDITOR", "PAGER", "GIT_PAGER"])
            XCTAssertTrue(ComputerCommandPolicy.requestNames.isDisjoint(with: ComputerCommandPolicy.forcedNames.keys))
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
            XCTAssertEqual(
                code { try ComputerCommandPolicy.workingDirectory(alias.path, roots: [root.path]) },
                "cwd_outside_workspace")
            let rootAlias = outside.appendingPathComponent("root-alias")
            try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: root)
            XCTAssertEqual(
                try ComputerCommandPolicy.workingDirectory(inside.path, roots: [rootAlias.path]), inside.path)
        }

        func testFoldersOutsideEveryRootAreRefusedWithoutBeingResolved() throws {
            let root = try folder()
            let inside = root.appendingPathComponent("inside")
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            var resolved: [String] = []
            func check(_ cwd: String) throws -> String {
                try ComputerCommandPolicy.workingDirectory(cwd, roots: [root.path]) { path in
                    resolved.append(path)
                    guard let pointer = realpath(path, nil) else { return nil }
                    defer { free(pointer) }
                    return String(cString: pointer)
                }
            }
            for cwd in [
                NSHomeDirectory() + "/Desktop", "/Volumes/Unmounted/share", root.path + "/../elsewhere",
                root.path + "-sibling", "",
            ] {
                XCTAssertEqual(code { try check(cwd) }, "cwd_outside_workspace", cwd)
            }
            XCTAssertEqual(resolved, Array(repeating: root.path, count: 4))
            resolved = []
            XCTAssertEqual(try check(root.path + "/./inside/../inside"), inside.path)
            XCTAssertEqual(resolved, [root.path, root.path + "/./inside/../inside"])
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

        func testOnlyPlainArgvInvocationsAreGrantable() throws {
            func argv(_ items: String...) throws -> ComputerCommandInvocation {
                try ComputerCommandPolicy.invocation(command: nil, argv: items)
            }
            let plain = try argv("wc", "-l", "notes.md")
            XCTAssertEqual(plain.argv0, "wc")
            XCTAssertTrue(plain.grantable)
            let literal = try argv("/usr/bin/wc", "-l", "a;b|c", "*.md", "$HOME", "~", "{a,b}")
            XCTAssertEqual(literal.argv0, "wc")
            XCTAssertTrue(literal.grantable)
            XCTAssertTrue(try argv("git", "status").grantable)
            XCTAssertTrue(try argv("git", "checkout", "main").grantable)
            XCTAssertTrue(try argv("find", ".", "-name", "x").grantable)
            for command in [
                "wc -l notes.md", "wc -l 'notes file.md'", "wc -l *.md", "ls ~", "echo $HOME", "ls {a,b}", "=ls",
                "wc -l $(ls)", "wc `ls`", "cat a | wc", "ls; rm x", "a && b", "a || b", "echo > out", "wc < in",
                "ls\nrm x", "sleep 5 &", "FOO=1 wc -l x", "wc 'unbalanced",
            ] {
                let invocation = try ComputerCommandPolicy.invocation(command: command, argv: nil)
                XCTAssertFalse(invocation.grantable, command)
                XCTAssertEqual(invocation.command, command)
                XCTAssertNil(invocation.argv)
            }
            XCTAssertEqual(try ComputerCommandPolicy.invocation(command: "wc -l notes.md", argv: nil).argv0, "wc")
            for wrapper in [
                "nice", "nohup", "time", "command", "exec", "caffeinate", "awk", "gawk", "sed", "make", "xcrun",
                "swift", "php", "lua", "tclsh", "osascript", "env", "su", "sudo", "script", "expect", "screen", "tmux",
                "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "python", "python3", "node", "ruby", "perl",
                "xargs", "open", "launchctl", "defaults", "security", "/usr/bin/nice", "/usr/bin/TIME",
            ] {
                XCTAssertFalse(try argv(wrapper, "wc", "-l", "notes.md").grantable, wrapper)
            }
            for effect in [
                ["find", ".", "-delete"], ["find", ".", "-exec", "rm", "{}", ";"], ["find", ".", "-execdir", "x"],
                ["git", "push"], ["git", "reset", "--hard"], ["git", "clean", "-fd"], ["git", "rebase", "main"],
                ["git", "checkout", "--", "file"],
            ] {
                let invocation = try ComputerCommandPolicy.invocation(command: nil, argv: effect)
                XCTAssertFalse(invocation.grantable, "\(effect)")
            }
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
