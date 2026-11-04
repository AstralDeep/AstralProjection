// Verifies the Mac sandbox controller and its command integration with fake proxies, validators and spawners:
// launches are refused before they start on any sandbox failure, wrappers carry the proxy environment, and
// results carry the profile digest, mode, domains, scrubbed output and attributed violations.

#if os(macOS)
    import AstralCore
    import CryptoKit
    import XCTest
    @testable import AstralDeep

    nonisolated final class MacComputerSandboxFakeProxy: MacComputerEgressProxying, @unchecked Sendable {
        private let lock = NSLock()
        private var startedCount = 0
        private var stoppedCount = 0
        private let fixedPort: UInt16
        private let failure: Error?
        init(fixedPort: UInt16 = 51234, failure: Error? = nil) {
            self.fixedPort = fixedPort
            self.failure = failure
        }
        var port: UInt16 { fixedPort }
        var started: Int { lock.withLock { startedCount } }
        var stopped: Int { lock.withLock { stoppedCount } }
        func start() throws {
            _ = lock.withLock { startedCount += 1 }
            if let failure { throw failure }
        }
        func stop() { _ = lock.withLock { stoppedCount += 1 } }
    }

    nonisolated final class MacComputerSandboxRecordingValidator: MacComputerSandboxValidating, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(String, String)] = []
        private let failure: Error?
        init(failure: Error? = nil) { self.failure = failure }
        var validations: [(String, String)] { lock.withLock { recorded } }
        func validate(executable: String, profilePath: String) async throws {
            _ = lock.withLock { recorded.append((executable, profilePath)) }
            if let failure { throw failure }
        }
    }

    nonisolated final class MacComputerSandboxEventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(String, [String: JSONValue])] = []
        func append(_ name: String, _ payload: [String: JSONValue]) {
            _ = lock.withLock { recorded.append((name, payload)) }
        }
        var events: [(String, [String: JSONValue])] { lock.withLock { recorded } }
        func named(_ name: String) -> [[String: JSONValue]] {
            lock.withLock { recorded }.filter { $0.0 == name }.map(\.1)
        }
    }

    final class MacComputerSandboxTests: XCTestCase {
        private var counter = 0

        private func configuration(mode: ComputerSandboxMode = .enforce) throws -> ComputerSandboxConfiguration {
            try XCTUnwrap(
                ComputerSandboxConfiguration(
                    mode: mode, domains: [ComputerEgressDomain("api.github.com")].compactMap { $0 },
                    bindings: [
                        ComputerEgressBinding(
                            placeholder: "ASTRAL_GITHUB_TOKEN", host: "api.github.com", secret: "astral.egress.test")
                    ].compactMap { $0 }))
        }
        private func controller(
            _ configuration: ComputerSandboxConfiguration, log: MacComputerSandboxEventLog,
            validator: MacComputerSandboxValidating = MacComputerSandboxRecordingValidator(),
            proxy: MacComputerSandboxFakeProxy = MacComputerSandboxFakeProxy()
        ) -> MacComputerSandboxController {
            MacComputerSandboxController(
                configuration: { configuration },
                secrets: { _ in "swapped-secret" },
                home: { "/Users/sam" },
                bundlePath: { "/Applications/AstralDeep.app" },
                validator: validator,
                proxyFactory: { _ in proxy },
                sink: { log.append($0, $1) })
        }
        private func folder() throws -> String {
            let created = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: created) }
            let pointer = try XCTUnwrap(realpath(created.path, nil))
            defer { free(pointer) }
            return String(cString: pointer)
        }
        private func request(_ verb: String, _ args: [String: JSONValue], deadline: Double = 600000) throws
            -> ComputerHostRequest
        {
            counter += 1
            return try ComputerHostRequest(
                json: .object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(format: "%032x", counter)),
                    "session_id": .string("11111111-1111-4111-8111-111111111111"), "verb": .string(verb),
                    "args": .object(args), "deadline_ms": .number(deadline),
                ]))
        }
        private func run(_ root: String) throws -> ComputerHostRequest {
            try request(
                "run_command", ["argv": .array([.string("echo"), .string("hi")]), "cwd": .string(root)])
        }
        private func code(_ work: () async throws -> Void) async -> String? {
            do {
                try await work()
                return nil
            } catch { return (error as? ComputerHostError)?.code ?? "\(error)" }
        }
        private func digest(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        func testPrepareWrapsThePlanBehindAProbedProfileProxyAndScratchDirectory() async throws {
            let root = try folder()
            let log = MacComputerSandboxEventLog()
            let validator = MacComputerSandboxRecordingValidator()
            let proxy = MacComputerSandboxFakeProxy()
            let subject = controller(try configuration(), log: log, validator: validator, proxy: proxy)
            let plan = MacComputerCommandPlan(
                executable: "/bin/echo", arguments: ["/bin/echo", "hi"],
                environment: ["HOME": "/Users/sam", "PATH": "/usr/bin:/bin"], directory: root, stdin: nil)
            let launch = try await subject.prepare(
                jobId: "job-1", plan: plan, environment: plan.environment, roots: [root],
                exclusions: .defaults)
            XCTAssertEqual(launch.plan.executable, ComputerSandboxProfile.launcherPath)
            XCTAssertEqual(validator.validations.count, 1)
            let (executable, profilePath) = try XCTUnwrap(validator.validations.first)
            XCTAssertEqual(executable, ComputerSandboxProfile.launcherPath)
            XCTAssertEqual(launch.plan.arguments, ["-f", profilePath, "/bin/echo", "hi"])
            let profile = try String(contentsOfFile: profilePath, encoding: .utf8)
            XCTAssertTrue(profile.contains("(deny default)"))
            XCTAssertTrue(profile.contains("(subpath \"\(root)\""))
            XCTAssertTrue(profile.contains("(allow network-outbound (remote ip \"127.0.0.1:51234\"))"))
            XCTAssertEqual(launch.session.digest, digest(profile))
            XCTAssertEqual(launch.session.mode, .enforce)
            XCTAssertEqual(launch.session.domains, ["api.github.com"])
            XCTAssertEqual(launch.session.placeholders, ["ASTRAL_GITHUB_TOKEN"])
            for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                XCTAssertEqual(launch.plan.environment[name], "http://127.0.0.1:51234")
            }
            XCTAssertEqual(launch.plan.environment["NO_PROXY"], "127.0.0.1,localhost,::1")
            let scratch = try XCTUnwrap(launch.plan.environment["TMPDIR"])
            XCTAssertTrue(scratch.hasSuffix("astral-command-job-1"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: scratch))
            XCTAssertEqual(launch.session.json()["mode"], .string("enforce"))
            XCTAssertEqual(launch.session.json()["proxy_port"], .number(51234))
            XCTAssertEqual(launch.session.json()["allowed_domains"], .array([.string("api.github.com")]))
            XCTAssertEqual(launch.session.json()["violations"], .array([]))
            XCTAssertTrue(log.events.isEmpty)
            launch.session.close()
            XCTAssertEqual(proxy.stopped, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch))
            XCTAssertFalse(FileManager.default.fileExists(atPath: profilePath))
        }

        func testPrepareRefusesBeforeStartWhenTheProfileFailsToCompile() async throws {
            let root = try folder()
            let log = MacComputerSandboxEventLog()
            let proxy = MacComputerSandboxFakeProxy()
            let validator = MacComputerSandboxRecordingValidator(
                failure: ComputerHostError("sandbox_refused", "The sandbox profile could not be compiled: bad."))
            let subject = controller(try configuration(), log: log, validator: validator, proxy: proxy)
            let plan = MacComputerCommandPlan(
                executable: "/bin/echo", arguments: ["/bin/echo"], environment: ["HOME": "/Users/sam"],
                directory: root, stdin: nil)
            let error = await code {
                _ = try await subject.prepare(
                    jobId: "job-2", plan: plan, environment: plan.environment, roots: [root], exclusions: .defaults)
            }
            XCTAssertEqual(error, "sandbox_refused")
            XCTAssertEqual(proxy.started, 1)
            XCTAssertEqual(proxy.stopped, 1)
            XCTAssertTrue(log.events.isEmpty)
        }

        func testCompileProbeRefusesWhenTheLauncherIsMissing() async throws {
            let error = await code {
                try await MacComputerSandboxCompileProbe().validate(
                    executable: "/usr/sbin/astral-missing-sandbox-exec", profilePath: "/tmp/profile.sb")
            }
            XCTAssertEqual(error, "sandbox_refused")
        }

        func testShadowModeContinuesWithoutAProxyAndRecordsTheOutage() async throws {
            let root = try folder()
            let log = MacComputerSandboxEventLog()
            let validator = MacComputerSandboxRecordingValidator()
            let proxy = MacComputerSandboxFakeProxy(failure: ComputerHostError("failed", "listener"))
            let subject = controller(try configuration(mode: .shadow), log: log, validator: validator, proxy: proxy)
            let plan = MacComputerCommandPlan(
                executable: "/bin/echo", arguments: ["/bin/echo"], environment: ["HOME": "/Users/sam"],
                directory: root, stdin: nil)
            let launch = try await subject.prepare(
                jobId: "job-3", plan: plan, environment: plan.environment, roots: [root], exclusions: .defaults)
            XCTAssertEqual(launch.session.mode, .shadow)
            XCTAssertEqual(launch.session.json()["proxy_port"], .null)
            XCTAssertNil(launch.plan.environment["HTTP_PROXY"])
            let violation = try XCTUnwrap(log.named("command.sandbox_violation").first)
            XCTAssertEqual(violation["detail"], .string("proxy_unavailable"))
            XCTAssertEqual(violation["source"], .string("proxy"))
            XCTAssertEqual(violation["blocked"], .bool(false))
            let profile = try String(contentsOfFile: XCTUnwrap(validator.validations.first?.1), encoding: .utf8)
            XCTAssertTrue(profile.contains("(allow default)"))
            launch.session.close()
        }

        func testEnforceModeRefusesWhenTheProxyCannotStart() async throws {
            let root = try folder()
            let log = MacComputerSandboxEventLog()
            let proxy = MacComputerSandboxFakeProxy(failure: ComputerHostError("failed", "listener"))
            let subject = controller(
                try configuration(), log: log, validator: MacComputerSandboxRecordingValidator(), proxy: proxy)
            let plan = MacComputerCommandPlan(
                executable: "/bin/echo", arguments: ["/bin/echo"], environment: ["HOME": "/Users/sam"],
                directory: root, stdin: nil)
            let error = await code {
                _ = try await subject.prepare(
                    jobId: "job-4", plan: plan, environment: plan.environment, roots: [root], exclusions: .defaults)
            }
            XCTAssertEqual(error, "sandbox_refused")
            XCTAssertTrue(log.events.isEmpty)
            XCTAssertEqual(proxy.stopped, 1)
        }

        func testPrepareRefusesEnvironmentsCarryingPlaceholderSecrets() async throws {
            let root = try folder()
            let log = MacComputerSandboxEventLog()
            let proxy = MacComputerSandboxFakeProxy()
            let subject = controller(
                try configuration(), log: log, validator: MacComputerSandboxRecordingValidator(), proxy: proxy)
            let plan = MacComputerCommandPlan(
                executable: "/bin/echo", arguments: ["/bin/echo"],
                environment: ["HOME": "/Users/sam", "APP_TOKEN": "ASTRAL_GITHUB_TOKEN"], directory: root,
                stdin: nil)
            let error = await code {
                _ = try await subject.prepare(
                    jobId: "job-5", plan: plan, environment: plan.environment, roots: [root], exclusions: .defaults)
            }
            XCTAssertEqual(error, "sandbox_refused")
            XCTAssertEqual(proxy.started, 0)
            XCTAssertTrue(log.events.isEmpty)
        }

        func testRunCommandExecutesBehindTheWrapperWithDigestViolationsAndScrubbing() async throws {
            let root = try folder()
            let log = MacComputerSandboxEventLog()
            let configuration = try configuration()
            let spawner = MacComputerFakeSpawner(script: { _, output, process in
                output.append(
                    .stderr, Array("Sandbox: sh(9001) deny(1) file-write-data /Users/sam/proj/out.txt\n".utf8))
                output.append(.stdout, Array("token=ASTRAL_GITHUB_TOKEN\n".utf8))
                output.finish(.stdout)
                output.finish(.stderr)
                process.exit(.exited(0))
            })
            let subject = controller(
                configuration, log: log, validator: MacComputerSandboxRecordingValidator(),
                proxy: MacComputerSandboxFakeProxy())
            let commands = MacComputerCommands(
                spawner: spawner, clock: MacComputerFakeClock { $0 >= 20 }, inherited: ["HOME": "/Users/sam"],
                loginPath: { "/usr/bin:/bin" }, sandbox: subject)
            let result = try await commands.run(
                try run(root), session: "11111111-1111-4111-8111-111111111111", roots: [root], authorize: {})
            let sandboxObject = try XCTUnwrap(result["sandbox"]?.objectValue)
            XCTAssertEqual(sandboxObject["mode"], .string("enforce"))
            XCTAssertEqual(sandboxObject["allowed_domains"], .array([.string("api.github.com")]))
            XCTAssertEqual(sandboxObject["proxy_port"], .number(51234))
            XCTAssertEqual(sandboxObject["profile_digest"]?.stringValue?.count, 64)
            let violations = try XCTUnwrap(sandboxObject["violations"]?.arrayValue)
            XCTAssertEqual(violations.count, 1)
            XCTAssertEqual(violations.first?["source"], .string("seatbelt"))
            XCTAssertEqual(violations.first?["operation"], .string("file-write-data"))
            XCTAssertEqual(violations.first?["target"], .string("/Users/sam/proj/out.txt"))
            XCTAssertEqual(violations.first?["blocked"], .bool(true))
            XCTAssertEqual(result["stdout"], .string("token=[astral:redacted]\n"))
            XCTAssertNotNil(result["job_id"])
            let plan = try XCTUnwrap(spawner.plans.first)
            XCTAssertEqual(plan.executable, ComputerSandboxProfile.launcherPath)
            XCTAssertEqual(plan.arguments.first, "-f")
            XCTAssertEqual(plan.arguments.last, "hi")
            XCTAssertNotNil(plan.environment["HTTP_PROXY"])
            let event = try XCTUnwrap(log.named("command.sandbox_violation").first)
            XCTAssertEqual(event["job_id"], result["job_id"])
            XCTAssertEqual(event["target"], .string("/Users/sam/proj/out.txt"))
        }

        func testReadOutputSurfacesFreshViolationsAndScrubsChunks() async throws {
            let root = try folder()
            let log = MacComputerSandboxEventLog()
            let spawner = MacComputerFakeSpawner(script: { _, output, process in
                output.append(
                    .stderr, Array("Sandbox: git(9002) deny(2) file-read-data /Users/sam/proj/.env\n".utf8))
                output.append(.stdout, Array("ASTRAL_GITHUB_TOKEN leaked\n".utf8))
            })
            let subject = controller(
                try configuration(), log: log, validator: MacComputerSandboxRecordingValidator(),
                proxy: MacComputerSandboxFakeProxy())
            let commands = MacComputerCommands(
                spawner: spawner, clock: MacComputerFakeClock { $0 >= 20 }, inherited: ["HOME": "/Users/sam"],
                loginPath: { "/usr/bin:/bin" }, sandbox: subject)
            let session = "11111111-1111-4111-8111-111111111111"
            let started = try await commands.run(
                try request(
                    "run_command",
                    ["argv": .array([.string("sleep"), .string("1")]), "cwd": .string(root),
                     "background": .bool(true)], deadline: 600000), session: session, roots: [root], authorize: {})
            let jobId = try XCTUnwrap(started["job_id"]?.stringValue)
            let read = try await commands.read(
                try request("read_output", ["job_id": .string(jobId)], deadline: 30000), authorize: {})
            XCTAssertEqual(read["sandbox"]?.objectValue?["mode"], .string("enforce"))
            let violations = try XCTUnwrap(read["sandbox"]?.objectValue?["violations"]?.arrayValue)
            XCTAssertEqual(violations.first?["operation"], .string("file-read-data"))
            let chunk = try XCTUnwrap(read["chunks"]?.arrayValue?.first?["data"]?.stringValue)
            XCTAssertEqual(chunk, "[astral:redacted] leaked\n")
            commands.endAll(as: "interrupted")
        }

        func testRealControllerPreparesAWorkingLaunchWithTheLiveProbeAndProxy() async throws {
            let root = try folder()
            let log = MacComputerSandboxEventLog()
            let configuration = try configuration()
            let subject = MacComputerSandboxController(
                configuration: { configuration },
                secrets: { _ in nil },
                home: { "/Users/sam" }, bundlePath: { nil },
                sink: { log.append($0, $1) })
            let plan = MacComputerCommandPlan(
                executable: "/bin/echo", arguments: ["/bin/echo"], environment: ["HOME": "/Users/sam"],
                directory: root, stdin: nil)
            let launch = try await subject.prepare(
                jobId: "job-live", plan: plan, environment: plan.environment, roots: [root], exclusions: .defaults)
            let port = try XCTUnwrap(launch.session.json()["proxy_port"]?.numberValue)
            XCTAssertTrue((1024..<65536).contains(Int(port)))
            XCTAssertEqual(launch.plan.environment["HTTP_PROXY"], "http://127.0.0.1:\(Int(port))")
            launch.session.close()
        }
    }
#endif
