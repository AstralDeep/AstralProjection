// Prepares the node's private home directory and its personal-profile env file with the pack's own installer script, and builds the launch command for the supervisor.
// NodeHostController calls it before the first start, and the env file stays in the home with mode 0600 and never passes through the app's own environment.

#if os(macOS)
    import Foundation

    public enum NodeHostError: Error, Equatable, Sendable {
        case homeSetupFailed(String)
        case launchFailed(String)
        case noFreePort
    }

    public struct NodeHome: Equatable, Sendable {
        public let root: URL

        public init(root: URL) { self.root = root }

        public var data: URL { root.appendingPathComponent("data", isDirectory: true) }
        public var envFile: URL { root.appendingPathComponent("node.env") }
        public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
        public var launchLog: URL { logs.appendingPathComponent("launch.log") }
        public var runRecord: URL { root.appendingPathComponent("run.json") }
        public var temporary: URL { root.appendingPathComponent("tmp", isDirectory: true) }

        public func prepare(
            pack: URL, issuer: String, clientId: String, meshLabel: String,
            runScript: @Sendable (URL, [String]) throws -> (status: Int32, output: String) = NodeHome.runInstaller
        ) throws {
            let fileManager = FileManager.default
            for directory in [root, logs, temporary] {
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let script = pack.appendingPathComponent("app/scripts/node/install-personal-node.sh")
            let result = try runScript(
                script, ["--issuer", issuer, "--client-id", clientId, "--home", root.path])
            guard result.status == 0, fileManager.fileExists(atPath: envFile.path) else {
                throw NodeHostError.homeSetupFailed(String(result.output.prefix(300)))
            }
            try ensureSetting("ASTRAL_NODE_MESH_LABEL", value: Self.safeLabel(meshLabel))
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
        }

        public func launchSpec(pack: URL, port: Int) -> NodeLaunchSpec {
            NodeLaunchSpec(
                executable: pack.appendingPathComponent("python/bin/python3.11"),
                arguments: [
                    "-I", pack.appendingPathComponent("launcher/astral_node_launch.py").path,
                    "--env-file", envFile.path, "--port", String(port), "--log-dir", logs.path,
                ],
                environment: [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path, "TMPDIR": temporary.path + "/",
                    "LANG": "en_US.UTF-8",
                ],
                workingDirectory: pack, launchLog: launchLog)
        }

        static func safeLabel(_ label: String) -> String {
            let cleaned = label.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 && $0 != "=" }
                .prefix(48).map(String.init).joined()
            return cleaned.isEmpty ? "Mac node" : cleaned
        }

        private func ensureSetting(_ key: String, value: String) throws {
            let existing = (try? String(contentsOf: envFile, encoding: .utf8)) ?? ""
            guard !existing.split(separator: "\n").contains(where: { $0.hasPrefix(key + "=") }) else { return }
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            try (existing + separator + "\(key)=\(value)\n").write(to: envFile, atomically: true, encoding: .utf8)
        }

        public static func runInstaller(script: URL, arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path] + arguments
            process.environment = ["PATH": "/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }

        public static func freeLoopbackPort() throws -> Int {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw NodeHostError.noFreePort }
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw NodeHostError.noFreePort }
            var assigned = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            guard named == 0 else { throw NodeHostError.noFreePort }
            return Int(UInt16(bigEndian: assigned.sin_port))
        }
    }

    public struct NodeRunRecord: Codable, Equatable, Sendable {
        public let pid: Int32
        public let port: Int
        public let packVersion: String
        public let startedAt: Date

        public init(pid: Int32, port: Int, packVersion: String, startedAt: Date) {
            self.pid = pid
            self.port = port
            self.packVersion = packVersion
            self.startedAt = startedAt
        }
    }
#endif
