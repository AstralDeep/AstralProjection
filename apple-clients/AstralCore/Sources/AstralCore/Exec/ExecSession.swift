// A confined tool that keeps running: it starts through the same Seatbelt profile and limits as ExecLauncher, and the owner reads its stdout lines and writes its stdin.
// MacStdioLauncher starts one per stdio connection, and stop() ends every process in its tree and removes its profile.

import Foundation

#if os(macOS)
    import AstralExecSpawn

    public final class ExecSession: @unchecked Sendable {
        static let lineLimit = 8 * 1024 * 1024
        static let sampleSeconds = 0.1

        private let root: pid_t
        private let stdinDescriptor: Int32
        private let stdoutDescriptor: Int32
        private let profilePath: String
        private let watch: ExecWatch
        private let limits: ExecPolicy.Limits
        private let lock = NSLock()
        private var stopped = false
        private var handler: (@Sendable (Data) -> Void)?
        private var endHandler: (@Sendable () -> Void)?

        init(
            root: pid_t, stdin: Int32, stdout: Int32, profilePath: String, watch: ExecWatch, limits: ExecPolicy.Limits
        ) {
            self.root = root
            stdinDescriptor = stdin
            stdoutDescriptor = stdout
            self.profilePath = profilePath
            self.watch = watch
            self.limits = limits
        }

        public var isRunning: Bool { lock.withLock { !stopped } }

        public func start(onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
            lock.withLock {
                handler = onLine
                endHandler = onEnd
            }
            _ = fcntl(stdinDescriptor, F_SETNOSIGPIPE, 1)
            Thread.detachNewThread { [self] in readLines() }
            Thread.detachNewThread { [self] in monitor() }
        }

        public func send(_ line: Data) -> Bool {
            guard isRunning else { return false }
            var bytes = line
            bytes.append(0x0A)
            return lock.withLock {
                var offset = 0
                while offset < bytes.count {
                    let count = bytes[offset...].withUnsafeBytes {
                        Foundation.write(stdinDescriptor, $0.baseAddress, $0.count)
                    }
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
        }

        public func stop() {
            let first: Bool = lock.withLock {
                if stopped { return false }
                stopped = true
                return true
            }
            guard first else { return }
            close(stdinDescriptor)
            if (try? watch.end())?.isEmpty != true { killpg(root, SIGKILL) }
            kill(root, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(root, &status, 0)
            close(stdoutDescriptor)
            unlink(profilePath)
            let done = lock.withLock { () -> (@Sendable () -> Void)? in
                let value = endHandler
                handler = nil
                endHandler = nil
                return value
            }
            done?()
        }

        private func readLines() {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Foundation.read(stdoutDescriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending = Data(pending[pending.index(after: newline)...])
                    if !line.isEmpty, let target = lock.withLock({ handler }) { target(Data(line)) }
                }
                if pending.count > Self.lineLimit { break }
            }
            stop()
        }

        private func monitor() {
            while isRunning {
                usleep(useconds_t(Self.sampleSeconds * 1_000_000))
                guard isRunning else { return }
                guard let sample = try? watch.sample(), sample.memory <= UInt64(limits.memoryBytes),
                    sample.processes <= limits.processes
                else {
                    stop()
                    return
                }
            }
        }
    }

    extension ExecMacRun {
        func openSession() -> ExecSession? {
            guard case .ready(let profilePath, let environment, let marker) = prepare() else { return nil }
            let policy = loaded.policy
            var outPipe: [Int32] = [-1, -1]
            var inPipe: [Int32] = [-1, -1]
            let errorSink: Int32 = open("/dev/null", O_WRONLY | O_CLOEXEC)
            guard errorSink >= 0, Self.makePipe(&outPipe), Self.makePipe(&inPipe) else {
                Self.closeAll(outPipe + inPipe + [errorSink])
                unlink(profilePath)
                return nil
            }
            var limits = astral_exec_limits(
                file_bytes: UInt64(policy.limits.fileBytes), open_files: UInt64(policy.limits.openFiles), core_bytes: 0,
                cpu_seconds: UInt64((policy.wallMs + 999) / 1000 + 1), apply_process_limit: 0, process_limit: 0)
            if policy.limits.processes > 1 {
                guard let counted = try? launcher.userProcesses() else {
                    Self.closeAll(outPipe + inPipe + [errorSink])
                    unlink(profilePath)
                    return nil
                }
                limits.apply_process_limit = 1
                limits.process_limit = UInt64(counted + policy.limits.processes + ExecLauncher.processSlack)
            }
            let command = [ExecBackends.sandboxExecPath, "-f", profilePath, "--"] + argv
            let entries = environment.map { "\($0.key)=\($0.value)" }
            var pid: pid_t = 0
            var step: Int32 = 0
            let status = Self.withCStrings(command) { argvPointers in
                Self.withCStrings(entries) { envPointers in
                    astral_exec_spawn(
                        ExecBackends.sandboxExecPath, argvPointers, envPointers, policy.workspace, inPipe[0],
                        outPipe[1], errorSink, &limits, &pid, &step)
                }
            }
            Self.closeAll([inPipe[0], outPipe[1], errorSink])
            guard status == 0 else {
                Self.closeAll([inPipe[1], outPipe[0]])
                unlink(profilePath)
                return nil
            }
            let entry = policy.limits.processes > 1 ? "\(ExecLauncher.markerName)=\(marker)" : nil
            return ExecSession(
                root: pid, stdin: inPipe[1], stdout: outPipe[0], profilePath: profilePath,
                watch: ExecWatch(root: pid, marker: entry), limits: policy.limits)
        }
    }
#endif
