// Tests the Mac host's task seams: advertised verbs and folders, browser and command routing, refusals, pauses and
// approvals. Commands use a scripted spawner, a settable ticket clock and a recording physical driver, so nothing
// reaches the desktop.

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
            roots: [URL] = [], projectGrants: MacProjectGrants? = nil,
            driver: any MacComputerDriving = MacComputerTaskDriver(),
            monitor: MacComputerTaskMonitor? = nil,
            commands: MacComputerCommands? = nil, presented: (() -> Void)? = nil, activated: (() -> Void)? = nil,
            authority: ComputerHostAuthority = ComputerHostAuthority()
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
                available: true, defaults: defaults, files: files, projectGrants: projectGrants, driver: driver,
                monitor: monitor ?? MacComputerTaskMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { _ in presented?() },
                commands: commands
                    ?? MacComputerCommands(
                        spawner: MacComputerFakeSpawner(), clock: MacComputerFakeClock { $0 >= 20 }, inherited: [:],
                        loginPath: { "/usr/bin:/bin" }),
                appActivator: { activated?() }, authority: authority)
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

        func testProjectHostWaitsForNegotiationCatalogAndExactManifestAcknowledgment() async throws {
            let project = "12345678-1234-1234-9234-123456789abc"
            let root = try folder().resolvingSymlinksInPath()
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var stored: [String: Data] = [:]
            let grants = MacProjectGrants(
                grants: io.port, persistence: .init(read: { stored[$0] }, write: { stored[$0] = $1 }))
            let host = try makeHost(roots: [root], projectGrants: grants)
            let hostId = try XCTUnwrap(host.descriptor?.hostId)
            host.beginWorkspaceNegotiation(server: URL(string: "https://example.test")!, account: "owner")
            XCTAssertNil(host.descriptor)
            host.workspaceNegotiated(projects: true)
            XCTAssertNil(host.descriptor)
            try host.reconcileProjects([project])
            let first = try XCTUnwrap(grants.manifest)
            XCTAssertTrue(host.descriptor!.workspaceRoots.isEmpty)
            XCTAssertTrue(host.descriptor!.verbs.contains("write_file"))
            XCTAssertTrue(first.projects.isEmpty)
            let sessionId = UUID().uuidString.lowercased()
            let origin = try ComputerProjectContext(
                chatId: "chat", projectId: project, grantRevision: nil, manifestGeneration: first.generation)
            let incoming = try frame(
                .object([
                    "type": .string("computer_session"), "host_id": .string(hostId),
                    "session_id": .string(sessionId), "state": .string("active"), "project_context": origin.json,
                ]))
            host.consume(incoming)
            XCTAssertNil(host.session)
            host.consume(
                try frame(
                    .object([
                        "type": .string("computer_host"), "host_id": .string(hostId),
                        "project_manifest_ack": .object([
                            "generation": .number(Double(first.generation)), "digest": .string("wrong"),
                            "accepted": .bool(true),
                        ]),
                    ])))
            host.consume(incoming)
            XCTAssertNil(host.session)
            host.consume(
                try frame(
                    .object([
                        "type": .string("computer_host"), "host_id": .string(hostId),
                        "project_manifest_ack": .object([
                            "generation": .number(Double(first.generation)), "digest": .string(first.digest),
                            "accepted": .bool(true),
                        ]),
                    ])))
            host.consume(incoming)
            XCTAssertEqual(host.session?.projectContext, origin)
            host.requestBypass(true, from: .controls)
            host.confirmBypass()
            XCTAssertTrue(host.bypass)
            for (verb, args, deadline) in [
                ("list_windows", [String: JSONValue](), 30000),
                ("browser_snapshot", ["mode": JSONValue.string("all")], 5000),
                (
                    "write_file",
                    [
                        "path": JSONValue.string(root.path + "/never-created"),
                        "content": .string("no"), "if_exists": .string("refuse"),
                    ], 30000
                ),
                ("run_command", ["argv": JSONValue.array([.string("echo")]), "cwd": .string(root.path)], 30000),
            ] {
                let browser = MacComputerTaskBrowser()
                host.browser = browser
                let requestId = "creq_" + String(format: "%032x", 100 + counter)
                counter += 1
                host.consume(
                    try frame(
                        .object([
                            "type": .string("computer_request"), "request_id": .string(requestId),
                            "session_id": .string(sessionId), "project_context": origin.json, "verb": .string(verb),
                            "args": .object(args), "deadline_ms": .number(Double(deadline)),
                        ])))
                let result = await response(requestId, host: host)
                XCTAssertEqual(
                    result?["ok"], .bool(["list_windows", "browser_snapshot"].contains(verb)),
                    "\(verb): \(String(describing: result))")
                if ["write_file", "run_command"].contains(verb) {
                    XCTAssertEqual(result?["error"]?["code"], .string("project_grant_required"))
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/never-created"))
            _ = await host.flushCurrentSends()
            let announcements = events.filter { $0["event"] == .string("announce") }.count
            host.updateProjectFolders { try grants.choose(project: project) }
            _ = await host.flushCurrentSends()
            XCTAssertTrue(host.bypass)
            XCTAssertEqual(events.filter { $0["event"] == .string("announce") }.count, announcements)
            XCTAssertEqual(events.filter { $0["event"] == .string("project_workspaces_changed") }.count, 1)
            XCTAssertEqual(grants.roots(project: project), [root.path])
        }

        func testProjectRemovalStopsRunningAndQueuedCommandsBeforeReleasingFolders() async throws {
            for control in ["remove", "paused", "ended", "missing", "snapshot", "effect"] {
                for queued in [false, true] {
                    if control == "effect" && !queued { continue }
                    let project = "12345678-1234-1234-9234-123456789abc"
                    let root = try folder().resolvingSymlinksInPath()
                    let spawner = MacComputerFakeSpawner()
                    let barrier = ProjectCommandStartBarrier(hold: queued)
                    let commands = MacComputerCommands(
                        spawner: spawner, clock: MacComputerFakeClock { _ in true }, inherited: [:],
                        loginPath: { await barrier.path() })
                    let io = MacComputerTestWorkspaceGrants()
                    io.selection = [root]
                    var stored: [String: Data] = [:]
                    let grants = MacProjectGrants(
                        grants: io.port, persistence: .init(read: { stored[$0] }, write: { stored[$0] = $1 }))
                    let host = try makeHost(projectGrants: grants, commands: commands)
                    let hostId = try XCTUnwrap(host.descriptor?.hostId)
                    host.beginWorkspaceNegotiation(server: URL(string: "https://example.test")!, account: "owner")
                    host.workspaceNegotiated(projects: true)
                    try host.reconcileProjects([project])
                    host.updateProjectFolders { try grants.choose(project: project) }
                    let manifest = try XCTUnwrap(grants.manifest)
                    host.consume(
                        try frame(
                            .object([
                                "type": .string("computer_host"), "host_id": .string(hostId),
                                "project_manifest_ack": .object([
                                    "generation": .number(Double(manifest.generation)),
                                    "digest": .string(manifest.digest),
                                    "accepted": .bool(true),
                                ]),
                            ])))
                    let id = UUID().uuidString.lowercased()
                    let context = try ComputerProjectContext(
                        chatId: "chat", projectId: project, grantRevision: manifest.projects[0].grantRevision,
                        manifestGeneration: manifest.generation)
                    host.consume(
                        try frame(
                            .object([
                                "type": .string("computer_session"), "host_id": .string(hostId),
                                "session_id": .string(id),
                                "state": .string("active"), "project_context": context.json,
                            ])))
                    for digit in ["a", "b"] {
                        host.consume(
                            try frame(
                                .object([
                                    "type": .string("computer_request"),
                                    "request_id": .string("creq_" + String(repeating: digit, count: 32)),
                                    "session_id": .string(id), "project_context": context.json,
                                    "verb": .string("run_command"),
                                    "args": .object(["argv": .array([.string("echo")]), "cwd": .string(root.path)]),
                                    "deadline_ms": .number(30000),
                                ])))
                    }
                    for _ in 0..<2000 {
                        if queued ? await barrier.calls > 0 : spawner.plans.count == 2 { break }
                        await Task.yield()
                    }
                    let expected = queued ? 0 : 2
                    XCTAssertEqual(spawner.plans.count, expected)
                    io.onStop = { _ in XCTAssertTrue(spawner.processes.allSatisfy { !$0.signals.isEmpty }) }
                    if control == "remove" {
                        host.updateProjectFolders { try grants.remove(project: project, path: root.path) }
                    } else if ["missing", "snapshot", "effect"].contains(control) {
                        try FileManager.default.removeItem(at: root)
                        if control == "effect" {
                            await barrier.release()
                            for _ in 0..<2000 {
                                if grants.unavailableProjects[project] != nil { break }
                                await Task.yield()
                            }
                        } else if control == "missing" {
                            NotificationCenter.default.post(
                                name: NSApplication.didBecomeActiveNotification, object: nil)
                            for _ in 0..<20 { await Task.yield() }
                        } else {
                            XCTAssertThrowsError(try grants.snapshot(context: context))
                        }
                        _ = await host.flushCurrentSends()
                        XCTAssertNotNil(grants.unavailableProjects[project])
                        let changed = events.last { $0["event"] == .string("project_workspaces_changed") }
                        XCTAssertEqual(changed?["project_manifest"]?["projects"], .array([]))
                    } else {
                        host.consume(
                            try frame(
                                .object([
                                    "type": .string("computer_session"), "host_id": .string(hostId),
                                    "session_id": .string(id), "state": .string(control),
                                    "project_context": context.json,
                                ])))
                    }
                    await barrier.release()
                    XCTAssertTrue(spawner.processes.allSatisfy { !$0.signals.isEmpty })
                    for _ in 0..<20 { await Task.yield() }
                    XCTAssertEqual(spawner.plans.count, expected)
                    XCTAssertEqual(
                        grants.roots(project: project).isEmpty,
                        ["remove", "missing", "snapshot", "effect"].contains(control))
                    host.consume(
                        try frame(
                            .object([
                                "type": .string("computer_request"),
                                "request_id": .string("creq_" + String(repeating: "c", count: 32)),
                                "session_id": .string(id),
                                "project_context": context.json, "verb": .string("run_command"),
                                "args": .object(["argv": .array([.string("echo")]), "cwd": .string(root.path)]),
                                "deadline_ms": .number(30000),
                            ])))
                    let refused = await response("creq_" + String(repeating: "c", count: 32), host: host)
                    XCTAssertEqual(refused?["ok"], .bool(false))
                    XCTAssertEqual(spawner.plans.count, expected)
                    host.signedOut()
                    XCTAssertEqual(io.started.count, io.stopped.count)
                }
            }
        }

        func testFolderIdentityLossAfterAFileEffectReportsUncertaintyAndRetiresTheGrant() async throws {
            let container = try folder().resolvingSymlinksInPath()
            let root = container.appendingPathComponent("selected")
            let moved = container.appendingPathComponent("moved")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let project = "12345678-1234-1234-9234-123456789abc"
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var stored: [String: Data] = [:]
            let grants = MacProjectGrants(
                grants: io.port, persistence: .init(read: { stored[$0] }, write: { stored[$0] = $1 }))
            let host = try makeHost(projectGrants: grants, driver: MacProjectMovedAfterEffectDriver(destination: moved))
            let hostId = try XCTUnwrap(host.descriptor?.hostId)
            host.beginWorkspaceNegotiation(server: URL(string: "https://example.test")!, account: "owner")
            host.workspaceNegotiated(projects: true)
            try host.reconcileProjects([project])
            host.updateProjectFolders { try grants.choose(project: project) }
            let manifest = try XCTUnwrap(grants.manifest)
            host.consume(
                try frame(
                    .object([
                        "type": .string("computer_host"), "host_id": .string(hostId),
                        "project_manifest_ack": .object([
                            "generation": .number(Double(manifest.generation)),
                            "digest": .string(manifest.digest), "accepted": .bool(true),
                        ]),
                    ])))
            let context = try ComputerProjectContext(
                chatId: "chat", projectId: project,
                grantRevision: manifest.projects[0].grantRevision, manifestGeneration: manifest.generation)
            let sessionId = UUID().uuidString.lowercased()
            host.consume(
                try frame(
                    .object([
                        "type": .string("computer_session"), "host_id": .string(hostId),
                        "session_id": .string(sessionId), "state": .string("active"), "project_context": context.json,
                    ])))
            let requestId = "creq_" + String(repeating: "d", count: 32)
            host.consume(
                try frame(
                    .object([
                        "type": .string("computer_request"), "request_id": .string(requestId),
                        "session_id": .string(sessionId), "project_context": context.json,
                        "verb": .string("write_file"),
                        "args": .object([
                            "path": .string(root.path + "/proof.txt"), "content": .string("effect completed"),
                            "if_exists": .string("refuse"),
                        ]), "deadline_ms": .number(30000),
                    ])))
            let result = await response(requestId, host: host)
            XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("proof.txt")), "effect completed")
            XCTAssertEqual(result?["ok"], .bool(false))
            XCTAssertNotEqual(result?["error"]?["effect_state"], .string("not_started"))
            XCTAssertNotNil(grants.unavailableProjects[project])
            XCTAssertThrowsError(try grants.snapshot(context: context))
            host.signedOut()
            XCTAssertEqual(io.started.count, io.stopped.count)
        }

        func testLateEndedFrameCannotRetireNewerSession() throws {
            let host = try makeHost()
            let old = UUID().uuidString.lowercased()
            let current = UUID().uuidString.lowercased()
            host.consume(try session(host, old))
            host.consume(try session(host, current))
            host.consume(try session(host, old, "ended"))
            XCTAssertEqual(host.session?.id, current)
            XCTAssertEqual(host.session?.state, "active")
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

        func testFoldersOutsideTheWorkspaceAreRefusedAtOnceAndNothingLaunches() async throws {
            let root = try folder()
            let spawner = MacComputerFakeSpawner()
            let commands = MacComputerCommands(
                spawner: spawner, clock: MacComputerFakeClock { $0 >= 20 }, inherited: [:],
                loginPath: { "/usr/bin:/bin" })
            let host = try makeHost(roots: [root], commands: commands)
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id))
            let granted = host.files.roots[0]
            let cases: [(JSONValue?, String)] = [
                (.string(NSHomeDirectory() + "/Desktop/outside-every-workspace"), "cwd_outside_workspace"),
                (.string(granted + "-sibling"), "cwd_outside_workspace"),
                (.string(granted + "/missing"), "cwd_outside_workspace"),
                (nil, "out_of_range"),
            ]
            for (cwd, expected) in cases {
                var args: [String: JSONValue] = ["argv": .array([.string("echo")])]
                if let cwd { args["cwd"] = cwd }
                let (call, refused) = try request(id, "run_command", args, deadline: 600000)
                host.consume(refused)
                let answer = await response(call, host: host)
                XCTAssertEqual(answer?["ok"], .bool(false), "\(String(describing: cwd))")
                XCTAssertEqual(answer?["error"]?["code"], .string(expected), "\(String(describing: cwd))")
            }
            XCTAssertTrue(spawner.plans.isEmpty)
            XCTAssertFalse(host.working)
        }

        func testEveryCommandIsAnsweredWhenItsTicketLapsesDuringValidationOrRun() async throws {
            let root = try folder()
            let time = HostTicketClock()
            let spawner = MacComputerFakeSpawner { _, output, process in
                time.advance(120)
                output.finish(.stdout)
                output.finish(.stderr)
                process.exit(.exited(0))
            }
            let commands = MacComputerCommands(
                spawner: spawner, clock: MacComputerFakeClock { $0 >= 20 }, inherited: [:],
                loginPath: {
                    time.advance(120)
                    return "/usr/bin:/bin"
                })
            let host = try makeHost(
                roots: [root], commands: commands, authority: ComputerHostAuthority(now: { time.now }))
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id))
            let granted = host.files.roots[0]
            let (missing, unknown) = try request(
                id, "run_command", ["argv": .array([.string("no-such-tool-zz")]), "cwd": .string(granted)],
                deadline: 60000)
            host.consume(unknown)
            let refused = await response(missing, host: host)
            XCTAssertEqual(refused?["ok"], .bool(false))
            XCTAssertEqual(refused?["error"]?["code"], .string("interrupted"))
            XCTAssertTrue(spawner.plans.isEmpty)
            let (lapsed, echo) = try request(
                id, "run_command", ["argv": .array([.string("/bin/echo")]), "cwd": .string(granted)],
                deadline: 60000)
            host.consume(echo)
            let interrupted = await response(lapsed, host: host)
            XCTAssertEqual(spawner.plans.count, 1)
            XCTAssertEqual(interrupted?["ok"], .bool(false))
            XCTAssertEqual(interrupted?["error"]?["code"], .string("interrupted"))
            XCTAssertNil(interrupted?["result"])
            XCTAssertFalse(host.working)
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

        func testHumanPausesDiscardBrowserPermitsButApprovalDecisionsAndResumesKeepThem() throws {
            let monitor = MacComputerTaskMonitor()
            let host = try makeHost(monitor: monitor)
            let browser = MacComputerTaskBrowser()
            host.browser = browser
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id))
            host.pause()
            XCTAssertEqual(browser.discarded, 1)
            host.consume(try session(host, id, "paused", reason: "local_pause"))
            host.resume()
            host.consume(try session(host, id))
            XCTAssertEqual(host.session?.state, "active")
            XCTAssertEqual(browser.discarded, 1)
            host.takeover()
            XCTAssertEqual(browser.discarded, 2)
            host.consume(try session(host, id, "paused", reason: "local_input"))
            host.consume(try session(host, id))
            XCTAssertEqual(host.session?.state, "active")
            monitor.humanInput?()
            XCTAssertEqual(host.session?.state, "paused")
            XCTAssertEqual(browser.discarded, 3)
            host.consume(try session(host, id, "paused", reason: "local_input"))
            host.consume(try session(host, id))
            XCTAssertEqual(host.recordApprovalInteraction(), id)
            XCTAssertEqual(host.session?.state, "paused")
            host.consume(try session(host, id, "paused", reason: "local_input"))
            host.consume(try session(host, id))
            XCTAssertEqual(host.session?.state, "active")
            XCTAssertEqual(browser.discarded, 3)
        }

        func testApprovedBrowserActionsSurviveTheApprovalPauseButNotATakeover() async throws {
            let harness = try MacBrowserHarness()
            await harness.start()
            addTeardownBlock { harness.close() }
            let host = try makeHost()
            host.browser = harness.driver
            harness.driver.host = host
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id))
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let pay = try harness.ref(snap.lines, containing: "button \"Pay now\"")
            let holder = try harness.ref(snap.lines, containing: "textbox \"Card holder\"")
            let click: [String: JSONValue] = ["ref": .string(pay), "snapshot_id": .string(snap.id)]
            func permit(_ ref: String) -> JSONValue {
                .object([
                    "ref": .string(ref), "refs": .array([.string(ref)]), "origin": .string(harness.origin),
                    "snapshot_id": .string(snap.id),
                ])
            }
            await harness.expectCode("browser_click", click, "confirmation_required")
            XCTAssertEqual(host.recordApprovalInteraction(), id)
            host.consume(try session(host, id, "paused", reason: "local_input"))
            host.resume()
            _ = await host.flushCurrentSends()
            XCTAssertEqual(events.last?["event"], .string("resumed"))
            host.consume(try session(host, id))
            XCTAssertEqual(host.session?.state, "active")
            await harness.expectCode("browser_click", click.merging(["permit": permit(pay)]) { $1 }, nil)
            try await harness.expectPage("document.title", "paid")
            let fill: [String: JSONValue] = [
                "snapshot_id": .string(snap.id),
                "fields": .array([.object(["ref": .string(holder), "value": .string("A Lovelace")])]),
            ]
            await harness.expectCode("browser_fill", fill, "confirmation_required")
            host.takeover()
            host.consume(try session(host, id, "paused", reason: "local_input"))
            host.consume(try session(host, id))
            XCTAssertEqual(host.session?.state, "active")
            let permitted = fill.merging(["permit": permit(holder)]) { $1 }
            await harness.expectCode("browser_fill", permitted, "confirmation_required")
            try await harness.expectPage("document.getElementById('holder').value", "")
            await harness.expectCode("browser_fill", permitted, nil)
            try await harness.expectPage("document.getElementById('holder').value", "A Lovelace")
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
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 380, height: 160), styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = rendered
            defer { window.close() }
            rendered.view.layoutSubtreeIfNeeded()
            let returnKey = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(window.performKeyEquivalent(with: returnKey), "Open Astral is the panel's default action")
            XCTAssertEqual(activations, 1)
            host.bringAstralForward()
            XCTAssertEqual(activations, 2)
            host.approvalWaiting(false)
            XCTAssertFalse(host.awaitingApproval)
            host.approvalWaiting(true)
            host.stop()
            XCTAssertFalse(host.awaitingApproval)
            XCTAssertFalse(host.taskActive)
        }
    }

    nonisolated final class HostTicketClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 1000.0
        var now: Double { lock.withLock { current } }
        func advance(_ seconds: Double) { lock.withLock { current += seconds } }
    }

    @MainActor
    final class MacComputerTaskMonitor: MacComputerMonitoring {
        var running = false
        var humanInput: (@MainActor () -> Void)?
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
            running = true
            self.humanInput = humanInput
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

    actor MacProjectMovedAfterEffectDriver: MacComputerDriving {
        let destination: URL
        init(destination: URL) { self.destination = destination }
        func execute(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            let workspace = try XCTUnwrap(workspaces.first)
            try workspace.write(
                workspace.root + "/proof.txt", content: "effect completed", overwrite: false, authorize: authorize)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: workspace.root), to: destination)
            return ["written": .bool(true)]
        }
        func reset() {}
    }

    @MainActor
    final class MacComputerTaskBrowser: MacBrowserVerbHandling {
        var isEnabled = true
        var handled: [(verb: String, ticket: String)] = []
        private(set) var discarded = 0
        func handle(
            _ request: ComputerHostRequest, ticket: ComputerHostTicket,
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try authorize()
            handled.append((request.verb, ticket.requestId))
            return ["snapshot_id": .string("s1")]
        }
        func discardPermits() { discarded += 1 }
    }
    private actor ProjectCommandStartBarrier {
        var calls = 0
        let hold: Bool
        init(hold: Bool) { self.hold = hold }
        private var pending: CheckedContinuation<Void, Never>?
        func path() async -> String {
            calls += 1
            if hold { await withCheckedContinuation { pending = $0 } }
            return "/usr/bin:/bin"
        }
        func release() {
            pending?.resume()
            pending = nil
        }
    }
#endif
