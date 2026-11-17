// Runs one confined tool on macOS: it selects the backend, writes the Seatbelt profile to a private file, starts sandbox-exec through AstralExecSpawn and enforces the time, memory and process limits until the tool ends.
// The Mac governed-command path calls run(_:argv:env:stdin:) with a policy from ExecPolicy.load, and ExecBackends and ExecSeatbeltProfile supply the selection and the profile text.

import Foundation

#if os(macOS)
    import AstralExecSpawn
#endif

public struct ExecOutcome: Sendable, Equatable {
    public let code: String?
    public let exitCode: Int32?
    public let signal: Int32?
    public let stdout: Data
    public let stderr: Data
    public let refusal: ExecRefusal?
    public let truncated: Bool

    public var message: String? {
        if let refusal { return refusal.message }
        return code.flatMap { ExecBackends.messages[$0] }
    }

    init(
        code: String?, exitCode: Int32? = nil, signal: Int32? = nil, stdout: Data = Data(), stderr: Data = Data(),
        refusal: ExecRefusal? = nil, truncated: Bool = false
    ) {
        self.code = code
        self.exitCode = exitCode
        self.signal = signal
        self.stdout = stdout
        self.stderr = stderr
        self.refusal = refusal
        self.truncated = truncated
    }

    static let launchFailed = ExecOutcome(code: "exec.launch_failed")
}

public struct ExecLauncher: Sendable {
    public typealias ProxyPort = @Sendable () -> UInt16?

    public static let markerName = "ASTRAL_EXEC_MARKER"
    static let outputLimit = 8 * 1024 * 1024
    static let profileFolder = "exec-profiles"
    static let processSlack = 32
    static let pollMilliseconds: Int32 = 10
    static let drainSeconds = 2.0
    static let reapSeconds = 5.0
    static let sandboxExecFailures: Set<Int32> = [64, 65, 71]

    let proxyPort: ProxyPort
    let facts: (@Sendable () -> ExecFacts)?
    var userProcesses: @Sendable () throws -> Int = ExecLauncher.countUserProcesses

    static let countUserProcesses: @Sendable () throws -> Int = {
        #if os(macOS)
            return try ExecWatch.userProcessCount()
        #else
            return 0
        #endif
    }

    public init(proxyPort: @escaping ProxyPort = { nil }) {
        self.proxyPort = proxyPort
        self.facts = nil
    }

    init(
        proxyPort: @escaping ProxyPort = { nil }, facts: (@Sendable () -> ExecFacts)?,
        userProcesses: (@Sendable () throws -> Int)? = nil
    ) {
        self.proxyPort = proxyPort
        self.facts = facts
        if let userProcesses { self.userProcesses = userProcesses }
    }

    public func run(_ loaded: ExecLoadedPolicy, argv: [String], env: [String: String], stdin: Data? = nil) async -> ExecOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(loaded, argv: argv, env: env, stdin: stdin))
            }
        }
    }

    func runBlocking(_ loaded: ExecLoadedPolicy, argv: [String], env: [String: String], stdin: Data? = nil) -> ExecOutcome {
        #if os(macOS)
            return ExecMacRun(launcher: self, loaded: loaded, argv: argv, env: env, stdin: stdin).execute()
        #else
            return ExecOutcome(
                code: "exec.backend_unavailable",
                refusal: ExecBackends.refusal(
                    code: "exec.backend_unavailable", reason: .platformUnsupported, platform: loaded.platform))
        #endif
    }
}

#if os(macOS)
    private struct ExecMacRun {
        let launcher: ExecLauncher
        let loaded: ExecLoadedPolicy
        let argv: [String]
        let env: [String: String]
        let stdin: Data?

        func execute() -> ExecOutcome {
            let policy = loaded.policy
            let facts = launcher.facts?() ?? ExecBackends.probe()
            let selection: ExecSelection
            do {
                selection = try ExecBackends.select(policy: policy, facts: facts, dataDirectory: loaded.dataDirectory)
            } catch {
                return .launchFailed
            }
            switch selection {
            case .refused(let refusal): return ExecOutcome(code: refusal.code, refusal: refusal)
            case .backend(.linux): return .launchFailed
            case .backend(.seatbelt): break
            }
            let marker = Self.newMarker()
            guard let childEnvironment = childEnvironment(marker: marker), checkedArgv() else { return .launchFailed }
            let port: UInt16? = policy.hosts.isEmpty ? nil : launcher.proxyPort()
            if !policy.hosts.isEmpty, port == nil { return .launchFailed }
            let profile: String
            do {
                profile = try ExecSeatbeltProfile.render(policy, context: ExecSeatbeltContext(home: loaded.home, proxyPort: port))
            } catch {
                return .launchFailed
            }
            guard let profilePath = Self.writeProfile(profile, dataDirectory: loaded.dataDirectory) else { return .launchFailed }
            defer { unlink(profilePath) }
            let environment =
                childEnvironment.merging(Self.proxyEnvironment(port)) { _, proxied in proxied }
            return start(profilePath: profilePath, environment: environment, marker: marker)
        }

        static func newMarker() -> String {
            var bytes = [UInt8](repeating: 0, count: 16)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        static func proxyEnvironment(_ port: UInt16?) -> [String: String] {
            guard let port else { return [:] }
            let url = "http://127.0.0.1:\(port)"
            var values = ["NO_PROXY": "", "no_proxy": ""]
            for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
                values[name] = url
                values[name.lowercased()] = url
            }
            return values
        }

        func checkedArgv() -> Bool {
            guard let first = argv.first, !first.hasPrefix("-") else { return false }
            return !argv.contains { $0.utf8.contains(0) }
        }

        func childEnvironment(marker: String) -> [String: String]? {
            for (key, value) in env {
                if key.isEmpty || key.utf8.contains(0x3D) || key.utf8.contains(0) || value.utf8.contains(0) { return nil }
                if key.hasPrefix("DYLD_") || key == ExecLauncher.markerName { return nil }
            }
            var result = env
            result[ExecLauncher.markerName] = marker
            return result
        }

        static func writeProfile(_ text: String, dataDirectory: String) -> String? {
            let folder = dataDirectory + "/" + ExecLauncher.profileFolder
            if mkdir(folder, 0o700) != 0, errno != EEXIST { return nil }
            var info = stat()
            guard lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
                info.st_mode & 0o077 == 0
            else { return nil }
            var template = Array((folder + "/profile-XXXXXX.sb").utf8CString)
            let descriptor = mkstemps(&template, 3)
            guard descriptor >= 0 else { return nil }
            let path = String(cString: template)
            let bytes = Array(text.utf8)
            var written = 0
            while written < bytes.count {
                let count = bytes[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    close(descriptor)
                    unlink(path)
                    return nil
                }
                written += count
            }
            close(descriptor)
            return path
        }

        func start(profilePath: String, environment: [String: String], marker: String) -> ExecOutcome {
            let policy = loaded.policy
            var processCount = 0
            if policy.limits.processes > 1 {
                guard let counted = try? launcher.userProcesses() else { return .launchFailed }
                processCount = counted
            }
            var outPipe: [Int32] = [-1, -1]
            var errPipe: [Int32] = [-1, -1]
            var inPipe: [Int32] = [-1, -1]
            var childInput: Int32 = open("/dev/null", O_RDONLY | O_CLOEXEC)
            let needsInput = stdin.map { !$0.isEmpty } ?? false
            guard childInput >= 0, Self.makePipe(&outPipe), Self.makePipe(&errPipe), !needsInput || Self.makePipe(&inPipe) else {
                Self.closeAll(outPipe + errPipe + inPipe + [childInput])
                return .launchFailed
            }
            if needsInput { childInput = inPipe[0] }
            let wall = policy.wallMs
            var limits = astral_exec_limits(
                file_bytes: UInt64(policy.limits.fileBytes), open_files: UInt64(policy.limits.openFiles), core_bytes: 0,
                cpu_seconds: UInt64((wall + 999) / 1000 + 1), apply_process_limit: 0, process_limit: 0)
            if policy.limits.processes > 1 {
                limits.apply_process_limit = 1
                limits.process_limit = UInt64(processCount + policy.limits.processes + ExecLauncher.processSlack)
            }
            let command = [ExecBackends.sandboxExecPath, "-f", profilePath, "--"] + argv
            let entries = environment.map { "\($0.key)=\($0.value)" }
            var pid: pid_t = 0
            var step: Int32 = 0
            let status = Self.withCStrings(command) { argvPointers in
                Self.withCStrings(entries) { envPointers in
                    astral_exec_spawn(
                        ExecBackends.sandboxExecPath, argvPointers, envPointers, policy.workspace, childInput, outPipe[1],
                        errPipe[1], &limits, &pid, &step)
                }
            }
            Self.closeAll([childInput, outPipe[1], errPipe[1]])
            if status != 0 {
                Self.closeAll([outPipe[0], errPipe[0], inPipe[1]])
                return .launchFailed
            }
            return ExecSupervisor(
                root: pid, readers: (outPipe[0], errPipe[0]), writer: inPipe[1], stdin: stdin ?? Data(), policy: policy,
                marker: marker
            ).supervise()
        }

        static func makePipe(_ ends: inout [Int32]) -> Bool {
            guard pipe(&ends) == 0 else { return false }
            for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
            return true
        }

        static func closeAll(_ descriptors: [Int32]) {
            for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
        }

        static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
            var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
            pointers.append(nil)
            defer { for pointer in pointers { free(pointer) } }
            return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
        }
    }

    private final class ExecSupervisor {
        let root: pid_t
        let policy: ExecPolicy
        var reading: [Int32: Int]
        var writer: Int32
        var pending: Data
        var captured: [Data] = [Data(), Data()]
        var truncated = false
        let watch: ExecWatch

        init(
            root: pid_t, readers: (Int32, Int32), writer: Int32, stdin: Data, policy: ExecPolicy, marker: String
        ) {
            self.root = root
            self.policy = policy
            self.reading = [readers.0: 0, readers.1: 1]
            self.writer = writer
            self.pending = stdin
            let entry = policy.limits.processes > 1 ? "\(ExecLauncher.markerName)=\(marker)" : nil
            self.watch = ExecWatch(root: root, marker: entry)
            for descriptor in [readers.0, readers.1] + (writer >= 0 ? [writer] : []) {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            }
            if writer >= 0 && stdin.isEmpty { closeWriter() }
        }

        func closeWriter() {
            if writer >= 0 { close(writer) }
            writer = -1
        }

        func supervise() -> ExecOutcome {
            let deadline = Self.now() + Double(policy.wallMs) / 1000
            var code: String?
            var failed = false
            var nextSample = 0.0
            monitor: while true {
                pump(milliseconds: ExecLauncher.pollMilliseconds)
                if exited() { break }
                let now = Self.now()
                if now >= deadline {
                    code = "exec.time_limit"
                    break
                }
                if now < nextSample { continue }
                nextSample = now + Double(ExecLauncher.pollMilliseconds) / 1000
                if !watch.started {
                    failed = true
                    break monitor
                }
                do {
                    let sample = try watch.sample()
                    if sample.memory > UInt64(policy.limits.memoryBytes) {
                        code = "exec.memory_limit"
                        break monitor
                    }
                    if sample.processes > policy.limits.processes {
                        code = "exec.process_limit"
                        break monitor
                    }
                } catch {
                    failed = true
                    break monitor
                }
            }
            let ended = end()
            drain()
            closeAll()
            let result = reap()
            if failed || !ended || result == nil { code = "exec.launch_failed" }
            return outcome(code: code, result: result)
        }

        static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

        func exited() -> Bool {
            var info = siginfo_t()
            let status = waitid(P_PID, id_t(root), &info, WEXITED | WNOHANG | WNOWAIT)
            return status == 0 && info.si_pid == root
        }

        func end() -> Bool {
            guard let survivors = try? watch.end() else {
                killpg(root, SIGKILL)
                return false
            }
            return survivors.isEmpty
        }

        func reap() -> Int32? {
            let deadline = Self.now() + ExecLauncher.reapSeconds
            var status: Int32 = 0
            while Self.now() < deadline {
                let result = waitpid(root, &status, WNOHANG)
                if result == root { return status }
                if result < 0, errno != EINTR { return nil }
                usleep(1000)
            }
            return nil
        }

        func pump(milliseconds: Int32) {
            var descriptors = reading.keys.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            if writer >= 0 { descriptors.append(pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)) }
            if descriptors.isEmpty {
                usleep(useconds_t(milliseconds) * 1000)
                return
            }
            guard poll(&descriptors, nfds_t(descriptors.count), milliseconds) > 0 else { return }
            for entry in descriptors where entry.revents != 0 {
                if entry.fd == writer { write(entry.fd) } else { read(entry.fd) }
            }
        }

        func read(_ descriptor: Int32) {
            guard let slot = reading[descriptor] else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = Foundation.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            if count <= 0 {
                close(descriptor)
                reading[descriptor] = nil
                return
            }
            let room = max(ExecLauncher.outputLimit - captured[slot].count, 0)
            if count > room { truncated = true }
            captured[slot].append(contentsOf: buffer[0..<min(count, room)])
        }

        func write(_ descriptor: Int32) {
            let count = pending.withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, min($0.count, 65536)) }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            if count <= 0 {
                pending = Data()
            } else {
                pending = pending.dropFirst(count)
            }
            if pending.isEmpty { closeWriter() }
        }

        func drain() {
            let deadline = Self.now() + ExecLauncher.drainSeconds
            while !reading.isEmpty, Self.now() < deadline { pump(milliseconds: ExecLauncher.pollMilliseconds) }
        }

        func closeAll() {
            closeWriter()
            for descriptor in reading.keys { close(descriptor) }
            reading = [:]
        }

        func outcome(code: String?, result: Int32?) -> ExecOutcome {
            let out = captured[0]
            let err = captured[1]
            guard let result else { return ExecOutcome(code: code, stdout: out, stderr: err, truncated: truncated) }
            let signalled = (result & 0x7F) != 0 && (result & 0x7F) != 0x7F
            let exitCode: Int32? = signalled ? nil : (result >> 8) & 0xFF
            let received: Int32? = signalled ? result & 0x7F : nil
            var final = code
            if let exitCode, ExecLauncher.sandboxExecFailures.contains(exitCode), err.starts(with: Array("sandbox-exec:".utf8)) {
                return ExecOutcome(code: "exec.launch_failed", stdout: out, stderr: err, truncated: truncated)
            }
            if final == nil, received == SIGXFSZ { final = "exec.file_limit" }
            if final == nil, received == SIGXCPU { final = "exec.time_limit" }
            return ExecOutcome(
                code: final, exitCode: exitCode, signal: received, stdout: out, stderr: err, truncated: truncated)
        }
    }
#endif
