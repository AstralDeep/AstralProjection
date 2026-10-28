// Runs approved workspace commands in their own process groups with bounded output rings and retained job records.
// MacComputerHost calls it off the physical-effect queue; ComputerCommandPolicy decides every launch input.

#if os(macOS)
    import AstralCore
    import Darwin
    import Foundation

    nonisolated enum MacComputerCommandStream: String, Sendable, CaseIterable {
        case stdout, stderr
    }

    nonisolated enum MacComputerCommandTermination: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
        case lost
    }

    nonisolated struct MacComputerCommandPlan: Sendable, Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let directory: String
        let stdin: Data?
    }

    nonisolated protocol MacComputerCommandProcess: AnyObject, Sendable {
        func signal(_ value: Int32)
        func wait() async -> MacComputerCommandTermination
    }

    nonisolated protocol MacComputerCommandSpawning: Sendable {
        func spawn(_ plan: MacComputerCommandPlan, output: MacComputerCommandOutput) throws
            -> any MacComputerCommandProcess
    }

    nonisolated protocol MacComputerCommandClock: Sendable {
        func now() -> Double
        func date() -> Date
        func sleep(_ seconds: Double) async throws
    }

    nonisolated struct MacComputerLiveCommandClock: MacComputerCommandClock {
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        func date() -> Date { Date() }
        func sleep(_ seconds: Double) async throws {
            try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 86400)) * 1_000_000_000))
        }
    }

    nonisolated final class MacComputerCommandOutput: @unchecked Sendable {
        static let ringBytes = 262_144
        static let chunkLimit = 16384
        private struct Chunk {
            let stream: MacComputerCommandStream
            var start: Int
            var bytes: [UInt8]
        }
        struct Slice: Equatable {
            let stream: MacComputerCommandStream
            let offset: Int
            let data: String
        }
        private let lock = NSLock()
        private var chunks: [Chunk] = []
        private var total = 0
        private var counts: [MacComputerCommandStream: Int] = [.stdout: 0, .stderr: 0]
        private var retained: [MacComputerCommandStream: Int] = [.stdout: 0, .stderr: 0]
        private var evicted: [MacComputerCommandStream: Int] = [.stdout: 0, .stderr: 0]
        private var open: Set<MacComputerCommandStream> = [.stdout, .stderr]
        private var revision: UInt64 = 0
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        var version: UInt64 { lock.withLock { revision } }
        var closed: Bool { lock.withLock { open.isEmpty } }
        func bytes(_ stream: MacComputerCommandStream) -> Int { lock.withLock { counts[stream] ?? 0 } }

        func append(_ stream: MacComputerCommandStream, _ data: some Collection<UInt8>) {
            guard !data.isEmpty else { return }
            lock.withLock {
                guard open.contains(stream) else { return }
                if let last = chunks.indices.last, chunks[last].stream == stream {
                    chunks[last].bytes.append(contentsOf: data)
                } else {
                    chunks.append(Chunk(stream: stream, start: total, bytes: Array(data)))
                }
                total += data.count
                counts[stream, default: 0] += data.count
                retained[stream, default: 0] += data.count
                evict(stream)
            }
            notify()
        }
        func finish(_ stream: MacComputerCommandStream) {
            lock.withLock { _ = open.remove(stream) }
            notify()
        }
        func touch() { notify() }

        private func evict(_ stream: MacComputerCommandStream) {
            while retained[stream, default: 0] > Self.ringBytes,
                let index = chunks.firstIndex(where: { $0.stream == stream })
            {
                let excess = retained[stream, default: 0] - Self.ringBytes
                if chunks[index].bytes.count <= excess {
                    let removed = chunks.remove(at: index)
                    retained[stream, default: 0] -= removed.bytes.count
                    evicted[stream] = max(evicted[stream] ?? 0, removed.start + removed.bytes.count)
                } else {
                    chunks[index].bytes.removeFirst(excess)
                    chunks[index].start += excess
                    retained[stream, default: 0] -= excess
                    evicted[stream] = max(evicted[stream] ?? 0, chunks[index].start)
                }
            }
            while chunks.count > Self.chunkLimit {
                let removed = chunks.removeFirst()
                retained[removed.stream, default: 0] -= removed.bytes.count
                evicted[removed.stream] = max(evicted[removed.stream] ?? 0, removed.start + removed.bytes.count)
            }
        }

        func available(after offset: Int, streams: Set<MacComputerCommandStream>) -> Bool {
            lock.withLock {
                chunks.contains { streams.contains($0.stream) && $0.start + $0.bytes.count > offset }
            }
        }

        func read(from requested: Int, streams: Set<MacComputerCommandStream>, maximum: Int)
            -> (slices: [Slice], next: Int, truncated: Bool)
        {
            lock.withLock {
                let offset = min(max(0, requested), total)
                let lost = streams.contains { (evicted[$0] ?? 0) > offset }
                var last: [MacComputerCommandStream: Int] = [:]
                for (index, chunk) in chunks.enumerated() { last[chunk.stream] = index }
                var budget = maximum
                var next = offset
                var stopped = false
                var cut = false
                var slices: [Slice] = []
                for (index, chunk) in chunks.enumerated() where streams.contains(chunk.stream) {
                    let end = chunk.start + chunk.bytes.count
                    guard end > offset else { continue }
                    guard budget > 0 else {
                        cut = true
                        stopped = true
                        break
                    }
                    let from = max(offset, chunk.start)
                    let lower = from - chunk.start
                    let limited = min(end - from, budget) < end - from
                    var take = min(end - from, budget)
                    if limited || (last[chunk.stream] == index && open.contains(chunk.stream)) {
                        let bounded = macComputerUTF8Boundary(Array(chunk.bytes[lower..<(lower + take)]), take)
                        if bounded < take { stopped = true }
                        if bounded > 0 || !limited { take = bounded }
                    }
                    if limited {
                        cut = true
                        stopped = true
                    }
                    if take > 0 {
                        slices.append(
                            Slice(
                                stream: chunk.stream, offset: from,
                                data: String(decoding: chunk.bytes[lower..<(lower + take)], as: UTF8.self)))
                        budget -= take
                        next = from + take
                    }
                    if stopped { break }
                }
                if !stopped { next = total }
                return (slices, next, lost || cut)
            }
        }

        func tail(_ stream: MacComputerCommandStream, limit: Int) -> (text: String, complete: Bool) {
            lock.withLock {
                var collected: [UInt8] = []
                for chunk in chunks.reversed() where chunk.stream == stream && collected.count < limit {
                    let take = min(limit - collected.count, chunk.bytes.count)
                    collected.insert(contentsOf: chunk.bytes.suffix(take), at: 0)
                }
                let total = counts[stream] ?? 0
                var start = 0
                if collected.count < total {
                    while start < collected.count, start < 4, collected[start] & 0xC0 == 0x80 { start += 1 }
                }
                return (String(decoding: collected[start...], as: UTF8.self), collected.count == total)
            }
        }

        func waitForChange(since expected: UInt64) async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = lock.withLock { () -> Bool in
                        if revision != expected || Task.isCancelled { return true }
                        waiters[id] = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            } onCancel: {
                let waiter = lock.withLock { waiters.removeValue(forKey: id) }
                waiter?.resume()
            }
        }

        private func notify() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                revision &+= 1
                let values = Array(waiters.values)
                waiters = [:]
                return values
            }
            for waiter in pending { waiter.resume() }
        }
    }

    nonisolated func macComputerUTF8Boundary(_ bytes: [UInt8], _ end: Int) -> Int {
        var start = end
        while start > 0, start > end - 4, bytes[start - 1] & 0xC0 == 0x80 { start -= 1 }
        guard start > 0 else { return end }
        let lead = bytes[start - 1]
        let width = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return start - 1 + width > end ? start - 1 : end
    }

    nonisolated final class MacComputerCommandJob: @unchecked Sendable {
        let id: String
        let session: String
        let argv0: String
        let cwd: String
        let startedAt: Date
        let started: Double
        let output: MacComputerCommandOutput
        let process: any MacComputerCommandProcess
        private let lock = NSLock()
        private var ending: String?
        private var termination: MacComputerCommandTermination?
        var requested: String? { lock.withLock { ending } }
        private var finished: Double?

        init(
            id: String, session: String, argv0: String, cwd: String, startedAt: Date, started: Double,
            output: MacComputerCommandOutput, process: any MacComputerCommandProcess
        ) {
            self.id = id
            self.session = session
            self.argv0 = argv0
            self.cwd = cwd
            self.startedAt = startedAt
            self.started = started
            self.output = output
            self.process = process
        }
        var running: Bool { lock.withLock { termination == nil } }
        var state: String { lock.withLock { termination == nil ? "running" : ending ?? "exited" } }
        var result: MacComputerCommandTermination? { lock.withLock { termination } }
        var duration: Double? { lock.withLock { finished.map { max(0, $0 - started) } } }
        func requestEnd(_ state: String) -> Bool {
            lock.withLock {
                guard termination == nil, ending == nil else { return false }
                ending = state
                return true
            }
        }
        func finish(_ value: MacComputerCommandTermination, at time: Double) {
            lock.withLock {
                guard termination == nil else { return }
                termination = value
                finished = time
            }
            output.touch()
        }
        var exitCode: JSONValue {
            if case .exited(let code) = result { return .number(Double(code)) }
            return .null
        }
        var signalName: JSONValue {
            guard case .signaled(let value) = result else { return .null }
            let names: [Int32: String] = [
                SIGHUP: "HUP", SIGINT: "INT", SIGQUIT: "QUIT", SIGILL: "ILL", SIGABRT: "ABRT", SIGFPE: "FPE",
                SIGKILL: "KILL", SIGBUS: "BUS", SIGSEGV: "SEGV", SIGPIPE: "PIPE", SIGALRM: "ALRM", SIGTERM: "TERM",
                SIGUSR1: "USR1", SIGUSR2: "USR2",
            ]
            return .string(names[value] ?? "SIG\(value)")
        }
    }

    nonisolated final class MacComputerCommandRegistry: @unchecked Sendable {
        static let sessionLimit = 4
        static let retainedLimit = 64
        private let lock = NSLock()
        private var jobs: [String: MacComputerCommandJob] = [:]
        private var order: [String] = []
        private var epoch = 0
        var generation: Int { lock.withLock { epoch } }
        var all: [MacComputerCommandJob] { lock.withLock { order.compactMap { jobs[$0] } } }
        func job(_ id: String) -> MacComputerCommandJob? { lock.withLock { jobs[id] } }
        func running(session: String) -> Int {
            lock.withLock { jobs.values.filter { $0.session == session && $0.running }.count }
        }
        func room() -> Bool {
            lock.withLock { order.count < Self.retainedLimit || order.contains { jobs[$0]?.running == false } }
        }
        func register(_ job: MacComputerCommandJob, generation expected: Int) -> Bool {
            lock.withLock {
                if order.count >= Self.retainedLimit,
                    let index = order.firstIndex(where: { jobs[$0]?.running == false })
                {
                    jobs[order.remove(at: index)] = nil
                }
                jobs[job.id] = job
                order.append(job.id)
                return epoch == expected
            }
        }
        func advance() -> [MacComputerCommandJob] {
            lock.withLock {
                epoch += 1
                return order.compactMap { jobs[$0] }.filter(\.running)
            }
        }
        func clear() {
            lock.withLock {
                epoch += 1
                jobs = [:]
                order = []
            }
        }
    }

    actor MacComputerCommands {
        static let tailBytes = 32768
        nonisolated let registry = MacComputerCommandRegistry()
        nonisolated let clock: any MacComputerCommandClock
        private let spawner: any MacComputerCommandSpawning
        private let inherited: [String: String]
        private let resolver: (@Sendable () async -> String)?
        private var path: String?
        private var resolving: Task<String, Never>?
        private static let timestamp: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        init(
            spawner: any MacComputerCommandSpawning = MacComputerPosixSpawner(),
            clock: any MacComputerCommandClock = MacComputerLiveCommandClock(),
            inherited: [String: String] = ProcessInfo.processInfo.environment,
            loginPath: (@Sendable () async -> String)? = nil
        ) {
            self.spawner = spawner
            self.clock = clock
            self.inherited = inherited
            resolver = loginPath
        }

        func loginPath() async -> String {
            if let path { return path }
            if let resolving { return await resolving.value }
            let task = Task { await self.resolveLoginPath() }
            resolving = task
            let value = await task.value
            path = value
            resolving = nil
            return value
        }

        private func resolveLoginPath() async -> String {
            if let resolver { return await resolver() }
            let fallback = ComputerCommandPolicy.fallbackPath
            guard
                let environment = try? ComputerCommandPolicy.environment(
                    inherited: inherited, path: fallback, additions: [:])
            else { return fallback }
            let output = MacComputerCommandOutput()
            let home = environment["HOME"].flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? "/"
            guard
                let process = try? spawner.spawn(
                    MacComputerCommandPlan(
                        executable: "/bin/zsh", arguments: ["/bin/zsh", "-lc", "print -r -- $PATH"],
                        environment: environment, directory: home, stdin: nil), output: output)
            else { return fallback }
            let job = MacComputerCommandJob(
                id: UUID().uuidString.lowercased(), session: "", argv0: "zsh", cwd: home, startedAt: clock.date(),
                started: clock.now(), output: output, process: process)
            let clock = clock
            Task { job.finish(await process.wait(), at: clock.now()) }
            if await !finished(job, within: 5) {
                end(job, as: "timed_out")
                _ = await finished(job, within: 5)
            }
            guard case .exited(0) = job.result else { return fallback }
            return ComputerCommandPolicy.loginPath(output.tail(.stdout, limit: 16384).text) ?? fallback
        }

        func run(
            _ request: ComputerHostRequest, session: String, roots: [String],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            let args = request.args
            let background = args["background"]?.boolValue == true
            let timeout = try ComputerCommandPolicy.timeout(args["timeout_s"]?.numberValue, background: background)
            let cwd = try ComputerCommandPolicy.workingDirectory(args["cwd"]?.stringValue ?? "", roots: roots)
            var additions: [String: String] = [:]
            for (name, value) in args["env"]?.objectValue ?? [:] {
                guard let text = value.stringValue else {
                    throw ComputerHostError("out_of_range", "Invalid command environment.")
                }
                additions[name] = text
            }
            let stdin = try ComputerCommandPolicy.stdin(args["stdin"]?.stringValue)
            let argv = try args["argv"]?.arrayValue.map { items in
                try items.map { item in
                    guard let text = item.stringValue else { throw ComputerHostError("out_of_range", "Invalid argv.") }
                    return text
                }
            }
            let invocation = try ComputerCommandPolicy.invocation(command: args["command"]?.stringValue, argv: argv)
            let environment = try ComputerCommandPolicy.environment(
                inherited: inherited, path: await loginPath(), additions: additions)
            let plan: MacComputerCommandPlan
            if let argv = invocation.argv {
                guard
                    let executable = ComputerCommandPolicy.executable(
                        argv[0], path: environment["PATH"] ?? ComputerCommandPolicy.fallbackPath, cwd: cwd)
                else {
                    throw ComputerHostError("not_found", "The program \(invocation.argv0) was not found on PATH.")
                }
                plan = MacComputerCommandPlan(
                    executable: executable, arguments: argv, environment: environment, directory: cwd, stdin: stdin)
            } else {
                plan = MacComputerCommandPlan(
                    executable: "/bin/zsh", arguments: ["/bin/zsh", "-lc", invocation.command ?? ""],
                    environment: environment, directory: cwd, stdin: stdin)
            }
            guard registry.running(session: session) < MacComputerCommandRegistry.sessionLimit else {
                throw ComputerHostError(
                    "capacity_exceeded", "Four commands are already running in this session. Interrupt one first.")
            }
            guard registry.room() else {
                throw ComputerHostError("capacity_exceeded", "The command job record capacity is full.")
            }
            let generation = registry.generation
            try authorize()
            try Task.checkCancellation()
            let output = MacComputerCommandOutput()
            let process = try spawner.spawn(plan, output: output)
            let job = MacComputerCommandJob(
                id: UUID().uuidString.lowercased(), session: session, argv0: invocation.argv0, cwd: cwd,
                startedAt: clock.date(), started: clock.now(), output: output, process: process)
            let clock = clock
            Task { job.finish(await process.wait(), at: clock.now()) }
            guard registry.register(job, generation: generation) else {
                end(job, as: "interrupted")
                throw ComputerHostError("interrupted", "Computer authority changed while the command started.")
            }
            if background {
                Task {
                    if await !self.finished(job, within: timeout) { self.end(job, as: "timed_out") }
                }
                return ["job_id": .string(job.id), "started_at": .string(Self.timestamp.string(from: job.startedAt))]
            }
            let completed = await withTaskCancellationHandler {
                await finished(job, within: timeout)
            } onCancel: {
                self.end(job, as: "interrupted")
            }
            if !completed { end(job, as: Task.isCancelled ? "interrupted" : "timed_out") }
            if job.running { _ = await finished(job, within: 10) }
            try Task.checkCancellation()
            let stdout = output.tail(.stdout, limit: Self.tailBytes)
            let stderr = output.tail(.stderr, limit: Self.tailBytes)
            return [
                "exit_code": job.exitCode, "signal": job.signalName, "timed_out": .bool(job.requested == "timed_out"),
                "duration_ms": .number(((job.duration ?? max(0, clock.now() - job.started)) * 1000).rounded()),
                "stdout": .string(stdout.text), "stderr": .string(stderr.text),
                "stdout_bytes": .number(Double(output.bytes(.stdout))),
                "stderr_bytes": .number(Double(output.bytes(.stderr))),
                "truncated": .bool(!stdout.complete || !stderr.complete), "cwd": .string(cwd),
                "started_at": .string(Self.timestamp.string(from: job.startedAt)),
            ]
        }

        func read(_ request: ComputerHostRequest, authorize: @escaping @Sendable () throws -> Void) async throws
            -> [String: JSONValue]
        {
            let job = try record(request)
            let streams: Set<MacComputerCommandStream> =
                switch request.args["stream"]?.stringValue {
                case "stdout": [.stdout]
                case "stderr": [.stderr]
                default: [.stdout, .stderr]
                }
            let offset = Int(request.args["offset"]?.numberValue ?? 0)
            let maximum = Int(request.args["max_bytes"]?.numberValue ?? 65536)
            let wait = request.args["wait_s"]?.numberValue ?? 0
            if wait > 0, job.running, !job.output.available(after: offset, streams: streams) {
                let output = job.output
                _ = await until(within: min(wait, 25), output: output) {
                    !job.running || output.available(after: offset, streams: streams)
                }
            }
            try authorize()
            let read = job.output.read(from: offset, streams: streams, maximum: maximum)
            return [
                "job_id": .string(job.id), "state": .string(job.state), "exit_code": job.exitCode,
                "chunks": .array(
                    read.slices.map {
                        .object([
                            "stream": .string($0.stream.rawValue), "offset": .number(Double($0.offset)),
                            "data": .string($0.data),
                        ])
                    }), "next_offset": .number(Double(read.next)), "truncated": .bool(read.truncated),
            ]
        }

        func interrupt(_ request: ComputerHostRequest, authorize: @escaping @Sendable () throws -> Void) async throws
            -> [String: JSONValue]
        {
            let job = try record(request)
            let signals: [String: Int32] = ["INT": SIGINT, "TERM": SIGTERM, "KILL": SIGKILL]
            guard let value = request.args["signal"]?.stringValue.flatMap({ signals[$0] }) else {
                throw ComputerHostError("out_of_range", "Invalid signal.")
            }
            try authorize()
            if job.running {
                _ = job.requestEnd("interrupted")
                job.process.signal(value)
                if value == SIGTERM { escalate(job) }
                _ = await finished(job, within: 1)
            }
            return ["job_id": .string(job.id), "state": .string(job.state), "exit_code": job.exitCode]
        }

        private func record(_ request: ComputerHostRequest) throws -> MacComputerCommandJob {
            guard let id = request.args["job_id"]?.stringValue, let job = registry.job(id) else {
                throw ComputerHostError("not_found", "No command job with that job_id exists on this Mac.")
            }
            return job
        }

        nonisolated func end(_ job: MacComputerCommandJob, as state: String) {
            guard job.requestEnd(state) else { return }
            job.process.signal(SIGTERM)
            escalate(job)
        }

        private nonisolated func escalate(_ job: MacComputerCommandJob) {
            let clock = clock
            Task {
                do { try await clock.sleep(2) } catch { return }
                if job.running { job.process.signal(SIGKILL) }
            }
        }

        nonisolated func endAll(as state: String) {
            for job in registry.advance() { end(job, as: state) }
        }

        nonisolated func forget() {
            endAll(as: "interrupted")
            registry.clear()
        }

        nonisolated func terminateNow() {
            let jobs = registry.advance()
            for job in jobs {
                _ = job.requestEnd("interrupted")
                job.process.signal(SIGTERM)
            }
            var waited = 0
            while waited < 20, jobs.contains(where: \.running) {
                usleep(10_000)
                waited += 1
            }
            for job in jobs where job.running { job.process.signal(SIGKILL) }
        }

        private func finished(_ job: MacComputerCommandJob, within seconds: Double) async -> Bool {
            await until(within: seconds, output: job.output) { !job.running }
        }

        private func until(
            within seconds: Double, output: MacComputerCommandOutput, _ condition: @escaping @Sendable () -> Bool
        ) async -> Bool {
            if condition() { return true }
            let clock = clock
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do { try await clock.sleep(seconds) } catch {}
                    return false
                }
                group.addTask {
                    while !Task.isCancelled {
                        let version = output.version
                        if condition() { return true }
                        await output.waitForChange(since: version)
                    }
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first || condition()
            }
        }
    }

    nonisolated struct MacComputerPosixSpawner: MacComputerCommandSpawning {
        func spawn(_ plan: MacComputerCommandPlan, output: MacComputerCommandOutput) throws
            -> any MacComputerCommandProcess
        {
            var input: [Int32] = [-1, -1]
            var out: [Int32] = [-1, -1]
            var err: [Int32] = [-1, -1]
            func closeAll() { for fd in input + out + err where fd >= 0 { close(fd) } }
            guard pipe(&input) == 0, pipe(&out) == 0, pipe(&err) == 0 else {
                closeAll()
                throw ComputerHostError("failed", "The command pipes could not be created (errno \(errno)).")
            }
            for fd in input + out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            posix_spawn_file_actions_adddup2(&actions, input[0], 0)
            posix_spawn_file_actions_adddup2(&actions, out[1], 1)
            posix_spawn_file_actions_adddup2(&actions, err[1], 2)
            posix_spawn_file_actions_addchdir_np(&actions, plan.directory)
            let flags =
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            posix_spawnattr_setflags(&attributes, Int16(flags))
            posix_spawnattr_setpgroup(&attributes, 0)
            var defaults = sigset_t()
            sigfillset(&defaults)
            sigdelset(&defaults, SIGKILL)
            sigdelset(&defaults, SIGSTOP)
            posix_spawnattr_setsigdefault(&attributes, &defaults)
            var mask = sigset_t()
            sigemptyset(&mask)
            posix_spawnattr_setsigmask(&attributes, &mask)
            let argv: [UnsafeMutablePointer<CChar>?] = plan.arguments.map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] =
                plan.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                for pointer in argv { free(pointer) }
                for pointer in envp { free(pointer) }
            }
            var pid: pid_t = 0
            let status = posix_spawn(&pid, plan.executable, &actions, &attributes, argv, envp)
            close(input[0])
            close(out[1])
            close(err[1])
            guard status == 0 else {
                close(input[1])
                close(out[0])
                close(err[0])
                throw ComputerHostError("failed", "The command could not start (errno \(status)).")
            }
            let writer = input[1]
            let stdin = plan.stdin
            DispatchQueue.global(qos: .utility).async {
                if let stdin {
                    stdin.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let written = write(writer, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if written < 0 && errno == EINTR { continue }
                            if written <= 0 { break }
                            offset += written
                        }
                    }
                }
                close(writer)
            }
            return MacComputerPosixProcess(pid: pid, stdout: out[0], stderr: err[0], output: output)
        }
    }

    nonisolated final class MacComputerPosixProcess: MacComputerCommandProcess, @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var reaped = false
        private var outcome: MacComputerCommandTermination?
        private var waiters: [CheckedContinuation<MacComputerCommandTermination, Never>] = []
        private let queue = DispatchQueue(label: "com.personalailabs.astraldeep.command-output")
        private let drained = DispatchGroup()
        private var sources: [DispatchSourceRead] = []

        init(pid: pid_t, stdout: Int32, stderr: Int32, output: MacComputerCommandOutput) {
            self.pid = pid
            for (fd, stream) in [(stdout, MacComputerCommandStream.stdout), (stderr, .stderr)] {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                drained.enter()
                source.setEventHandler { [weak source] in
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if count > 0 {
                        output.append(stream, buffer[0..<count])
                    } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        source?.cancel()
                    }
                }
                let group = drained
                source.setCancelHandler {
                    close(fd)
                    output.finish(stream)
                    group.leave()
                }
                sources.append(source)
                source.resume()
            }
            let thread = Thread(block: { [self] in self.reap() })
            thread.name = "Astral command \(pid)"
            thread.start()
        }

        private func reap() {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            lock.withLock { reaped = true }
            if drained.wait(timeout: .now() + 0.5) == .timedOut {
                for source in sources { source.cancel() }
                _ = drained.wait(timeout: .now() + 0.5)
            }
            let termination: MacComputerCommandTermination
            if result != pid {
                termination = .lost
            } else if status & 0x7f == 0 {
                termination = .exited((status >> 8) & 0xff)
            } else if status & 0x7f != 0x7f {
                termination = .signaled(status & 0x7f)
            } else {
                termination = .lost
            }
            let pending = lock.withLock { () -> [CheckedContinuation<MacComputerCommandTermination, Never>] in
                outcome = termination
                let values = waiters
                waiters = []
                return values
            }
            for waiter in pending { waiter.resume(returning: termination) }
        }

        func signal(_ value: Int32) {
            lock.withLock {
                guard !reaped else { return }
                _ = killpg(pid, value)
            }
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
#endif
