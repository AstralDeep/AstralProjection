// Prepares per-job governed-command launches: it loads the owner's sandbox configuration, starts the job's
// loopback egress proxy, generates and compile-probes the Seatbelt profile, and refuses the job before it
// starts when the launcher, profile or proxy cannot be readied. MacComputerCommands wraps every spawn with it.

#if os(macOS)
    import AstralCore
    import Darwin
    import Foundation
    import Security

    nonisolated protocol MacComputerSandboxValidating: Sendable {
        func validate(executable: String, profilePath: String) async throws
    }

    nonisolated protocol MacComputerEgressProxying: AnyObject, Sendable {
        var port: UInt16 { get }
        func start() throws
        func stop()
    }

    nonisolated enum MacComputerKeychainSecrets {
        static func secret(_ service: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
            else { return nil }
            let value = String(decoding: data, as: UTF8.self)
            return value.isEmpty ? nil : value
        }
    }

    nonisolated struct MacComputerEgressProxyRequest: Sendable {
        let jobId: String
        let policy: ComputerEgressPolicy
        let secrets: @Sendable (String) -> String?
        let sink: MacComputerEgressDecisionSink
    }

    nonisolated final class MacComputerEgressDecisionSink: @unchecked Sendable {
        private let lock = NSLock()
        private weak var backing: MacComputerJobSandbox?
        var target: MacComputerJobSandbox? {
            get { lock.withLock { backing } }
            set { lock.withLock { backing = newValue } }
        }
        func send(_ decision: ComputerEgressDecision) {
            target?.recordDecision(decision)
        }
    }

    nonisolated struct MacComputerSandboxLaunch: Sendable {
        let plan: MacComputerCommandPlan
        let session: MacComputerJobSandbox
    }

    nonisolated protocol MacComputerCommandSandboxing: Sendable {
        func prepare(
            jobId: String, plan: MacComputerCommandPlan, environment: [String: String], roots: [String],
            exclusions: ComputerWorkspaceExclusions
        ) async throws -> MacComputerSandboxLaunch
    }

    nonisolated struct MacComputerSandboxRecord: Equatable, Sendable {
        let source: String
        let operation: String
        let target: String
        let detail: String
        let blocked: Bool

        var key: String { "\(source)|\(operation)|\(target)|\(detail)" }

        var json: JSONValue {
            .object([
                "source": .string(source), "operation": .string(operation), "target": .string(target),
                "detail": .string(detail), "blocked": .bool(blocked),
            ])
        }
    }

    nonisolated final class MacComputerJobSandbox: @unchecked Sendable {
        static let decisionEventLimit = 64
        static let violationLimit = 20
        static let recordCeiling = 80

        let jobId: String
        let mode: ComputerSandboxMode
        let digest: String
        let domains: [String]
        let placeholders: [String]
        private let proxy: (any MacComputerEgressProxying)?
        private let directories: [String]
        private let sink: @Sendable (String, [String: JSONValue]) -> Void
        private let lock = NSLock()
        private var proxyPort: UInt16?
        private var records: [MacComputerSandboxRecord] = []
        private var emittedKeys: Set<String> = []
        private var decisions = 0
        private var closed = false

        init(
            jobId: String, mode: ComputerSandboxMode, digest: String, domains: [String], placeholders: [String],
            proxyPort: UInt16?, proxy: (any MacComputerEgressProxying)?, directories: [String],
            sink: @escaping @Sendable (String, [String: JSONValue]) -> Void
        ) {
            self.jobId = jobId
            self.mode = mode
            self.digest = digest
            self.domains = domains
            self.placeholders = placeholders
            self.proxyPort = proxyPort
            self.proxy = proxy
            self.directories = directories
            self.sink = sink
        }

        func recordViolation(_ violation: ComputerSandboxViolation) {
            let record = MacComputerSandboxRecord(
                source: "seatbelt", operation: violation.operation, target: violation.target,
                detail: "pid \(violation.pid) \(violation.process)", blocked: mode == .enforce)
            var payload: [String: JSONValue]?
            lock.withLock {
                guard emittedKeys.insert("seatbelt|\(violation.key)").inserted else { return }
                appendLocked(record)
                payload = violationJSON(record)
            }
            if let payload { sink("command.sandbox_violation", payload) }
        }

        func recordDecision(_ decision: ComputerEgressDecision) {
            var payload: [String: JSONValue]?
            var violation: MacComputerSandboxRecord?
            lock.withLock {
                if case .refuse(let reason) = decision.verdict {
                    let record = MacComputerSandboxRecord(
                        source: "egress", operation: "network", target: decision.target.label,
                        detail: reason.rawValue, blocked: !decision.forwarded)
                    if emittedKeys.insert("egress|\(record.key)").inserted { appendLocked(record) }
                    violation = record
                }
                guard decisions < Self.decisionEventLimit else { return }
                decisions += 1
                payload = decision.json.merging(["job_id": .string(jobId), "mode": .string(mode.rawValue)]) {
                    _, new in new
                }
            }
            if let payload { sink("egress.decision", payload) }
            if let violation, !violation.blocked {
                sink("command.sandbox_violation", violationJSON(violation))
            }
        }

        func json() -> [String: JSONValue] {
            lock.withLock {
                [
                    "mode": .string(mode.rawValue), "profile_digest": .string(digest),
                    "allowed_domains": .array(domains.sorted().map(.string)),
                    "proxy_port": proxyPort.map { .number(Double($0)) } ?? .null,
                    "violations": .array(records.prefix(Self.violationLimit).map(\.json)),
                ]
            }
        }

        func close() {
            let proxy = lock.withLock { () -> (any MacComputerEgressProxying)? in
                guard !closed else { return nil }
                closed = true
                return self.proxy
            }
            proxy?.stop()
            for directory in directories {
                try? FileManager.default.removeItem(atPath: directory)
            }
        }

        private func appendLocked(_ record: MacComputerSandboxRecord) {
            records.append(record)
            if records.count > Self.recordCeiling {
                records.removeFirst(records.count - Self.recordCeiling)
            }
        }

        private func violationJSON(_ record: MacComputerSandboxRecord) -> [String: JSONValue] {
            [
                "job_id": .string(jobId), "source": .string(record.source), "operation": .string(record.operation),
                "target": .string(record.target), "detail": .string(record.detail),
                "blocked": .bool(record.blocked),
            ]
        }
    }

    nonisolated struct MacComputerSandboxConfigurationReader: @unchecked Sendable {
        let defaults: UserDefaults
        func read() -> ComputerSandboxConfiguration {
            MacComputerSandboxController.configuration(from: defaults)
        }
    }

    nonisolated final class MacComputerSandboxController: MacComputerCommandSandboxing, @unchecked Sendable {
        nonisolated static let configurationKey = "computer.sandbox.configuration"
        nonisolated static let launcherPath = ComputerSandboxProfile.launcherPath

        private let configurationProvider: @Sendable () -> ComputerSandboxConfiguration
        private let secrets: @Sendable (String) -> String?
        private let home: @Sendable () -> String
        private let bundlePath: @Sendable () -> String?
        private let validator: any MacComputerSandboxValidating
        private let proxyFactory: @Sendable (MacComputerEgressProxyRequest) throws -> any MacComputerEgressProxying
        private let sink: @Sendable (String, [String: JSONValue]) -> Void

        init(
            configuration: @escaping @Sendable () -> ComputerSandboxConfiguration,
            secrets: @escaping @Sendable (String) -> String? = { MacComputerKeychainSecrets.secret($0) },
            home: @escaping @Sendable () -> String = { NSHomeDirectory() },
            bundlePath: @escaping @Sendable () -> String? = { Bundle.main.bundlePath },
            validator: any MacComputerSandboxValidating = MacComputerSandboxCompileProbe(),
            proxyFactory: @escaping @Sendable (MacComputerEgressProxyRequest) throws -> any MacComputerEgressProxying =
                { try MacComputerEgressProxy(request: $0) },
            sink: @escaping @Sendable (String, [String: JSONValue]) -> Void = { _, _ in }
        ) {
            configurationProvider = configuration
            self.secrets = secrets
            self.home = home
            self.bundlePath = bundlePath
            self.validator = validator
            self.proxyFactory = proxyFactory
            self.sink = sink
        }

        nonisolated static func configuration(from defaults: UserDefaults) -> ComputerSandboxConfiguration {
            guard let text = defaults.string(forKey: configurationKey), let data = text.data(using: .utf8) else {
                return .fallback
            }
            return ComputerSandboxConfiguration.decoded(data)
        }

        nonisolated static func canonical(_ path: String) -> String {
            guard let pointer = realpath(path, nil) else { return path }
            defer { free(pointer) }
            return String(cString: pointer)
        }

        func prepare(
            jobId: String, plan: MacComputerCommandPlan, environment: [String: String], roots: [String],
            exclusions: ComputerWorkspaceExclusions
        ) async throws -> MacComputerSandboxLaunch {
            let configuration = configurationProvider()
            let policy = ComputerEgressPolicy(configuration: configuration)
            if let variable = ComputerSandboxPolicy.leakedEnvironmentVariable(
                environment, placeholders: configuration.placeholders)
            {
                throw ComputerHostError(
                    "sandbox_refused",
                    "The command environment variable \(variable) carries a placeholder secret. Placeholder "
                        + "secrets are swapped by the egress proxy, never handed to the command environment.")
            }
            let childDirectory =
                FileManager.default.temporaryDirectory.appendingPathComponent("astral-command-" + jobId).path
            let profileDirectory =
                FileManager.default.temporaryDirectory.appendingPathComponent("astral-profile-" + jobId).path
            do {
                try FileManager.default.createDirectory(atPath: childDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(atPath: profileDirectory, withIntermediateDirectories: true)
            } catch {
                throw ComputerHostError(
                    "sandbox_refused", "The command sandbox could not create its per-job directories.")
            }
            let directories = [childDirectory, profileDirectory]
            func cleanup() {
                for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
            }
            let writeRoots = (roots.map(Self.canonical) + [Self.canonical(childDirectory)]).filter { !$0.isEmpty }
            let holder = MacComputerEgressDecisionSink()
            var proxy: (any MacComputerEgressProxying)?
            do {
                let created = try proxyFactory(
                    MacComputerEgressProxyRequest(jobId: jobId, policy: policy, secrets: secrets, sink: holder))
                do {
                    try created.start()
                } catch {
                    created.stop()
                    throw error
                }
                proxy = created
            } catch {
                guard configuration.mode == .shadow else {
                    let reason = (error as? ComputerHostError)?.message ?? String(describing: error)
                    cleanup()
                    throw ComputerHostError(
                        "sandbox_refused", "The command egress proxy could not start: \(reason)")
                }
                sink(
                    "command.sandbox_violation",
                    [
                        "job_id": .string(jobId), "source": .string("proxy"), "operation": .string("proxy"),
                        "target": .string(jobId), "detail": .string("proxy_unavailable"), "blocked": .bool(false),
                    ])
                proxy = nil
            }
            let profileInput = ComputerSandboxProfile.Input(
                mode: configuration.mode, writeRoots: writeRoots, exclusions: exclusions.patterns, home: home(),
                bundlePath: bundlePath(), supportIdentifier: "com.personalailabs.astraldeep",
                proxyPort: proxy?.port)
            let profile = ComputerSandboxProfile.generate(profileInput)
            let digest = ComputerSandboxProfile.digest(profile)
            let profilePath = profileDirectory + "/profile.sb"
            guard
                FileManager.default.createFile(
                    atPath: profilePath, contents: Data(profile.utf8),
                    attributes: [.posixPermissions: 0o600])
            else {
                proxy?.stop()
                cleanup()
                throw ComputerHostError("sandbox_refused", "The sandbox profile could not be written.")
            }
            do {
                try await validator.validate(executable: Self.launcherPath, profilePath: profilePath)
            } catch let error as ComputerHostError {
                proxy?.stop()
                cleanup()
                throw error
            } catch {
                proxy?.stop()
                cleanup()
                throw ComputerHostError("sandbox_refused", String(describing: error))
            }
            var launchEnvironment = environment
            if let port = proxy?.port {
                let address = "http://127.0.0.1:\(port)"
                for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                    launchEnvironment[name] = address
                }
                for name in ["NO_PROXY", "no_proxy"] {
                    launchEnvironment[name] = "127.0.0.1,localhost,::1"
                }
            }
            launchEnvironment["TMPDIR"] = childDirectory
            let session = MacComputerJobSandbox(
                jobId: jobId, mode: configuration.mode, digest: digest,
                domains: configuration.domains.map(\.value), placeholders: configuration.placeholders,
                proxyPort: proxy?.port, proxy: proxy, directories: directories, sink: sink)
            holder.target = session
            let wrapped = MacComputerCommandPlan(
                executable: Self.launcherPath,
                arguments: ["-f", profilePath] + plan.arguments,
                environment: launchEnvironment, directory: plan.directory, stdin: plan.stdin)
            return MacComputerSandboxLaunch(plan: wrapped, session: session)
        }
    }

    nonisolated struct MacComputerSandboxCompileProbe: MacComputerSandboxValidating {
        func validate(executable: String, profilePath: String) async throws {
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw ComputerHostError(
                    "sandbox_refused",
                    "The macOS sandbox launcher \(executable) is missing, so the command cannot run under its "
                        + "profile.")
            }
            guard FileManager.default.isExecutableFile(atPath: ComputerSandboxProfile.probeProgram) else {
                throw ComputerHostError(
                    "sandbox_refused", "The sandbox compile probe \(ComputerSandboxProfile.probeProgram) is "
                        + "missing, so the command cannot be checked before it starts.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-f", profilePath, ComputerSandboxProfile.probeProgram]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = Pipe()
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
            } catch {
                throw ComputerHostError(
                    "sandbox_refused", "The sandbox launcher could not start (errno \(errno)).")
            }
            let waiter = Task.detached(priority: .utility) { process.waitUntilExit() }
            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    _ = try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return false
                }
                group.addTask {
                    _ = await waiter.value
                    return true
                }
                let first = await group.next() ?? true
                group.cancelAll()
                return first
            }
            if !finished {
                process.terminate()
                _ = await waiter.value
                throw ComputerHostError(
                    "sandbox_refused", "The sandbox profile compile probe did not finish in five seconds.")
            }
            guard process.terminationStatus == 0 else {
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ComputerHostError(
                    "sandbox_refused",
                    "The sandbox profile could not be compiled: \(String(text.prefix(400))).")
            }
        }
    }
#endif
