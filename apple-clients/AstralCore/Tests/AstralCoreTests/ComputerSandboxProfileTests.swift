// Asserts the generated Seatbelt profile text for both modes: write containment, protected metadata,
// unreadable exclusions and keychains, proxy-only network, and that the enforce profile compiles with the
// system sandbox-exec on a real Mac.

#if os(macOS)
    import Darwin
    import XCTest

    @testable import AstralCore

    final class ComputerSandboxProfileTests: XCTestCase {
        private func input(
            mode: ComputerSandboxMode = .enforce, roots: [String] = ["/Users/sam/Work/Pi-Agent"],
            exclusions: [String] = ComputerWorkspaceExclusions.defaults.patterns, home: String = "/Users/sam",
            bundle: String? = "/Applications/AstralDeep.app", port: UInt16? = 45678
        ) -> ComputerSandboxProfile.Input {
            ComputerSandboxProfile.Input(
                mode: mode, writeRoots: roots + ["/private/var/folders/job-temp"], exclusions: exclusions,
                home: home, bundlePath: bundle, supportIdentifier: "com.personalailabs.astraldeep", proxyPort: port)
        }

        func testEnforceProfileDeniesByDefaultAndAllowsOnlyGrantedWrites() {
            let profile = ComputerSandboxProfile.generate(input())
            XCTAssertTrue(profile.contains("(version 1)"))
            XCTAssertTrue(profile.contains("(deny default)"))
            XCTAssertTrue(profile.contains("(import \"system.sb\")"))
            XCTAssertTrue(profile.contains("(allow process-exec*)"))
            XCTAssertTrue(profile.contains("(allow file-read* (subpath \"/\"))"))
            let writeRule = "(allow file-write* "
            XCTAssertTrue(profile.contains(writeRule + "(subpath \"/Users/sam/Work/Pi-Agent\"))"))
            XCTAssertTrue(profile.contains(writeRule + "(subpath \"/private/var/folders/job-temp\"))"))
            XCTAssertFalse(profile.contains("(allow file-write* (subpath \"/Users/sam\"))"))
            XCTAssertTrue(profile.contains("(allow network-outbound (remote ip \"localhost:45678\"))"))
            XCTAssertTrue(profile.contains("(allow network-bind (local ip \"localhost:*\"))"))
            XCTAssertEqual(
                profile.components(separatedBy: "(allow network-outbound (remote ip").count - 1, 1)
            XCTAssertTrue(profile.contains("(allow network-outbound (remote unix-socket"))
            XCTAssertFalse(profile.contains("(allow default)"))
        }

        func testEnforceProfileKeepsProtectedMetadataReadOnly() {
            let profile = ComputerSandboxProfile.generate(input())
            XCTAssertTrue(profile.contains("(subpath \"/Users/sam/Work/Pi-Agent/.git/hooks\")"))
            XCTAssertTrue(profile.contains("(literal \"/Users/sam/Work/Pi-Agent/.git/config\")"))
            XCTAssertTrue(profile.contains("(literal \"/Users/sam/Work/Pi-Agent/.git/config.lock\")"))
            for file in ComputerSandboxProfile.shellStartupFiles {
                XCTAssertTrue(profile.contains("(literal \"/Users/sam/\(file)\"))"), file)
            }
            XCTAssertTrue(profile.contains("(subpath \"/Users/sam/Library/LaunchAgents\")"))
            XCTAssertTrue(profile.contains("(subpath \"/Library/LaunchAgents\")"))
            XCTAssertTrue(profile.contains("(subpath \"/System/Library/LaunchAgents\")"))
            XCTAssertTrue(profile.contains("(subpath \"/Applications/AstralDeep.app\")"))
            XCTAssertTrue(
                profile.contains("(subpath \"/Users/sam/Library/Application Support/com.personalailabs.astraldeep\")"))
            XCTAssertTrue(
                profile.contains("(literal \"/Users/sam/Library/Preferences/com.personalailabs.astraldeep.plist\")"))
        }

        func testEnforceProfileMakesExclusionsAndKeychainsUnreadable() {
            let profile = ComputerSandboxProfile.generate(input())
            XCTAssertTrue(profile.contains("(deny file-read* (subpath \"/Users/sam/Library/Keychains\"))"))
            XCTAssertTrue(profile.contains("(deny file-read* (subpath \"/Library/Keychains\"))"))
            XCTAssertTrue(profile.contains("(deny file-read* (subpath \"/System/Library/Keychains\"))"))
            XCTAssertTrue(profile.contains("(deny file-read* (literal \"/Users/sam/Work/Pi-Agent/private\"))"))
            XCTAssertTrue(profile.contains("(deny file-read* (subpath \"/Users/sam/Work/Pi-Agent/private\"))"))
            XCTAssertTrue(
                profile.contains("(deny file-read* (literal \"/Users/sam/Work/Pi-Agent/realm-export.json\"))"))
            XCTAssertTrue(
                profile.contains(
                    "(deny file-read* (regex #\"^/Users/sam/Work/Pi-Agent(/[^/]+)*/[^/]*[.][pP][eE][mM](/|$)\"))"))
            XCTAssertTrue(profile.contains("[.][eE][nN][vV][^/]*"))
        }

        func testExclusionRegexesAnchorUnderTheRootAndMatchAnyDepth() throws {
            let rules = ComputerSandboxProfile.readDenials(
                root: "/Users/sam/Work", patterns: ["*.pem", "private/", "id_rsa*", "credentials?.json"])
            XCTAssertTrue(rules.count == 5)
            let pem = try XCTUnwrap(rules.first { $0.contains("[.][pP][eE][mM]") })
            XCTAssertTrue(
                pem.hasPrefix(
                    "(deny file-read* (regex #\"^/Users/sam/Work" + "(/[^/]+)*/[^/]*[.][pP][eE][mM](/|$)"))
            let directory = try XCTUnwrap(rules.first { $0.contains("private") && $0.contains("literal") })
            XCTAssertTrue(directory.contains("(literal \"/Users/sam/Work/private\")"))
            XCTAssertEqual(
                ComputerSandboxProfile.globRegex("*.pem"), "[^/]*[.]pem")
            XCTAssertEqual(ComputerSandboxProfile.globRegex("id_rsa*"), "id_rsa[^/]*")
            XCTAssertEqual(ComputerSandboxProfile.globRegex("credentials?.json"), "credentials[^/][.]json")
            XCTAssertEqual(ComputerSandboxProfile.globRegex("[abc].txt"), "[abc][.]txt")
            XCTAssertEqual(ComputerSandboxProfile.globRegex("[!a-z].txt"), "[^a-z][.]txt")
            XCTAssertEqual(ComputerSandboxProfile.globRegex("a+b.txt"), "a[+]b[.]txt")
            XCTAssertEqual(ComputerSandboxProfile.globRegex("unterminated"), "unterminated")
        }

        func testShadowProfileAllowsEverythingAndOmitsNetworkRules() {
            let profile = ComputerSandboxProfile.generate(input(mode: .shadow, port: nil))
            XCTAssertTrue(profile.contains("(allow default)"))
            XCTAssertFalse(profile.contains("(deny"))
            XCTAssertFalse(profile.contains("network"))
            XCTAssertEqual(
                ComputerSandboxProfile.generate(input(mode: .shadow)),
                ComputerSandboxProfile.generate(input(mode: .shadow, port: nil)))
        }

        func testDigestIsStableAndInputSensitive() {
            let first = ComputerSandboxProfile.digest(ComputerSandboxProfile.generate(input()))
            let second = ComputerSandboxProfile.digest(ComputerSandboxProfile.generate(input()))
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.count, 64)
            XCTAssertNotEqual(
                first, ComputerSandboxProfile.digest(ComputerSandboxProfile.generate(input(port: 1))))
        }

        func testGeneratedEnforceProfileCompilesWithTheSystemLauncher() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let profilePath = directory.appendingPathComponent("profile.sb").path
            let profile = ComputerSandboxProfile.generate(
                input(
                    roots: [directory.path], exclusions: ["private/", "*.pem"], home: NSHomeDirectory(),
                    bundle: nil, port: 45678))
            try Data(profile.utf8).write(to: URL(fileURLWithPath: profilePath))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ComputerSandboxProfile.launcherPath)
            process.arguments = ["-f", profilePath, ComputerSandboxProfile.probeProgram]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(
                process.terminationStatus, 0,
                String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        func testEnforceProfileRefusesMixedCaseExcludedFiles() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let profilePath = directory.appendingPathComponent("profile.sb")
            let pointer = try XCTUnwrap(realpath(directory.path, nil))
            defer { free(pointer) }
            let root = String(cString: pointer)
            let profile = ComputerSandboxProfile.generate(
                input(roots: [root], exclusions: ["*.pem", ".env*"], bundle: nil, port: nil))
            try Data(profile.utf8).write(to: profilePath)
            for name in ["secret.PEM", ".ENV.local"] {
                let path = directory.appendingPathComponent(name)
                try Data("private".utf8).write(to: path)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ComputerSandboxProfile.launcherPath)
                process.arguments = ["-f", profilePath.path, "/bin/cat", path.path]
                process.standardError = Pipe()
                process.standardOutput = Pipe()
                try process.run()
                process.waitUntilExit()
                XCTAssertNotEqual(process.terminationStatus, 0, name)
            }
        }

        func testGeneratedShadowProfileAlsoCompiles() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let profilePath = directory.appendingPathComponent("profile.sb").path
            try Data(ComputerSandboxProfile.generate(input(mode: .shadow, port: nil)).utf8)
                .write(to: URL(fileURLWithPath: profilePath))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ComputerSandboxProfile.launcherPath)
            process.arguments = ["-f", profilePath, ComputerSandboxProfile.probeProgram]
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }
#endif
