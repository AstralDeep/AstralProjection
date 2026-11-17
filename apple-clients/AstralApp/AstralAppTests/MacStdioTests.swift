// Runs a Python stdio fixture under the real Seatbelt profile through MacStdioLauncher and checks the bridge: proxy-only egress, refused direct network, file denials, the environment, the bearer and removal.
// ASTRAL_EXEC_TEST_PYTHON names the interpreter (it falls back to /usr/bin/python3), and the egress proxy is a recording stand-in so no test touches the network.

#if os(macOS)
    import AstralKernel
    import CryptoKit
    import Foundation
    import XCTest

    @testable import AstralDeep

    private let fixtureSource = """
        import json, os, socket, sys
        def probe(p):
            c = p["check"]
            try:
                if c == "env": return sorted(os.environ.keys())
                if c == "pid": return os.getpid()
                if c == "read": open(p["path"]).read(1)
                elif c == "write": open(p["path"], "w").write("x")
                elif c == "tcp": socket.create_connection(("127.0.0.1", p["port"]), timeout=2)
                elif c == "udp":
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(b"x", ("127.0.0.1", p["port"]))
                elif c == "dns": socket.getaddrinfo("example.com", 80)
                elif c == "proxy":
                    host, port = os.environ["HTTPS_PROXY"].split("//")[1].split(":")
                    s = socket.create_connection((host, int(port)), timeout=3)
                    s.sendall(b"CONNECT allowed.example:443 HTTP/1.1\\r\\nHost: allowed.example:443\\r\\n\\r\\n")
                    return s.recv(64).decode()
                return "allowed"
            except Exception as error:
                return "refused:" + type(error).__name__
        for line in sys.stdin:
            message = json.loads(line)
            if "id" not in message: continue
            result = probe(message.get("params", {})) if message["method"] == "probe" else {}
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
        """

    private final class RecordingProxy: MacComputerEgressProxying, @unchecked Sendable {
        private(set) var descriptor: Int32 = -1
        private(set) var port: UInt16 = 0
        private let lock = NSLock()
        private var heads: [String] = []
        private(set) var stopped = false

        init() {
            let made = socket(AF_INET, SOCK_STREAM, 0)
            descriptor = made
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(made, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            listen(made, 4)
            var bound = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(made, $0, &size) }
            }
            port = UInt16(bigEndian: bound.sin_port)
            Thread.detachNewThread { [self] in serve() }
        }

        var requests: [String] { lock.withLock { heads } }

        func start() throws {}

        func stop() {
            lock.withLock { stopped = true }
            close(descriptor)
        }

        private func serve() {
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 512)
                let count = read(client, &buffer, buffer.count)
                if count > 0 {
                    let text = String(decoding: buffer[0..<count], as: UTF8.self)
                    lock.withLock { heads.append(text.components(separatedBy: "\r\n").first ?? "") }
                    let reply = Array("HTTP/1.1 200 OK\r\n\r\n".utf8)
                    _ = write(client, reply, reply.count)
                }
                close(client)
            }
        }
    }

    private final class EchoChannel: MacStdioChannel, @unchecked Sendable {
        var sent: [Data] = []
        func send(_ line: Data) -> Bool {
            sent.append(line)
            return true
        }
    }

    final class MacStdioTests: XCTestCase {
        private var root = ""
        private var python = ""
        private var prefix = ""
        private var proxy: RecordingProxy?
        private var launcher: MacStdioLauncher!

        override func setUpWithError() throws {
            continueAfterFailure = false
            let base = NSTemporaryDirectory() + "stdio-" + UUID().uuidString.prefix(8)
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            root = String(cString: realpath(base, nil))
            for directory in ["data", "home/.ssh", "scripts", "outside"] {
                try FileManager.default.createDirectory(
                    atPath: root + "/" + directory, withIntermediateDirectories: true)
            }
            try "secret".write(toFile: root + "/home/.ssh/id_test", atomically: true, encoding: .utf8)
            try fixtureSource.write(toFile: root + "/scripts/server.py", atomically: true, encoding: .utf8)
            let configured = ProcessInfo.processInfo.environment["ASTRAL_EXEC_TEST_PYTHON"] ?? "/usr/bin/python3"
            python = String(cString: realpath(configured, nil))
            prefix = try Self.basePrefix(python)
            let recording = RecordingProxy()
            proxy = recording
            let scripts = root + "/scripts"
            let reads = [prefix, scripts]
            launcher = MacStdioLauncher(
                dataDirectory: root + "/data", home: root + "/home", extraReads: { reads },
                proxyFactory: { _, _ in recording })
        }

        override func tearDown() {
            proxy?.stop()
            try? FileManager.default.removeItem(atPath: root)
        }

        private static func basePrefix(_ python: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-I", "-c", "import os,sys;print(os.path.realpath(sys.base_prefix))"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func request(id: String, hosts: [String] = []) throws -> HostLaunchRequest {
            let hostList = hosts.map { "{\"host\":\"\($0)\",\"port\":443}" }.joined(separator: ",")
            let policy = """
                {"v":1,"reads":["\(python.components(separatedBy: "/").dropLast().joined(separator: "/"))"],\
                "workspace":null,"hosts":[\(hostList)],"limits":{"memory_bytes":1073741824,"processes":16,\
                "open_files":256,"file_bytes":1073741824},"time":{"wall_ms":86400000}}
                """
            let canonical = try KernelCanonicalJSON.canonicalize(Data(policy.utf8))
            let digest = "sha256:" + SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            return HostLaunchRequest(
                id: id, command: python, args: ["-I", "-B", "-S", root + "/scripts/server.py"],
                env: [ConnectionKeyEntry(name: "TOKEN_ONE", value: "one")], egress: hosts, policyJson: policy,
                policyDigest: digest)
        }

        private func call(_ server: HostLaunchedServer, _ params: [String: Any], bearer: String? = nil) async throws
            -> (Int, Any?)
        {
            let (status, body) = try await post(server.url, bearer: bearer ?? server.bearer, params: params)
            let value = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["result"]
            return (status, value)
        }

        private func post(_ url: String, bearer: String?, params: [String: Any]) async throws -> (Int, Data) {
            var urlRequest = URLRequest(url: URL(string: url)!)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 20
            if let bearer { urlRequest.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
            let message: [String: Any] = [
                "jsonrpc": "2.0", "id": Int.random(in: 1...1_000_000), "method": "probe", "params": params,
            ]
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: message)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        private func launched(_ id: String, hosts: [String] = []) throws -> HostLaunchedServer {
            try launcher.start(request: try request(id: id, hosts: hosts))
        }

        private let idOne = String(repeating: "a", count: 32)

        func testTheServerReachesAnAllowedHostOnlyThroughTheProxy() async throws {
            let server = try launched(idOne, hosts: ["allowed.example"])
            defer { launcher.stop(id: idOne) }
            let (status, reply) = try await call(server, ["check": "proxy"])
            XCTAssertEqual(status, 200)
            XCTAssertTrue((reply as? String)?.hasPrefix("HTTP/1.1 200") ?? false)
            XCTAssertEqual(proxy?.requests, ["CONNECT allowed.example:443 HTTP/1.1"])
            let direct = try await call(server, ["check": "tcp", "port": Int(proxy?.port ?? 0) + 1])
            XCTAssertEqual(direct.1 as? String, "refused:PermissionError")
        }

        func testDirectTcpUdpAndDnsAreRefused() async throws {
            let server = try launched(idOne)
            defer { launcher.stop(id: idOne) }
            let other = Int(proxy?.port ?? 1)
            for check in [["check": "tcp", "port": other], ["check": "udp", "port": other], ["check": "dns"]] {
                let (_, reply) = try await call(server, check)
                XCTAssertTrue((reply as? String)?.hasPrefix("refused:") ?? false, "\(check)")
            }
        }

        func testWritesOutsideTheWorkspaceAndTheSshFolderAreRefused() async throws {
            let server = try launched(idOne)
            defer { launcher.stop(id: idOne) }
            let inside = root + "/data/exec/" + idOne + "/note.txt"
            for (path, check) in [(root + "/outside/x.txt", "write"), (root + "/home/.ssh/id_test", "read")] {
                let (_, reply) = try await call(server, ["check": check, "path": path])
                XCTAssertEqual(reply as? String, "refused:PermissionError", path)
            }
            let (_, written) = try await call(server, ["check": "write", "path": inside])
            XCTAssertEqual(written as? String, "allowed")
        }

        func testTheEnvironmentHoldsOnlyTheRecordNames() async throws {
            let server = try launched(idOne, hosts: ["allowed.example"])
            defer { launcher.stop(id: idOne) }
            let (_, reply) = try await call(server, ["check": "env"])
            let names = Set((reply as? [String]) ?? [])
            let allowed: Set<String> = [
                "TOKEN_ONE", "ASTRAL_EXEC_MARKER", "LC_CTYPE", "__CF_USER_TEXT_ENCODING", "NO_PROXY", "no_proxy",
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy",
            ]
            XCTAssertTrue(names.contains("TOKEN_ONE"))
            XCTAssertTrue(names.isSubset(of: allowed), "\(names.subtracting(allowed))")
        }

        func testTheBridgeRefusesAMissingOrWrongBearer() async throws {
            let server = try launched(idOne)
            defer { launcher.stop(id: idOne) }
            let missing = try await post(server.url, bearer: nil, params: ["check": "pid"])
            let wrong = try await post(server.url, bearer: "wrong", params: ["check": "pid"])
            XCTAssertEqual(missing.0, 401)
            XCTAssertEqual(wrong.0, 401)
            let good = try await call(server, ["check": "pid"])
            XCTAssertEqual(good.0, 200)
        }

        func testRemovalStopsTheProcessAndTheEndpoint() async throws {
            let server = try launched(idOne, hosts: ["allowed.example"])
            let (_, pid) = try await call(server, ["check": "pid"])
            let number = try XCTUnwrap((pid as? NSNumber)?.int32Value)
            launcher.stop(id: idOne)
            var gone = false
            for _ in 0..<30 where !gone {
                gone = kill(number, 0) != 0
                if !gone { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            XCTAssertTrue(gone)
            XCTAssertTrue(proxy?.stopped ?? false)
            let after = try? await post(server.url, bearer: server.bearer, params: ["check": "pid"])
            XCTAssertNil(after)
        }

        func testUnsafeServerIdsAreRefusedBeforeTouchingTheFilesystem() throws {
            let sentinel = root + "/outside/keep"
            try "keep".write(toFile: sentinel, atomically: true, encoding: .utf8)
            let bad = ["../x", "../../outside", "a/b", String(repeating: "A", count: 32),
                String(repeating: "a", count: 31), String(repeating: "a", count: 33), ""]
            for id in bad {
                XCTAssertThrowsError(try launcher.start(request: try request(id: id)), id)
                launcher.stop(id: id)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/data/exec"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/data/x"))
            XCTAssertEqual(try String(contentsOfFile: sentinel, encoding: .utf8), "keep")
        }

        func testAWorkspaceThatEscapesTheExecFolderIsRefused() throws {
            try FileManager.default.createDirectory(atPath: root + "/data/exec", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: root + "/data/exec/" + idOne, withDestinationPath: root + "/outside")
            XCTAssertThrowsError(try launcher.start(request: try request(id: idOne)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/outside"))
        }

        func testAPolicyThatIsNotTheApprovedOneStartsNothing() throws {
            var changed = try request(id: idOne)
            changed.policyDigest = "sha256:" + String(repeating: "0", count: 64)
            XCTAssertThrowsError(try launcher.start(request: changed))
            var relative = try request(id: idOne)
            relative.command = "server"
            XCTAssertThrowsError(try launcher.start(request: relative))
        }

        func testTheBridgeAnswersNotificationsAndTimesOutOnSilence() async throws {
            let channel = EchoChannel()
            let bridge = MacStdioBridge(bearer: "b", channel: channel, replyTimeout: 0.3)
            let port = try bridge.start()
            defer { bridge.stop() }
            let url = "http://127.0.0.1:\(port)/mcp"
            var note = URLRequest(url: URL(string: url)!)
            note.httpMethod = "POST"
            note.setValue("Bearer b", forHTTPHeaderField: "Authorization")
            note.httpBody = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)
            let (_, answer) = try await URLSession.shared.data(for: note)
            XCTAssertEqual((answer as? HTTPURLResponse)?.statusCode, 202)
            let silent = try await post(url, bearer: "b", params: [:])
            XCTAssertEqual(silent.0, 504)
            XCTAssertEqual(channel.sent.count, 2)
            var read = URLRequest(url: URL(string: url)!)
            read.setValue("Bearer b", forHTTPHeaderField: "Authorization")
            let (_, getAnswer) = try await URLSession.shared.data(for: read)
            XCTAssertEqual((getAnswer as? HTTPURLResponse)?.statusCode, 405)
        }
    }
#endif
