// Starts a stdio MCP server on the Mac under the enforced Seatbelt profile: it checks the Kernel's policy digest, runs the server through ExecLauncher and puts MacStdioBridge in front of it.
// MeshRuntime installs it on the Kernel only on macOS, and its egress goes only through MacComputerEgressProxy limited to the hosts in the record.

#if os(macOS)
    import AstralCore
    import AstralKernel
    import CryptoKit
    import Foundation

    nonisolated final class MacStdioLauncher: HostLauncher, @unchecked Sendable {
        typealias ProxyFactory = @Sendable (_ id: String, _ hosts: [String]) throws -> any MacComputerEgressProxying

        private struct Running {
            let session: ExecSession
            let bridge: MacStdioBridge
            let proxy: (any MacComputerEgressProxying)?
            let workspace: String
        }

        private let dataDirectory: String
        private let home: String
        private let extraReads: @Sendable () -> [String]
        private let proxyFactory: ProxyFactory
        private let lock = NSLock()
        private var running: [String: Running] = [:]

        init(
            dataDirectory: String, home: String = NSHomeDirectory(),
            extraReads: @escaping @Sendable () -> [String] = { [] },
            proxyFactory: @escaping ProxyFactory = MacStdioLauncher.defaultProxy
        ) {
            self.dataDirectory = dataDirectory
            self.home = home
            self.extraReads = extraReads
            self.proxyFactory = proxyFactory
        }

        static let defaultProxy: ProxyFactory = { id, hosts in
            let domains: [ComputerEgressDomain] = hosts.compactMap { ComputerEgressDomain($0) }
            let policy = ComputerEgressPolicy(mode: .enforce, domains: domains, bindings: [])
            let request = MacComputerEgressProxyRequest(
                jobId: "stdio-" + id, policy: policy, secrets: { _ in nil }, sink: MacComputerEgressDecisionSink())
            let proxy = try MacComputerEgressProxy(request: request)
            try proxy.start()
            return proxy
        }

        func start(request: HostLaunchRequest) throws -> HostLaunchedServer {
            let existing: Running? = lock.withLock { running.removeValue(forKey: request.id) }
            if let existing { Self.end(existing) }
            let plan = try Self.plan(request, dataDirectory: dataDirectory, extraReads: extraReads())
            let proxy: (any MacComputerEgressProxying)? =
                plan.hosts.isEmpty ? nil : try proxyFactory(request.id, plan.hosts)
            do {
                return try launch(request, plan: plan, proxy: proxy)
            } catch {
                proxy?.stop()
                try? FileManager.default.removeItem(atPath: plan.workspace)
                throw error
            }
        }

        func stop(id: String) {
            let found: Running? = lock.withLock { running.removeValue(forKey: id) }
            if let found { Self.end(found) }
        }

        private func launch(_ request: HostLaunchRequest, plan: Plan, proxy: (any MacComputerEgressProxying)?) throws
            -> HostLaunchedServer
        {
            let loaded = try ExecPolicy.load(json: plan.document, dataDirectory: dataDirectory, home: home)
            let port: UInt16? = proxy?.port
            let launcher = ExecLauncher(proxyPort: { port })
            var environment: [String: String] = [:]
            for entry in request.env { environment[entry.name] = entry.value }
            guard let session = launcher.openSession(loaded, argv: [request.command] + request.args, env: environment)
            else { throw HostLauncherError.Failed(message: "the sandbox could not start the server") }
            let bearer = Self.newBearer()
            let channel = MacStdioSessionChannel(session: session)
            let bridge = MacStdioBridge(bearer: bearer, channel: channel)
            session.start(onLine: { bridge.receive(line: $0) }, onEnd: { bridge.stop() })
            do {
                let bound = try bridge.start()
                lock.withLock {
                    running[request.id] = Running(
                        session: session, bridge: bridge, proxy: proxy, workspace: plan.workspace)
                }
                return HostLaunchedServer(url: "http://127.0.0.1:\(bound)" + MacStdioBridge.path, bearer: bearer)
            } catch {
                session.stop()
                throw HostLauncherError.Failed(message: "the bridge could not listen")
            }
        }

        private static func end(_ value: Running) {
            value.bridge.stop()
            value.session.stop()
            value.proxy?.stop()
            try? FileManager.default.removeItem(atPath: value.workspace)
        }

        static func newBearer() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    nonisolated final class MacStdioSessionChannel: MacStdioChannel, @unchecked Sendable {
        private let session: ExecSession

        init(session: ExecSession) { self.session = session }

        func send(_ line: Data) -> Bool { session.send(line) }
    }

    extension MacStdioLauncher {
        private static func resolvedPath(_ path: String) throws -> String {
            guard let resolved = realpath(path, nil) else {
                throw HostLauncherError.Failed(message: "the server workspace is not available")
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        struct Plan {
            let document: Data
            let hosts: [String]
            let workspace: String
        }

        static func plan(_ request: HostLaunchRequest, dataDirectory: String, extraReads: [String]) throws -> Plan {
            guard request.command.hasPrefix("/"),
                let source = request.policyJson.data(using: .utf8),
                let canonical = try? KernelCanonicalJSON.canonicalize(source),
                "sha256:" + SHA256.hash(data: canonical).map({ String(format: "%02x", $0) }).joined()
                    == request.policyDigest,
                var policy = try? JSONSerialization.jsonObject(with: source) as? [String: Any]
            else { throw HostLauncherError.Failed(message: "the launch policy is not the one approved") }
            let workspace = dataDirectory + "/exec/" + request.id
            try FileManager.default.createDirectory(
                atPath: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let granted: [String] = (policy["reads"] as? [String]) ?? []
            let readRoots: [String] = try (granted + extraReads).map(resolvedPath)
            policy["reads"] = Array(Set(readRoots)).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            policy["workspace"] = try resolvedPath(workspace)
            let hosts: [String] = ((policy["hosts"] as? [[String: Any]]) ?? []).compactMap { $0["host"] as? String }
            let document = try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys])
            return Plan(document: document, hosts: hosts, workspace: workspace)
        }
    }
#endif
