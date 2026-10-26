// Drives the Mac command host through a scripted spawner and clock for every job state transition.
// Real runs of echo, env, cat and sleep cover posix_spawn, pipes, the group timeout and the sanitized environment.

#if os(macOS)
    import AstralCore
    import Darwin
    import XCTest
    @testable import AstralDeep

    final class MacComputerCommandsTests: XCTestCase {
        private let session = "11111111-1111-4111-8111-111111111111"
        private var counter = 0

        private func folder() throws -> String {
            let created = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: created) }
            let pointer = try XCTUnwrap(realpath(created.path, nil))
            defer { free(pointer) }
            return String(cString: pointer)
        }
        private func request(_ verb: String, _ args: [String: JSONValue], deadline: Double = 30000) throws
            -> ComputerHostRequest
        {
            counter += 1
            return try ComputerHostRequest(
                json: .object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(format: "%032x", counter)), "session_id": .string(session),
                    "verb": .string(verb), "args": .object(args), "deadline_ms": .number(deadline),
                ]))
        }
        private func run(_ root: String, _ extra: [String: JSONValue] = [:]) throws -> ComputerHostRequest {
            let base: [String: JSONValue] = ["argv": .array([.string("echo"), .string("hi")]), "cwd": .string(root)]
            return try request("run_command", base.merging(extra) { $1 }, deadline: 600000)
        }
        private func commands(
            _ spawner: MacComputerFakeSpawner, clock: MacComputerFakeClock = MacComputerFakeClock()
        ) -> MacComputerCommands {
            MacComputerCommands(
                spawner: spawner, clock: clock,
                inherited: ["HOME": "/Users/synthetic", "ASTRAL_TOKEN": "secret", "PATH": "/inherited", "LANG": "C"],
                loginPath: { "/usr/bin:/bin" })
        }
        private func code(_ work: () async throws -> Void) async -> String? {
            do {
                try await work()
                return nil
            } catch { return (error as? ComputerHostError)?.code ?? "\(error)" }
        }

        func testForegroundRunReturnsTailsExitAndTheSanitizedPlan() async throws {
            let root = try folder()
            let spawner = MacComputerFakeSpawner { _, output, process in
                output.append(.stdout, Array("hello\n".utf8))
                output.append(.stderr, Array("warn".utf8))
                output.finish(.stdout)
                output.finish(.stderr)
                process.exit(.exited(3))
            }
            let host = commands(spawner)
            let result = try await host.run(
                run(root, ["env": .object(["APP_FOO": .string("bar")]), "stdin": .string("in")]), session: session,
                roots: [root], authorize: {})
            XCTAssertEqual(result["exit_code"], .number(3))
            XCTAssertEqual(result["signal"], .null)
            XCTAssertEqual(result["timed_out"], .bool(false))
            XCTAssertEqual(result["stdout"], .string("hello\n"))
            XCTAssertEqual(result["stderr"], .string("warn"))
            XCTAssertEqual(result["stdout_bytes"], .number(6))
            XCTAssertEqual(result["stderr_bytes"], .number(4))
            XCTAssertEqual(result["truncated"], .bool(false))
            XCTAssertEqual(result["cwd"], .string(root))
            let rfc3339 = ISO8601DateFormatter()
            rfc3339.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            XCTAssertEqual(result["started_at"], .string("2027-01-15T08:00:00.000Z"))
            XCTAssertNotNil(result["started_at"]?.stringValue.flatMap { rfc3339.date(from: $0) })
            XCTAssertNotNil(result["duration_ms"]?.numberValue)
            let plan = try XCTUnwrap(spawner.plans.first)
            XCTAssertEqual(plan.executable, "/bin/echo")
            XCTAssertEqual(plan.arguments, ["echo", "hi"])
            XCTAssertEqual(plan.directory, root)
            XCTAssertEqual(plan.stdin, Data("in".utf8))
            XCTAssertEqual(
                plan.environment,
                ["HOME": "/Users/synthetic", "LANG": "C", "PATH": "/usr/bin:/bin", "TERM": "dumb", "APP_FOO": "bar"])
            _ = try await host.run(
                request("run_command", ["command": .string("wc -l notes.md"), "cwd": .string(root)]),
                session: session, roots: [root], authorize: {})
            XCTAssertEqual(spawner.plans.last?.executable, "/bin/zsh")
            XCTAssertEqual(spawner.plans.last?.arguments, ["/bin/zsh", "-lc", "wc -l notes.md"])
        }

        func testRefusalsHappenBeforeAnythingLaunches() async throws {
            let root = try folder()
            let outside = try folder()
            let spawner = MacComputerFakeSpawner()
            let host = commands(spawner)
            let cases: [(ComputerHostRequest, [String], String)] = [
                (try run(outside), [root], "cwd_outside_workspace"),
                (try run(root), [], "cwd_outside_workspace"),
                (try run(root, ["env": .object(["GITHUB_TOKEN": .string("x")])]), [root], "env_forbidden"),
                (try run(root, ["env": .object(["DYLD_INSERT_LIBRARIES": .string("/x")])]), [root], "env_forbidden"),
                (
                    try request(
                        "run_command", ["argv": .array([.string("no-such-tool-zz")]), "cwd": .string(root)]), [root],
                    "not_found"
                ),
            ]
            for (call, roots, expected) in cases {
                let found = await code {
                    _ = try await host.run(call, session: self.session, roots: roots, authorize: {})
                }
                XCTAssertEqual(found, expected)
            }
            let denied = await code {
                _ = try await host.run(
                    self.run(root), session: self.session, roots: [root],
                    authorize: { throw ComputerHostError("interrupted", "revoked") })
            }
            XCTAssertEqual(denied, "interrupted")
            XCTAssertTrue(spawner.plans.isEmpty)
            spawner.failure = ComputerHostError("failed", "spawn")
            let failed = await code {
                _ = try await host.run(self.run(root), session: self.session, roots: [root], authorize: {})
            }
            XCTAssertEqual(failed, "failed")
            XCTAssertTrue(host.registry.all.isEmpty)
        }

        func testForegroundTimeoutTermsTheGroupThenKillsAfterTwoSeconds() async throws {
            let root = try folder()
            let spawner = MacComputerFakeSpawner(exits: [SIGKILL: .signaled(SIGKILL)])
            let clock = MacComputerFakeClock { $0 == 10 }
            let host = commands(spawner, clock: clock)
            let result = try await host.run(
                run(root, ["timeout_s": .number(5)]), session: session, roots: [root], authorize: {})
            XCTAssertEqual(result["timed_out"], .bool(true))
            XCTAssertEqual(result["signal"], .string("KILL"))
            XCTAssertEqual(result["exit_code"], .null)
            XCTAssertEqual(spawner.processes.first?.signals, [SIGTERM, SIGKILL])
            XCTAssertTrue(clock.sleeps.contains(5))
            XCTAssertTrue(clock.sleeps.contains(2))
            XCTAssertEqual(host.registry.all.first?.state, "timed_out")
        }

        func testBackgroundJobReadsOffsetsStreamsAndWaitsForNewOutput() async throws {
            let root = try folder()
            let spawner = MacComputerFakeSpawner()
            let clock = MacComputerFakeClock { $0 >= 20 }
            let host = commands(spawner, clock: clock)
            let started = try await host.run(
                run(root, ["background": .bool(true), "timeout_s": .number(3600)]), session: session, roots: [root],
                authorize: {})
            let id = try XCTUnwrap(started["job_id"]?.stringValue)
            let uuid = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
            XCTAssertNotNil(id.range(of: uuid, options: .regularExpression))
            XCTAssertNotNil(started["started_at"]?.stringValue)
            XCTAssertEqual(Set(started.keys), ["job_id", "started_at"])
            let output = try XCTUnwrap(spawner.outputs.first)
            output.append(.stdout, Array("one\n".utf8))
            output.append(.stderr, Array("err\n".utf8))
            output.append(.stdout, Array("two\n".utf8))
            let both = try await host.read(request("read_output", ["job_id": .string(id)]), authorize: {})
            XCTAssertEqual(both["state"], .string("running"))
            XCTAssertEqual(both["exit_code"], .null)
            XCTAssertEqual(
                both["chunks"],
                .array([
                    .object(["stream": .string("stdout"), "offset": .number(0), "data": .string("one\n")]),
                    .object(["stream": .string("stderr"), "offset": .number(4), "data": .string("err\n")]),
                    .object(["stream": .string("stdout"), "offset": .number(8), "data": .string("two\n")]),
                ]))
            XCTAssertEqual(both["next_offset"], .number(12))
            XCTAssertEqual(both["truncated"], .bool(false))
            let errors = try await host.read(
                request("read_output", ["job_id": .string(id), "stream": .string("stderr")]), authorize: {})
            XCTAssertEqual(errors["chunks"]?.arrayValue?.count, 1)
            let partial = try await host.read(
                request("read_output", ["job_id": .string(id), "offset": .number(2), "max_bytes": .number(3)]),
                authorize: {})
            XCTAssertEqual(
                partial["chunks"],
                .array([.object(["stream": .string("stdout"), "offset": .number(2), "data": .string("e\n")]),
                    .object(["stream": .string("stderr"), "offset": .number(4), "data": .string("e")])]))
            XCTAssertEqual(partial["next_offset"], .number(5))
            XCTAssertEqual(partial["truncated"], .bool(true))
            let waiting = Task {
                try await host.read(
                    self.request("read_output", ["job_id": .string(id), "offset": .number(12), "wait_s": .number(25)]),
                    authorize: {})
            }
            while !clock.sleeps.contains(25) { await Task.yield() }
            output.append(.stdout, Array("three\n".utf8))
            let woke = try await waiting.value
            XCTAssertEqual(woke["chunks"]?.arrayValue?.first?["data"], .string("three\n"))
            XCTAssertEqual(woke["next_offset"], .number(18))
            spawner.processes.first?.exit(.exited(0))
            while host.registry.job(id)?.running == true { await Task.yield() }
            let ended = try await host.read(
                request("read_output", ["job_id": .string(id), "offset": .number(18), "wait_s": .number(25)]),
                authorize: {})
            XCTAssertEqual(ended["state"], .string("exited"))
            XCTAssertEqual(ended["exit_code"], .number(0))
            XCTAssertEqual(ended["chunks"], .array([]))
            let missing = await code {
                _ = try await host.read(
                    self.request("read_output", ["job_id": .string(UUID().uuidString.lowercased())]), authorize: {})
            }
            XCTAssertEqual(missing, "not_found")
        }

        func testBackgroundTimeoutEndsTheJobAsTimedOut() async throws {
            let root = try folder()
            let spawner = MacComputerFakeSpawner()
            let host = commands(spawner)
            let started = try await host.run(
                run(root, ["background": .bool(true), "timeout_s": .number(30)]), session: session, roots: [root],
                authorize: {})
            let id = try XCTUnwrap(started["job_id"]?.stringValue)
            while host.registry.job(id)?.running == true { await Task.yield() }
            XCTAssertEqual(host.registry.job(id)?.state, "timed_out")
            XCTAssertEqual(spawner.processes.first?.signals, [SIGTERM])
        }

        func testInterruptSignalsTheGroupAndEscalatesTerm() async throws {
            let root = try folder()
            let cases: [(String, [Int32: MacComputerCommandTermination], [Int32])] = [
                ("INT", [SIGINT: .signaled(SIGINT)], [SIGINT]),
                ("TERM", [SIGKILL: .signaled(SIGKILL)], [SIGTERM, SIGKILL]),
                ("KILL", [SIGKILL: .signaled(SIGKILL)], [SIGKILL]),
            ]
            for (name, exits, expected) in cases {
                let spawner = MacComputerFakeSpawner(exits: exits)
                let host = commands(spawner, clock: MacComputerFakeClock { $0 == 1 || $0 >= 20 })
                let started = try await host.run(
                    run(root, ["background": .bool(true), "timeout_s": .number(3600)]), session: session,
                    roots: [root], authorize: {})
                let id = try XCTUnwrap(started["job_id"]?.stringValue)
                let result = try await host.interrupt(
                    request("interrupt_command", ["job_id": .string(id), "signal": .string(name)], deadline: 5000),
                    authorize: {})
                XCTAssertEqual(result["state"], .string("interrupted"), name)
                XCTAssertEqual(result["exit_code"], .null, name)
                XCTAssertEqual(spawner.processes.first?.signals, expected, name)
                let again = try await host.interrupt(
                    request("interrupt_command", ["job_id": .string(id), "signal": .string("KILL")], deadline: 5000),
                    authorize: {})
                XCTAssertEqual(again["state"], .string("interrupted"))
                XCTAssertEqual(spawner.processes.first?.signals, expected, name)
            }
        }

        func testSessionConcurrencyAndRetainedRecordLimits() async throws {
            let root = try folder()
            let spawner = MacComputerFakeSpawner { plan, _, process in
                if plan.environment["APP_QUICK"] == "1" { process.exit(.exited(0)) }
            }
            let quick: [String: JSONValue] = ["env": .object(["APP_QUICK": .string("1")])]
            let host = commands(spawner, clock: MacComputerFakeClock { $0 >= 20 })
            let background: [String: JSONValue] = ["background": .bool(true), "timeout_s": .number(3600)]
            for _ in 0..<4 {
                _ = try await host.run(run(root, background), session: session, roots: [root], authorize: {})
            }
            let fifth = await code {
                _ = try await host.run(self.run(root, background), session: self.session, roots: [root], authorize: {})
            }
            XCTAssertEqual(fifth, "capacity_exceeded")
            let other = "22222222-2222-4222-8222-222222222222"
            _ = try await host.run(run(root, background), session: other, roots: [root], authorize: {})
            for process in spawner.processes { process.exit(.exited(0)) }
            let first = try XCTUnwrap(host.registry.all.first?.id)
            while host.registry.all.contains(where: \.running) { await Task.yield() }
            for _ in 0..<59 {
                _ = try await host.run(run(root, quick), session: session, roots: [root], authorize: {})
            }
            XCTAssertEqual(host.registry.all.count, 64)
            XCTAssertNotNil(host.registry.job(first))
            _ = try await host.run(run(root, quick), session: session, roots: [root], authorize: {})
            XCTAssertEqual(host.registry.all.count, 64)
            XCTAssertNil(host.registry.job(first))
        }

        func testEndAllInterruptsOrMarksUncertainAndForgetClearsRecords() async throws {
            let root = try folder()
            let spawner = MacComputerFakeSpawner()
            let host = commands(spawner, clock: MacComputerFakeClock { $0 >= 20 })
            let background: [String: JSONValue] = ["background": .bool(true), "timeout_s": .number(3600)]
            let finished = try await host.run(run(root, background), session: session, roots: [root], authorize: {})
            spawner.processes[0].exit(.exited(0))
            let first = try await host.run(run(root, background), session: session, roots: [root], authorize: {})
            let second = try await host.run(run(root, background), session: session, roots: [root], authorize: {})
            let ids = try [finished, first, second].map { try XCTUnwrap($0["job_id"]?.stringValue) }
            while host.registry.job(ids[0])?.running == true { await Task.yield() }
            host.endAll(as: "uncertain")
            for id in ids.dropFirst() {
                while host.registry.job(id)?.running == true { await Task.yield() }
            }
            XCTAssertEqual(ids.map { host.registry.job($0)?.state }, ["exited", "uncertain", "uncertain"])
            let third = try await host.run(run(root, background), session: session, roots: [root], authorize: {})
            let thirdId = try XCTUnwrap(third["job_id"]?.stringValue)
            host.endAll(as: "interrupted")
            while host.registry.job(thirdId)?.running == true { await Task.yield() }
            XCTAssertEqual(host.registry.job(thirdId)?.state, "interrupted")
            let raced = await code {
                _ = try await host.run(
                    self.run(root, background), session: self.session, roots: [root],
                    authorize: { host.endAll(as: "interrupted") })
            }
            XCTAssertEqual(raced, "interrupted")
            XCTAssertEqual(spawner.processes.last?.signals, [SIGTERM])
            host.forget()
            XCTAssertTrue(host.registry.all.isEmpty)
        }

        func testOutputRingEvictsOldBytesAndForegroundTailsAreBounded() async throws {
            let root = try folder()
            let large = Array(repeating: UInt8(ascii: "a"), count: MacComputerCommandOutput.ringBytes + 1000)
            let spawner = MacComputerFakeSpawner { _, output, process in
                output.append(.stdout, large)
                output.finish(.stdout)
                output.finish(.stderr)
                process.exit(.exited(0))
            }
            let host = commands(spawner)
            let result = try await host.run(run(root), session: session, roots: [root], authorize: {})
            XCTAssertEqual(result["truncated"], .bool(true))
            XCTAssertEqual(result["stdout"]?.stringValue?.utf8.count, MacComputerCommands.tailBytes)
            XCTAssertEqual(result["stdout_bytes"], .number(Double(large.count)))
            let output = try XCTUnwrap(spawner.outputs.first)
            let read = output.read(from: 0, streams: [.stdout], maximum: 65536)
            XCTAssertEqual(read.slices.first?.offset, 1000)
            XCTAssertTrue(read.truncated)
            XCTAssertEqual(read.next, 1000 + 65536)
        }

        func testOpenStreamsNeverSplitAScalarAndClosedStreamsDecodeLossily() {
            let output = MacComputerCommandOutput()
            let compass = Array("🧭".utf8)
            output.append(.stdout, Array("a".utf8) + compass.prefix(2))
            var read = output.read(from: 0, streams: [.stdout, .stderr], maximum: 100)
            XCTAssertEqual(read.slices, [.init(stream: .stdout, offset: 0, data: "a")])
            XCTAssertEqual(read.next, 1)
            output.append(.stdout, compass.suffix(2))
            read = output.read(from: 1, streams: [.stdout], maximum: 100)
            XCTAssertEqual(read.slices, [.init(stream: .stdout, offset: 1, data: "🧭")])
            XCTAssertEqual(read.next, 5)
            read = output.read(from: 0, streams: [.stdout], maximum: 3)
            XCTAssertEqual(read.slices, [.init(stream: .stdout, offset: 0, data: "a")])
            XCTAssertTrue(read.truncated)
            read = output.read(from: 1, streams: [.stdout], maximum: 1)
            XCTAssertEqual(read.next, 2)
            output.append(.stdout, compass.prefix(1))
            output.finish(.stdout)
            read = output.read(from: 5, streams: [.stdout], maximum: 100)
            XCTAssertEqual(read.slices, [.init(stream: .stdout, offset: 5, data: "\u{FFFD}")])
            XCTAssertEqual(read.next, 6)
            XCTAssertEqual(output.read(from: 99, streams: [.stdout], maximum: 100).next, 6)
            output.append(.stdout, Array("late".utf8))
            XCTAssertEqual(output.bytes(.stdout), 6)
        }

        func testRealEchoRunsThroughPosixSpawnWithTheSanitizedEnvironment() async throws {
            let root = try folder()
            let host = MacComputerCommands(
                inherited: ["HOME": NSHomeDirectory(), "ASTRAL_SESSION": "secret", "USER": "synthetic"],
                loginPath: { "/usr/bin:/bin" })
            let echo = try await host.run(
                request(
                    "run_command", ["argv": .array([.string("/bin/echo"), .string("hello")]), "cwd": .string(root)],
                    deadline: 600000), session: session, roots: [root], authorize: {})
            XCTAssertEqual(echo["exit_code"], .number(0))
            XCTAssertEqual(echo["stdout"], .string("hello\n"))
            XCTAssertEqual(echo["stderr"], .string(""))
            XCTAssertEqual(echo["timed_out"], .bool(false))
            let env = try await host.run(
                request(
                    "run_command",
                    [
                        "argv": .array([.string("env")]), "cwd": .string(root),
                        "env": .object(["APP_FOO": .string("bar")]), "stdin": .string("ignored"),
                    ], deadline: 600000), session: session, roots: [root], authorize: {})
            let lines = Set((env["stdout"]?.stringValue ?? "").split(separator: "\n").map(String.init))
            XCTAssertTrue(lines.isSuperset(of: ["TERM=dumb", "APP_FOO=bar", "PATH=/usr/bin:/bin", "USER=synthetic"]))
            XCTAssertFalse(lines.contains { $0.hasPrefix("ASTRAL_") })
            let cat = try await host.run(
                request(
                    "run_command", ["argv": .array([.string("cat")]), "cwd": .string(root), "stdin": .string("piped")],
                    deadline: 600000), session: session, roots: [root], authorize: {})
            XCTAssertEqual(cat["stdout"], .string("piped"))
        }

        func testRealSleepIsKilledAtItsTimeoutAsAGroup() async throws {
            let root = try folder()
            let host = MacComputerCommands(inherited: [:], loginPath: { "/usr/bin:/bin" })
            let result = try await host.run(
                request(
                    "run_command",
                    [
                        "argv": .array([.string("/bin/sleep"), .string("30")]), "cwd": .string(root),
                        "timeout_s": .number(1),
                    ],
                    deadline: 600000), session: session, roots: [root], authorize: {})
            XCTAssertEqual(result["timed_out"], .bool(true))
            XCTAssertEqual(result["signal"], .string("TERM"))
            XCTAssertEqual(result["exit_code"], .null)
            XCTAssertLessThan(try XCTUnwrap(result["duration_ms"]?.numberValue), 30000)
        }
    }

    nonisolated final class MacComputerFakeProcess: MacComputerCommandProcess, @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: MacComputerCommandTermination?
        private var waiters: [CheckedContinuation<MacComputerCommandTermination, Never>] = []
        private var received: [Int32] = []
        private let exits: [Int32: MacComputerCommandTermination]
        init(exits: [Int32: MacComputerCommandTermination]) { self.exits = exits }
        var signals: [Int32] { lock.withLock { received } }
        func signal(_ value: Int32) {
            let termination = lock.withLock { () -> MacComputerCommandTermination? in
                guard outcome == nil else { return nil }
                received.append(value)
                return exits[value]
            }
            if let termination { exit(termination) }
        }
        func exit(_ value: MacComputerCommandTermination) {
            let pending = lock.withLock { () -> [CheckedContinuation<MacComputerCommandTermination, Never>] in
                guard outcome == nil else { return [] }
                outcome = value
                let values = waiters
                waiters = []
                return values
            }
            for waiter in pending { waiter.resume(returning: value) }
        }
        func wait() async -> MacComputerCommandTermination {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> MacComputerCommandTermination? in
                    if let outcome { return outcome }
                    waiters.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }

    typealias MacComputerFakeScript =
        @Sendable (MacComputerCommandPlan, MacComputerCommandOutput, MacComputerFakeProcess) -> Void

    nonisolated final class MacComputerFakeSpawner: MacComputerCommandSpawning, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedPlans: [MacComputerCommandPlan] = []
        private var recordedProcesses: [MacComputerFakeProcess] = []
        private var recordedOutputs: [MacComputerCommandOutput] = []
        private var injected: Error?
        private let exits: [Int32: MacComputerCommandTermination]
        private let script: MacComputerFakeScript?
        init(
            exits: [Int32: MacComputerCommandTermination] = [
                SIGINT: .signaled(SIGINT), SIGTERM: .signaled(SIGTERM), SIGKILL: .signaled(SIGKILL),
            ],
            script: MacComputerFakeScript? = nil
        ) {
            self.exits = exits
            self.script = script
        }
        var plans: [MacComputerCommandPlan] { lock.withLock { recordedPlans } }
        var processes: [MacComputerFakeProcess] { lock.withLock { recordedProcesses } }
        var outputs: [MacComputerCommandOutput] { lock.withLock { recordedOutputs } }
        var failure: Error? {
            get { lock.withLock { injected } }
            set { lock.withLock { injected = newValue } }
        }
        func spawn(_ plan: MacComputerCommandPlan, output: MacComputerCommandOutput) throws
            -> any MacComputerCommandProcess
        {
            if let failure { throw failure }
            let process = MacComputerFakeProcess(exits: exits)
            lock.withLock {
                recordedPlans.append(plan)
                recordedProcesses.append(process)
                recordedOutputs.append(output)
            }
            script?(plan, output, process)
            return process
        }
    }

    nonisolated final class MacComputerFakeClock: MacComputerCommandClock, @unchecked Sendable {
        private let lock = NSLock()
        private var current = 100.0
        private var recorded: [Double] = []
        private let hold: @Sendable (Double) -> Bool
        init(hold: @escaping @Sendable (Double) -> Bool = { _ in false }) { self.hold = hold }
        var sleeps: [Double] { lock.withLock { recorded } }
        func now() -> Double { lock.withLock { current } }
        func date() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
        func sleep(_ seconds: Double) async throws {
            lock.withLock { recorded.append(seconds) }
            if hold(seconds) {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
            await Task.yield()
            try Task.checkCancellation()
            lock.withLock { current += seconds }
        }
    }
#endif
