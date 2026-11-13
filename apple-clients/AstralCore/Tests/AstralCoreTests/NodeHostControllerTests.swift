// Runs the Run a node on this Mac controller end to end with a real archive, a fake process and fake loopback HTTP: offer, install, start, descriptor, pairing, stop, removal and quit behaviour.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    @MainActor
    final class NodeHostControllerTests: XCTestCase {
        private var root: URL!
        private var defaults: UserDefaults!
        private var suite: String!

        override func setUpWithError() throws {
            root = try NodePackTestSupport.temporaryDirectory()
            suite = "nodehost-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        private func environment(
            available: Bool = true, launcher: FakeLauncher = FakeLauncher(), probe: FakeProbe = FakeProbe(),
            http: FakeNodeHTTP = FakeNodeHTTP(), transport: NodePackTransport = FileTransport()
        ) -> NodeHostEnvironment {
            var policy = NodeSupervisorPolicy()
            policy.startupChecks = 3
            let home = root.appendingPathComponent("node/home")
            return NodeHostEnvironment(
                root: root.appendingPathComponent("node"), available: available, issuer: "https://iam.example/realms/a",
                clientId: "astral-desktop", meshLabel: "Test Mac", defaults: defaults, transport: transport,
                launcher: launcher, probe: probe, http: http, policy: policy, sleep: { _ in try await Task.sleep(nanoseconds: 2_000_000) },
                freePort: { 18_731 },
                runInstaller: { _, _ in
                    try "ASTRAL_NODE_PROFILE=personal\n".write(to: home.appendingPathComponent("node.env"), atomically: true, encoding: .utf8)
                    return (0, "")
                })
        }

        private func waitFor(_ controller: NodeHostController, _ predicate: @escaping (NodeHostController.Phase) -> Bool) async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !predicate(controller.phase) { try? await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(predicate(controller.phase), "phase was \(controller.phase)")
        }

        func testAnUnavailableBuildOffersNothing() async throws {
            let controller = NodeHostController(environment: environment(available: false))
            XCTAssertEqual(controller.phase, .unavailable)
            await controller.refresh()
            await controller.lookUpOffer()
            await controller.start()
            XCTAssertEqual(controller.phase, .unavailable)
        }

        func testTheFullLifecycleOfferInstallStartPairStopRemove() async throws {
            let built = try NodePackTestSupport.build()
            let launcher = FakeLauncher()
            let http = FakeNodeHTTP()
            http.responses = [
                (Data(#"{"node_id":"astral-node:1","capabilities":["mesh-peer"],"mesh":{"state":"not_enrolled"}}"#.utf8), 200),
                (Data(#"{"node_id":"astral-node:1","capabilities":["mesh-peer"],"mesh":{"state":"not_enrolled"}}"#.utf8), 200),
                (Data(#"{"mesh":{"state":"offer","code":"ABCD-1234","payload":"the-payload"}}"#.utf8), 200),
            ]
            let controller = NodeHostController(environment: environment(launcher: launcher, http: http))
            await controller.refresh()
            XCTAssertEqual(controller.phase, .notInstalled)

            controller.packURLText = built.descriptorURL.absoluteString
            await controller.lookUpOffer()
            guard case .offered(let offer) = controller.phase else { return XCTFail("\(controller.phase)") }
            XCTAssertTrue(offer.sizeDescription.contains("on disk"))

            await controller.install()
            XCTAssertEqual(controller.phase, .installed(version: "3.11.18-test"))

            await controller.start()
            await waitFor(controller) { $0 == .running(port: 18_731) }
            XCTAssertTrue(controller.isRunning && controller.port == 18_731)
            XCTAssertEqual(launcher.specs.first?.arguments.contains("--log-dir"), true)
            let record = root.appendingPathComponent("node/home/run.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))

            let offerResult = try await controller.requestPairing { "owner-token" }
            XCTAssertEqual(offerResult, .offer(NodePairingOffer(code: "ABCD-1234", payload: "the-payload", expiresMs: nil)))
            XCTAssertEqual(controller.descriptor?.canJoinMesh, true)

            await controller.stop()
            XCTAssertEqual(controller.phase, .installed(version: "3.11.18-test"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
            XCTAssertTrue(launcher.process(0).terminated)

            await controller.remove()
            XCTAssertEqual(controller.phase, .notInstalled)
        }

        func testPairingNeedsARunningNodeThatCanJoinAMesh() async throws {
            let built = try NodePackTestSupport.build()
            let http = FakeNodeHTTP()
            let controller = NodeHostController(environment: environment(http: http))
            do {
                _ = try await controller.requestPairing { "t" }
                XCTFail("expected a refusal")
            } catch { XCTAssertEqual(error as? NodePairingError, .meshUnavailable("node_not_running")) }
            controller.packURLText = built.descriptorURL.absoluteString
            await controller.lookUpOffer()
            await controller.install()
            await controller.start()
            await waitFor(controller) { $0 == .running(port: 18_731) }
            http.responses = [
                (Data(#"{"node_id":"n","capabilities":["chat"],"mesh":null}"#.utf8), 200),
                (Data(#"{"node_id":"n","capabilities":["chat"],"mesh":null}"#.utf8), 200),
            ]
            do {
                _ = try await controller.requestPairing { "t" }
                XCTFail("expected a refusal")
            } catch { XCTAssertEqual(error as? NodePairingError, .meshUnavailable("mesh_peer_unavailable")) }
            await controller.stop()
        }

        func testAnInvalidAddressOrUnreachableHostKeepsThePhaseAndExplains() async throws {
            let controller = NodeHostController(environment: environment())
            controller.packURLText = "   "
            await controller.lookUpOffer()
            XCTAssertEqual(controller.phase, .notInstalled)
            XCTAssertEqual(controller.message, "Enter the address of the node pack.")
            controller.packURLText = "http://example.com/node-pack.json"
            await controller.lookUpOffer()
            XCTAssertEqual(controller.message, "The pack address must be https, or http on this Mac.")
            controller.packURLText = root.appendingPathComponent("missing.json").absoluteString
            await controller.lookUpOffer()
            XCTAssertNotNil(controller.message)
            XCTAssertEqual(controller.phase, .notInstalled)
        }

        func testAFailedInstallReportsWhyAndLeavesNothingInstalled() async throws {
            let built = try NodePackTestSupport.build()
            let controller = NodeHostController(environment: environment(transport: FileTransport(corruptDownload: true)))
            controller.packURLText = built.descriptorURL.absoluteString
            await controller.lookUpOffer()
            await controller.install()
            XCTAssertEqual(controller.phase, .notInstalled)
            XCTAssertEqual(controller.message, "The archive digest does not match and the download was discarded.")
        }

        func testASetupFailureSurfacesAsAFailedPhase() async throws {
            let built = try NodePackTestSupport.build()
            var failing = environment()
            failing.runInstaller = { _, _ in (3, "openssl missing") }
            let controller = NodeHostController(environment: failing)
            controller.packURLText = built.descriptorURL.absoluteString
            await controller.lookUpOffer()
            await controller.install()
            await controller.start()
            XCTAssertEqual(controller.phase, .failed("The node home could not be prepared (openssl missing)."))
        }

        func testSettingsPersistAcrossControllers() {
            let first = NodeHostController(environment: environment())
            XCTAssertFalse(first.keepRunning)
            first.keepRunning = true
            first.packURLText = "https://example.com/node-pack.json"
            let second = NodeHostController(environment: environment())
            XCTAssertTrue(second.keepRunning)
            XCTAssertEqual(second.packURLText, "https://example.com/node-pack.json")
        }

        func testQuitStopsTheNodeUnlessKeepRunningIsOn() async throws {
            let built = try NodePackTestSupport.build()
            for keep in [false, true] {
                let launcher = FakeLauncher()
                let controller = NodeHostController(environment: environment(launcher: launcher))
                controller.keepRunning = keep
                controller.packURLText = built.descriptorURL.absoluteString
                await controller.lookUpOffer()
                await controller.install()
                await controller.start()
                await waitFor(controller) { $0 == .running(port: 18_731) }
                let record = root.appendingPathComponent("node/home/run.json")
                controller.applicationWillTerminate()
                XCTAssertEqual(FileManager.default.fileExists(atPath: record.path), keep)
                await controller.stop()
            }
        }

        func testARecordedLiveNodeIsAdoptedOnTheNextLaunch() async throws {
            let built = try NodePackTestSupport.build()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try child.run()
            defer { child.terminate() }
            let first = NodeHostController(environment: environment())
            first.packURLText = built.descriptorURL.absoluteString
            await first.lookUpOffer()
            await first.install()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let home = root.appendingPathComponent("node/home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try encoder.encode(NodeRunRecord(pid: child.processIdentifier, port: 18_740, packVersion: "3.11.18-test", startedAt: Date()))
                .write(to: home.appendingPathComponent("run.json"))
            let launcher = FakeLauncher()
            let second = NodeHostController(environment: environment(launcher: launcher))
            await second.refresh()
            await waitFor(second) { $0 == .running(port: 18_740) }
            XCTAssertEqual(launcher.count, 0)
            await second.stop()
        }

        func testAStaleRunRecordIsIgnoredAndRemoved() async throws {
            let built = try NodePackTestSupport.build()
            let seed = NodeHostController(environment: environment())
            seed.packURLText = built.descriptorURL.absoluteString
            await seed.lookUpOffer()
            await seed.install()
            let home = root.appendingPathComponent("node/home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(NodeRunRecord(pid: 2_000_000_001, port: 18_741, packVersion: "3.11.18-test", startedAt: Date()))
                .write(to: home.appendingPathComponent("run.json"))
            let controller = NodeHostController(environment: environment())
            await controller.refresh()
            XCTAssertEqual(controller.phase, .installed(version: "3.11.18-test"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("run.json").path))
        }
    }
#endif
