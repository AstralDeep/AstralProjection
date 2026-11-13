// Checks the node home setup, launch command, pairing client and availability gate with fake installers and HTTP.

#if os(macOS)
    import XCTest

    @testable import AstralCore

    final class FakeNodeHTTP: NodeHTTP, @unchecked Sendable {
        var responses: [(Data, Int)] = []
        private(set) var requests: [URLRequest] = []

        func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            requests.append(request)
            return responses.isEmpty ? (Data(), 500) : responses.removeFirst()
        }
    }

    final class NodeHostSupportTests: XCTestCase {
        private var root: URL!
        private var pack: URL!

        override func setUpWithError() throws {
            root = try NodePackTestSupport.temporaryDirectory()
            pack = root.appendingPathComponent("pack")
        }
        override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

        private func fakeInstaller(_ home: NodeHome, content: String = "ASTRAL_NODE_PROFILE=personal\nKEYCLOAK_CLIENT_ID=x\n")
            -> @Sendable (URL, [String]) throws -> (status: Int32, output: String)
        {
            { script, arguments in
                XCTAssertTrue(script.path.hasSuffix("app/scripts/node/install-personal-node.sh"))
                XCTAssertEqual(arguments, ["--issuer", "https://iam.example/realms/a", "--client-id", "astral-desktop", "--home", home.root.path])
                try content.write(to: home.envFile, atomically: true, encoding: .utf8)
                return (0, "ok")
            }
        }

        func testPrepareCreatesPrivateDirectoriesAndAddsTheLabelOnce() throws {
            let home = NodeHome(root: root.appendingPathComponent("home"))
            for _ in 0..<2 {
                try home.prepare(
                    pack: pack, issuer: "https://iam.example/realms/a", clientId: "astral-desktop", meshLabel: "Sam's Mac",
                    runScript: fakeInstaller(home))
            }
            let env = try String(contentsOf: home.envFile, encoding: .utf8)
            XCTAssertEqual(env.components(separatedBy: "ASTRAL_NODE_MESH_LABEL=").count, 2)
            XCTAssertTrue(env.contains("ASTRAL_NODE_MESH_LABEL=Sam's Mac\n"))
            func mode(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? 0 }
            XCTAssertEqual(mode(home.root), 0o700)
            XCTAssertEqual(mode(home.logs), 0o700)
            XCTAssertEqual(mode(home.envFile), 0o600)
        }

        func testAnExistingLabelIsKeptAndAMissingNewlineIsHandled() throws {
            let home = NodeHome(root: root.appendingPathComponent("home"))
            try home.prepare(
                pack: pack, issuer: "https://iam.example/realms/a", clientId: "astral-desktop", meshLabel: "ignored",
                runScript: fakeInstaller(home, content: "ASTRAL_NODE_MESH_LABEL=Mine"))
            XCTAssertEqual(try String(contentsOf: home.envFile, encoding: .utf8), "ASTRAL_NODE_MESH_LABEL=Mine")
            let other = NodeHome(root: root.appendingPathComponent("other"))
            try other.prepare(
                pack: pack, issuer: "https://iam.example/realms/a", clientId: "astral-desktop", meshLabel: "Mac",
                runScript: { _, _ in
                    try "A=1".write(to: other.envFile, atomically: true, encoding: .utf8)
                    return (0, "")
                })
            XCTAssertEqual(try String(contentsOf: other.envFile, encoding: .utf8), "A=1\nASTRAL_NODE_MESH_LABEL=Mac\n")
        }

        func testAFailingInstallerOrMissingEnvFileIsReported() {
            let home = NodeHome(root: root.appendingPathComponent("home"))
            XCTAssertThrowsError(
                try home.prepare(pack: pack, issuer: "i", clientId: "c", meshLabel: "m", runScript: { _, _ in (2, "boom") })
            ) { XCTAssertEqual($0 as? NodeHostError, .homeSetupFailed("boom")) }
            XCTAssertThrowsError(
                try home.prepare(pack: pack, issuer: "i", clientId: "c", meshLabel: "m", runScript: { _, _ in (0, "silent") })
            ) { XCTAssertEqual($0 as? NodeHostError, .homeSetupFailed("silent")) }
        }

        func testLabelsAreCleanedAndBounded() {
            XCTAssertEqual(NodeHome.safeLabel("A=B\nC"), "ABC")
            XCTAssertEqual(NodeHome.safeLabel("\n="), "Mac node")
            XCTAssertEqual(NodeHome.safeLabel(String(repeating: "x", count: 100)).count, 48)
        }

        func testTheLaunchCommandIsolatesPythonAndPassesNoSecrets() {
            let home = NodeHome(root: root.appendingPathComponent("home"))
            let spec = home.launchSpec(pack: pack, port: 18_800)
            XCTAssertEqual(spec.executable, pack.appendingPathComponent("python/bin/python3.11"))
            XCTAssertEqual(spec.arguments.first, "-I")
            XCTAssertTrue(spec.arguments.contains("18800") && spec.arguments.contains(home.envFile.path))
            XCTAssertEqual(Set(spec.environment.keys), ["PATH", "HOME", "TMPDIR", "LANG"])
            XCTAssertEqual(spec.workingDirectory, pack)
        }

        func testAFreeLoopbackPortCanBeBound() throws {
            let port = try NodeHome.freeLoopbackPort()
            XCTAssertTrue((1024...65_535).contains(port))
        }

        func testAvailabilityRequiresTheDirectDownloadMarkerAndNoSandbox() {
            XCTAssertTrue(NodeHostAvailability.permits(marker: "direct-download", sandboxed: false))
            XCTAssertFalse(NodeHostAvailability.permits(marker: "direct-download", sandboxed: true))
            XCTAssertFalse(NodeHostAvailability.permits(marker: nil, sandboxed: false))
            XCTAssertFalse(NodeHostAvailability.permits(marker: "app-store", sandboxed: false))
            XCTAssertFalse(NodeHostAvailability.current(bundle: Bundle(for: NodeHostSupportTests.self), environment: [:]))
        }

        func testPairingClientReadsTheDescriptorAndTheOffer() async throws {
            let http = FakeNodeHTTP()
            http.responses = [
                (Data(#"{"node_id":"astral-node:1","capabilities":["chat","mesh-peer"],"mesh":{"state":"not_enrolled","mesh_id":null,"member_id":null,"requests":true}}"#.utf8), 200),
                (Data(#"{"pairing":{},"mesh":{"state":"offer","code":"ABCD-1234","payload":"payload-text","expires_ms":1700000000000}}"#.utf8), 200),
            ]
            let client = try NodePairingClient(port: 18_700, http: http)
            let descriptor = try await client.descriptor()
            XCTAssertTrue(descriptor.canJoinMesh)
            XCTAssertEqual(descriptor.mesh?.state, "not_enrolled")
            let result = try await client.pairingOffer(bearer: "tok", label: "Sam's Mac")
            XCTAssertEqual(result, .offer(NodePairingOffer(code: "ABCD-1234", payload: "payload-text", expiresMs: 1_700_000_000_000)))
            let request = http.requests[1]
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:18700/api/node/pairing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["label"] as? String, "Sam's Mac")
            XCTAssertEqual(body["scopes"] as? [String], [])
            let key = try XCTUnwrap(body["device_key"] as? [String: String])
            XCTAssertEqual(Set(key.keys), ["kty", "crv", "x"])
            XCTAssertEqual(key["kty"], "OKP")
            var padded = key["x"]!.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while padded.count % 4 != 0 { padded += "=" }
            XCTAssertEqual(Data(base64Encoded: padded)?.count, 32)
        }

        func testPairingClientReportsJoinedRefusedAndMalformedAnswers() async throws {
            let http = FakeNodeHTTP()
            let client = try NodePairingClient(port: 18_700, http: http)
            http.responses = [(Data(#"{"mesh":{"state":"enrolled","mesh_id":"m1","member_id":"d1"}}"#.utf8), 200)]
            let joined = try await client.pairingOffer(bearer: "t", label: "l")
            XCTAssertEqual(joined, .alreadyJoined(meshId: "m1"))
            http.responses = [(Data(#"{"mesh":{"state":"not_enrolled","error":"kernel_unavailable"}}"#.utf8), 200)]
            await assertThrows(NodePairingError.meshUnavailable("kernel_unavailable")) { _ = try await client.pairingOffer(bearer: "t", label: "l") }
            http.responses = [(Data(), 401)]
            await assertThrows(NodePairingError.unauthorized) { _ = try await client.pairingOffer(bearer: "t", label: "l") }
            http.responses = [(Data(#"{"detail":"node_owner_mismatch"}"#.utf8), 403)]
            await assertThrows(NodePairingError.refused(status: 403, detail: "node_owner_mismatch")) { _ = try await client.pairingOffer(bearer: "t", label: "l") }
            http.responses = [(Data(#"{"no":"mesh"}"#.utf8), 200)]
            await assertThrows(NodePairingError.unexpectedResponse) { _ = try await client.pairingOffer(bearer: "t", label: "l") }
            http.responses = [(Data(#"{"mesh":{"state":"offer","code":"x","payload":""}}"#.utf8), 200)]
            await assertThrows(NodePairingError.unexpectedResponse) { _ = try await client.pairingOffer(bearer: "t", label: "l") }
            http.responses = [(Data("x".utf8), 500)]
            await assertThrows(NodePairingError.unexpectedResponse) { _ = try await client.descriptor() }
            XCTAssertThrowsError(try NodePairingClient(port: 0, http: http)) { XCTAssertEqual($0 as? NodePairingError, .notLoopback) }
        }

        private func assertThrows(_ expected: NodePairingError, _ body: () async throws -> Void) async {
            do {
                try await body()
                XCTFail("expected \(expected)")
            } catch { XCTAssertEqual(error as? NodePairingError, expected) }
        }
    }
#endif
