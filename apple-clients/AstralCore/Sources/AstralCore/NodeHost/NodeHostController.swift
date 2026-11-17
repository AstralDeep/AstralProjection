// Drives the Settings control "Run a node on this Mac": it offers the pack with its size, downloads and installs it, supervises the node and starts the pairing into the owner's mesh with no sign-in.
// The app's Mac settings view binds to it, and the quit handler calls applicationWillTerminate so the node stops unless Keep running is on.

#if os(macOS)
    import Darwin
    import Foundation
    import Observation

    public enum NodeHostAvailability {
        public static func permits(marker: String?, sandboxed: Bool) -> Bool {
            marker == "direct-download" && !sandboxed
        }

        public static func current(
            bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment
        )
            -> Bool
        {
            permits(
                marker: bundle.object(forInfoDictionaryKey: "ASTRALDistribution") as? String,
                sandboxed: environment["APP_SANDBOX_CONTAINER_ID"] != nil)
        }
    }

    public struct NodeHostEnvironment {
        public var root: URL
        public var available: Bool
        public var meshLabel: String
        public var defaults: UserDefaults
        public var transport: NodePackTransport
        public var launcher: NodeProcessLauncher
        public var probe: NodeHealthProbe
        public var http: NodeHTTP
        public var policy: NodeSupervisorPolicy
        public var sleep: @Sendable (Double) async throws -> Void
        public var freePort: @Sendable () throws -> Int
        public var runInstaller: @Sendable (URL, [String]) throws -> (status: Int32, output: String)
        public var defaultPackURL: String
        public var pinnedDescriptorSha256: String?
        public var processPath: @Sendable (Int32) -> String?

        public init(
            root: URL, available: Bool, meshLabel: String,
            defaults: UserDefaults = .standard, transport: NodePackTransport = URLSessionNodePackTransport(),
            launcher: NodeProcessLauncher = PosixNodeProcessLauncher(),
            probe: NodeHealthProbe = LoopbackNodeHealthProbe(),
            http: NodeHTTP = URLSessionNodeHTTP(), policy: NodeSupervisorPolicy = NodeSupervisorPolicy(),
            sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            },
            freePort: @escaping @Sendable () throws -> Int = NodeHome.freeLoopbackPort,
            runInstaller: @escaping @Sendable (URL, [String]) throws -> (status: Int32, output: String) =
                NodeHome.runInstaller,
            defaultPackURL: String = "", pinnedDescriptorSha256: String? = nil,
            processPath: @escaping @Sendable (Int32) -> String? = NodeHostEnvironment.executablePath
        ) {
            self.root = root
            self.available = available
            self.meshLabel = meshLabel
            self.defaults = defaults
            self.transport = transport
            self.launcher = launcher
            self.probe = probe
            self.http = http
            self.policy = policy
            self.sleep = sleep
            self.freePort = freePort
            self.runInstaller = runInstaller
            self.defaultPackURL = defaultPackURL
            self.pinnedDescriptorSha256 = pinnedDescriptorSha256
            self.processPath = processPath
        }

        public static func executablePath(of pid: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            return String(cString: buffer)
        }
    }

    @MainActor
    @Observable
    public final class NodeHostController {
        public enum Phase: Equatable {
            case unavailable
            case notInstalled
            case offered(NodePackOffer)
            case downloading(fraction: Double)
            case verifying
            case installed(version: String)
            case starting
            case running(port: Int)
            case backingOff(String)
            case failed(String)
        }

        public static let packURLKey = "node.pack.url"
        public static let keepRunningKey = "node.keepRunning"
        public static let autoOfferedKey = "node.pack.autoOffered"

        public private(set) var phase: Phase
        public private(set) var descriptor: NodeDescriptor?
        public private(set) var message: String?
        public var packURLText: String { didSet { environment.defaults.set(packURLText, forKey: Self.packURLKey) } }
        public var keepRunning: Bool { didSet { environment.defaults.set(keepRunning, forKey: Self.keepRunningKey) } }

        @ObservationIgnored private let environment: NodeHostEnvironment
        @ObservationIgnored private let installer: NodePackInstaller
        @ObservationIgnored private let home: NodeHome
        @ObservationIgnored private var supervisor: NodeSupervisor?
        @ObservationIgnored private var installed: InstalledNodePack?
        @ObservationIgnored private var currentPort: Int?
        @ObservationIgnored private var installTask: Task<Void, Never>?

        public init(environment: NodeHostEnvironment) {
            self.environment = environment
            installer = NodePackInstaller(
                root: environment.root, transport: environment.transport,
                pinnedDescriptorSha256: environment.pinnedDescriptorSha256)
            home = NodeHome(root: environment.root.appendingPathComponent("home", isDirectory: true))
            packURLText = environment.defaults.string(forKey: Self.packURLKey) ?? environment.defaultPackURL
            keepRunning = environment.defaults.bool(forKey: Self.keepRunningKey)
            phase = environment.available ? .notInstalled : .unavailable
        }

        public var isAvailable: Bool { environment.available }
        public var isRunning: Bool { if case .running = phase { return true } else { return false } }
        public var isBusy: Bool {
            switch phase {
            case .downloading, .verifying, .starting: return true
            default: return false
            }
        }
        public var port: Int? { currentPort }
        public var logDirectory: URL { home.logs }

        public func refresh() async {
            guard environment.available else { return }
            installed = await installer.installed()
            guard let installed else {
                if case .offered = phase { return }
                phase = .notInstalled
                return
            }
            if supervisor == nil, environment.launcher.ownsProcesses {
                await resumeUnderLaunchd(installed)
            } else if supervisor == nil, let record = adoptableRecord() {
                await begin(port: record.port, adopting: AdoptedNodeProcess(pid: record.pid, sleep: environment.sleep))
            } else if supervisor == nil {
                phase = .installed(version: installed.version)
            }
        }

        public func lookUpOffer() async {
            guard environment.available else { return }
            message = nil
            guard let url = URL(string: packURLText.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil
            else {
                phase = installed.map { .installed(version: $0.version) } ?? .notInstalled
                message = "Enter the address of the node pack."
                return
            }
            do {
                phase = .offered(try await installer.fetchOffer(from: url))
            } catch {
                phase = installed.map { .installed(version: $0.version) } ?? .notInstalled
                message = Self.describe(error)
            }
        }

        public func install() async {
            guard case .offered(let offer) = phase, installTask == nil else { return }
            let task = Task { await self.performInstall(offer) }
            installTask = task
            await task.value
            installTask = nil
        }

        public func cancelInstall() { installTask?.cancel() }

        public func installOnFirstLaunch() async {
            guard environment.available, environment.pinnedDescriptorSha256?.isEmpty == false,
                !environment.defaultPackURL.isEmpty, installTask == nil,
                !environment.defaults.bool(forKey: Self.autoOfferedKey)
            else { return }
            await refresh()
            guard installed == nil, let url = URL(string: environment.defaultPackURL) else { return }
            environment.defaults.set(true, forKey: Self.autoOfferedKey)
            do {
                phase = .offered(try await installer.fetchOffer(from: url))
            } catch {
                message = Self.describe(error)
                return
            }
            await install()
        }

        private func performInstall(_ offer: NodePackOffer) async {
            await stop()
            phase = .downloading(fraction: 0)
            do {
                let result = try await installer.install(offer) { update in
                    Task { @MainActor in self.applyProgress(update) }
                }
                installed = result
                phase = .installed(version: result.version)
            } catch is CancellationError {
                message = "The download was cancelled."
                phase = installed.map { .installed(version: $0.version) } ?? .notInstalled
            } catch {
                message = Self.describe(error)
                phase = installed.map { .installed(version: $0.version) } ?? .notInstalled
            }
        }

        private func applyProgress(_ update: NodePackInstallProgress) {
            switch update {
            case .downloading(let received, let expected):
                if case .downloading = phase {
                    phase = .downloading(fraction: expected > 0 ? min(1, Double(received) / Double(expected)) : 0)
                }
            case .verifying, .unpacking, .checking:
                if case .downloading = phase { phase = .verifying }
            case .done: break
            }
        }

        public func start() async {
            guard let installed, supervisor == nil else { return }
            phase = .starting
            do {
                try home.prepare(
                    pack: installed.root,
                    meshLabel: environment.meshLabel, runScript: environment.runInstaller)
                await begin(port: try environment.freePort(), adopting: nil)
            } catch {
                phase = .failed(Self.describe(error))
            }
        }

        public func stop() async {
            guard let supervisor else { return }
            await supervisor.stop()
            environment.launcher.teardown()
            self.supervisor = nil
            currentPort = nil
            descriptor = nil
            try? FileManager.default.removeItem(at: home.runRecord)
            phase = installed.map { .installed(version: $0.version) } ?? .notInstalled
        }

        public func remove() async {
            environment.defaults.set(true, forKey: Self.autoOfferedKey)
            await stop()
            environment.launcher.teardown()
            try? await installer.remove()
            installed = nil
            phase = .notInstalled
        }

        public func applicationWillTerminate() {
            guard let supervisor else { return }
            if keepRunning { return }
            environment.launcher.teardown()
            supervisor.stopSynchronously()
            try? FileManager.default.removeItem(at: home.runRecord)
        }

        public func requestPairing() async throws -> NodePairingResult {
            guard let port = currentPort, isRunning else { throw NodePairingError.meshUnavailable("node_not_running") }
            let client = try NodePairingClient(port: port, http: environment.http)
            let descriptor = try await client.descriptor()
            self.descriptor = descriptor
            guard descriptor.canJoinMesh else { throw NodePairingError.meshUnavailable("mesh_peer_unavailable") }
            do {
                return try await client.pairingOffer(secret: try home.readPairingSecret())
            } catch NodePairingError.pairingSecretRequired {
                return try await client.pairingOffer(secret: try home.readPairingSecret())
            }
        }

        private func begin(port: Int, adopting handle: NodeProcessHandle?) async {
            guard let installed else { return }
            currentPort = port
            let spec = home.launchSpec(pack: installed.root, port: port, keepRunning: keepRunning)
            let supervisor = NodeSupervisor(
                spec: spec, port: port, launcher: environment.launcher, probe: environment.probe,
                policy: environment.policy, sleep: environment.sleep
            ) { [weak self] state in
                Task { @MainActor in self?.apply(state, version: installed.version) }
            }
            self.supervisor = supervisor
            phase = .starting
            await supervisor.start(adopting: handle)
        }

        private func apply(_ state: NodeSupervisorState, version: String) {
            guard supervisor != nil else { return }
            switch state {
            case .stopped, .stopping: break
            case .starting: phase = .starting
            case .running(let pid, let port):
                phase = .running(port: port)
                writeRunRecord(NodeRunRecord(pid: pid, port: port, packVersion: version, startedAt: Date()))
                Task { await installer.pruneSuperseded() }
                Task { await refreshDescriptor(port: port) }
            case .backingOff(_, let seconds, _):
                phase = .backingOff("The node stopped. Restarting in \(Int(seconds.rounded(.up))) s.")
            case .failed(let reason):
                environment.launcher.teardown()
                phase = .failed(reason)
            }
        }

        private func refreshDescriptor(port: Int) async {
            guard let client = try? NodePairingClient(port: port, http: environment.http) else { return }
            descriptor = try? await client.descriptor()
        }

        private func writeRunRecord(_ record: NodeRunRecord) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(record) else { return }
            try? data.write(to: home.runRecord, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.runRecord.path)
        }

        private func resumeUnderLaunchd(_ installed: InstalledNodePack) async {
            if let adoption = environment.launcher.adoptable() {
                await begin(port: adoption.port, adopting: adoption.handle)
                return
            }
            guard let record = readRunRecord() else {
                phase = .installed(version: installed.version)
                return
            }
            try? FileManager.default.removeItem(at: home.runRecord)
            guard kill(record.pid, 0) == 0 else {
                phase = .installed(version: installed.version)
                return
            }
            guard let path = environment.processPath(record.pid), Self.isInside(path, root: installed.root) else {
                message = "A process outside the node pack holds the recorded node, so it was left running."
                phase = .installed(version: installed.version)
                return
            }
            let legacy = AdoptedNodeProcess(pid: record.pid, sleep: environment.sleep)
            legacy.terminate()
            if await !legacy.waitForExit(timeout: environment.policy.terminationGrace) {
                legacy.kill()
                _ = await legacy.waitForExit(timeout: 2)
            }
            do { await begin(port: try environment.freePort(), adopting: nil) } catch {
                phase = .failed(Self.describe(error))
            }
        }

        static func isInside(_ path: String, root: URL) -> Bool {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let base = root.resolvingSymlinksInPath().path
            return resolved.hasPrefix(base + "/")
        }

        private func readRunRecord() -> NodeRunRecord? {
            guard let data = try? Data(contentsOf: home.runRecord) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(NodeRunRecord.self, from: data)
        }

        private func adoptableRecord() -> NodeRunRecord? {
            guard let data = try? Data(contentsOf: home.runRecord) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let record = try? decoder.decode(NodeRunRecord.self, from: data),
                record.packVersion == installed?.version,
                kill(record.pid, 0) == 0
            else {
                try? FileManager.default.removeItem(at: home.runRecord)
                return nil
            }
            return record
        }

        public static func describePairing(_ error: Error) -> String? {
            switch error as? NodePairingError {
            case .pairingSecretUnavailable: return "The node has no pairing code yet. Wait a moment and try again."
            case .pairingSecretRequired: return "The node's pairing code changed. Try again."
            case .loopbackRequired: return "The node only pairs with a request from this Mac."
            case .ownerMismatch: return "This node belongs to a different mesh."
            case .rateLimited: return "Too many pairing attempts. Wait a minute and try again."
            case .unknownDescriptorFormat: return "This node is too old. Update the node pack."
            case .ownerBindingUnavailable: return "The node cannot read its owner yet. Try again in a moment."
            case .profileInactive: return "This node is not set up for a personal mesh."
            case .meshUnavailable(let code):
                switch code {
                case "node_not_running": return "Start the node first."
                case "mesh_peer_unavailable": return "This node cannot join a mesh."
                case "mesh_unavailable": return "The node's mesh is not ready yet. Try again in a moment."
                default: return "The node cannot join a mesh yet (\(code))."
                }
            case .notLoopback, .refused, .unexpectedResponse, nil: return "The node refused the request."
            }
        }

        static func describe(_ error: Error) -> String {
            switch error as? NodePackError {
            case .unsupportedURL: return "The pack address must be https, or http on this Mac."
            case .descriptorInvalid(let reason): return "The pack description is not valid (\(reason))."
            case .descriptorPinMismatch: return "The pack description does not match the pinned digest."
            case .platformMismatch(let platform): return "This pack is for \(platform), not this Mac."
            case .insufficientSpace(let needed, let available):
                let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
                return "Not enough free space. It needs \(format(needed)) and \(format(available)) is free."
            case .downloadFailed(let reason): return "The download failed (\(reason))."
            case .sizeMismatch: return "The download has the wrong size and was discarded."
            case .digestMismatch(let what): return "The \(what) digest does not match and the download was discarded."
            case .extractionFailed: return "The pack could not be unpacked."
            case .treeMismatch(let problems):
                return "The unpacked pack does not match its manifest (\(problems.first ?? "unknown"))."
            case .notInstalled: return "The node pack is not installed."
            case nil: break
            }
            switch error as? NodeHostError {
            case .homeSetupFailed(let output): return "The node home could not be prepared (\(output))."
            case .launchFailed(let reason): return "The node could not start (\(reason))."
            case .noFreePort: return "No free loopback port was available."
            case nil: return "\(error.localizedDescription)"
            }
        }
    }
#endif
