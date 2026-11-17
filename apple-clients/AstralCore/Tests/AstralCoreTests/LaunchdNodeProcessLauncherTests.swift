// Drives the launchd node launcher and the controller's migration with a fake launchctl that spawns real sleep processes: plist goldens, call order, health restarts, adoption, teardown and crash loops.
// It shares the pack builder and fakes with the other node host tests and never touches the real launchd.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    final class FakeLaunchctl: LaunchctlRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        private var child: Process?
        private var pid: Int32?
        private var loaded = false
        var bootstrapStatus: Int32 = 0
        var lifetime = "60"

        var verbs: [String] { lock.withLock { calls.map { $0[0] } } }
        var allCalls: [[String]] { lock.withLock { calls } }

        func preload(pid: Int32) {
            lock.withLock {
                loaded = true
                self.pid = pid
            }
        }

        func run(_ arguments: [String]) -> (status: Int32, output: String) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(arguments)
            switch arguments[0] {
            case "bootstrap":
                guard bootstrapStatus == 0 else {
                    return (bootstrapStatus, "Bootstrap failed: 5: Input/output error\nmore")
                }
                loaded = true
                return (0, "")
            case "kickstart":
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                process.arguments = [lifetime]
                try? process.run()
                DispatchQueue.global().async { process.waitUntilExit() }
                child = process
                pid = process.processIdentifier
                return (0, "")
            case "print":
                guard loaded else { return (113, "Could not find service") }
                return (0, "gui/501/label = {\n\tstate = running\n\tpid = \(pid.map(String.init) ?? "0")\n}\n")
            case "bootout":
                child?.terminate()
                child = nil
                loaded = false
                return (0, "")
            default:
                return (1, "")
            }
        }

        func stopChild() { lock.withLock { child?.terminate() } }
    }

    @MainActor
    final class LaunchdNodeProcessLauncherTests: XCTestCase {
        private var root: URL!
        private var defaults: UserDefaults!
        private var suite: String!
        private let label = "com.test.astral.node"

        override func setUpWithError() throws {
            root = try NodePackTestSupport.temporaryDirectory()
            suite = "launchd-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        private func spec(keepRunning: Bool = false, port: Int = 18_750) -> NodeLaunchSpec {
            NodeLaunchSpec(
                executable: URL(fileURLWithPath: "/pack/python/bin/python3.11"),
                arguments: ["-I", "-B", "/pack/launcher/astral_node_launch.py", "--port", String(port)],
                environment: ["PATH": "/usr/bin:/bin", "HOME": "/home/node & co"],
                workingDirectory: URL(fileURLWithPath: "/pack"), launchLog: URL(fileURLWithPath: "/home/logs/l.log"),
                keepRunning: keepRunning)
        }

        private func launcher(_ runner: FakeLaunchctl) -> LaunchdNodeProcessLauncher {
            LaunchdNodeProcessLauncher(
                label: label, plist: root.appendingPathComponent("agents/\(label).plist"), runner: runner,
                userIdentifier: 501, sleep: { _ in })
        }

        func testExecutablePathsAreResolvedAndMatchedInsideThePackOnly() throws {
            XCTAssertNotNil(NodeHostEnvironment.executablePath(of: getpid()))
            XCTAssertNil(NodeHostEnvironment.executablePath(of: 2_000_000_000))
            let pack = root.appendingPathComponent("pack")
            try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
            XCTAssertTrue(NodeHostController.isInside(pack.path + "/python/bin/python3.11", root: pack))
            XCTAssertFalse(NodeHostController.isInside(pack.path + "-other/bin/python", root: pack))
            XCTAssertFalse(NodeHostController.isInside("/usr/bin/python3", root: pack))
        }

        func testThePlistWhenKeepRunningIsOff() {
            let text = LaunchdNodePlist.render(label: label, spec: spec())
            XCTAssertTrue(text.contains("<key>RunAtLoad</key>\n    <false/>"))
            XCTAssertTrue(text.contains("<key>KeepAlive</key>\n    <false/>"))
            XCTAssertTrue(text.contains("<string>/home/node &amp; co</string>"))
            XCTAssertTrue(text.contains("<string>--port</string>\n        <string>18750</string>"))
        }

        func testThePlistWhenKeepRunningIsOn() throws {
            let text = LaunchdNodePlist.render(label: label, spec: spec(keepRunning: true))
            XCTAssertTrue(text.contains("<key>RunAtLoad</key>\n    <true/>"))
            XCTAssertTrue(
                text.contains("<key>KeepAlive</key>\n    <dict>\n        <key>SuccessfulExit</key>\n        <false/>"))
            let object =
                try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any]
            XCTAssertEqual(object?["Label"] as? String, label)
            XCTAssertEqual(object?["WorkingDirectory"] as? String, "/pack")
            XCTAssertEqual((object?["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
            XCTAssertEqual(
                (object?["ProgramArguments"] as? [String])?.first, "/pack/python/bin/python3.11")
            XCTAssertEqual(
                Set((object?["EnvironmentVariables"] as? [String: String] ?? [:]).keys), ["PATH", "HOME"])
        }

        func testItBootstrapsKickstartsAndBootsOutInOrder() async throws {
            let runner = FakeLaunchctl()
            let launcher = launcher(runner)
            let handle = try launcher.launch(spec())
            XCTAssertEqual(runner.verbs, ["print", "bootout", "bootstrap", "kickstart", "print"])
            XCTAssertEqual(runner.allCalls[2], ["bootstrap", "gui/501", launcher.plist.path])
            XCTAssertEqual(runner.allCalls[3], ["kickstart", "gui/501/\(label)"])
            let written = try String(contentsOf: launcher.plist, encoding: .utf8)
            XCTAssertEqual(written, LaunchdNodePlist.render(label: label, spec: spec()))
            let attributes = try FileManager.default.attributesOfItem(atPath: launcher.plist.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
            handle.terminate()
            let exited = await handle.waitForExit(timeout: 5)
            XCTAssertTrue(exited)
            XCTAssertEqual(runner.verbs.last, "bootout")
        }

        func testALoadedJobIsReusedNotBootstrappedAgain() throws {
            let runner = FakeLaunchctl()
            runner.preload(pid: getpid())
            let handle = try launcher(runner).launch(spec())
            XCTAssertEqual(handle.processIdentifier, getpid())
            XCTAssertEqual(runner.verbs, ["print"])
        }

        func testABootstrapFailureIsAShortLaunchError() {
            let runner = FakeLaunchctl()
            runner.bootstrapStatus = 5
            XCTAssertThrowsError(try launcher(runner).launch(spec())) {
                XCTAssertEqual(
                    $0 as? NodeHostError, .launchFailed("Bootstrap failed: 5: Input/output error"))
            }
            XCTAssertFalse(runner.verbs.contains("kickstart"))
        }

        func testTeardownBootsOutAndDeletesThePlist() throws {
            let runner = FakeLaunchctl()
            let launcher = launcher(runner)
            _ = try launcher.launch(spec())
            launcher.teardown()
            XCTAssertEqual(runner.verbs.last, "bootout")
            XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.plist.path))
            XCTAssertNil(launcher.adoptable())
        }

        func testALoadedJobIsAdoptedWithThePortFromItsPlist() throws {
            let runner = FakeLaunchctl()
            let launcher = launcher(runner)
            _ = try launcher.launch(spec(port: 18_777))
            let adoption = try XCTUnwrap(launcher.adoptable())
            XCTAssertEqual(adoption.port, 18_777)
            runner.stopChild()
        }

        func testTheSupervisorRestartsAnUnhealthyNodeThroughLaunchd() async throws {
            let runner = FakeLaunchctl()
            let probe = FakeProbe()
            probe.script([true, false])
            var policy = NodeSupervisorPolicy()
            policy.startupChecks = 5
            policy.unhealthyChecksBeforeRestart = 1
            policy.terminationGrace = 2
            let log = StateLog()
            let clock = FakeClock()
            let supervisor = NodeSupervisor(
                spec: spec(), port: 18_750, launcher: launcher(runner), probe: probe, policy: policy,
                sleep: clock.sleep, onState: { log.add($0) })
            await supervisor.start()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, runner.verbs.filter({ $0 == "bootstrap" }).count < 2 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(runner.verbs.filter { $0 == "bootstrap" }.count, 2)
            XCTAssertTrue(runner.verbs.contains("bootout"))
            await supervisor.stop()
            runner.stopChild()
        }

        private func controller(
            _ runner: FakeLaunchctl, processPath: @escaping @Sendable (Int32) -> String? = { _ in nil }
        ) -> (NodeHostController, LaunchdNodeProcessLauncher) {
            var policy = NodeSupervisorPolicy()
            policy.startupChecks = 3
            policy.maximumConsecutiveFailures = 2
            policy.terminationGrace = 2
            let launcher = launcher(runner)
            let home = root.appendingPathComponent("node/home")
            let environment = NodeHostEnvironment(
                root: root.appendingPathComponent("node"), available: true, meshLabel: "Test Mac", defaults: defaults,
                launcher: launcher, probe: FakeProbe(), http: FakeNodeHTTP(), policy: policy,
                sleep: { _ in try await Task.sleep(nanoseconds: 2_000_000) }, freePort: { 18_731 },
                runInstaller: { _, _ in
                    try "ASTRAL_NODE_PROFILE=personal\n".write(
                        to: home.appendingPathComponent("node.env"), atomically: true, encoding: .utf8)
                    return (0, "")
                }, processPath: processPath)
            return (NodeHostController(environment: environment), launcher)
        }

        private func install(_ controller: NodeHostController) async throws {
            let built = try NodePackTestSupport.build()
            controller.packURLText = built.descriptorURL.absoluteString
            await controller.lookUpOffer()
            await controller.install()
        }

        private func writeRecord(pid: Int32) throws {
            let home = root.appendingPathComponent("node/home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(
                NodeRunRecord(pid: pid, port: 18_740, packVersion: "3.11.18-test", startedAt: Date())
            )
            .write(to: home.appendingPathComponent("run.json"))
        }

        private func snapshot() -> [String: Data] {
            let home = root.appendingPathComponent("node/home")
            var result: [String: Data] = [:]
            for case let url as URL in FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)!
            where url.lastPathComponent != "run.json" && !url.hasDirectoryPath {
                result[url.path] = try? Data(contentsOf: url)
            }
            return result
        }

        private func waitFor(
            _ controller: NodeHostController, _ predicate: @escaping (NodeHostController.Phase) -> Bool
        ) async {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, !predicate(controller.phase) { try? await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(predicate(controller.phase), "phase was \(controller.phase)")
        }

        func testALegacyNodeInsideThePackIsStoppedThenLaunchedUnderLaunchd() async throws {
            let runner = FakeLaunchctl()
            let legacy = Process()
            legacy.executableURL = URL(fileURLWithPath: "/bin/sleep")
            legacy.arguments = ["60"]
            try legacy.run()
            DispatchQueue.global().async { legacy.waitUntilExit() }
            defer { legacy.terminate() }
            let pid = legacy.processIdentifier
            let packRoot = root.appendingPathComponent("node/packs/3.11.18-test/python/bin/python3.11").path
            let (controller, _) = controller(runner) { $0 == pid ? packRoot : nil }
            try await install(controller)
            try writeRecord(pid: pid)
            let before = snapshot()
            await controller.refresh()
            await waitFor(controller) { $0 == .running(port: 18_731) }
            XCTAssertNotEqual(kill(pid, 0), 0)
            XCTAssertTrue(runner.verbs.contains("bootstrap"))
            XCTAssertEqual(snapshot(), before)
            await controller.stop()
        }

        func testAProcessOutsideThePackIsLeftAloneAndReported() async throws {
            let runner = FakeLaunchctl()
            let stranger = Process()
            stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
            stranger.arguments = ["60"]
            try stranger.run()
            DispatchQueue.global().async { stranger.waitUntilExit() }
            defer { stranger.terminate() }
            let pid = stranger.processIdentifier
            let (controller, _) = controller(runner) { _ in "/usr/bin/other" }
            try await install(controller)
            try writeRecord(pid: pid)
            let before = snapshot()
            await controller.refresh()
            XCTAssertEqual(controller.phase, .installed(version: "3.11.18-test"))
            XCTAssertEqual(kill(pid, 0), 0)
            XCTAssertEqual(
                controller.message, "A process outside the node pack holds the recorded node, so it was left running.")
            XCTAssertFalse(runner.verbs.contains("bootstrap"))
            XCTAssertEqual(snapshot(), before)
        }

        func testASurvivingAgentIsAdoptedOnTheNextLaunch() async throws {
            let runner = FakeLaunchctl()
            let (first, launcher) = controller(runner)
            try await install(first)
            await first.start()
            await waitFor(first) { $0 == .running(port: 18_731) }
            let bootstraps = runner.verbs.filter { $0 == "bootstrap" }.count
            let (second, _) = self.controller(runner)
            await second.refresh()
            await waitFor(second) { $0 == .running(port: 18_731) }
            XCTAssertEqual(runner.verbs.filter { $0 == "bootstrap" }.count, bootstraps)
            await second.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.plist.path))
            runner.stopChild()
        }

        func testQuitBootsTheAgentOutUnlessKeepRunningIsOnAndNeverTouchesHomeData() async throws {
            for keep in [false, true] {
                let runner = FakeLaunchctl()
                let (controller, launcher) = controller(runner)
                controller.keepRunning = keep
                try await install(controller)
                await controller.start()
                await waitFor(controller) { $0 == .running(port: 18_731) }
                let before = snapshot()
                controller.applicationWillTerminate()
                XCTAssertEqual(FileManager.default.fileExists(atPath: launcher.plist.path), keep)
                XCTAssertEqual(runner.verbs.last == "bootout", !keep)
                XCTAssertEqual(snapshot(), before)
                await controller.stop()
                runner.stopChild()
            }
        }

        func testACrashLoopEndsAsAShortFailureAndRemovesTheAgent() async throws {
            let runner = FakeLaunchctl()
            runner.lifetime = "0"
            let (controller, launcher) = controller(runner)
            try await install(controller)
            await controller.start()
            await waitFor(controller) { if case .failed = $0 { return true } else { return false } }
            XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.plist.path))
            XCTAssertEqual(runner.verbs.last, "bootout")
        }

        func testRemovingTheNodeBootsTheAgentOutAndKeepsTheHome() async throws {
            let runner = FakeLaunchctl()
            let (controller, launcher) = controller(runner)
            try await install(controller)
            await controller.start()
            await waitFor(controller) { $0 == .running(port: 18_731) }
            await controller.remove()
            XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.plist.path))
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("node/home/node.env").path))
            runner.stopChild()
        }
    }
#endif
