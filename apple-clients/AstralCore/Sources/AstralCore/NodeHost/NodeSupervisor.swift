// Keeps the packed node running: it launches the process, waits for health, restarts it after a crash with growing delays and stops it on request.
// The launcher, health probe and sleeper are injected so tests drive the whole lifecycle with a fake process, and NodeHostController owns one supervisor.

#if os(macOS)
    import Darwin
    import Foundation

    public struct NodeLaunchSpec: Equatable, Sendable {
        public let executable: URL
        public let arguments: [String]
        public let environment: [String: String]
        public let workingDirectory: URL
        public let launchLog: URL

        public init(
            executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL, launchLog: URL
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.launchLog = launchLog
        }
    }

    public protocol NodeProcessHandle: Sendable {
        var processIdentifier: Int32 { get }
        func waitForExit() async -> Int32
        func waitForExit(timeout seconds: Double) async -> Bool
        func terminate()
        func kill()
    }

    public protocol NodeProcessLauncher: Sendable {
        func launch(_ spec: NodeLaunchSpec) throws -> NodeProcessHandle
    }

    public protocol NodeHealthProbe: Sendable {
        func isHealthy(port: Int) async -> Bool
    }

    public enum NodeSupervisorState: Equatable, Sendable {
        case stopped
        case starting(attempt: Int)
        case running(pid: Int32, port: Int)
        case backingOff(attempt: Int, seconds: Double, lastExit: Int32?)
        case stopping
        case failed(String)
    }

    public struct NodeSupervisorPolicy: Equatable, Sendable {
        public var baseDelay: Double = 1
        public var maximumDelay: Double = 60
        public var maximumConsecutiveFailures = 8
        public var startupChecks = 120
        public var checkInterval: Double = 0.5
        public var monitorInterval: Double = 5
        public var unhealthyChecksBeforeRestart = 3
        public var stableChecks = 12
        public var terminationGrace: Double = 10

        public init() {}

        func delay(afterFailure count: Int) -> Double {
            min(maximumDelay, baseDelay * pow(2, Double(max(count - 1, 0))))
        }
    }

    public actor NodeSupervisor {
        private enum RunEnd: Equatable {
            case exited(Int32)
            case unhealthy
        }

        private let launcher: NodeProcessLauncher
        private let probe: NodeHealthProbe
        private let sleep: @Sendable (Double) async throws -> Void
        private let policy: NodeSupervisorPolicy
        private let spec: NodeLaunchSpec
        private let port: Int
        private let onState: @Sendable (NodeSupervisorState) -> Void

        public private(set) var state: NodeSupervisorState = .stopped {
            didSet { if state != oldValue { onState(state) } }
        }
        private var loop: Task<Void, Never>?
        private var current: NodeProcessHandle?
        private var wanted = false
        private var consecutiveFailures = 0
        private let pidBox = ProcessIdentifierBox()

        public init(
            spec: NodeLaunchSpec, port: Int, launcher: NodeProcessLauncher, probe: NodeHealthProbe,
            policy: NodeSupervisorPolicy = NodeSupervisorPolicy(),
            sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            },
            onState: @escaping @Sendable (NodeSupervisorState) -> Void = { _ in }
        ) {
            self.spec = spec
            self.port = port
            self.launcher = launcher
            self.probe = probe
            self.policy = policy
            self.sleep = sleep
            self.onState = onState
        }

        public func start(adopting existing: NodeProcessHandle? = nil) {
            guard !wanted else { return }
            wanted = true
            consecutiveFailures = 0
            loop = Task { await self.supervise(adopting: existing) }
        }

        public func stop() async {
            guard wanted || loop != nil else { return }
            wanted = false
            state = .stopping
            let handle = current
            loop?.cancel()
            if let handle { await terminateAndWait(handle) }
            await loop?.value
            loop = nil
            current = nil
            pidBox.set(nil)
            state = .stopped
        }

        public nonisolated func stopSynchronously(timeout: Double = 5) {
            guard let pid = pidBox.get() else { return }
            killpg(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, kill(pid, 0) == 0 { usleep(50_000) }
            if kill(pid, 0) == 0 { killpg(pid, SIGKILL) }
        }

        private func supervise(adopting existing: NodeProcessHandle?) async {
            var adopted = existing
            while wanted && !Task.isCancelled {
                state = .starting(attempt: consecutiveFailures + 1)
                let end: RunEnd
                do {
                    let handle = try adopted ?? launcher.launch(spec)
                    adopted = nil
                    end = await run(handle)
                } catch {
                    end = .exited(-1)
                }
                guard wanted && !Task.isCancelled else { return }
                consecutiveFailures += 1
                let lastExit: Int32? = { if case .exited(let code) = end { return code } else { return nil } }()
                if consecutiveFailures >= policy.maximumConsecutiveFailures {
                    state = .failed("The node stopped \(consecutiveFailures) times in a row.")
                    wanted = false
                    return
                }
                let seconds = policy.delay(afterFailure: consecutiveFailures)
                state = .backingOff(attempt: consecutiveFailures, seconds: seconds, lastExit: lastExit)
                do { try await sleep(seconds) } catch { return }
            }
        }

        private func run(_ handle: NodeProcessHandle) async -> RunEnd {
            current = handle
            pidBox.set(handle.processIdentifier)
            let end = await withTaskGroup(of: RunEnd.self) { group -> RunEnd in
                group.addTask { .exited(await handle.waitForExit()) }
                group.addTask { await self.monitor(handle) }
                let first = await group.next() ?? .unhealthy
                group.cancelAll()
                if first == .unhealthy { await self.terminateAndWait(handle) }
                return first
            }
            current = nil
            pidBox.set(nil)
            return end
        }

        private func monitor(_ handle: NodeProcessHandle) async -> RunEnd {
            var ready = false
            var misses = 0
            var healthyChecks = 0
            var startupChecksUsed = 0
            while !Task.isCancelled {
                let healthy = await probe.isHealthy(port: port)
                if Task.isCancelled { break }
                if healthy {
                    misses = 0
                    healthyChecks += 1
                    if !ready {
                        ready = true
                        state = .running(pid: handle.processIdentifier, port: port)
                    }
                    if healthyChecks >= policy.stableChecks { consecutiveFailures = 0 }
                } else if ready {
                    misses += 1
                    healthyChecks = 0
                    if misses >= policy.unhealthyChecksBeforeRestart { return .unhealthy }
                } else {
                    startupChecksUsed += 1
                    if startupChecksUsed >= policy.startupChecks { return .unhealthy }
                }
                do { try await sleep(ready ? policy.monitorInterval : policy.checkInterval) } catch { break }
            }
            return .exited(0)
        }

        private func terminateAndWait(_ handle: NodeProcessHandle) async {
            handle.terminate()
            if await handle.waitForExit(timeout: policy.terminationGrace) { return }
            handle.kill()
            _ = await handle.waitForExit()
        }
    }

    final class ProcessIdentifierBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?

        func set(_ pid: Int32?) {
            lock.lock()
            value = pid
            lock.unlock()
        }

        func get() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    public struct PosixNodeProcessLauncher: NodeProcessLauncher {
        public init() {}

        public func launch(_ spec: NodeLaunchSpec) throws -> NodeProcessHandle {
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
            posix_spawnattr_setpgroup(&attributes, 0)
            var defaults = sigset_t()
            sigfillset(&defaults)
            posix_spawnattr_setsigdefault(&attributes, &defaults)
            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            posix_spawnattr_setsigmask(&attributes, &unblocked)

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(
                &actions, 1, spec.launchLog.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
            posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory.path)

            let arguments = [spec.executable.path] + spec.arguments
            let environment = spec.environment.map { "\($0.key)=\($0.value)" }
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var pid: pid_t = 0
            let status = posix_spawn(&pid, spec.executable.path, &actions, &attributes, argv, envp)
            guard status == 0 else { throw NodeHostError.launchFailed(String(cString: strerror(status))) }
            return PosixNodeProcess(pid: pid)
        }
    }

    final class PosixNodeProcess: NodeProcessHandle, @unchecked Sendable {
        let processIdentifier: Int32
        private let exit: ExitBroadcast

        init(pid: Int32) {
            processIdentifier = pid
            exit = ExitBroadcast()
            DispatchQueue.global(qos: .utility).async { [exit] in
                var status: Int32 = 0
                var result = waitpid(pid, &status, 0)
                while result == -1 && errno == EINTR { result = waitpid(pid, &status, 0) }
                let code: Int32 = result == pid ? (status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : -1
                exit.complete(code)
            }
        }

        func waitForExit() async -> Int32 { await exit.wait() }
        func waitForExit(timeout seconds: Double) async -> Bool { await exit.wait(timeout: seconds) }
        func terminate() { killpg(processIdentifier, SIGTERM) }
        func kill() { killpg(processIdentifier, SIGKILL) }
    }

    public struct AdoptedNodeProcess: NodeProcessHandle {
        public let processIdentifier: Int32
        private let sleep: @Sendable (Double) async throws -> Void

        public init(
            pid: Int32,
            sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        ) {
            processIdentifier = pid
            self.sleep = sleep
        }

        public func waitForExit() async -> Int32 {
            while Darwin.kill(processIdentifier, 0) == 0 {
                do { try await sleep(1) } catch { return 0 }
            }
            return 0
        }

        public func waitForExit(timeout seconds: Double) async -> Bool {
            var waited = 0.0
            while Darwin.kill(processIdentifier, 0) == 0 {
                if waited >= seconds { return false }
                do { try await sleep(0.1) } catch { return false }
                waited += 0.1
            }
            return true
        }

        public func terminate() { killpg(processIdentifier, SIGTERM) }
        public func kill() { killpg(processIdentifier, SIGKILL) }
    }

    final class ExitBroadcast: @unchecked Sendable {
        private let lock = NSLock()
        private var code: Int32?
        private var waiters: [(Int32) -> Void] = []

        func complete(_ value: Int32) {
            lock.lock()
            code = value
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0(value) }
        }

        func wait() async -> Int32 {
            await withCheckedContinuation { continuation in
                register { continuation.resume(returning: $0) }
            }
        }

        func wait(timeout seconds: Double) async -> Bool {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = OnceResume(continuation)
                register { _ in once.resume(true) }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.resume(false) }
            }
        }

        private func register(_ waiter: @escaping (Int32) -> Void) {
            lock.lock()
            if let code {
                lock.unlock()
                waiter(code)
            } else {
                waiters.append(waiter)
                lock.unlock()
            }
        }
    }

    final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    public struct LoopbackNodeHealthProbe: NodeHealthProbe {
        private static let session = URLSession(configuration: .ephemeral)

        public init() {}

        public func isHealthy(port: Int) async -> Bool {
            guard let url = URL(string: "http://127.0.0.1:\(port)/healthz") else { return false }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
            request.httpMethod = "GET"
            guard let (data, response) = try? await Self.session.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return body["status"] as? String == "ok"
        }
    }
#endif
