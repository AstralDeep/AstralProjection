// Runs the packed node as a per-user launchd agent: it writes the agent plist, bootstraps and kickstarts it, and hands the supervisor the job's pid.
// NodeHostController picks it for the Mac app so the node can outlive a quit when Keep running is on, and teardown boots the agent out and deletes the plist.

#if os(macOS)
    import Darwin
    import Foundation

    public protocol LaunchctlRunner: Sendable {
        func run(_ arguments: [String]) -> (status: Int32, output: String)
    }

    public struct ProcessLaunchctlRunner: LaunchctlRunner {
        public init() {}

        public func run(_ arguments: [String]) -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }

    public enum LaunchdNodePlist {
        public static func render(label: String, spec: NodeLaunchSpec) -> String {
            let arguments = ([spec.executable.path] + spec.arguments).map { "        <string>\(escape($0))</string>" }
            let environment = spec.environment.sorted { $0.key < $1.key }.map {
                "        <key>\(escape($0.key))</key>\n        <string>\(escape($0.value))</string>"
            }
            let keepAlive =
                spec.keepRunning
                ? "    <key>KeepAlive</key>\n    <dict>\n        <key>SuccessfulExit</key>\n"
                    + "        <false/>\n    </dict>"
                : "    <key>KeepAlive</key>\n    <false/>"
            let runAtLoad = spec.keepRunning ? "<true/>" : "<false/>"
            return """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>\(escape(label))</string>
                    <key>ProgramArguments</key>
                    <array>
                \(arguments.joined(separator: "\n"))
                    </array>
                    <key>EnvironmentVariables</key>
                    <dict>
                \(environment.joined(separator: "\n"))
                    </dict>
                    <key>WorkingDirectory</key>
                    <string>\(escape(spec.workingDirectory.path))</string>
                    <key>StandardOutPath</key>
                    <string>\(escape(spec.launchLog.path))</string>
                    <key>StandardErrorPath</key>
                    <string>\(escape(spec.launchLog.path))</string>
                    <key>RunAtLoad</key>
                    \(runAtLoad)
                \(keepAlive)
                    <key>ThrottleInterval</key>
                    <integer>10</integer>
                    <key>ExitTimeOut</key>
                    <integer>10</integer>
                </dict>
                </plist>

                """
        }

        static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }

    public struct LaunchdNodeProcessLauncher: NodeProcessLauncher {
        public let label: String
        public let plist: URL
        private let runner: LaunchctlRunner
        private let userIdentifier: UInt32
        private let sleep: @Sendable (Double) -> Void

        public init(
            label: String, plist: URL, runner: LaunchctlRunner = ProcessLaunchctlRunner(),
            userIdentifier: UInt32 = getuid(),
            sleep: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
        ) {
            self.label = label
            self.plist = plist
            self.runner = runner
            self.userIdentifier = userIdentifier
            self.sleep = sleep
        }

        public var ownsProcesses: Bool { true }
        private var domain: String { "gui/\(userIdentifier)" }
        private var target: String { "\(domain)/\(label)" }

        public func launch(_ spec: NodeLaunchSpec) throws -> NodeProcessHandle {
            if let pid = loadedPid() { return handle(pid) }
            try write(spec)
            _ = runner.run(["bootout", target])
            let bootstrap = runner.run(["bootstrap", domain, plist.path])
            guard bootstrap.status == 0 else { throw NodeHostError.launchFailed(Self.short(bootstrap.output)) }
            let kick = runner.run(["kickstart", target])
            guard kick.status == 0 else { throw NodeHostError.launchFailed(Self.short(kick.output)) }
            for _ in 0..<50 {
                if let pid = loadedPid() { return handle(pid) }
                sleep(0.1)
            }
            throw NodeHostError.launchFailed("launchd did not start the node")
        }

        public func adoptable() -> NodeAdoption? {
            guard let pid = loadedPid(), let port = plistPort() else { return nil }
            return NodeAdoption(handle: handle(pid), port: port)
        }

        public func teardown() {
            _ = runner.run(["bootout", target])
            try? FileManager.default.removeItem(at: plist)
        }

        private func handle(_ pid: Int32) -> NodeProcessHandle {
            LaunchdNodeProcess(pid: pid, runner: runner, target: target)
        }

        private func loadedPid() -> Int32? {
            let result = runner.run(["print", target])
            guard result.status == 0 else { return nil }
            for line in result.output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("pid = "), let pid = Int32(trimmed.dropFirst(6)), pid > 0 { return pid }
            }
            return nil
        }

        private func write(_ spec: NodeLaunchSpec) throws {
            let directory = plist.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LaunchdNodePlist.render(label: label, spec: spec).write(to: plist, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
        }

        private func plistPort() -> Int? {
            guard let data = try? Data(contentsOf: plist),
                let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                let arguments = (object as? [String: Any])?["ProgramArguments"] as? [String],
                let index = arguments.firstIndex(of: "--port"), arguments.indices.contains(index + 1)
            else { return nil }
            return Int(arguments[index + 1])
        }

        private static func short(_ output: String) -> String {
            let line = output.split(separator: "\n").first.map(String.init) ?? "launchctl failed"
            return String(line.prefix(120))
        }
    }

    struct LaunchdNodeProcess: NodeProcessHandle {
        let processIdentifier: Int32
        private let runner: LaunchctlRunner
        private let target: String
        private let watcher: AdoptedNodeProcess

        init(pid: Int32, runner: LaunchctlRunner, target: String) {
            processIdentifier = pid
            self.runner = runner
            self.target = target
            watcher = AdoptedNodeProcess(pid: pid)
        }

        func waitForExit() async -> Int32 { await watcher.waitForExit() }
        func waitForExit(timeout seconds: Double) async -> Bool { await watcher.waitForExit(timeout: seconds) }
        func terminate() { _ = runner.run(["bootout", target]) }

        func kill() {
            _ = runner.run(["bootout", target])
            watcher.kill()
        }
    }
#endif
