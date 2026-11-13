// Drives the Settings control "Run a node on this Mac": it offers the pack with its size, downloads and installs it, supervises the node and starts the pairing into the owner's mesh.
// The app's Mac settings view binds to it, and the quit handler calls applicationWillTerminate so the node stops unless Keep running is on.

#if os(macOS)
    import Foundation
    import Observation

    public enum NodeHostAvailability {
        public static func permits(marker: String?, sandboxed: Bool) -> Bool {
            marker == "direct-download" && !sandboxed
        }

        public static func current(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment)
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
        public var issuer: String
        public var clientId: String
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

        public init(
            root: URL, available: Bool, issuer: String, clientId: String, meshLabel: String,
            defaults: UserDefaults = .standard, transport: NodePackTransport = URLSessionNodePackTransport(),
            launcher: NodeProcessLauncher = PosixNodeProcessLauncher(), probe: NodeHealthProbe = LoopbackNodeHealthProbe(),
            http: NodeHTTP = URLSessionNodeHTTP(), policy: NodeSupervisorPolicy = NodeSupervisorPolicy(),
            sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            },
            freePort: @escaping @Sendable () throws -> Int = NodeHome.freeLoopbackPort,
            runInstaller: @escaping @Sendable (URL, [String]) throws -> (status: Int32, output: String) =
                NodeHome.runInstaller,
            defaultPackURL: String = "", pinnedDescriptorSha256: String? = nil
        ) {
            self.root = root
            self.available = available
            self.issuer = issuer
            self.clientId = clientId
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
            if supervisor == nil, let record = adoptableRecord() {
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
            guard case .offered(let offer) = phase else { return }
            await stop()
            phase = .downloading(fraction: 0)
            do {
                let result = try await installer.install(offer) { update in
                    Task { @MainActor in self.applyProgress(update) }
                }
                installed = result
                phase = .installed(version: result.version)
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
                    pack: installed.root, issuer: environment.issuer, clientId: environment.clientId,
                    meshLabel: environment.meshLabel, runScript: environment.runInstaller)
                await begin(port: try environment.freePort(), adopting: nil)
            } catch {
                phase = .failed(Self.describe(error))
            }
        }

        public func stop() async {
            guard let supervisor else { return }
            await supervisor.stop()
            self.supervisor = nil
            currentPort = nil
            descriptor = nil
            try? FileManager.default.removeItem(at: home.runRecord)
            phase = installed.map { .installed(version: $0.version) } ?? .notInstalled
        }

        public func remove() async {
            await stop()
            try? await installer.remove()
            installed = nil
            phase = .notInstalled
        }

        public func applicationWillTerminate() {
            guard let supervisor else { return }
            if keepRunning { return }
            supervisor.stopSynchronously()
            try? FileManager.default.removeItem(at: home.runRecord)
        }

        public func requestPairing(ownerToken: () async throws -> String) async throws -> NodePairingResult {
            guard let port = currentPort, isRunning else { throw NodePairingError.meshUnavailable("node_not_running") }
            let client = try NodePairingClient(port: port, http: environment.http)
            let descriptor = try await client.descriptor()
            self.descriptor = descriptor
            guard descriptor.canJoinMesh else { throw NodePairingError.meshUnavailable("mesh_peer_unavailable") }
            let token = try await ownerToken()
            return try await client.pairingOffer(bearer: token, label: environment.meshLabel)
        }

        private func begin(port: Int, adopting handle: NodeProcessHandle?) async {
            guard let installed else { return }
            currentPort = port
            let spec = home.launchSpec(pack: installed.root, port: port)
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
                Task { await refreshDescriptor(port: port) }
            case .backingOff(_, let seconds, _):
                phase = .backingOff("The node stopped. Restarting in \(Int(seconds.rounded(.up))) s.")
            case .failed(let reason): phase = .failed(reason)
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

        private func adoptableRecord() -> NodeRunRecord? {
            guard let data = try? Data(contentsOf: home.runRecord) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let record = try? decoder.decode(NodeRunRecord.self, from: data), record.packVersion == installed?.version,
                kill(record.pid, 0) == 0
            else {
                try? FileManager.default.removeItem(at: home.runRecord)
                return nil
            }
            return record
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
