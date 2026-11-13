// Drives the node supervisor with a fake process, health probe and sleeper: start, crash backoff, stability reset, hung nodes, stuck processes, stop and adoption.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    final class FakeNodeProcess: NodeProcessHandle, @unchecked Sendable {
        let processIdentifier: Int32
        private let exit = ExitBroadcast()
        private let lock = NSLock()
        private(set) var terminated = false
        private(set) var killed = false
        var ignoresTerminate = false

        init(pid: Int32) { processIdentifier = pid }

        func crash(_ code: Int32) { exit.complete(code) }
        func waitForExit() async -> Int32 { await exit.wait() }
        func waitForExit(timeout seconds: Double) async -> Bool { await exit.wait(timeout: 0.05) }
        func terminate() {
            lock.lock()
            terminated = true
            lock.unlock()
            if !ignoresTerminate { exit.complete(143) }
        }
        func kill() {
            lock.lock()
            killed = true
            lock.unlock()
            exit.complete(137)
        }
    }

    final class FakeLauncher: NodeProcessLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var processes: [FakeNodeProcess] = []
        private(set) var specs: [NodeLaunchSpec] = []
        var failures = 0
        var ignoreTerminate = false
        var launched: (@Sendable (FakeNodeProcess) -> Void)?

        func launch(_ spec: NodeLaunchSpec) throws -> NodeProcessHandle {
            lock.lock()
            defer { lock.unlock() }
            if failures > 0 {
                failures -= 1
                throw NodeHostError.launchFailed("no such file")
            }
            let process = FakeNodeProcess(pid: Int32(2_000_000_000 + processes.count))
            process.ignoresTerminate = ignoreTerminate
            processes.append(process)
            specs.append(spec)
            launched?(process)
            return process
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return processes.count }
        func process(_ index: Int) -> FakeNodeProcess { lock.lock(); defer { lock.unlock() }; return processes[index] }
    }

    final class FakeProbe: NodeHealthProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Bool] = []
        var fallback = true
        private(set) var calls = 0

        func script(_ values: [Bool]) { lock.lock(); answers = values; lock.unlock() }
        func isHealthy(port: Int) async -> Bool {
            lock.withLock {
                calls += 1
                return answers.isEmpty ? fallback : answers.removeFirst()
            }
        }
    }

    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var slept: [Double] = []
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return slept }
        func sleep(_ seconds: Double) async throws {
            lock.withLock { slept.append(seconds) }
            try await Task.sleep(nanoseconds: 2_000_000)
            try Task.checkCancellation()
        }
    }

    final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [NodeSupervisorState] = []
        func add(_ state: NodeSupervisorState) { lock.lock(); items.append(state); lock.unlock() }
        var values: [NodeSupervisorState] { lock.lock(); defer { lock.unlock() }; return items }
    }

    final class NodeSupervisorTests: XCTestCase {
        private let spec = NodeLaunchSpec(
            executable: URL(fileURLWithPath: "/pack/python/bin/python3.11"), arguments: ["-I"], environment: ["A": "b"],
            workingDirectory: URL(fileURLWithPath: "/pack"), launchLog: URL(fileURLWithPath: "/tmp/launch.log"))

        private func make(
            launcher: FakeLauncher, probe: FakeProbe, clock: FakeClock, log: StateLog,
            tune: (inout NodeSupervisorPolicy) -> Void = { _ in }
        ) -> NodeSupervisor {
            var policy = NodeSupervisorPolicy()
            policy.startupChecks = 5
            policy.stableChecks = 3
            tune(&policy)
            return NodeSupervisor(
                spec: spec, port: 18_700, launcher: launcher, probe: probe, policy: policy, sleep: clock.sleep,
                onState: { log.add($0) })
        }

        private func waitUntil(_ timeout: Double = 5, _ condition: @escaping () async -> Bool) async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await condition() { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTFail("condition not reached")
        }

        func testStartsWaitsForHealthAndReportsRunning() async {
            let launcher = FakeLauncher(), log = StateLog()
            let supervisor = make(launcher: launcher, probe: FakeProbe(), clock: FakeClock(), log: log)
            await supervisor.start()
            await waitUntil { await supervisor.state == .running(pid: 2_000_000_000, port: 18_700) }
            XCTAssertEqual(launcher.specs.first, spec)
            XCTAssertEqual(log.values.first, .starting(attempt: 1))
            await supervisor.stop()
            let state = await supervisor.state
            XCTAssertEqual(state, .stopped)
            XCTAssertTrue(launcher.process(0).terminated && !launcher.process(0).killed)
        }

        func testACrashRestartsWithDoublingDelays() async {
            let launcher = FakeLauncher(), clock = FakeClock(), log = StateLog(), probe = FakeProbe()
            probe.fallback = false
            let supervisor = make(launcher: launcher, probe: probe, clock: clock, log: log)
            launcher.launched = { $0.crash(1) }
            await supervisor.start()
            await waitUntil { launcher.count >= 4 }
            await supervisor.stop()
            let delays = log.values.compactMap { state -> Double? in
                if case .backingOff(_, let seconds, _) = state { return seconds }
                return nil
            }
            XCTAssertEqual(Array(delays.prefix(3)), [1, 2, 4])
            XCTAssertTrue(log.values.contains(.backingOff(attempt: 1, seconds: 1, lastExit: 1)))
        }

        func testBackoffIsCapped() {
            var policy = NodeSupervisorPolicy()
            policy.maximumDelay = 10
            XCTAssertEqual((1...6).map { policy.delay(afterFailure: $0) }, [1, 2, 4, 8, 10, 10])
        }

        func testARunThatStaysHealthyResetsTheFailureCount() async {
            let launcher = FakeLauncher(), clock = FakeClock(), log = StateLog()
            let supervisor = make(launcher: launcher, probe: FakeProbe(), clock: clock, log: log)
            await supervisor.start()
            await waitUntil { await supervisor.state == .running(pid: 2_000_000_000, port: 18_700) }
            await waitUntil { clock.values.filter { $0 == 5 }.count >= 4 }
            launcher.process(0).crash(9)
            await waitUntil { launcher.count == 2 }
            await supervisor.stop()
            XCTAssertTrue(log.values.contains(.backingOff(attempt: 1, seconds: 1, lastExit: 9)))
        }

        func testRepeatedFailuresGiveUp() async {
            let launcher = FakeLauncher(), log = StateLog(), probe = FakeProbe()
            probe.fallback = false
            let supervisor = make(launcher: launcher, probe: probe, clock: FakeClock(), log: log) {
                $0.maximumConsecutiveFailures = 3
                $0.baseDelay = 0.001
            }
            launcher.launched = { $0.crash(2) }
            await supervisor.start()
            await waitUntil { if case .failed = await supervisor.state { return true } else { return false } }
            XCTAssertEqual(launcher.count, 3)
            await supervisor.stop()
        }

        func testALaunchFailureIsRetriedAndThenRuns() async {
            let launcher = FakeLauncher()
            launcher.failures = 2
            let supervisor = make(launcher: launcher, probe: FakeProbe(), clock: FakeClock(), log: StateLog()) { $0.baseDelay = 0.001 }
            await supervisor.start()
            await waitUntil { await supervisor.state == .running(pid: 2_000_000_000, port: 18_700) }
            XCTAssertEqual(launcher.count, 1)
            await supervisor.stop()
        }

        func testAProcessThatNeverBecomesHealthyIsKilledAndRestarted() async {
            let launcher = FakeLauncher(), probe = FakeProbe(), log = StateLog()
            probe.fallback = false
            let supervisor = make(launcher: launcher, probe: probe, clock: FakeClock(), log: log) { $0.baseDelay = 0.001 }
            await supervisor.start()
            await waitUntil { launcher.count >= 2 }
            await supervisor.stop()
            XCTAssertTrue(launcher.process(0).terminated)
            XCTAssertTrue(log.values.contains(.backingOff(attempt: 1, seconds: 0.001, lastExit: nil)))
        }

        func testARunningNodeThatStopsAnsweringIsRestarted() async {
            let launcher = FakeLauncher(), probe = FakeProbe()
            probe.script([true, true, false, false, false])
            let supervisor = make(launcher: launcher, probe: probe, clock: FakeClock(), log: StateLog()) {
                $0.baseDelay = 0.001
                $0.stableChecks = 100
            }
            await supervisor.start()
            await waitUntil { launcher.count >= 2 }
            XCTAssertTrue(launcher.process(0).terminated)
            await supervisor.stop()
        }

        func testAProcessThatIgnoresTerminateIsKilledAfterTheGrace() async {
            let launcher = FakeLauncher()
            launcher.ignoreTerminate = true
            let supervisor = make(launcher: launcher, probe: FakeProbe(), clock: FakeClock(), log: StateLog())
            await supervisor.start()
            await waitUntil { await supervisor.state == .running(pid: 2_000_000_000, port: 18_700) }
            await supervisor.stop()
            XCTAssertTrue(launcher.process(0).terminated && launcher.process(0).killed)
        }

        func testStartingTwiceDoesNotLaunchTwoNodesAndStopWhenStoppedIsHarmless() async {
            let launcher = FakeLauncher()
            let supervisor = make(launcher: launcher, probe: FakeProbe(), clock: FakeClock(), log: StateLog())
            await supervisor.stop()
            await supervisor.start()
            await supervisor.start()
            await waitUntil { await supervisor.state == .running(pid: 2_000_000_000, port: 18_700) }
            XCTAssertEqual(launcher.count, 1)
            await supervisor.stop()
        }

        func testAnAdoptedProcessIsSupervisedWithoutLaunching() async {
            let launcher = FakeLauncher()
            let adopted = FakeNodeProcess(pid: 2_000_004_242)
            let supervisor = make(launcher: launcher, probe: FakeProbe(), clock: FakeClock(), log: StateLog()) { $0.baseDelay = 0.001 }
            await supervisor.start(adopting: adopted)
            await waitUntil { await supervisor.state == .running(pid: 2_000_004_242, port: 18_700) }
            XCTAssertEqual(launcher.count, 0)
            adopted.crash(1)
            await waitUntil { launcher.count == 1 }
            await supervisor.stop()
        }

        func testStopSynchronouslyEndsARealProcessGroup() async throws {
            let launcher = PosixNodeProcessLauncher()
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString).log")
            let real = NodeLaunchSpec(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo started; sleep 60 & wait"],
                environment: ["PATH": "/usr/bin:/bin"], workingDirectory: FileManager.default.temporaryDirectory, launchLog: log)
            let supervisor = NodeSupervisor(
                spec: real, port: 1, launcher: launcher, probe: FakeProbe(), policy: NodeSupervisorPolicy())
            await supervisor.start()
            await waitUntil { if case .running = await supervisor.state { return true } else { return false } }
            guard case .running(let pid, _) = await supervisor.state else { return XCTFail("not running") }
            XCTAssertEqual(kill(pid, 0), 0)
            await waitUntil { (try? String(contentsOf: log, encoding: .utf8)) == "started\n" }
            supervisor.stopSynchronously(timeout: 3)
            var gone = false
            for _ in 0..<100 where !gone {
                var status: Int32 = 0
                gone = kill(pid, 0) != 0
                if !gone { try await Task.sleep(nanoseconds: 20_000_000) }
                _ = status
                status = 0
            }
            XCTAssertTrue(gone)
            XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "started\n")
            await supervisor.stop()
            try? FileManager.default.removeItem(at: log)
        }

        func testTheLoopbackProbeAcceptsOnlyAnOkBody() async throws {
            let probe = LoopbackNodeHealthProbe()
            let closed = try NodeHome.freeLoopbackPort()
            let healthy = await probe.isHealthy(port: closed)
            XCTAssertFalse(healthy)
        }
    }
#endif
