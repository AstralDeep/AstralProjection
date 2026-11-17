// Runs every committed execution policy vector through ExecPolicy, ExecBackends and ExecSeatbeltProfile: validation codes, digests, selection results, context errors and the Seatbelt text byte for byte.
// The vectors in Fixtures/exec/exec-policy-v1.json are a copy of Deep's specs/106-sign-in-free-clients/contracts/vectors/exec-policy-v1.json at Deep commit a2a561d1, and the committed copies are pinned by SHA-256 so a drift fails here.

import CryptoKit
import XCTest

@testable import AstralCore

enum ExecVectors {
    static func fixtureURL(_ name: String, _ ext: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "exec") else {
            preconditionFailure("missing fixture \(name).\(ext)")
        }
        return url
    }

    static let document: ExecJSON = {
        do {
            return try ExecJSON.parse(Data(contentsOf: fixtureURL("exec-policy-v1", "json")))
        } catch {
            preconditionFailure("unreadable vectors: \(error)")
        }
    }()

    static func cases(_ key: String) -> [ExecJSON] { document[key]?.arrayValue ?? [] }

    static func name(_ item: ExecJSON) -> String { item["name"]?.stringValue ?? "?" }

    static func data(hex: String) -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes)
    }

    static let minimalPolicy: ExecJSON = cases("validation").first { name($0) == "minimal_valid" }?["policy"] ?? .null
}

final class ExecPolicyTests: XCTestCase {
    func testEveryValidationVectorGivesItsCodeAndDigest() throws {
        let cases = ExecVectors.cases("validation")
        XCTAssertEqual(cases.count, 158)
        for item in cases {
            let platform = item["platform"]?.stringValue
            let expected = item["code"]?.stringValue ?? ""
            let label = ExecVectors.name(item)
            do {
                let policy: ExecPolicy
                if let policyDocument = item["policy"] {
                    policy = try ExecPolicy(document: policyDocument, platform: platform)
                } else if let raw = item["raw"]?.stringValue {
                    policy = try ExecPolicy(json: Data(raw.utf8), platform: platform)
                } else {
                    policy = try ExecPolicy(json: ExecVectors.data(hex: item["bytes_hex"]?.stringValue ?? ""), platform: platform)
                }
                XCTAssertEqual(expected, "ok", label)
                if let digest = item["digest"]?.stringValue { XCTAssertEqual(policy.digest, digest, label) }
            } catch let error as ExecPolicyError {
                XCTAssertEqual(error.code, expected, label)
            }
        }
    }

    func testSelectionVectors() throws {
        for item in ExecVectors.cases("selection") {
            let label = ExecVectors.name(item)
            let policy = try ExecPolicy(document: item["policy"] ?? .null, platform: "linux")
            let facts = try ExecFacts(json: item["facts"] ?? .null)
            let dataDirectory = item["data_dir"]?.stringValue ?? ""
            let expected = item["result"] ?? .null
            do {
                let selection = try ExecBackends.select(policy: policy, facts: facts, dataDirectory: dataDirectory)
                switch selection {
                case .backend(let backend):
                    XCTAssertEqual(
                        try expected.canonicalData(),
                        try ExecJSON.object([("backend", .string(backend.rawValue)), ("ok", .bool(true))]).canonicalData(), label)
                case .refused(let refusal):
                    XCTAssertEqual(try expected.canonicalData(), try refusal.json.canonicalData(), label)
                }
            } catch let error as ExecPolicyError {
                XCTAssertEqual(expected["policy_error"]?.stringValue, error.code, label)
            }
        }
    }

    func testContextErrorVectors() throws {
        let cases = ExecVectors.cases("context_errors")
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let label = ExecVectors.name(item)
            let platform = item["facts"]?["platform"]?.stringValue ?? "linux"
            let policy = try ExecPolicy(document: ExecVectors.minimalPolicy, platform: platform)
            XCTAssertThrowsError(
                try ExecBackends.select(
                    policy: policy, facts: try ExecFacts(json: item["facts"] ?? .null),
                    dataDirectory: item["data_dir"]?.stringValue ?? ""), label
            ) { XCTAssertTrue($0 is ExecContextError, "\(label): \($0)") }
        }
    }

    func testProfileVectorsMatchByteForByte() throws {
        let cases = ExecVectors.cases("profiles")
        XCTAssertEqual(cases.count, 5)
        for item in cases {
            let label = ExecVectors.name(item)
            let policy = try ExecPolicy(document: item["policy"] ?? .null, platform: "darwin")
            XCTAssertEqual(policy.digest, item["digest"]?.stringValue, label)
            let context = item["context"] ?? .null
            let port = context["proxy_port"]?.intValue.map { UInt16($0) }
            let rendered = try ExecSeatbeltProfile.render(
                policy, context: ExecSeatbeltContext(home: context["home"]?.stringValue ?? "", proxyPort: port))
            XCTAssertEqual(Array(rendered.utf8), Array((item["seatbelt"]?.stringValue ?? "").utf8), label)
        }
    }

    func testProfileErrorVectorsAreRefusedOnMacAndAcceptedOnLinux() throws {
        for item in ExecVectors.cases("profile_errors") {
            let label = ExecVectors.name(item)
            XCTAssertThrowsError(try ExecPolicy(document: item["policy"] ?? .null, platform: "darwin"), label) {
                XCTAssertEqual(($0 as? ExecPolicyError)?.code, item["code"]?.stringValue, label)
            }
            XCTAssertNoThrow(try ExecPolicy(document: item["policy"] ?? .null, platform: "linux"), label)
        }
    }

    func testConstantsMatchTheContract() {
        let constants = ExecVectors.document["constants"] ?? .null
        func strings(_ key: String) -> [String] { constants[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        XCTAssertEqual(ExecBackends.darwinBase, strings("darwin_base_reads"))
        XCTAssertEqual(ExecBackends.linuxBase, strings("linux_base_reads"))
        XCTAssertEqual(ExecSeatbeltProfile.execBase, strings("darwin_exec_base"))
        XCTAssertEqual(ExecSeatbeltProfile.execOnly, strings("darwin_exec_only"))
        XCTAssertEqual(ExecSeatbeltProfile.keychains, strings("darwin_keychain_denials"))
        XCTAssertEqual(ExecSeatbeltProfile.deniedServices, strings("denied_services"))
        XCTAssertEqual(ExecSeatbeltProfile.deniedLoggers, strings("denied_log_services"))
        XCTAssertEqual(ExecSeatbeltProfile.dnssdService, constants["dnssd_service"]?.stringValue)
        XCTAssertEqual(ExecSeatbeltProfile.syslogSocket, constants["syslog_socket"]?.stringValue)
        XCTAssertEqual(ExecBackends.execSubdirectory, constants["exec_subdirectory"]?.stringValue)
        XCTAssertEqual(ExecPolicy.format, constants["format"]?.stringValue)
        XCTAssertEqual(strings("backend_reasons"), [
            "landlock_abi", "bwrap_missing", "userns_denied", "root_node", "sandbox_exec_missing", "app_sandboxed",
            "platform_unsupported",
        ])
        XCTAssertEqual(ExecBackends.requiredLandlockABI, Int(constants["landlock_abi"]?.intValue ?? 0))
        let messages = constants["messages"]
        for (code, text) in ExecBackends.messages { XCTAssertEqual(messages?[code]?.stringValue, text, code) }
    }

    func testQuotingIsSharedWithTheComputerProfile() {
        for value in ["plain", "a\"b", "a\\b", "tab\tsp ace", "é\u{0378}"] {
            XCTAssertEqual(SeatbeltQuoting.quote(value), ComputerSandboxProfile.quote(value))
        }
        XCTAssertEqual(SeatbeltQuoting.quote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    func testRenderRefusesBadContexts() throws {
        let policy = try ExecPolicy(document: ExecVectors.minimalPolicy, platform: "darwin")
        XCTAssertThrowsError(try ExecSeatbeltProfile.render(policy, context: .init(home: "relative", proxyPort: nil)))
        XCTAssertThrowsError(try ExecSeatbeltProfile.render(policy, context: .init(home: "/Users/\u{0378}", proxyPort: nil)))
        let hosted = try ExecPolicy(
            document: try ExecJSON.parse(
                Data(
                    """
                    {"v":1,"reads":[],"workspace":"/private/tmp/ws","hosts":[{"host":"example.com","port":443}],\
                    "limits":{"memory_bytes":536870912,"processes":1,"open_files":256,"file_bytes":104857600},\
                    "time":{"wall_ms":30000}}
                    """.utf8)),
            platform: "darwin")
        XCTAssertThrowsError(try ExecSeatbeltProfile.render(hosted, context: .init(home: "/Users/test", proxyPort: nil)))
        XCTAssertThrowsError(try ExecSeatbeltProfile.render(hosted, context: .init(home: "/Users/test", proxyPort: 0)))
        let text = try ExecSeatbeltProfile.render(hosted, context: .init(home: "/Users/test", proxyPort: 4242))
        XCTAssertTrue(text.contains("(allow network-outbound (remote ip \"localhost:4242\"))"))
    }

    func testFactsRefuseUnknownAndMistypedKeys() throws {
        XCTAssertThrowsError(try ExecFacts(json: .int(1)))
        XCTAssertThrowsError(try ExecFacts(json: .object([("platform", .string("darwin")), ("extra", .bool(true))])))
        XCTAssertThrowsError(
            try ExecFacts(
                json: .object([
                    ("platform", .string("darwin")), ("mode", .string("loud")), ("landlock_abi", .int(0)), ("bwrap", .bool(false)),
                    ("userns", .bool(false)), ("euid", .int(1)), ("sandbox_exec", .bool(true)), ("app_sandboxed", .bool(false)),
                ])))
    }

    func testCommittedCopiesMatchTheContractDigests() throws {
        func digest(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(
            try digest(ExecVectors.fixtureURL("exec-policy-v1", "json")),
            "b165ecbd018b6a2b5af14e252dc83adb37b4ac5ea84cde19b95a480d399a6281")
        let table = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AstralCore/Resources/Exec/path_fold.json")
        XCTAssertEqual(try digest(table), "abd8ed95f18a9f9970e32593c93da1d6e48423a8e1c5a89acce022661a16ecbe")
    }

    #if os(macOS)
        func testBackendCurrentIsSeatbeltOnThisMac() {
            XCTAssertEqual(ExecBackends.current, .available(.seatbelt))
        }

        func testLoaderRequiresCanonicalSpellingsAndRefusesDataOverlap() throws {
            let root = try ExecTemporary.canonicalDirectory()
            defer { try? FileManager.default.removeItem(atPath: root) }
            let data = root + "/data"
            let workspace = data + "/exec/call"
            let home = root + "/home"
            for path in [workspace, home] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            let link = root + "/link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: workspace)
            func policyJSON(workspace: String, reads: [String] = []) -> Data {
                let list = reads.map { "\"\($0)\"" }.joined(separator: ",")
                return Data(
                    """
                    {"v":1,"reads":[\(list)],"workspace":"\(workspace)","hosts":[],\
                    "limits":{"memory_bytes":536870912,"processes":1,"open_files":256,"file_bytes":104857600},\
                    "time":{"wall_ms":30000}}
                    """.utf8)
            }
            let loaded = try ExecPolicy.load(json: policyJSON(workspace: workspace), dataDirectory: data, home: home)
            XCTAssertEqual(loaded.platform, "darwin")
            XCTAssertEqual(loaded.policy.workspace, workspace)
            XCTAssertThrowsError(try ExecPolicy.load(json: policyJSON(workspace: link), dataDirectory: data, home: home)) {
                XCTAssertEqual(($0 as? ExecPolicyError)?.code, "policy.path_invalid")
            }
            XCTAssertThrowsError(try ExecPolicy.load(json: policyJSON(workspace: root + "/absent"), dataDirectory: data, home: home))
            XCTAssertThrowsError(try ExecPolicy.load(json: policyJSON(workspace: workspace), dataDirectory: link, home: home)) {
                XCTAssertTrue($0 is ExecContextError)
            }
            XCTAssertThrowsError(try ExecPolicy.load(json: policyJSON(workspace: workspace), dataDirectory: data, home: "relative"))
            XCTAssertThrowsError(try ExecPolicy.load(json: policyJSON(workspace: workspace, reads: [data]), dataDirectory: data, home: home)) {
                XCTAssertEqual(($0 as? ExecPolicyError)?.code, "policy.path_invalid")
            }
            let secrets = data + "/secrets"
            try FileManager.default.createDirectory(atPath: secrets, withIntermediateDirectories: true)
            XCTAssertThrowsError(try ExecPolicy.load(json: policyJSON(workspace: workspace, reads: [secrets]), dataDirectory: data, home: home)) {
                XCTAssertEqual(($0 as? ExecRefused)?.refusal.code, "exec.policy_overlaps_data")
            }
            XCTAssertNoThrow(try ExecPolicy.load(json: policyJSON(workspace: home), dataDirectory: data, home: home))
            let inside = data + "/other"
            try FileManager.default.createDirectory(atPath: inside, withIntermediateDirectories: true)
            XCTAssertThrowsError(try ExecPolicy.load(json: policyJSON(workspace: inside), dataDirectory: data, home: home)) {
                XCTAssertEqual(($0 as? ExecRefused)?.refusal.code, "exec.policy_overlaps_data")
            }
        }
    #endif
}

#if os(macOS)
    enum ExecTemporary {
        static func canonicalDirectory() throws -> String {
            let base = NSTemporaryDirectory() + "astral-exec-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            return try ExecPolicy.canonicalPath(base)
        }
    }
#endif
