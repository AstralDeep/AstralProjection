// Tests the durable receipt claim store across relaunch, the gate's foreign-evidence and replay refusals,
// the owner configuration reader, and the host command and file paths refusing drifted or repeated receipts.

#if os(macOS)
    import AstralCore
    import CryptoKit
    import Foundation
    import XCTest
    @testable import AstralDeep

    final class MacComputerReceiptsTests: XCTestCase {
        private func tempDirectory(_ label: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("receipts-" + label + "-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }

        private func workspaceFolder() throws -> String {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url.path
        }

        private func script(_ path: String, body: String = "#!/bin/sh\necho synthetic\n") throws {
            guard FileManager.default.createFile(atPath: path, contents: Data(body.utf8)),
                chmod(path, 0o755) == 0
            else {
                throw ComputerHostError("failed", "The synthetic script could not be prepared.")
            }
        }

        private func mint(
            _ changes: (inout [String: ComputerLetsValue]) -> Void = { _ in }
        ) throws -> (json: String, privateKey: Curve25519.Signing.PrivateKey) {
            let privateKey = Curve25519.Signing.PrivateKey()
            var payload: [String: ComputerLetsValue] = [
                "type": .string(ComputerLetsReceipt.wireType),
                "tenant_id": .string("tenant"),
                "envelope_id": .string("envelope"),
                "config_epoch": .integer(1),
                "receipt_id": .string("receipt_app" + String(Int.random(in: 100_000...999_999))),
                "request_id": .string("request_app01"),
                "warden_id": .string("warden-test"),
                "key_id": .string("warden-test/ed25519-test"),
                "policy_id": .string("policy-app01"),
                "policy_version": .string("v1"),
                "policy_digest": .string("sha256:" + String(repeating: "1", count: 64)),
                "machine_digest": .string("sha256:" + String(repeating: "2", count: 64)),
                "lease_id": .string("lease_app001"),
                "lineage_id": .string("lineage_app1"),
                "subject_id": .string("subject-app1"),
                "executor_audience": .string("mac-host"),
                "transition": .string("act"),
                "source_state": .string("ready"),
                "target_state": .string("ready"),
                "cost": .array([.integer(1)]),
                "resulting_sequence": .integer(1),
                "evidence_digest": .string("sha256:" + String(repeating: "3", count: 64)),
                "nonce": .string("nonce-app-0001"),
                "issued_at_ns": .integer(1_000),
                "expires_at_ns": .integer(2_000),
            ]
            changes(&payload)
            let canonical = try ComputerLetsCanonical.canonicalString(.object(payload))
            let signature = try privateKey.signature(for: Data(canonical.utf8))
            payload["signature"] = .string(ComputerLetsCanonical.base64URLEncode(signature))
            return (try ComputerLetsCanonical.canonicalString(.object(payload)), privateKey)
        }

        private func gate(
            privateKey: Curve25519.Signing.PrivateKey, store: MacComputerReceiptClaimStore,
            audience: String = "mac-host"
        ) throws -> MacComputerReceiptGate {
            MacComputerReceiptGate(
                policy: ComputerLetsExecutorPolicy(audience: audience),
                keys: [
                    try ComputerLetsTrustedKey(
                        wardenId: "warden-test", keyId: "warden-test/ed25519-test",
                        publicKey: privateKey.publicKey.rawRepresentation)
                ], store: store, clock: { 1_500 }, uncertaintyNs: 0)
        }

        private func code(_ work: () throws -> Void) -> String? {
            do {
                try work()
                return nil
            } catch { return (error as? ComputerHostError)?.code }
        }

        private func outcomeCode(_ work: () async throws -> Void) async -> String? {
            do {
                try await work()
                return nil
            } catch { return (error as? ComputerHostError)?.code }
        }

        func testClaimStoreSurvivesRelaunchAndRefusesSecondClaims() throws {
            let directory = try tempDirectory("store")
            let (json, _) = try mint()
            let receipt = try ComputerLetsReceipt(json: json)
            let first = try MacComputerReceiptClaimStore(directory: directory, identity: "identity-a")
            try first.claim(receipt, claimedAtNs: 1_234)
            let claimFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertEqual(claimFiles.count, 2)
            let claimName = try XCTUnwrap(claimFiles.first { $0.hasPrefix("claim-") })
            let stored = try XCTUnwrap(
                FileManager.default.contents(atPath: directory.appendingPathComponent(claimName)))
            let record = try JSONSerialization.jsonObject(with: stored) as? [String: Any]
            XCTAssertEqual(record?["receipt_id"] as? String, receipt.receiptId)
            XCTAssertEqual(record?["claimed_at_ns"] as? Int, 1_234)
            let relaunched = try MacComputerReceiptClaimStore(directory: directory, identity: "identity-a")
            XCTAssertEqual(
                code { try relaunched.claim(receipt, claimedAtNs: 1_234) }, "receipt_replayed")
            let (second, _) = try mint { $0["receipt_id"] = .string("receipt_app999999") }
            XCTAssertNoThrow(try relaunched.claim(try ComputerLetsReceipt(json: second), claimedAtNs: 1_235))
            XCTAssertThrowsError(
                try MacComputerReceiptClaimStore(directory: directory, identity: "identity-b")
            ) { error in
                XCTAssertEqual((error as? ComputerHostError)?.code, "receipt_store_failed")
            }
        }

        func testGateRefusesForeignEvidenceReplaysAndStaleReceipts() throws {
            let directory = try tempDirectory("gate")
            let privateKey = Curve25519.Signing.PrivateKey()
            let evidence = "sha256:" + String(repeating: "a", count: 64)
            let (json, _) = try mint { $0["evidence_digest"] = .string(evidence) }
            let receiptGate = try gate(
                privateKey: privateKey, store: try .init(directory: directory, identity: "i"))
            let receipt = try receiptGate.verify(json, evidence: evidence)
            XCTAssertEqual(
                code { _ = try receiptGate.verify(json, evidence: evidence + "0") }, "plan_drift")
            XCTAssertNoThrow(try receiptGate.claim(receipt))
            XCTAssertEqual(code { try receiptGate.claim(receipt) }, "receipt_replayed")
            let (stale, _) = try mint {
                $0["receipt_id"] = .string("receipt_app888888")
                $0["expires_at_ns"] = .integer(1_100)
            }
            XCTAssertEqual(code { _ = try receiptGate.verify(stale, evidence: evidence) }, "receipt_refused")
            let (foreign, _) = try mint {
                $0["receipt_id"] = .string("receipt_app777777")
                $0["executor_audience"] = .string("other-host")
            }
            let otherGate = try MacComputerReceiptGate(
                policy: ComputerLetsExecutorPolicy(audience: "mac-host"),
                keys: [
                    try ComputerLetsTrustedKey(
                        wardenId: "warden-test", keyId: "warden-test/ed25519-test",
                        publicKey: privateKey.publicKey.rawRepresentation)
                ], store: try .init(directory: directory, identity: "i"), clock: { 1_500 }, uncertaintyNs: 0)
            XCTAssertEqual(
                code { _ = try otherGate.verify(foreign, evidence: evidence) }, "receipt_refused")
        }

        func testConfigurationReaderBuildsAGateAndRefusesBrokenConfiguration() throws {
            let suite = "receipts-config-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            let reader = MacComputerReceiptConfigurationReader(defaults: defaults)
            XCTAssertNil(reader.read())
            let privateKey = Curve25519.Signing.PrivateKey()
            let material = ComputerLetsCanonical.base64URLEncode(privateKey.publicKey.rawRepresentation)
            let valid =
                "{\"audience\":\"mac-host\",\"max_clock_uncertainty_ns\":60000000000,\"uncertainty_ns\":1000000000,"
                + "\"tenant_id\":\"tenant\",\"config_epoch\":1,\"policy_digests\":[\"sha256:"
                + String(repeating: "1", count: 64) + "],\"wardens\":[{\"warden_id\":\"warden-test\","
                + "\"key_id\":\"warden-test/ed25519-test\",\"public_key\":\"\(material)\"}]}"
            defaults.set(valid, forKey: MacComputerReceiptConfigurationReader.configurationKey)
            let loaded = reader.read()
            XCTAssertNotNil(loaded)
            XCTAssertEqual(loaded?.policy.audience, "mac-host")
            XCTAssertEqual(loaded?.policy.tenantId, "tenant")
            XCTAssertEqual(loaded?.uncertaintyNs, 1_000_000_000)
            let broken = [
                "{ not json",
                "{\"wardens\":[]}",
                "{\"audience\":\"mac-host\"}",
                "{\"audience\":\"mac-host\",\"max_clock_uncertainty_ns\":1,\"uncertainty_ns\":2,\"wardens\":"
                    + "[{\"warden_id\":\"w\",\"key_id\":\"k\",\"public_key\":\"\(material)\"}]}",
                "{\"audience\":\"mac-host\",\"wardens\":[{\"warden_id\":\"w\",\"key_id\":\"k\","
                    + "\"public_key\":\"AAAA\"}]}",
                "{\"audience\":\"mac-host\",\"policy_digests\":[\"md5:zz\"],\"wardens\":[{\"warden_id\":\"w\","
                    + "\"key_id\":\"k\",\"public_key\":\"\(material)\"}]}",
            ]
            for configuration in broken {
                defaults.set(configuration, forKey: MacComputerReceiptConfigurationReader.configurationKey)
                XCTAssertNil(reader.read(), configuration)
            }
        }

        func testRunCommandWithReceiptRunsOnceAndRefusesRepeatsAndDrift() async throws {
            let root = try workspaceFolder()
            let tool = root + "/tool.sh"
            try script(tool)
            let storeDirectory = try tempDirectory("commands")
            let privateKey = Curve25519.Signing.PrivateKey()
            let plan = try ComputerCommandPlan.resolve(
                command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
            let changes: (inout [String: ComputerLetsValue]) -> Void = {
                $0["evidence_digest"] = .string(plan.digest)
            }
            var receiptJSON = try mint(changes).json
            let claimStore = try MacComputerReceiptClaimStore(directory: storeDirectory, identity: "commands")
            let receiptGate = try gate(privateKey: privateKey, store: claimStore)
            let spawner = MacComputerFakeSpawner()
            let commands = MacComputerCommands(
                spawner: spawner, clock: MacComputerFakeClock(),
                inherited: ["HOME": "/Users/synthetic", "PATH": "/inherited", "LANG": "C"],
                loginPath: { "/usr/bin:/bin" }, receipts: { receiptGate })
            func command(_ receipt: String?) throws -> ComputerHostRequest {
                var args: [String: JSONValue] = [
                    "argv": .array([.string(tool)]), "cwd": .string(root), "background": .bool(true),
                ]
                if let receipt { args["receipt"] = .string(receipt) }
                return try ComputerHostRequest(
                    json: .object([
                        "type": .string("computer_request"),
                        "request_id": .string("creq_" + String(repeating: "d", count: 32)),
                        "session_id": .string("11111111-1111-4111-8111-111111111111"), "verb": .string("run_command"),
                        "args": .object(args), "deadline_ms": .number(600000),
                    ]))
            }
            let first = try await commands.run(
                try command(receiptJSON), session: "11111111-1111-4111-8111-111111111111", roots: [root],
                authorize: {})
            XCTAssertNotNil(first["job_id"])
            XCTAssertEqual(spawner.plans.count, 1)
            let outcome1 = await outcomeCode {
                    try await commands.run(
                    try command(receiptJSON), session: "11111111-1111-4111-8111-111111111111", roots: [root],
                    authorize: {})
            }
            XCTAssertEqual(outcome1, "receipt_replayed")
            XCTAssertEqual(spawner.plans.count, 1)
            try "#!/bin/sh\necho changed\n".write(toFile: tool, atomically: true, encoding: .utf8)
            (receiptJSON, _) = try mint(changes)
            let outcome2 = await outcomeCode {
                    try await commands.run(
                    try command(receiptJSON), session: "11111111-1111-4111-8111-111111111111", roots: [root],
                    authorize: {})
            }
            XCTAssertEqual(outcome2, "plan_drift")
            XCTAssertEqual(spawner.plans.count, 1)
            let unconfigured = MacComputerCommands(
                spawner: spawner, clock: MacComputerFakeClock(),
                inherited: ["HOME": "/Users/synthetic", "PATH": "/inherited", "LANG": "C"],
                loginPath: { "/usr/bin:/bin" }, receipts: nil)
            let outcome3 = await outcomeCode {
                    try await unconfigured.run(
                    try command(receiptJSON), session: "11111111-1111-4111-8111-111111111111", roots: [root],
                    authorize: {})
            }
            XCTAssertEqual(outcome3, "receipt_refused")
            XCTAssertEqual(spawner.plans.count, 1)
        }

        func testPrepareReturnsTheResolvedPlanForReview() async throws {
            let root = try workspaceFolder()
            let tool = root + "/tool.sh"
            try script(tool)
            let commands = MacComputerCommands(
                spawner: MacComputerFakeSpawner(), clock: MacComputerFakeClock(),
                inherited: ["HOME": "/Users/synthetic", "PATH": "/inherited", "LANG": "C"],
                loginPath: { "/usr/bin:/bin" })
            let request = try ComputerHostRequest(
                json: .object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(repeating: "e", count: 32)),
                    "session_id": .string("11111111-1111-4111-8111-111111111111"),
                    "verb": .string("prepare_run_command"),
                    "args": .object(["argv": .array([.string(tool)]), "cwd": .string(root)]),
                    "deadline_ms": .number(5000),
                ]))
            let payload = try await commands.prepare(request, roots: [root], exclusions: .defaults)
            XCTAssertEqual(payload["executable"], .string(tool))
            let expected = try ComputerCommandPlan.resolve(
                command: nil, argv: [tool], cwd: root, roots: [root], path: "/usr/bin:/bin")
            XCTAssertEqual(payload["plan_digest"], .string(expected.digest))
            let unreadable = root + "/missing.sh"
            let failure = try ComputerHostRequest(
                json: .object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(repeating: "f", count: 32)),
                    "session_id": .string("11111111-1111-4111-8111-111111111111"),
                    "verb": .string("prepare_run_command"),
                    "args": .object(["argv": .array([.string(unreadable)]), "cwd": .string(root)]),
                    "deadline_ms": .number(5000),
                ]))
            let outcome4 = await outcomeCode {
                    try await commands.prepare(failure, roots: [root], exclusions: .defaults)
            }
            XCTAssertEqual(outcome4, "not_found")
        }

        func testFileVerbsRefuseReplayedReceiptsAndReplacedFolders() async throws {
            let root = try workspaceFolder()
            let workspace = try ComputerWorkspace(root: root)
            let storeDirectory = try tempDirectory("files")
            let privateKey = Curve25519.Signing.PrivateKey()
            let claimStore = try MacComputerReceiptClaimStore(directory: storeDirectory, identity: "files")
            let receiptGate = try gate(privateKey: privateKey, store: claimStore)
            let system = MacComputerTestSystem()
            let driver = MacComputerDriver(marker: 7, system: system, receipts: { receiptGate })
            let plan = try ComputerFilePlan(
                verb: "write_file", path: root + "/notes.md", root: root, rootIdentity: workspace.rootIdentity.digest)
            let (writeReceipt, _) = try mint { $0["evidence_digest"] = .string(plan.digest) }
            func fileRequest(_ verb: String, _ receipt: String?) throws -> ComputerHostRequest {
                var args: [String: JSONValue] = ["path": .string(root + "/notes.md")]
                if verb == "write_file" { args["content"] = .string("synthetic") }
                if let receipt { args["receipt"] = .string(receipt) }
                return try ComputerHostRequest(
                    json: .object([
                        "type": .string("computer_request"),
                        "request_id": .string("creq_" + String(repeating: "b", count: 32)),
                        "session_id": .string("11111111-1111-4111-8111-111111111111"), "verb": .string(verb),
                        "args": .object(args), "deadline_ms": .number(30000),
                    ]))
            }
            let written = try await driver.execute(
                try fileRequest("write_file", writeReceipt), workspaces: [workspace], authorize: {})
            XCTAssertEqual(written["bytes"], .number(Double("synthetic".utf8.count)))
            let outcome5 = await outcomeCode {
                    try await driver.execute(
                    try fileRequest("write_file", writeReceipt), workspaces: [workspace], authorize: {})
            }
            XCTAssertEqual(outcome5, "receipt_replayed")
            XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: root + "/notes.md")), "synthetic")
            let deletion = try ComputerFilePlan(
                verb: "delete_path", path: root + "/notes.md", root: root,
                rootIdentity: workspace.rootIdentity.digest)
            let (deleteReceipt, _) = try mint { $0["evidence_digest"] = .string(deletion.digest) }
            let wrongEvidence = try mint {
                $0["receipt_id"] = .string("receipt_app555555")
                $0["evidence_digest"] = .string("sha256:" + String(repeating: "b", count: 64))
            }.json
            let outcome6 = await outcomeCode {
                    try await driver.execute(
                    try fileRequest("delete_path", wrongEvidence), workspaces: [workspace], authorize: {})
            }
            XCTAssertEqual(outcome6, "plan_drift")
            XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: root + "/notes.md"))
            _ = try await driver.execute(
                try fileRequest("delete_path", deleteReceipt), workspaces: [workspace], authorize: {})
            XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: root + "/notes.md"))
            let replacement = try ComputerFilePlan(
                verb: "write_file", path: root + "/notes.md", root: root,
                rootIdentity: workspace.rootIdentity.digest)
            let (replacementReceipt, _) = try mint { $0["evidence_digest"] = .string(replacement.digest) }
            try FileManager.default.removeItem(atPath: root)
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let outcome7 = await outcomeCode {
                    try await driver.execute(
                    try fileRequest("write_file", replacementReceipt), workspaces: [workspace],
                    authorize: {})
            }
            XCTAssertEqual(outcome7, "plan_drift")
            XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: root + "/notes.md"))
        }
    }
#endif
