// Runs the real downloaded pack: it fetches the descriptor from the URL in ASTRAL_NODE_PACK_URL, installs the archive, starts the packed node, checks health, the mesh capability and the log, and stops it.
// It is skipped unless that variable names a locally served pack, so the gate stays deterministic.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    @MainActor
    final class NodePackRealRunTests: XCTestCase {
        private func processes(matching pattern: String) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-f", pattern]
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        func testDownloadInstallStartHealthDescriptorAndStop() async throws {
            guard let address = ProcessInfo.processInfo.environment["ASTRAL_NODE_PACK_URL"] else {
                throw XCTSkip("ASTRAL_NODE_PACK_URL is not set")
            }
            let root = URL(fileURLWithPath: "/tmp/nodepack-realrun-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = UserDefaults(suiteName: "nodepack-realrun-\(UUID().uuidString)")!
            var policy = NodeSupervisorPolicy()
            policy.startupChecks = 240
            let environment = NodeHostEnvironment(
                root: root, available: true, issuer: "https://iam.invalid/realms/Astral", clientId: "astral-desktop",
                meshLabel: "Test Mac node", defaults: defaults, policy: policy)
            let controller = NodeHostController(environment: environment)
            controller.packURLText = address

            await controller.lookUpOffer()
            guard case .offered(let offer) = controller.phase else { return XCTFail("\(controller.phase) \(controller.message ?? "")") }
            print("OFFER", offer.sizeDescription)
            await controller.install()
            guard case .installed(let version) = controller.phase else { return XCTFail("\(controller.phase) \(controller.message ?? "")") }
            print("INSTALLED", version)

            await controller.start()
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline, !controller.isRunning {
                if case .failed = controller.phase { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard case .running(let port) = controller.phase else { return XCTFail("\(controller.phase)") }
            print("RUNNING on", port)

            let client = try NodePairingClient(port: port)
            let descriptor = try await client.descriptor()
            XCTAssertTrue(descriptor.canJoinMesh, "capabilities: \(descriptor.capabilities)")
            XCTAssertEqual(descriptor.mesh?.state, "not_enrolled")
            let health = await LoopbackNodeHealthProbe().isHealthy(port: port)
            XCTAssertTrue(health)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/readyz")!)
            request.timeoutInterval = 10
            let (_, ready) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((ready as? HTTPURLResponse)?.statusCode, 200)

            let home = root.appendingPathComponent("home")
            let log = try String(contentsOf: home.appendingPathComponent("logs/node.log"), encoding: .utf8)
            XCTAssertTrue(log.contains("Application startup complete"))
            let env = try String(contentsOf: home.appendingPathComponent("node.env"), encoding: .utf8)
            for line in env.split(separator: "\n") where line.contains("KEY=") || line.contains("SECRET=") {
                let value = String(line.split(separator: "=", maxSplits: 1)[1])
                XCTAssertFalse(log.contains(value), "a secret value reached the log")
            }
            let pack = root.appendingPathComponent("packs/\(version)").path
            XCTAssertTrue(processes(matching: pack + "/bin/astral-mailbox"), "the node should supervise its mailbox")

            await controller.stop()
            XCTAssertEqual(controller.phase, .installed(version: version))
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertFalse(processes(matching: pack + "/python/bin/python3.11"))
            XCTAssertFalse(processes(matching: pack + "/bin/astral-mailbox"))
            let stopped = await LoopbackNodeHealthProbe().isHealthy(port: port)
            XCTAssertFalse(stopped)
        }
    }
#endif
