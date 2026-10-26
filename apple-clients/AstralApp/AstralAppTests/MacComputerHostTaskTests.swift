// Tests the Mac host's task seams: advertised verbs and folders, browser and command routing, pauses and approvals.
// Commands use a scripted spawner and the physical driver is a recorder, so nothing reaches the desktop.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerHostTaskTests: XCTestCase {
        private var counter = 0
        private var sent: [JSONValue] = []

        private func folder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }
        private func makeHost(
            roots: [URL] = [], driver: any MacComputerDriving = MacComputerTaskDriver(),
            commands: MacComputerCommands? = nil, presented: (() -> Void)? = nil, activated: (() -> Void)? = nil
        ) throws -> MacComputerHost {
            let suite = "host-task-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
            let grants = MacComputerWorkspaceGrantIO(
                chooseDirectories: { roots },
                resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
                makeBookmark: { Data($0.path.utf8) }, startAccess: { _ in true }, stopAccess: { _ in })
            let files = MacComputerFiles(defaults: defaults, grants: grants)
            files.bind("task-owner")
            if !roots.isEmpty { files.choose() }
            let host = MacComputerHost(
                available: true, defaults: defaults, files: files, driver: driver, monitor: MacComputerTaskMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { _ in presented?() },
                commands: commands
                    ?? MacComputerCommands(
                        spawner: MacComputerFakeSpawner(), clock: MacComputerFakeClock { $0 >= 20 }, inherited: [:],
                        loginPath: { "/usr/bin:/bin" }),
                appActivator: { activated?() })
            host.bind(owner: "task-owner") { [weak self] text in
                if let frame = try? JSONValue.parse(Data(text.utf8)) { self?.sent.append(frame) }
                return true
            }
            host.setEnabled(true)
            addTeardownBlock { host.applicationWillTerminate() }
            return host
        }
        private func frame(_ value: JSONValue) throws -> InboundFrame {
            try XCTUnwrap(InboundFrame.parse(String(decoding: value.encoded(), as: UTF8.self)))
        }
        private func session(_ host: MacComputerHost, _ id: String, _ state: String = "active", reason: String? = nil)
            throws -> InboundFrame
        {
            var payload: [String: JSONValue] = [
                "type": .string("computer_session"), "host_id": .string(try XCTUnwrap(host.descriptor).hostId),
                "session_id": .string(id), "state": .string(state), "controller_label": .string("Test controller"),
            ]
            if let reason { payload["pause_reason"] = .string(reason) }
            return try frame(.object(payload))
        }
        private func request(_ session: String, _ verb: String, _ args: [String: JSONValue], deadline: Double = 30000)
            throws -> (String, InboundFrame)
        {
            counter += 1
            let id = "creq_" + String(format: "%032x", counter)
            return (
                id,
                try frame(
                    .object([
                        "type": .string("computer_request"), "request_id": .string(id),
                        "session_id": .string(session), "verb": .string(verb), "args": .object(args),
                        "deadline_ms": .number(deadline),
                    ]))
            )
        }
        private func response(_ id: String, host: MacComputerHost) async -> JSONValue? {
            for _ in 0..<2000 {
                if let found = sent.first(where: { $0["payload"]?["request_id"] == .string(id) }) {
                    return found["payload"]
                }
                _ = await host.flushCurrentSends()
                await Task.yield()
            }
            return nil
        }
        private var events: [JSONValue] {
            sent.compactMap { $0["payload"] }.filter { $0["event"] != nil }
        }

        func testDescriptorAdvertisesCommandsWithFoldersAndBrowserOnlyWhenEnabled() throws {
            let bare = try makeHost()
            let browserVerbs = ComputerHostRequest.verbs.filter { $0.hasPrefix("browser_") }
            let commandVerbs: Set<String> = ["run_command", "read_output", "interrupt_command"]
            var verbs = Set(try XCTUnwrap(bare.descriptor).verbs)
            XCTAssertTrue(verbs.isDisjoint(with: commandVerbs.union(browserVerbs).union(["read_file"])))
            XCTAssertNil(try XCTUnwrap(bare.descriptor).json["workspace_roots"])
            let browser = MacComputerTaskBrowser()
            bare.browser = browser
            XCTAssertTrue(Set(try XCTUnwrap(bare.descriptor).verbs).isSuperset(of: browserVerbs))
            browser.isEnabled = false
            XCTAssertTrue(Set(try XCTUnwrap(bare.descriptor).verbs).isDisjoint(with: browserVerbs))
            let root = try folder()
            let host = try makeHost(roots: [root])
            let descriptor = try XCTUnwrap(host.descriptor)
            verbs = Set(descriptor.verbs)
            XCTAssertTrue(verbs.isSuperset(of: commandVerbs.union(["read_file", "write_file"])))
            XCTAssertTrue(verbs.isDisjoint(with: browserVerbs))
            XCTAssertEqual(
                descriptor.workspaceRoots,
                [ComputerHostWorkspaceRoot(name: root.lastPathComponent, path: host.files.roots[0])])
            XCTAssertEqual(
                descriptor.json["workspace_roots"],
                .array([.object(["name": .string(root.lastPathComponent), "path": .string(host.files.roots[0])])]))
        }

        func testBrowserVerbsRouteThroughTheSeamOrRefuseAsUnsupported() async throws {
            let host = try makeHost()
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id))
            let (first, refused) = try request(id, "browser_snapshot", ["mode": .string("interactive")], deadline: 5000)
            host.consume(refused)
            let unavailable = await response(first, host: host)
            XCTAssertEqual(unavailable?["error"]?["code"], .string("unsupported"))
            let browser = MacComputerTaskBrowser()
            host.browser = browser
            let (second, routed) = try request(id, "browser_snapshot", ["mode": .string("all")], deadline: 5000)
            host.consume(routed)
            let accepted = await response(second, host: host)
            XCTAssertEqual(accepted?["ok"], .bool(true))
            XCTAssertEqual(accepted?["result"]?["snapshot_id"], .string("s1"))
            XCTAssertEqual(browser.handled.map(\.verb), ["browser_snapshot"])
            XCTAssertEqual(browser.handled.map(\.ticket), [second])
            browser.isEnabled = false
            let (third, disabled) = try request(id, "browser_wait", ["for": .string("load")], deadline: 15000)
            host.consume(disabled)
            let off = await response(third, host: host)
            XCTAssertEqual(off?["error"]?["code"], .string("unsupported"))
            XCTAssertEqual(browser.handled.count, 1)
        }

        func testCommandsRunOffThePhysicalQueueAndEndWithPause() async throws {
            let root = try folder()
            let spawner = MacComputerFakeSpawner()
            let commands = MacComputerCommands(
                spawner: spawner, clock: MacComputerFakeClock { $0 >= 20 }, inherited: [:],
                loginPath: { "/usr/bin:/bin" })
            let driver = MacComputerTaskDriver()
            let host = try makeHost(roots: [root], driver: driver, commands: commands)
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id))
            let (command, running) = try request(
                id, "run_command",
                ["argv": .array([.string("echo")]), "cwd": .string(host.files.roots[0]), "timeout_s": .number(60)],
                deadline: 600000)
            host.consume(running)
            for _ in 0..<2000 where spawner.plans.isEmpty { await Task.yield() }
            XCTAssertEqual(spawner.plans.count, 1)
            let (click, pointer) = try request(id, "click", ["x": .number(1), "y": .number(1)])
            host.consume(pointer)
            let clicked = await response(click, host: host)
            XCTAssertEqual(clicked?["ok"], .bool(true))
            let executed = await driver.executed
            XCTAssertEqual(executed, ["click"])
            XCTAssertTrue(commands.registry.all.first?.running == true)
            host.pause()
            for _ in 0..<2000 where commands.registry.all.first?.running == true { await Task.yield() }
            XCTAssertEqual(commands.registry.all.first?.state, "interrupted")
            XCTAssertEqual(spawner.processes.first?.signals, [SIGTERM])
            _ = await host.flushCurrentSends()
            XCTAssertFalse(sent.contains { $0["payload"]?["request_id"] == .string(command) })
        }

        func testSocketLossLeavesRunningJobsUncertainForTheNextRead() async throws {
            let root = try folder()
            let commands = MacComputerCommands(
                spawner: MacComputerFakeSpawner(), clock: MacComputerFakeClock { $0 >= 20 }, inherited: [:],
                loginPath: { "/usr/bin:/bin" })
            let host = try makeHost(roots: [root], commands: commands)
            let first = UUID().uuidString.lowercased()
            host.consume(try session(host, first))
            let (start, background) = try request(
                first, "run_command",
                [
                    "argv": .array([.string("echo")]), "cwd": .string(host.files.roots[0]),
                    "background": .bool(true), "timeout_s": .number(3600),
                ], deadline: 600000)
            host.consume(background)
            let started = await response(start, host: host)
            let job = try XCTUnwrap(started?["result"]?["job_id"]?.stringValue)
            host.disconnect()
            for _ in 0..<2000 where commands.registry.job(job)?.running == true { await Task.yield() }
            host.bind(owner: "task-owner") { [weak self] text in
                if let frame = try? JSONValue.parse(Data(text.utf8)) { self?.sent.append(frame) }
                return true
            }
            let second = UUID().uuidString.lowercased()
            host.consume(try session(host, second))
            let (read, output) = try request(second, "read_output", ["job_id": .string(job)])
            host.consume(output)
            let state = await response(read, host: host)
            XCTAssertEqual(state?["result"]?["state"], .string("uncertain"))
            host.signedOut()
            XCTAssertNil(commands.registry.job(job))
        }

        func testLocalPauseRefusesRemoteResumeUntilLocalResume() async throws {
            let host = try makeHost()
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id))
            host.pause()
            host.consume(try session(host, id, "paused", reason: "local_input"))
            XCTAssertEqual(host.session?.state, "paused")
            host.consume(try session(host, id))
            XCTAssertEqual(host.session?.state, "paused")
            _ = await host.flushCurrentSends()
            XCTAssertEqual(events.last?["event"], .string("paused"))
            XCTAssertEqual(events.last?["reason"], .string("local_pause"))
            host.resume()
            _ = await host.flushCurrentSends()
            XCTAssertEqual(events.last?["event"], .string("resumed"))
            host.consume(try session(host, id))
            XCTAssertEqual(host.session?.state, "active")
            host.takeover()
            host.consume(try session(host, id, "paused", reason: "local_input"))
            XCTAssertEqual(host.session?.state, "paused")
            host.consume(try session(host, id))
            XCTAssertEqual(host.session?.state, "active")
            host.pause()
            host.consume(try session(host, id, "paused"))
            host.consume(try session(host, id))
            XCTAssertEqual(host.session?.state, "paused")
        }

        func testApprovalWaitingFollowsTheSessionAndBringsAstralForward() throws {
            var presentations = 0
            var activations = 0
            let host = try makeHost(presented: { presentations += 1 }, activated: { activations += 1 })
            XCTAssertFalse(host.taskActive)
            host.approvalWaiting(true)
            XCTAssertFalse(host.awaitingApproval)
            XCTAssertEqual(presentations, 0)
            host.consume(try session(host, UUID().uuidString.lowercased()))
            XCTAssertTrue(host.taskActive)
            let shown = presentations
            host.approvalWaiting(true)
            XCTAssertTrue(host.awaitingApproval)
            XCTAssertEqual(presentations, shown + 1)
            let rendered = NSHostingController(rootView: MacComputerSessionPanel(host: host))
            rendered.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(rendered.view.fittingSize.height, 0)
            host.bringAstralForward()
            XCTAssertEqual(activations, 1)
            host.approvalWaiting(false)
            XCTAssertFalse(host.awaitingApproval)
            host.approvalWaiting(true)
            host.stop()
            XCTAssertFalse(host.awaitingApproval)
            XCTAssertFalse(host.taskActive)
        }
    }

    @MainActor
    final class MacComputerTaskMonitor: MacComputerMonitoring {
        var running = false
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
            running = true
            return true
        }
        func stop() { running = false }
    }

    actor MacComputerTaskDriver: MacComputerDriving {
        var executed: [String] = []
        func execute(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try authorize()
            executed.append(request.verb)
            return ["attempted": .bool(true)]
        }
        func reset() {}
    }

    @MainActor
    final class MacComputerTaskBrowser: MacBrowserVerbHandling {
        var isEnabled = true
        var handled: [(verb: String, ticket: String)] = []
        func handle(
            _ request: ComputerHostRequest, ticket: ComputerHostTicket,
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try authorize()
            handled.append((request.verb, ticket.requestId))
            return ["snapshot_id": .string("s1")]
        }
    }
#endif
