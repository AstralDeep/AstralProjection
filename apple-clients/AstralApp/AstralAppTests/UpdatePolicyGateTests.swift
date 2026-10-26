// Verifies the signed minimum-build policy gate with throwaway Ed25519 keys, tampered fixtures and a stubbed network.
// Every rejection path must leave the app connecting normally and report only signature, parse or rollback faults.

#if os(macOS)
    import CryptoKit
    import XCTest
    @testable import AstralDeep

    private nonisolated final class StubFetcher: UpdatePolicyFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String: Result<Data, Error>] = [:]
        private var seen: [String] = []
        struct Down: Error {}

        func serve(_ name: String, _ data: Data) { set(name, .success(data)) }
        func fail(_ name: String) { set(name, .failure(Down())) }
        private func set(_ name: String, _ value: Result<Data, Error>) {
            lock.lock()
            responses[name] = value
            lock.unlock()
        }
        var requests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
        func body(of url: URL) async throws -> Data {
            lock.lock()
            seen.append(url.lastPathComponent)
            let result = responses[url.lastPathComponent]
            lock.unlock()
            guard let result else { throw Down() }
            return try result.get()
        }
    }

    private nonisolated final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    @MainActor
    final class UpdatePolicyGateTests: XCTestCase {
        private let key = Curve25519.Signing.PrivateKey()
        private let clock = Clock()
        private let fetcher = StubFetcher()

        private func defaults() -> UserDefaults {
            let name = "policy-tests-" + UUID().uuidString
            let value = UserDefaults(suiteName: name)!
            addTeardownBlock { value.removePersistentDomain(forName: name) }
            return value
        }

        private func gate(build: Int = 70, defaults: UserDefaults? = nil) throws -> UpdatePolicyGate {
            let clock = self.clock
            return try XCTUnwrap(
                UpdatePolicyGate(
                    publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(), installedBuild: build,
                    fetcher: fetcher, defaults: defaults ?? self.defaults(), now: { clock.date }))
        }

        private func policy(
            minimum: Int = 71, serial: Int = 3, expires: String = "2027-06-01T00:00:00Z",
            message: String = "Update required", schema: Int = 1
        ) -> String {
            "{\"schemaVersion\": \(schema), \"minimumBuild\": \(minimum), \"serial\": \(serial), "
                + "\"expires\": \"\(expires)\", \"message\": \"\(message)\"}"
        }

        private func publish(_ json: String, signedBy signer: Curve25519.Signing.PrivateKey? = nil) throws {
            let bytes = Data(json.utf8)
            let signature = try (signer ?? key).signature(for: bytes)
            fetcher.serve("mac-update-policy.json", bytes)
            fetcher.serve("mac-update-policy.json.sig", Data((signature.base64EncodedString() + "\n").utf8))
        }

        func testBuildBelowMinimumIsBlockedWithTheSignedMessage() async throws {
            try publish(policy(minimum: 71, message: "Install 1.9.1 to continue"))
            let outcome = await (try gate(build: 70)).evaluate()
            XCTAssertEqual(
                outcome,
                .required(UpdateRequirement(minimumBuild: 71, installedBuild: 70, message: "Install 1.9.1 to continue"))
            )
        }

        func testCoordinatorEnforcesTheRequirementAndRecordsReportableFailures() async throws {
            let coordinator = UpdateCoordinator(isBusy: { false }, defaults: defaults())
            try publish(policy(minimum: 71))
            let required = await coordinator.enforce(try gate(build: 70))
            XCTAssertEqual(
                required, UpdateRequirement(minimumBuild: 71, installedBuild: 70, message: "Update required"))
            XCTAssertNil(coordinator.policyFailure)
            try publish(policy(minimum: 99), signedBy: Curve25519.Signing.PrivateKey())
            let refused = await coordinator.enforce(try gate(build: 70))
            XCTAssertNil(refused)
            XCTAssertEqual(coordinator.policyFailure, UpdatePolicyFailure.signature.summary)
            let skipped = await coordinator.enforce(nil)
            XCTAssertNil(skipped)
            XCTAssertEqual(coordinator.policyFailure, UpdatePolicyFailure.signature.summary)
            try publish(policy(minimum: 70))
            let recovered = await coordinator.enforce(try gate(build: 70))
            XCTAssertNil(recovered)
            XCTAssertNil(coordinator.policyFailure)
        }

        func testBuildAtOrAboveMinimumConnects() async throws {
            try publish(policy(minimum: 70))
            let atMinimum = try gate(build: 70)
            let outcome = await atMinimum.evaluate()
            XCTAssertEqual(outcome, .allowed)
            XCTAssertNil(atMinimum.lastFailure)
            let newer = await (try gate(build: 71)).evaluate()
            XCTAssertEqual(newer, .allowed)
        }

        func testTamperedPolicyBytesFailTheSignatureAndConnect() async throws {
            let original = policy(minimum: 99)
            let signature = try key.signature(for: Data(original.utf8))
            fetcher.serve("mac-update-policy.json", Data(original.replacingOccurrences(of: "99", with: "98").utf8))
            fetcher.serve("mac-update-policy.json.sig", Data(signature.base64EncodedString().utf8))
            let subject = try gate()
            let outcome = await subject.evaluate()
            XCTAssertEqual(outcome, .allowed)
            XCTAssertEqual(subject.lastFailure, .signature)
        }

        func testPolicySignedByAnotherKeyIsRefused() async throws {
            try publish(policy(minimum: 99), signedBy: Curve25519.Signing.PrivateKey())
            let subject = try gate()
            let outcome = await subject.evaluate()
            XCTAssertEqual(outcome, .allowed)
            XCTAssertEqual(subject.lastFailure, .signature)
        }

        func testMalformedSignatureTextIsRefused() async throws {
            for text in ["not base64!!", Data(count: 10).base64EncodedString(), ""] {
                fetcher.serve("mac-update-policy.json", Data(policy().utf8))
                fetcher.serve("mac-update-policy.json.sig", Data(text.utf8))
                let subject = try gate()
                let outcome = await subject.evaluate()
                XCTAssertEqual(outcome, .allowed)
                XCTAssertEqual(subject.lastFailure, .signature)
            }
        }

        func testOversizedSignatureIsRefused() async throws {
            fetcher.serve("mac-update-policy.json", Data(policy().utf8))
            fetcher.serve("mac-update-policy.json.sig", Data(repeating: 65, count: UpdatePolicyGate.signatureLimit + 1))
            let subject = try gate()
            _ = await subject.evaluate()
            XCTAssertEqual(subject.lastFailure, .signature)
        }

        func testSignedButUnreadablePolicyReportsParseFailure() async throws {
            for json in [
                "{", policy(schema: 2), policy(minimum: 0), policy(expires: "tomorrow"),
                "{\"schemaVersion\":1,\"minimumBuild\":71}",
            ] {
                try publish(json)
                let subject = try gate()
                let outcome = await subject.evaluate()
                XCTAssertEqual(outcome, .allowed, json)
                XCTAssertEqual(subject.lastFailure, .parse, json)
            }
        }

        func testOversizedPolicyReportsParseFailure() async throws {
            try publish(policy(message: String(repeating: "x", count: UpdatePolicyGate.policyLimit)))
            let subject = try gate()
            _ = await subject.evaluate()
            XCTAssertEqual(subject.lastFailure, .parse)
        }

        func testExpiredPolicyConnectsWithoutReportingAFailure() async throws {
            try publish(policy(minimum: 99, expires: "2020-01-01T00:00:00Z"))
            let subject = try gate()
            let outcome = await subject.evaluate()
            XCTAssertEqual(outcome, .allowed)
            XCTAssertNil(subject.lastFailure)
        }

        func testUnreachablePolicyConnectsWithoutReportingAFailure() async throws {
            fetcher.fail("mac-update-policy.json")
            let subject = try gate()
            let outcome = await subject.evaluate()
            XCTAssertEqual(outcome, .allowed)
            XCTAssertNil(subject.lastFailure)
            XCTAssertEqual(fetcher.requests, ["mac-update-policy.json"])
        }

        func testMissingSignatureForAPublishedPolicyIsAFailure() async throws {
            fetcher.serve("mac-update-policy.json", Data(policy(minimum: 99).utf8))
            fetcher.fail("mac-update-policy.json.sig")
            let subject = try gate()
            let outcome = await subject.evaluate()
            XCTAssertEqual(outcome, .allowed)
            XCTAssertEqual(subject.lastFailure, .signature)
        }

        func testLowerSerialThanOneAlreadySeenIsTreatedAsRollback() async throws {
            let store = defaults()
            try publish(policy(minimum: 70, serial: 5))
            let first = await (try gate(build: 70, defaults: store)).evaluate()
            XCTAssertEqual(first, .allowed)
            clock.advance(UpdatePolicyGate.cacheLifetime + 60)
            try publish(policy(minimum: 99, serial: 4))
            let replay = try gate(build: 70, defaults: store)
            let outcome = await replay.evaluate()
            XCTAssertEqual(outcome, .allowed)
            XCTAssertEqual(replay.lastFailure, .rollback)
        }

        func testEqualOrHigherSerialIsAccepted() async throws {
            let store = defaults()
            try publish(policy(minimum: 70, serial: 5))
            _ = await (try gate(build: 70, defaults: store)).evaluate()
            clock.advance(UpdatePolicyGate.cacheLifetime + 60)
            try publish(policy(minimum: 71, serial: 5))
            let equal = await (try gate(build: 70, defaults: store)).evaluate()
            XCTAssertEqual(
                equal, .required(UpdateRequirement(minimumBuild: 71, installedBuild: 70, message: "Update required")))
            clock.advance(UpdatePolicyGate.cacheLifetime + 60)
            try publish(policy(minimum: 72, serial: 6))
            let higher = await (try gate(build: 70, defaults: store)).evaluate()
            XCTAssertEqual(
                higher, .required(UpdateRequirement(minimumBuild: 72, installedBuild: 70, message: "Update required")))
            XCTAssertEqual(store.integer(forKey: UpdatePolicyGate.serialKey), 6)
        }

        func testVerifiedPolicyIsCachedForTwentyFourHours() async throws {
            let store = defaults()
            try publish(policy(minimum: 71))
            let first = try gate(build: 70, defaults: store)
            _ = await first.evaluate()
            XCTAssertEqual(fetcher.requests.count, 2)
            clock.advance(UpdatePolicyGate.cacheLifetime - 60)
            fetcher.fail("mac-update-policy.json")
            let cached = await (try gate(build: 70, defaults: store)).evaluate()
            XCTAssertEqual(
                cached, .required(UpdateRequirement(minimumBuild: 71, installedBuild: 70, message: "Update required")))
            XCTAssertEqual(fetcher.requests.count, 2)
            clock.advance(120)
            let stale = try gate(build: 70, defaults: store)
            let outcome = await stale.evaluate()
            XCTAssertEqual(outcome, .allowed)
            XCTAssertEqual(fetcher.requests.count, 3)
        }

        func testCacheIsReverifiedAndIgnoredWhenTamperedOrExpired() async throws {
            let store = defaults()
            try publish(policy(minimum: 71, expires: "2027-01-20T00:00:00Z"))
            _ = await (try gate(build: 70, defaults: store)).evaluate()
            let requestsAfterFirst = fetcher.requests.count

            let cacheData = try XCTUnwrap(store.data(forKey: UpdatePolicyGate.cacheKey))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: cacheData) as? [String: Any])
            object["policy"] = Data(policy(minimum: 1).utf8).base64EncodedString()
            store.set(try JSONSerialization.data(withJSONObject: object), forKey: UpdatePolicyGate.cacheKey)
            fetcher.fail("mac-update-policy.json")
            let tampered = await (try gate(build: 70, defaults: store)).evaluate()
            XCTAssertEqual(tampered, .allowed)
            XCTAssertGreaterThan(fetcher.requests.count, requestsAfterFirst)

            try publish(policy(minimum: 71, expires: "2027-01-20T00:00:00Z"))
            _ = await (try gate(build: 70, defaults: store)).evaluate()
            clock.advance(60 * 60 * 24 * 365)
            let expired = await (try gate(build: 70, defaults: store)).evaluate()
            XCTAssertEqual(expired, .allowed)
        }

        func testCacheStampedInTheFutureIsIgnored() async throws {
            let store = defaults()
            try publish(policy(minimum: 71))
            _ = await (try gate(build: 70, defaults: store)).evaluate()
            let count = fetcher.requests.count
            clock.advance(-3600)
            _ = await (try gate(build: 70, defaults: store)).evaluate()
            XCTAssertGreaterThan(fetcher.requests.count, count)
        }

        func testFailureStateResetsOnTheNextEvaluation() async throws {
            let subject = try gate()
            try publish(policy(minimum: 99), signedBy: Curve25519.Signing.PrivateKey())
            _ = await subject.evaluate()
            XCTAssertEqual(subject.lastFailure, .signature)
            try publish(policy(minimum: 70))
            _ = await subject.evaluate()
            XCTAssertNil(subject.lastFailure)
        }

        func testControlCharactersAndEmptyMessagesAreCleaned() async throws {
            try publish(policy(message: "Update\\nnow\\u0007"))
            let cleaned = await (try gate()).evaluate()
            XCTAssertEqual(
                cleaned, .required(UpdateRequirement(minimumBuild: 71, installedBuild: 70, message: "Updatenow")))
            try publish(policy(message: ""))
            let empty = await (try gate()).evaluate()
            XCTAssertEqual(
                empty, .required(UpdateRequirement(minimumBuild: 71, installedBuild: 70, message: "Update required")))
        }

        func testFailureSummariesAndReportability() {
            XCTAssertEqual(
                Set(["signature", "parse", "rollback"]),
                Set(
                    [UpdatePolicyFailure.unreachable, .expired, .signature, .parse, .rollback].filter(\.reportable).map(
                        \.rawValue)))
            for failure in [UpdatePolicyFailure.unreachable, .expired, .signature, .parse, .rollback] {
                XCTAssertFalse(failure.summary.isEmpty)
            }
        }

        func testInitRejectsUnusableKeysAndBuilds() {
            let valid = key.publicKey.rawRepresentation.base64EncodedString()
            XCTAssertNil(UpdatePolicyGate(publicKeyBase64: "###", installedBuild: 70))
            XCTAssertNil(UpdatePolicyGate(publicKeyBase64: Data(count: 5).base64EncodedString(), installedBuild: 70))
            XCTAssertNil(UpdatePolicyGate(publicKeyBase64: valid, installedBuild: 0))
            XCTAssertNotNil(UpdatePolicyGate(publicKeyBase64: " \(valid)\n", installedBuild: 70))
        }

        private func bundle(_ info: [String: Any]) throws -> Bundle {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
            let contents = root.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return try XCTUnwrap(Bundle(url: root))
        }

        func testBundleGateRequiresTheDirectDownloadMarkerKeyAndBuild() throws {
            let valid = key.publicKey.rawRepresentation.base64EncodedString()
            let full: [String: Any] = [
                "CFBundleIdentifier": "fixture.updates", "ASTRALDistribution": "direct-download",
                "SUPublicEDKey": valid, "CFBundleVersion": "70",
            ]
            XCTAssertNotNil(UpdatePolicyGate(bundle: try bundle(full), fetcher: fetcher))
            for missing in ["ASTRALDistribution", "SUPublicEDKey", "CFBundleVersion"] {
                var info = full
                info[missing] = nil
                XCTAssertNil(UpdatePolicyGate(bundle: try bundle(info), fetcher: fetcher), missing)
            }
            var store = full
            store["ASTRALDistribution"] = ""
            XCTAssertNil(UpdatePolicyGate(bundle: try bundle(store), fetcher: fetcher))
            var badBuild = full
            badBuild["CFBundleVersion"] = "seventy"
            XCTAssertNil(UpdatePolicyGate(bundle: try bundle(badBuild), fetcher: fetcher))
        }
    }

    private nonisolated final class PolicyURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (status, data) = Self.handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @MainActor
    final class UpdatePolicyHTTPTests: XCTestCase {
        private func http() -> UpdatePolicyHTTP {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PolicyURLProtocol.self]
            return UpdatePolicyHTTP(session: URLSession(configuration: configuration), timeout: 3)
        }

        override func tearDown() {
            PolicyURLProtocol.handler = nil
            super.tearDown()
        }

        func testOkResponseReturnsBodyWithNoStoreRequestHeaders() async throws {
            var captured: URLRequest?
            PolicyURLProtocol.handler = { request in
                captured = request
                return (200, Data("body".utf8))
            }
            let data = try await http().body(of: UpdatePolicyGate.policyURL)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "body")
            XCTAssertEqual(captured?.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(captured?.timeoutInterval, 3)
        }

        func testNonOkStatusAndPlainHTTPAreRejected() async throws {
            PolicyURLProtocol.handler = { _ in (404, Data()) }
            do {
                _ = try await http().body(of: UpdatePolicyGate.policyURL)
                XCTFail("404 must be rejected")
            } catch {}
            PolicyURLProtocol.handler = { _ in (200, Data("x".utf8)) }
            do {
                _ = try await http().body(of: URL(string: "http://astraldeep.github.io/data/mac-update-policy.json")!)
                XCTFail("cleartext must be rejected")
            } catch {}
        }

        func testPolicyURLPointsAtTheDownloadsSite() {
            XCTAssertEqual(
                UpdatePolicyGate.policyURL.absoluteString, "https://astraldeep.github.io/data/mac-update-policy.json")
        }
    }
#endif
