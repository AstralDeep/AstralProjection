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
                root: root.appendingPathComponent("node"), available: available,
                meshLabel: "Test Mac", defaults: defaults, transport: transport,
                launcher: launcher, probe: probe, http: http, policy: policy,
                sleep: { _ in try await Task.sleep(nanoseconds: 2_000_000) },
                freePort: { 18_731 },
                runInstaller: { _, _ in
                    try "ASTRAL_NODE_PROFILE=personal\n".write(
                        to: home.appendingPathComponent("node.env"), atomically: true, encoding: .utf8)
                    return (0, "")
                })
        }

        private static let descriptorJSON =
            #"{"format":"astral.node.descriptor/v2","node_id":"astral-node:1","capabilities":["mesh-peer"],"mesh":{"state":"not_enrolled","owner_binding":{"state":"setup_required","code":"mesh.not_enrolled"}}}"#

        private func writeSecret(_ text: String = "node-secret") throws {
            let data = root.appendingPathComponent("node/home/data")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let file = data.appendingPathComponent("pairing-secret")
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        private func runningController(_ http: FakeNodeHTTP) async throws -> NodeHostController {
            let built = try NodePackTestSupport.build()
            let controller = NodeHostController(environment: environment(http: http))
            controller.packURLText = built.descriptorURL.absoluteString
            await controller.lookUpOffer()
            await controller.install()
            await controller.start()
            await waitFor(controller) { $0 == .running(port: 18_731) }
            return controller
        }

        private func waitFor(
            _ controller: NodeHostController, _ predicate: @escaping (NodeHostController.Phase) -> Bool
        ) async {
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
                (Data(Self.descriptorJSON.utf8), 200),
                (Data(Self.descriptorJSON.utf8), 200),
                (Data(#"{"state":"offer","code":"ABCD-1234","payload":"the-payload"}"#.utf8), 200),
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

            try writeSecret()
            let offerResult = try await controller.requestPairing()
            let offerRequest = try XCTUnwrap(http.requests.last)
            XCTAssertEqual(offerRequest.value(forHTTPHeaderField: "Astral-Pairing-Secret"), "node-secret")
            XCTAssertNil(offerRequest.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(
                offerResult, .offer(NodePairingOffer(code: "ABCD-1234", payload: "the-payload", expiresMs: nil)))
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
                _ = try await controller.requestPairing()
                XCTFail("expected a refusal")
            } catch { XCTAssertEqual(error as? NodePairingError, .meshUnavailable("node_not_running")) }
            controller.packURLText = built.descriptorURL.absoluteString
            await controller.lookUpOffer()
            await controller.install()
            await controller.start()
            await waitFor(controller) { $0 == .running(port: 18_731) }
            http.responses = [
                (Data(#"{"format":"astral.node.descriptor/v2","node_id":"n","capabilities":["chat"]}"#.utf8), 200),
                (Data(#"{"format":"astral.node.descriptor/v2","node_id":"n","capabilities":["chat"]}"#.utf8), 200),
            ]
            do {
                _ = try await controller.requestPairing()
                XCTFail("expected a refusal")
            } catch { XCTAssertEqual(error as? NodePairingError, .meshUnavailable("mesh_peer_unavailable")) }
            await controller.stop()
        }

        func testARetiredOwnerCodeIsAnOrdinaryRefusalThatKeepsTheNodeAndItsData() async throws {
            let http = FakeNodeHTTP()
            let controller = try await runningController(http)
            try writeSecret()
            http.responses = [
                (Data(Self.descriptorJSON.utf8), 200),
                (Data(#"{"detail":"node.legacy_owner"}"#.utf8), 409),
            ]
            do {
                _ = try await controller.requestPairing()
                XCTFail("expected a refusal")
            } catch { XCTAssertEqual(error as? NodePairingError, .refused(status: 409, code: "node.legacy_owner")) }
            XCTAssertTrue(controller.isRunning)
            let secretFile = root.appendingPathComponent("node/home/data/pairing-secret")
            XCTAssertTrue(FileManager.default.fileExists(atPath: secretFile.path))
            await controller.stop()
        }

        func testARotatedSecretIsReadAgainOnceAndAMissingFileStopsTheOffer() async throws {
            let http = FakeNodeHTTP()
            let controller = try await runningController(http)
            do {
                http.responses = [(Data(Self.descriptorJSON.utf8), 200)]
                _ = try await controller.requestPairing()
                XCTFail("expected a refusal")
            } catch { XCTAssertEqual(error as? NodePairingError, .pairingSecretUnavailable) }
            try writeSecret("stale")
            http.responses = [
                (Data(Self.descriptorJSON.utf8), 200),
                (Data(#"{"detail":"node.pairing_secret_required"}"#.utf8), 401),
                (Data(#"{"state":"enrolled","mesh_id":"m1","member_id":"d1"}"#.utf8), 200),
            ]
            let result = try await controller.requestPairing()
            XCTAssertEqual(result, .alreadyJoined(meshId: "m1"))
            http.responses = [
                (Data(Self.descriptorJSON.utf8), 200),
                (Data(#"{"detail":"node.pairing_secret_required"}"#.utf8), 401),
                (Data(#"{"detail":"node.pairing_secret_required"}"#.utf8), 401),
            ]
            do {
                _ = try await controller.requestPairing()
                XCTFail("expected a refusal")
            } catch { XCTAssertEqual(error as? NodePairingError, .pairingSecretRequired) }
            await controller.stop()
        }

        func testEachPairingRefusalHasItsOwnPlainState() {
            let describe = NodeHostController.describePairing
            let errors: [NodePairingError] = [
                .pairingSecretUnavailable, .pairingSecretRequired, .loopbackRequired, .ownerMismatch, .rateLimited,
                .unknownDescriptorFormat, .meshUnavailable("mesh_unavailable"), .meshUnavailable("node_not_running"),
                .meshUnavailable("mesh_peer_unavailable"), .ownerBindingUnavailable, .profileInactive,
                .refused(status: 500, code: ""), .unexpectedResponse, .notLoopback,
            ]
            let texts = errors.compactMap { describe($0) }
            XCTAssertEqual(texts.count, errors.count)
            XCTAssertEqual(Set(texts).count, errors.count - 2)
            XCTAssertEqual(describe(NodePairingError.meshUnavailable("node_not_running")), "Start the node first.")
            XCTAssertEqual(
                describe(NodePairingError.meshUnavailable("kernel_x")), "The node can't join a mesh yet (kernel_x).")
            XCTAssertEqual(
                describe(NodePairingError.rateLimited), "Too many pairing attempts. Wait a minute and try again.")
            XCTAssertEqual(describe(CancellationError()), "The node refused the request.")
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
            let controller = NodeHostController(
                environment: environment(transport: FileTransport(corruptDownload: true)))
            controller.packURLText = built.descriptorURL.absoluteString
            await controller.lookUpOffer()
            await controller.install()
            XCTAssertEqual(controller.phase, .notInstalled)
            XCTAssertEqual(controller.message, "The archive digest doesn't match and the download was discarded.")
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
            XCTAssertEqual(controller.phase, .failed("The node home couldn't be prepared (openssl missing)."))
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
            try encoder.encode(
                NodeRunRecord(
                    pid: child.processIdentifier, port: 18_740, packVersion: "3.11.18-test", startedAt: Date())
            )
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
            try encoder.encode(
                NodeRunRecord(pid: 2_000_000_001, port: 18_741, packVersion: "3.11.18-test", startedAt: Date())
            )
            .write(to: home.appendingPathComponent("run.json"))
            let controller = NodeHostController(environment: environment())
            await controller.refresh()
            XCTAssertEqual(controller.phase, .installed(version: "3.11.18-test"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("run.json").path))
        }

        private struct StalledTransport: NodePackTransport {
            func data(from url: URL, maxBytes: Int) async throws -> Data { try Data(contentsOf: url) }
            func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void)
                async throws
            {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }

        private func pinnedEnvironment(_ built: BuiltPack, transport: NodePackTransport = FileTransport())
            throws -> NodeHostEnvironment
        {
            var result = environment(transport: transport)
            result.defaultPackURL = built.descriptorURL.absoluteString
            result.pinnedDescriptorSha256 = NodePackTestSupport.sha(try Data(contentsOf: built.descriptorURL))
            return result
        }

        func testTheFirstLaunchDownloadsThePinnedPackOnceAndNeverAfterARemoval() async throws {
            let built = try NodePackTestSupport.build()
            let controller = NodeHostController(environment: try pinnedEnvironment(built))
            await controller.installOnFirstLaunch()
            XCTAssertEqual(controller.phase, .installed(version: "3.11.18-test"))
            XCTAssertTrue(defaults.bool(forKey: NodeHostController.autoOfferedKey))

            await controller.remove()
            await controller.installOnFirstLaunch()
            XCTAssertEqual(controller.phase, .notInstalled)
            let next = NodeHostController(environment: try pinnedEnvironment(built))
            await next.installOnFirstLaunch()
            XCTAssertEqual(next.phase, .notInstalled)
        }

        func testTheFirstLaunchDownloadNeedsAPinAnAddressAndAnAvailableBuild() async throws {
            let built = try NodePackTestSupport.build()
            var unpinned = try pinnedEnvironment(built)
            unpinned.pinnedDescriptorSha256 = nil
            var unaddressed = try pinnedEnvironment(built)
            unaddressed.defaultPackURL = ""
            var unavailable = try pinnedEnvironment(built)
            unavailable.available = false
            for candidate in [unpinned, unaddressed, unavailable] {
                let controller = NodeHostController(environment: candidate)
                await controller.installOnFirstLaunch()
                XCTAssertFalse(defaults.bool(forKey: NodeHostController.autoOfferedKey))
                XCTAssertNotEqual(controller.phase, .installed(version: "3.11.18-test"))
            }
        }

        func testAnUnreachableOrMismatchedFirstLaunchOfferExplainsAndDoesNotRetry() async throws {
            let built = try NodePackTestSupport.build()
            var wrongPin = try pinnedEnvironment(built)
            wrongPin.pinnedDescriptorSha256 = String(repeating: "0", count: 64)
            let controller = NodeHostController(environment: wrongPin)
            await controller.installOnFirstLaunch()
            XCTAssertEqual(controller.phase, .notInstalled)
            XCTAssertEqual(controller.message, "The pack description doesn't match the pinned digest.")
            XCTAssertTrue(defaults.bool(forKey: NodeHostController.autoOfferedKey))
            await controller.installOnFirstLaunch()
            let packs = root.appendingPathComponent("node/packs").path
            XCTAssertNil(try? FileManager.default.contentsOfDirectory(atPath: packs))
        }

        func testAnInstalledPackIsNotDownloadedAgainOnFirstLaunch() async throws {
            let built = try NodePackTestSupport.build()
            let first = NodeHostController(environment: try pinnedEnvironment(built))
            first.packURLText = built.descriptorURL.absoluteString
            await first.lookUpOffer()
            await first.install()
            let second = NodeHostController(environment: try pinnedEnvironment(built, transport: StalledTransport()))
            await second.installOnFirstLaunch()
            XCTAssertEqual(second.phase, .installed(version: "3.11.18-test"))
        }

        func testTheFirstLaunchDownloadCanBeCancelled() async throws {
            let built = try NodePackTestSupport.build()
            let stalled = try pinnedEnvironment(built, transport: StalledTransport())
            let controller = NodeHostController(environment: stalled)
            let download = Task { await controller.installOnFirstLaunch() }
            await waitFor(controller) { if case .downloading = $0 { return true } else { return false } }
            controller.cancelInstall()
            await download.value
            XCTAssertEqual(controller.phase, .notInstalled)
            XCTAssertEqual(controller.message, "The download was cancelled.")
            XCTAssertTrue(defaults.bool(forKey: NodeHostController.autoOfferedKey))
        }

        func testTheOldPackIsRemovedOnlyAfterTheNewOneIsHealthy() async throws {
            let launcher = FakeLauncher()
            let controller = NodeHostController(environment: environment(launcher: launcher))
            let packs = root.appendingPathComponent("node/packs").path
            for version in ["one", "two"] {
                let built = try NodePackTestSupport.build(version: version)
                controller.packURLText = built.descriptorURL.absoluteString
                await controller.lookUpOffer()
                await controller.install()
            }
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: packs)), ["one", "two"])
            await controller.start()
            await waitFor(controller) { $0 == .running(port: 18_731) }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, try FileManager.default.contentsOfDirectory(atPath: packs).count > 1 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: packs), ["two"])
            await controller.stop()
        }
    }
#endif
