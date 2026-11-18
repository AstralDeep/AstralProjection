// Runs the Python probe tool under the real sandbox-exec through ExecLauncher and asserts outcomes only: denials, limits, teardown, the environment and the refusals that start no process.
// probe_tool.py in Fixtures/exec is a copy of Deep's backend/astral_exec/conformance/probe_tool.py at Deep commit 98bada40, and a Python 3.11 at ASTRAL_EXEC_TEST_PYTHON must exist or every run fails.

#if os(macOS)
    import CryptoKit
    import Foundation
    import XCTest

    @testable import AstralCore

    private struct ExecRig {
        let root: String
        let data: String
        let home: String
        let outside: String
        let readable: String
        let python: String
        let prefix: String
        let source: String
        var calls = 0

        static func make() throws -> ExecRig {
            guard let configured = ProcessInfo.processInfo.environment["ASTRAL_EXEC_TEST_PYTHON"], !configured.isEmpty
            else {
                throw ExecRigError.pythonUnset
            }
            let root = try ExecTemporary.canonicalDirectory()
            let rig = ExecRig(
                root: root, data: root + "/data", home: root + "/home", outside: root + "/outside",
                readable: root + "/readable",
                python: try ExecPolicy.canonicalPath(configured), prefix: try basePrefix(of: configured),
                source: try String(contentsOf: ExecVectors.fixtureURL("probe_tool", "py"), encoding: .utf8))
            for directory in [
                rig.data + "/exec", rig.home + "/.ssh", rig.home + "/Library/Keychains", rig.outside, rig.readable,
            ] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let canaries = [
                rig.data + "/node.db": "node", rig.home + "/.zshrc": "shell", rig.home + "/.ssh/id_ed25519": "key",
                rig.home + "/Library/Keychains/login.keychain-db": "keychain", rig.outside + "/secret.txt": "outside",
                rig.readable + "/readable.txt": "readable",
            ]
            for (path, text) in canaries { try text.write(toFile: path, atomically: true, encoding: .utf8) }
            return rig
        }

        static func basePrefix(of python: String) throws -> String {
            let result = try capture(
                python, ["-I", "-c", "import os,sys;print(os.path.realpath(sys.base_prefix))"])
            return try ExecPolicy.canonicalPath(result.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        static func capture(_ tool: String, _ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: output, as: UTF8.self)
        }

        mutating func workspace() throws -> String {
            calls += 1
            let path = data + "/exec/call-\(calls)"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }

        func loaded(
            workspace: String, reads: [String] = [], hosts: [(String, Int)] = [], memory: Int = 536_870_912,
            processes: Int = 1,
            openFiles: Int = 256, fileBytes: Int = 104_857_600, wallMs: Int = 60000
        ) throws -> ExecLoadedPolicy {
            let readList = Set([prefix] + reads).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            let hostList = hosts.map { "{\"host\":\"\($0.0)\",\"port\":\($0.1)}" }.joined(separator: ",")
            let document = """
                {"v":1,"reads":[\(readList.map { "\"\($0)\"" }.joined(separator: ","))],"workspace":"\(workspace)",\
                "hosts":[\(hostList)],"limits":{"memory_bytes":\(memory),"processes":\(processes),"open_files":\(openFiles),\
                "file_bytes":\(fileBytes)},"time":{"wall_ms":\(wallMs)}}
                """
            return try ExecPolicy.load(json: Data(document.utf8), dataDirectory: data, home: home)
        }

        func argv(mode: String, workspace: String, extra: [String: Any] = [:]) throws -> [String] {
            var config: [String: Any] = [
                "mode": mode, "workspace": workspace, "outside": outside, "readable": readable, "home": home,
                "data": data,
                "tcp_port": 9, "echo_port": 9, "udp_port": 9, "unix_path": ExecRig.socketPath, "cert": NSNull(),
                "python": python, "loader": NSNull(), "library": NSNull(),
                "parent_keys": ProcessInfo.processInfo.environment.keys.sorted(),
                "passed": ["PATH", "ASTRAL_PASSED"],
            ]
            for (key, value) in extra { config[key] = value }
            let json = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            return [python, "-I", "-B", "-S", "-c", source, String(decoding: json, as: UTF8.self)]
        }

        static let socketPath = "/private/tmp/ax-\(getpid()).sock"

        static func listenOnSocket() -> Int32 {
            unlink(socketPath)
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in socketPath.utf8.enumerated() { buffer[index] = byte }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if bound != 0 || listen(descriptor, 4) != 0 { close(descriptor) }
            return descriptor
        }

        static let passedEnvironment = ["PATH": "/usr/bin:/bin", "ASTRAL_PASSED": "yes"]

        func cleanup() { try? FileManager.default.removeItem(atPath: root) }
    }

    private enum ExecRigError: Error { case pythonUnset }

    private func checks(_ outcome: ExecOutcome) -> [String: ExecJSON] {
        var found = [String: ExecJSON]()
        for line in String(decoding: outcome.stdout, as: UTF8.self).split(separator: "\n") {
            if let item = try? ExecJSON.parse(Data(line.utf8)), let name = item["check"]?.stringValue,
                let value = item["outcome"]
            {
                found[name] = value
            }
        }
        return found
    }

    private func stray(_ token: String) -> Bool {
        let output = (try? ExecRig.capture("/usr/bin/pgrep", ["-f", token])) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    final class ExecLauncherTests: XCTestCase {
        private var rig: ExecRig!
        private var listener: Int32 = -1

        override func setUpWithError() throws {
            continueAfterFailure = false
            listener = ExecRig.listenOnSocket()
            do {
                rig = try ExecRig.make()
            } catch ExecRigError.pythonUnset {
                XCTFail("ASTRAL_EXEC_TEST_PYTHON must name a Python 3.11 interpreter")
                throw ExecRigError.pythonUnset
            }
        }

        override func tearDown() {
            rig?.cleanup()
            if listener >= 0 { close(listener) }
            unlink(ExecRig.socketPath)
        }

        private func run(
            _ mode: String, processes: Int = 1, extra: [String: Any] = [:], memory: Int = 536_870_912,
            openFiles: Int = 256,
            fileBytes: Int = 104_857_600, wallMs: Int = 60000, env: [String: String] = ExecRig.passedEnvironment,
            reads: [String] = []
        ) throws -> (ExecOutcome, String) {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(
                workspace: workspace, reads: reads, memory: memory, processes: processes, openFiles: openFiles,
                fileBytes: fileBytes, wallMs: wallMs)
            let outcome = ExecLauncher().runBlocking(
                policy, argv: try rig.argv(mode: mode, workspace: workspace, extra: extra), env: env)
            return (outcome, workspace)
        }

        func testDenialsHoldAndTheEnvironmentHoldsOnlyWhatWasPassed() throws {
            let (outcome, workspace) = try run("base", reads: [rig.readable])
            XCTAssertNil(outcome.code)
            XCTAssertEqual(outcome.exitCode, 0)
            let found = checks(outcome)
            for allowed in ["write_workspace", "read_workspace", "read_read_root"] {
                XCTAssertEqual(found[allowed]?.stringValue, "ok", allowed)
            }
            for denied in [
                "write_outside", "write_outside_existing", "write_read_root", "write_home_startup", "write_system",
                "write_tmp",
                "read_outside", "read_data_dir", "read_home_ssh", "read_home_dotfile", "list_outside",
                "read_system_keychain",
                "read_framework_keychain", "unix_mdnsresponder", "tcp_public", "tcp_node_port", "udp_loopback",
                "udp_public",
                "unix_fixture", "listen_loopback", "listen_all", "fork", "spawn",
            ] {
                XCTAssertEqual(found[denied]?.stringValue, "EPERM", denied)
            }
            XCTAssertEqual(found["leaked"]?.arrayValue?.count, 0)
            let environ = (found["environ"]?.arrayValue ?? []).compactMap(\.stringValue)
            XCTAssertTrue(Set(environ).isSuperset(of: ["PATH", "ASTRAL_PASSED", ExecLauncher.markerName]))
            XCTAssertTrue(
                Set(environ).isSubset(of: [
                    "PATH", "ASTRAL_PASSED", ExecLauncher.markerName, "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
                ]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: rig.outside + "/escape.txt"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace + "/inside.txt"))
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: rig.data + "/exec-profiles")) ?? []
            XCTAssertEqual(leftovers, [])
        }

        func testForkIsAllowedOnlyWhenTheProcessLimitAllowsIt() throws {
            let (one, _) = try run("base")
            XCTAssertEqual(checks(one)["fork"]?.stringValue, "EPERM")
            let (two, _) = try run("base", processes: 2)
            XCTAssertEqual(checks(two)["fork"]?.stringValue, "ok")
        }

        func testKeychainReadsAreDenied() throws {
            let (outcome, _) = try run("keychain")
            XCTAssertEqual(checks(outcome)["read_home_keychain"]?.stringValue, "EPERM")
            XCTAssertEqual(checks(outcome)["read_home_dotfile"]?.stringValue, "EPERM")
        }

        func testTheWallClockEndsASleepingTool() throws {
            let (outcome, _) = try run("time", wallMs: 1500)
            XCTAssertEqual(outcome.code, "exec.time_limit")
            XCTAssertEqual(outcome.message, ExecBackends.messages["exec.time_limit"])
        }

        func testMemoryBeyondTheLimitIsStopped() throws {
            let (outcome, _) = try run("memory", extra: ["ceiling": 1_073_741_824], memory: 67_108_864)
            XCTAssertEqual(outcome.code, "exec.memory_limit")
        }

        func testFileSizeIsBoundedByTheLimit() throws {
            let (outcome, workspace) = try run("file_size", extra: ["chunks": 160], fileBytes: 1_048_576)
            XCTAssertEqual(outcome.code, "exec.file_limit")
            let size =
                (try FileManager.default.attributesOfItem(atPath: workspace + "/big.bin")[.size] as? Int) ?? Int.max
            XCTAssertLessThanOrEqual(size, 1_048_576)
        }

        func testOpenFilesAreBoundedByTheLimit() throws {
            let (outcome, _) = try run(
                "open_files", extra: ["attempts": 400, "readable_file": rig.readable + "/readable.txt"], openFiles: 32,
                reads: [rig.readable])
            let found = checks(outcome)
            XCTAssertEqual(found["refused"]?.stringValue, "EMFILE")
            XCTAssertLessThan(found["opened"]?.intValue ?? 99, 32)
        }

        func testMoreProcessesThanTheLimitAreStoppedAndNothingSurvives() throws {
            let token = "astral-exec-limit-" + UUID().uuidString.lowercased()
            let (outcome, _) = try run(
                "sleepers", processes: 3, extra: ["token": token, "count": 8, "linger": 30], wallMs: 20000)
            XCTAssertEqual(outcome.code, "exec.process_limit")
            XCTAssertFalse(stray(token))
        }

        func testDetachedAndBackgroundChildrenAreGoneAfterTheCall() throws {
            let token = "astral-exec-stray-" + UUID().uuidString.lowercased()
            let (outcome, _) = try run("sleepers", processes: 8, extra: ["token": token, "count": 4, "linger": 0])
            XCTAssertNil(outcome.code)
            XCTAssertEqual(checks(outcome)["spawned"]?.intValue, 4)
            XCTAssertFalse(stray(token))
        }

        func testStdinReachesTheToolAndTheWorkingDirectoryIsTheWorkspace() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            let script = "import os,sys;print(os.getcwd(), sys.stdin.read())"
            let outcome = ExecLauncher().runBlocking(
                policy, argv: [rig.python, "-I", "-B", "-S", "-c", script], env: ExecRig.passedEnvironment,
                stdin: Data("hello".utf8))
            XCTAssertNil(outcome.code)
            XCTAssertEqual(String(decoding: outcome.stdout, as: UTF8.self), "\(workspace) hello\n")
        }

        func testLargeStdinAndOutputFlowWithoutBlocking() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            let payload = Data(repeating: 0x61, count: 600_000)
            let outcome = ExecLauncher().runBlocking(
                policy, argv: [rig.python, "-I", "-B", "-S", "-c", "import sys;sys.stdout.write(sys.stdin.read())"],
                env: ExecRig.passedEnvironment, stdin: payload)
            XCTAssertNil(outcome.code)
            XCTAssertEqual(outcome.stdout.count, payload.count)
            XCTAssertFalse(outcome.truncated)
        }

        func testExitCodesAndStderrPassThrough() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            let outcome = ExecLauncher().runBlocking(
                policy, argv: [rig.python, "-I", "-B", "-S", "-c", "import sys;sys.stderr.write('bad');sys.exit(7)"],
                env: ExecRig.passedEnvironment)
            XCTAssertNil(outcome.code)
            XCTAssertEqual(outcome.exitCode, 7)
            XCTAssertEqual(String(decoding: outcome.stderr, as: UTF8.self), "bad")
        }

        func testASignalledToolReportsTheSignal() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            let outcome = ExecLauncher().runBlocking(
                policy,
                argv: [rig.python, "-I", "-B", "-S", "-c", "import os,signal;os.kill(os.getpid(),signal.SIGTERM)"],
                env: ExecRig.passedEnvironment)
            XCTAssertNil(outcome.code)
            XCTAssertNil(outcome.exitCode)
            XCTAssertEqual(outcome.signal, SIGTERM)
        }

        func testAMissingToolIsALaunchFailure() throws {
            let workspace = try rig.workspace()
            let outcome = ExecLauncher().runBlocking(
                try rig.loaded(workspace: workspace), argv: ["/usr/bin/astral-absent-tool"], env: [:])
            XCTAssertEqual(outcome.code, "exec.launch_failed")
        }

        func testShadowModeNeverRunsUntrustedCode() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            let shadow = ExecLauncher(
                facts: { ExecFacts(platform: "darwin", mode: .shadow, euid: 501, sandboxExec: true) })
            let outcome = shadow.runBlocking(
                policy, argv: try rig.argv(mode: "marker", workspace: workspace), env: ExecRig.passedEnvironment)
            XCTAssertEqual(outcome.code, "exec.shadow_refused")
            XCTAssertEqual(outcome.refusal?.code, "exec.shadow_refused")
            XCTAssertNil(outcome.exitCode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/ran"))
        }

        func testAnAppSandboxedHostOrMissingSandboxExecStartsNothing() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            for (facts, reason) in [
                (
                    ExecFacts(platform: "darwin", euid: 501, sandboxExec: true, appSandboxed: true),
                    ExecBackendReason.appSandboxed
                ),
                (ExecFacts(platform: "darwin", euid: 501, sandboxExec: false), ExecBackendReason.sandboxExecMissing),
                (
                    ExecFacts(platform: "linux", landlockABI: 6, bwrap: true, userns: true, euid: 1000),
                    ExecBackendReason?.none
                ),
            ] {
                let outcome = ExecLauncher(facts: { facts }).runBlocking(
                    policy, argv: try rig.argv(mode: "marker", workspace: workspace), env: ExecRig.passedEnvironment)
                XCTAssertNil(outcome.exitCode)
                XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/ran"))
                if let reason {
                    XCTAssertEqual(outcome.code, "exec.backend_unavailable")
                    XCTAssertEqual(outcome.refusal?.reason, reason)
                } else {
                    XCTAssertEqual(outcome.code, "exec.launch_failed")
                }
            }
        }

        func testBadArgumentsAreRefusedBeforeAnyProcessStarts() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            let launcher = ExecLauncher()
            let cases: [([String], [String: String])] = [
                ([], [:]), (["-p", "(version 1)(allow default)"], [:]), (["/usr/bin/true", "a\0b"], [:]),
                (["/usr/bin/true"], ["DYLD_INSERT_LIBRARIES": "x"]),
                (["/usr/bin/true"], [ExecLauncher.markerName: "x"]),
                (["/usr/bin/true"], ["A=B": "x"]), (["/usr/bin/true"], ["": "x"]), (["/usr/bin/true"], ["A": "x\0"]),
            ]
            for (argv, env) in cases {
                XCTAssertEqual(
                    launcher.runBlocking(policy, argv: argv, env: env).code, "exec.launch_failed", "\(argv) \(env)")
            }
        }

        func testHostsNeedAProxyAndTheChildSeesTheProxyEnvironment() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace, hosts: [("example.com", 443)])
            XCTAssertEqual(
                ExecLauncher().runBlocking(policy, argv: ["/usr/bin/env"], env: [:]).code, "exec.launch_failed")
            let outcome = ExecLauncher(proxyPort: { 4242 }).runBlocking(
                policy, argv: ["/usr/bin/env"], env: ["KEEP": "1"])
            XCTAssertNil(outcome.code)
            let lines = Set(String(decoding: outcome.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
            for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                XCTAssertTrue(lines.contains("\(name)=http://127.0.0.1:4242"), name)
            }
            XCTAssertTrue(lines.contains("KEEP=1"))
            XCTAssertTrue(lines.contains("NO_PROXY="))
        }

        func testTheMarkerIsFreshForEveryCall() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            func marker() -> String {
                let outcome = ExecLauncher().runBlocking(policy, argv: ["/usr/bin/env"], env: [:])
                let line = String(decoding: outcome.stdout, as: UTF8.self).split(separator: "\n").first {
                    $0.hasPrefix(ExecLauncher.markerName + "=")
                }
                return line.map { String($0.dropFirst(ExecLauncher.markerName.count + 1)) } ?? ""
            }
            let first = marker()
            XCTAssertEqual(first.count, 32)
            XCTAssertNotEqual(first, marker())
        }

        func testOutputPastTheCapIsTruncated() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            let script = "import sys\nfor _ in range(9): sys.stdout.buffer.write(b'x' * 1048576)"
            let outcome = ExecLauncher().runBlocking(
                policy, argv: [rig.python, "-I", "-B", "-S", "-c", script], env: ExecRig.passedEnvironment)
            XCTAssertNil(outcome.code)
            XCTAssertTrue(outcome.truncated)
            XCTAssertEqual(outcome.stdout.count, ExecLauncher.outputLimit)
        }

        func testADescriptorAboveTheOpenFilesLimitNeverReachesTheTool() throws {
            var low: Int32 = -1
            var high: Int32 = -1
            low = open("/dev/null", O_RDONLY)
            high = fcntl(low, F_DUPFD, 200)
            close(low)
            XCTAssertGreaterThanOrEqual(high, 200)
            defer { close(high) }
            XCTAssertEqual(fcntl(high, F_GETFD) & FD_CLOEXEC, 0)
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace, openFiles: 32)
            let script =
                "import os,sys\nfor fd in range(3, 1024):\n    try:\n        os.fstat(fd)\n        print(fd)\n    except OSError:\n        pass"
            let outcome = ExecLauncher().runBlocking(
                policy, argv: [rig.python, "-I", "-B", "-S", "-c", script], env: ExecRig.passedEnvironment)
            XCTAssertNil(outcome.code)
            XCTAssertEqual(outcome.exitCode, 0)
            XCTAssertEqual(String(decoding: outcome.stdout, as: UTF8.self), "")
        }

        func testAProcessCountFailureRefusesBeforeAnythingStarts() throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace, processes: 2)
            let launcher = ExecLauncher(facts: nil, userProcesses: { throw POSIXError(.EIO) })
            let outcome = launcher.runBlocking(
                policy, argv: try rig.argv(mode: "marker", workspace: workspace), env: ExecRig.passedEnvironment)
            XCTAssertEqual(outcome.code, "exec.launch_failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/ran"))
        }

        func testTheAsyncEntryPointGivesTheSameResult() async throws {
            let workspace = try rig.workspace()
            let policy = try rig.loaded(workspace: workspace)
            let argv = [rig.python, "-I", "-B", "-S", "-c", "import sys;sys.stderr.write('e');print('o');sys.exit(3)"]
            let blocking = ExecLauncher().runBlocking(policy, argv: argv, env: ExecRig.passedEnvironment)
            let awaited = await ExecLauncher().run(policy, argv: argv, env: ExecRig.passedEnvironment)
            XCTAssertEqual(awaited, blocking)
            XCTAssertEqual(awaited.exitCode, 3)
        }

        func testTheOutputLimitMatchesTheContract() {
            XCTAssertEqual(ExecLauncher.outputLimit, 8 * 1024 * 1024)
        }
    }

    final class ExecWatchTests: XCTestCase {
        private final class Table: ExecProcessTable {
            var processes: [Int32: (parent: Int32, group: Int32, usage: ExecProcessUsage, strings: [[UInt8]])] = [:]
            var failListing = false

            func pids(kind: UInt32, info: UInt32) throws -> [Int32] {
                if failListing { throw POSIXError(.EIO) }
                switch kind {
                case DarwinProcessTable.pgrpOnly:
                    return processes.filter { $0.value.group == Int32(info) }.keys.sorted()
                case DarwinProcessTable.ppidOnly:
                    return processes.filter { $0.value.parent == Int32(info) }.keys.sorted()
                default: return processes.keys.sorted()
                }
            }

            func usage(_ pid: Int32) -> ExecProcessUsage? { processes[pid]?.usage }
            func strings(_ pid: Int32) -> [[UInt8]]? { processes[pid]?.strings }
        }

        func testSampleSumsTheTreeAndSkipsExitedProcesses() {
            let table = Table()
            table.processes[100] = (1, 100, ExecProcessUsage(start: 1, exited: false, footprint: 10), [])
            table.processes[101] = (100, 100, ExecProcessUsage(start: 2, exited: false, footprint: 20), [])
            table.processes[102] = (101, 102, ExecProcessUsage(start: 3, exited: true, footprint: 40), [])
            let watch = ExecWatch(root: 100, marker: nil, table: table)
            XCTAssertTrue(watch.started)
            let sample = try? watch.sample()
            XCTAssertEqual(sample?.processes, 3)
            XCTAssertEqual(sample?.memory, 30)
        }

        func testAnInvisibleRootIsNotStartedAndListingFailuresSurface() {
            let table = Table()
            let watch = ExecWatch(root: 5, marker: nil, table: table)
            XCTAssertFalse(watch.started)
            table.processes[5] = (1, 5, ExecProcessUsage(start: 1, exited: false, footprint: 1), [])
            table.failListing = true
            XCTAssertThrowsError(try ExecWatch(root: 5, marker: nil, table: table).sample())
        }

        func testTheMarkerSweepFindsAMarkedProcessOutsideTheTree() throws {
            let table = Table()
            let entry = Array("\(ExecLauncher.markerName)=abc".utf8)
            table.processes[100] = (1, 100, ExecProcessUsage(start: 1, exited: false, footprint: 10), [])
            table.processes[900] = (1, 900, ExecProcessUsage(start: 9, exited: false, footprint: 5), [entry])
            table.processes[901] = (
                1, 901, ExecProcessUsage(start: 9, exited: false, footprint: 5), [Array("other".utf8)]
            )
            let marked = ExecWatch(root: 100, marker: "\(ExecLauncher.markerName)=abc", table: table)
            XCTAssertEqual(try marked.sample().processes, 2)
            let unmarked = ExecWatch(root: 100, marker: nil, table: table)
            XCTAssertEqual(try unmarked.sample().processes, 1)
        }

        func testUserProcessCountListsThisUsersProcesses() throws {
            XCTAssertGreaterThan(try ExecWatch.userProcessCount(), 0)
        }

        func testDarwinTableSeesThisProcessAndItsArguments() throws {
            let table = DarwinProcessTable()
            let own = getpid()
            XCTAssertTrue(try table.pids(kind: DarwinProcessTable.uidOnly, info: UInt32(geteuid())).contains(own))
            XCTAssertNotNil(table.usage(own))
            XCTAssertNil(table.usage(Int32.max))
            XCTAssertFalse((table.strings(own) ?? []).isEmpty)
        }
    }
#endif
