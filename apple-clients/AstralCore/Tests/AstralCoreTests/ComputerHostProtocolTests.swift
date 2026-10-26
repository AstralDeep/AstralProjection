// Exercises the native computer host's closed v1 wire models and physical-effect admission fence.
// These fixtures share the server's existing computer transport without granting authority from text.

import XCTest

@testable import AstralCore

final class ComputerHostProtocolTests: XCTestCase {
    let session = "88888888-8888-4888-8888-888888888888"

    let job = "abcdef01-2345-4678-9abc-def012345678"

    func request(
        _ verb: String = "click", args: [String: JSONValue] = ["x": .number(1), "y": .number(2)],
        deadline: Double = 1000
    ) throws -> ComputerHostRequest {
        try ComputerHostRequest(
            json: .object([
                "type": .string("computer_request"), "request_id": .string("creq_" + String(repeating: "a", count: 32)),
                "session_id": .string(session), "verb": .string(verb), "args": .object(args),
                "deadline_ms": .number(deadline),
            ]))
    }

    func command(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        ["command": .string("wc -l notes.md"), "cwd": .string("/Users/sam/Projects/x")].merging(extra) { $1 }
    }

    func testClosedArgumentsAndTerminalAuthority() throws {
        XCTAssertEqual(try request().verb, "click")
        XCTAssertEqual(
            try request(args: ["x": .number(1), "y": .number(2), "hwnd": .number(9)]).args["hwnd"], .number(9))
        XCTAssertThrowsError(try request(args: ["x": .number(1), "y": .number(2), "extra": .bool(true)]))
        XCTAssertThrowsError(
            try request("open_app", args: ["app": .string("Terminal"), "args": .array([.string("-c")])]))
        XCTAssertThrowsError(try request("type_text", args: ["text": .string(String(repeating: "a", count: 4001))]))
        XCTAssertEqual(
            try request("type_text", args: ["text": .string("hello"), "terminal_ok": .bool(true)]).args["terminal_ok"],
            .bool(true))
        XCTAssertThrowsError(try request("run_shell", args: [:]))
    }

    func testCommandAndBrowserVerbsJoinTheClosedVocabulary() throws {
        let added: Set<String> = [
            "run_command", "read_output", "interrupt_command", "browser_snapshot", "browser_get_text",
            "browser_screenshot", "browser_wait", "browser_navigate", "browser_click", "browser_fill", "browser_press",
            "browser_scroll", "browser_dialog",
        ]
        XCTAssertTrue(added.isSubset(of: ComputerHostRequest.verbs))
        XCTAssertEqual(ComputerHostRequest.verbs.count, 32)
        XCTAssertFalse(ComputerHostRequest.verbs.contains("run_shell"))
        let descriptor = try ComputerHostDescriptor(
            hostId: session, name: "Test Mac", clientVersion: "1.9.0",
            screens: [ComputerHostScreen(index: 0, width: 1000, height: 800, scale: 2, primary: true)],
            verbs: Array(added))
        XCTAssertEqual(Set(descriptor.verbs), added)
        XCTAssertThrowsError(
            try ComputerHostDescriptor(
                hostId: session, name: "Test Mac", clientVersion: "1.9.0",
                screens: [ComputerHostScreen(index: 0, width: 1000, height: 800, scale: 2, primary: true)],
                verbs: ["run_shell"]))
    }

    func testDeadlineCeilingFollowsTheVerb() throws {
        let ceilings: [String: Double] = [
            "run_command": 600000, "read_output": 30000, "interrupt_command": 5000, "browser_navigate": 15000,
            "browser_wait": 15000, "browser_snapshot": 5000, "browser_get_text": 5000, "browser_screenshot": 5000,
            "browser_click": 5000, "browser_fill": 5000, "browser_press": 5000, "browser_scroll": 5000,
            "browser_dialog": 5000,
        ]
        for verb in ComputerHostRequest.verbs {
            XCTAssertEqual(ComputerHostRequest.maximumDeadlineMs(for: verb), ceilings[verb] ?? 30000, verb)
        }
        XCTAssertEqual(try request("run_command", args: command(), deadline: 600000).deadline, 600)
        XCTAssertThrowsError(try request("run_command", args: command(), deadline: 600001))
        XCTAssertNoThrow(try request(deadline: 30000))
        XCTAssertThrowsError(try request(deadline: 30001))
        XCTAssertThrowsError(try request(deadline: 0))
        XCTAssertThrowsError(try request(deadline: 1.5))
        let interrupt: [String: JSONValue] = ["job_id": .string(job), "signal": .string("INT")]
        XCTAssertNoThrow(try request("interrupt_command", args: interrupt, deadline: 5000))
        XCTAssertThrowsError(try request("interrupt_command", args: interrupt, deadline: 5001))
        XCTAssertNoThrow(try request("read_output", args: ["job_id": .string(job)], deadline: 30000))
        XCTAssertThrowsError(try request("read_output", args: ["job_id": .string(job)], deadline: 30001))
        let url: [String: JSONValue] = ["url": .string("https://example.org/form")]
        XCTAssertNoThrow(try request("browser_navigate", args: url, deadline: 15000))
        XCTAssertThrowsError(try request("browser_navigate", args: url, deadline: 15001))
        XCTAssertNoThrow(try request("browser_wait", args: ["for": .string("load")], deadline: 15000))
        XCTAssertThrowsError(try request("browser_wait", args: ["for": .string("load")], deadline: 15001))
        XCTAssertNoThrow(try request("browser_snapshot", args: [:], deadline: 5000))
        XCTAssertThrowsError(try request("browser_snapshot", args: [:], deadline: 5001))
    }

    func testRunCommandTakesExactlyOneCommandFormAndBoundedFields() throws {
        XCTAssertEqual(try request("run_command", args: command()).args["command"], .string("wc -l notes.md"))
        let argv: [String: JSONValue] = [
            "argv": .array([.string("wc"), .string("-l"), .string("notes.md")]), "cwd": .string("/Users/sam/x"),
        ]
        XCTAssertNoThrow(try request("run_command", args: argv))
        XCTAssertNoThrow(
            try request(
                "run_command",
                args: command([
                    "env": .object(["FOO": .string("bar"), "_X1": .string("")]), "timeout_s": .number(600),
                    "background": .bool(false), "stdin": .string(String(repeating: "a", count: 16384)),
                ])))
        XCTAssertNoThrow(
            try request("run_command", args: command(["timeout_s": .number(3600), "background": .bool(true)])))
        func environment(_ count: Int) -> JSONValue {
            .object(Dictionary(uniqueKeysWithValues: (0..<count).map { ("V\($0)", JSONValue.string("x")) }))
        }
        XCTAssertNoThrow(try request("run_command", args: command(["env": environment(32)])))
        let env33 = environment(33)
        let refused: [[String: JSONValue]] = [
            ["cwd": .string("/Users/sam/x")],
            command(["argv": .array([.string("wc")])]),
            command(["command": .string("")]),
            command(["command": .string(String(repeating: "a", count: 4097))]),
            command(["command": .string("ls\u{0}")]),
            command(["command": .number(1)]),
            ["command": .string("ls")],
            command(["cwd": .string("Projects/x")]),
            command(["cwd": .string("/Users/sam/x/../y")]),
            command(["cwd": .string("")]),
            command(["cwd": .number(1)]),
            ["argv": .array([]), "cwd": .string("/Users/sam/x")],
            ["argv": .array([.string("")]), "cwd": .string("/Users/sam/x")],
            ["argv": .array([.string("wc"), .number(1)]), "cwd": .string("/Users/sam/x")],
            ["argv": .string("wc"), "cwd": .string("/Users/sam/x")],
            command(["env": env33]),
            command(["env": .object(["FOO": .number(1)])]),
            command(["env": .object(["1FOO": .string("x")])]),
            command(["env": .object(["FO=O": .string("x")])]),
            command(["env": .array([])]),
            command(["timeout_s": .number(0)]),
            command(["timeout_s": .number(601)]),
            command(["timeout_s": .number(601), "background": .bool(false)]),
            command(["timeout_s": .number(3601), "background": .bool(true)]),
            command(["timeout_s": .number(1.5)]),
            command(["background": .string("yes")]),
            command(["stdin": .string(String(repeating: "a", count: 16385))]),
            command(["stdin": .string(String(repeating: "é", count: 8193))]),
            command(["stdin": .number(1)]),
            command(["shell": .string("/bin/bash")]),
        ]
        for args in refused {
            XCTAssertThrowsError(try request("run_command", args: args), "\(args)")
        }
    }

    func testReadOutputAndInterruptAddressAJobWithBoundedOptions() throws {
        XCTAssertNoThrow(
            try request(
                "read_output",
                args: [
                    "job_id": .string(job), "stream": .string("both"), "offset": .number(0),
                    "max_bytes": .number(65536), "wait_s": .number(25),
                ]))
        XCTAssertNoThrow(
            try request(
                "read_output", args: ["job_id": .string(job), "stream": .string("stderr"), "wait_s": .number(0)]))
        for args: [String: JSONValue] in [
            [:], ["job_id": .string("job-1")], ["job_id": .string(job), "stream": .string("all")],
            ["job_id": .string(job), "offset": .number(-1)], ["job_id": .string(job), "offset": .number(0.5)],
            ["job_id": .string(job), "max_bytes": .number(0)], ["job_id": .string(job), "max_bytes": .number(65537)],
            ["job_id": .string(job), "wait_s": .number(26)], ["job_id": .string(job), "wait_s": .number(-1)],
            ["job_id": .string(job), "signal": .string("INT")],
        ] {
            XCTAssertThrowsError(try request("read_output", args: args), "\(args)")
        }
        for signal in ["INT", "TERM", "KILL"] {
            XCTAssertNoThrow(
                try request("interrupt_command", args: ["job_id": .string(job), "signal": .string(signal)]))
        }
        for args: [String: JSONValue] in [
            ["job_id": .string(job)], ["signal": .string("INT")],
            ["job_id": .string(job), "signal": .string("HUP")], ["job_id": .string(job), "signal": .number(2)],
            ["job_id": .string(job.uppercased()), "signal": .string("INT")],
            ["job_id": .string(job + "\n"), "signal": .string("INT")],
        ] {
            XCTAssertThrowsError(try request("interrupt_command", args: args), "\(args)")
        }
    }

    func testBrowserObservationsTakeBoundedReferencesAndModes() throws {
        XCTAssertNoThrow(try request("browser_snapshot", args: [:]))
        XCTAssertNoThrow(
            try request(
                "browser_snapshot",
                args: ["scope_ref": .string("e12"), "mode": .string("interactive"), "max_chars": .number(60000)]))
        XCTAssertNoThrow(try request("browser_snapshot", args: ["mode": .string("all")]))
        XCTAssertNoThrow(try request("browser_get_text", args: ["ref": .string("e1"), "max_chars": .number(1)]))
        XCTAssertNoThrow(try request("browser_screenshot", args: ["max_width": .number(1280), "ref": .string("e3")]))
        XCTAssertNoThrow(
            try request(
                "browser_wait", args: ["for": .string("text"), "text": .string("Done"), "seconds": .number(10)]))
        XCTAssertNoThrow(try request("browser_wait", args: ["for": .string("ref"), "ref": .string("e4")]))
        let refused: [(String, [String: JSONValue])] = [
            ("browser_snapshot", ["mode": .string("full")]),
            ("browser_snapshot", ["scope_ref": .string("12")]),
            ("browser_snapshot", ["max_chars": .number(60001)]),
            ("browser_snapshot", ["max_chars": .number(0)]),
            ("browser_get_text", ["ref": .string("e")]),
            ("browser_get_text", ["ref": .string("E1")]),
            ("browser_get_text", ["ref": .string("e1 ")]),
            ("browser_get_text", ["ref": .string("e1\n")]),
            ("browser_get_text", ["ref": .number(1)]),
            ("browser_screenshot", ["max_width": .number(100)]),
            ("browser_screenshot", ["max_width": .number(1921)]),
            ("browser_wait", [:]),
            ("browser_wait", ["for": .string("idle")]),
            ("browser_wait", ["for": .string("text")]),
            ("browser_wait", ["for": .string("ref")]),
            ("browser_wait", ["for": .string("load"), "text": .string("x")]),
            ("browser_wait", ["for": .string("load"), "ref": .string("e1")]),
            ("browser_wait", ["for": .string("load"), "seconds": .number(11)]),
            ("browser_wait", ["for": .string("load"), "seconds": .number(0)]),
            ("browser_get_text", ["x": .number(1), "y": .number(1)]),
        ]
        for (verb, args) in refused {
            XCTAssertThrowsError(try request(verb, args: args), "\(verb) \(args)")
        }
    }

    func testBrowserActionsNeedSnapshotBoundReferencesAndWebURLs() throws {
        for url in ["https://example.org/form", "http://localhost:8080/a?b=c", "HTTPS://Example.org"] {
            XCTAssertNoThrow(try request("browser_navigate", args: ["url": .string(url)]), url)
        }
        for action in ["back", "forward", "reload"] {
            XCTAssertNoThrow(try request("browser_navigate", args: ["action": .string(action)]))
        }
        let click: [String: JSONValue] = ["ref": .string("e12"), "snapshot_id": .string("s9")]
        XCTAssertNoThrow(try request("browser_click", args: click))
        XCTAssertNoThrow(
            try request(
                "browser_click", args: click.merging(["button": .string("right"), "count": .number(2)]) { $1 }))
        let fields = JSONValue.array([.object(["ref": .string("e2"), "value": .string("Ada")])])
        XCTAssertNoThrow(try request("browser_fill", args: ["fields": fields, "snapshot_id": .string("s9")]))
        XCTAssertNoThrow(try request("browser_press", args: ["keys": .string("cmd+a")]))
        XCTAssertNoThrow(try request("browser_press", args: ["keys": .string("Enter"), "ref": .string("e2")]))
        XCTAssertNoThrow(try request("browser_scroll", args: ["dy": .number(600)]))
        XCTAssertNoThrow(try request("browser_scroll", args: ["dy": .number(-600), "ref": .string("e5")]))
        XCTAssertNoThrow(try request("browser_dialog", args: ["action": .string("accept"), "text": .string("")]))
        XCTAssertNoThrow(try request("browser_dialog", args: ["action": .string("dismiss")]))
        let tooMany = JSONValue.array(
            (0..<33).map { .object(["ref": .string("e\($0)"), "value": .string("x")]) })
        let refused: [(String, [String: JSONValue])] = [
            ("browser_navigate", [:]),
            ("browser_navigate", ["url": .string("https://example.org"), "action": .string("back")]),
            ("browser_navigate", ["url": .string("file:///etc/passwd")]),
            ("browser_navigate", ["url": .string("javascript:alert(1)")]),
            ("browser_navigate", ["url": .string("data:text/html,hi")]),
            ("browser_navigate", ["url": .string("astral://x")]),
            ("browser_navigate", ["url": .string("https://")]),
            ("browser_navigate", ["url": .string("https://exa mple.org")]),
            ("browser_navigate", ["url": .string("example.org")]),
            ("browser_navigate", ["url": .string("https://user:secret@example.org")]),
            ("browser_navigate", ["url": .string("https://example.org/" + String(repeating: "a", count: 4096))]),
            ("browser_navigate", ["action": .string("stop")]),
            ("browser_click", ["ref": .string("e12")]),
            ("browser_click", ["snapshot_id": .string("s9")]),
            ("browser_click", ["ref": .string("x12"), "snapshot_id": .string("s9")]),
            ("browser_click", ["ref": .string("e12"), "snapshot_id": .string("9")]),
            ("browser_click", click.merging(["button": .string("middle")]) { $1 }),
            ("browser_click", click.merging(["count": .number(3)]) { $1 }),
            ("browser_click", click.merging(["x": .number(1)]) { $1 }),
            ("browser_fill", ["fields": fields]),
            ("browser_fill", ["fields": .array([]), "snapshot_id": .string("s9")]),
            ("browser_fill", ["fields": tooMany, "snapshot_id": .string("s9")]),
            ("browser_fill", ["fields": .array([.object(["ref": .string("e2")])]), "snapshot_id": .string("s9")]),
            (
                "browser_fill",
                [
                    "fields": .array([.object(["ref": .string("e2"), "value": .number(1)])]),
                    "snapshot_id": .string("s9"),
                ]
            ),
            (
                "browser_fill",
                [
                    "fields": .array([
                        .object(["ref": .string("e2"), "value": .string("x"), "secret": .bool(true)])
                    ]), "snapshot_id": .string("s9"),
                ]
            ),
            (
                "browser_fill",
                [
                    "fields": .array([
                        .object(["ref": .string("e2"), "value": .string(String(repeating: "a", count: 16385))])
                    ]), "snapshot_id": .string("s9"),
                ]
            ),
            ("browser_fill", ["fields": .array([.string("e2")]), "snapshot_id": .string("s9")]),
            ("browser_press", [:]),
            ("browser_press", ["keys": .string("hyper+a")]),
            ("browser_press", ["keys": .string("Enter"), "ref": .string("e")]),
            ("browser_scroll", [:]),
            ("browser_scroll", ["dy": .number(10001)]),
            ("browser_scroll", ["dy": .number(1.5)]),
            ("browser_dialog", [:]),
            ("browser_dialog", ["action": .string("ok")]),
            ("browser_dialog", ["action": .string("accept"), "text": .string(String(repeating: "a", count: 4001))]),
        ]
        for (verb, args) in refused {
            XCTAssertThrowsError(try request(verb, args: args), "\(verb) \(args)")
        }
    }

    func testExactTerminalAppRequiresTargetAndMatchesActualBundle() throws {
        let args: [String: JSONValue] = [
            "text": .string("printf hello"), "hwnd": .number(9), "terminal_app": .string("com.apple.Terminal"),
            "terminal_ok": .bool(true),
        ]
        XCTAssertEqual(try request("type_text", args: args).args["terminal_app"], .string("com.apple.Terminal"))
        XCTAssertThrowsError(
            try request("type_text", args: ["text": .string("hello"), "terminal_app": .string("Terminal")]))
        XCTAssertThrowsError(
            try ComputerTerminalPolicy.authorize("Terminal", bundle: "com.google.Chrome", granted: true))
        XCTAssertThrowsError(
            try ComputerTerminalPolicy.authorize("Terminal", bundle: "com.apple.Terminal", granted: false))
        XCTAssertNoThrow(try ComputerTerminalPolicy.authorize("Terminal", bundle: "com.apple.Terminal", granted: true))
    }

    func testNamedTerminalLaunchMustMatchResolvedBundleIdentity() {
        XCTAssertThrowsError(
            try ComputerTerminalPolicy.validateLaunch("/workspace/Terminal.app", bundle: "example.fake"))
        XCTAssertNoThrow(
            try ComputerTerminalPolicy.validateLaunch(
                "/System/Applications/Utilities/Terminal.app", bundle: "com.apple.Terminal"))
        XCTAssertThrowsError(try ComputerTerminalPolicy.validateLaunch("Warp.app", bundle: "example.fake"))
        XCTAssertNoThrow(try ComputerTerminalPolicy.validateLaunch("/workspace/Regular.app", bundle: "example.regular"))
    }

    func testDescriptorIsOptionalAndDoesNotEnableAgentHosting() throws {
        let descriptor = try ComputerHostDescriptor(
            hostId: session, name: "Test Mac", clientVersion: "1.8.0",
            screens: [ComputerHostScreen(index: 0, width: 1000, height: 800, scale: 2, primary: true)],
            verbs: ["screenshot"])
        let frame = Outbound.registerUI(
            token: "test", sessionId: nil, device: .macos(viewportWidth: 800, viewportHeight: 600), resumed: false,
            computerHost: descriptor)
        let value = try JSONValue.parse(Data(frame.utf8))
        XCTAssertEqual(value["computer_host"]?["platform"], .string("macos"))
        XCTAssertNil(value["agent_host"])
        XCTAssertFalse(value["capabilities"]?.arrayValue?.contains(.string("agent_host")) ?? true)
    }

    func testHostCapableIsIndependentOfConsentAndWorkbenchNegotiatesExplicitly() throws {
        let frame = Outbound.registerUI(
            token: "test", sessionId: nil, device: .macos(viewportWidth: 800, viewportHeight: 600), resumed: false,
            computerHostCapable: true, macWorkbenchSupported: true)
        let value = try JSONValue.parse(Data(frame.utf8))
        XCTAssertNil(value["computer_host"])
        XCTAssertTrue(value["capabilities"]?.arrayValue?.contains(.string("computer_host_capable")) == true)
        XCTAssertTrue(value["capabilities"]?.arrayValue?.contains(.string("mac_workbench_v1")) == true)
        XCTAssertEqual(value["device"]?["mac_workbench_v1"], .bool(true))
        let plain = try JSONValue.parse(
            Data(
                Outbound.registerUI(
                    token: "test", sessionId: nil, device: .ios(viewportWidth: 400, viewportHeight: 800), resumed: false
                ).utf8))
        XCTAssertFalse(plain["capabilities"]?.arrayValue?.contains(.string("computer_host_capable")) == true)
        XCTAssertFalse(plain["capabilities"]?.arrayValue?.contains(.string("mac_workbench_v1")) == true)
        XCTAssertNil(plain["device"]?["mac_workbench_v1"])
    }

    func testReplayExpiryPauseAndConnectionReplacementDenyTickets() throws {
        var fence = ComputerHostFence()
        try fence.begin(sessionId: session)
        let ticket = try fence.admit(request(), now: 10)
        XCTAssertTrue(fence.permits(ticket, now: 10.5))
        XCTAssertFalse(fence.permits(ticket, now: 11))
        XCTAssertThrowsError(try fence.admit(request(), now: 10.5))
        fence.invalidate()
        XCTAssertFalse(fence.permits(ticket, now: 10.5))
        XCTAssertThrowsError(try fence.begin(sessionId: session))
    }

    func testPauseRetainsReplayLedgerAndResumeNeedsFreshTicket() throws {
        var fence = ComputerHostFence()
        try fence.begin(sessionId: session)
        let ticket = try fence.admit(request(), now: 1)
        fence.pause()
        XCTAssertFalse(fence.permits(ticket, now: 1.1))
        fence.resume()
        XCTAssertThrowsError(try fence.admit(request(), now: 1.2))
    }

    func testCurrentHostEventsNeverAcceptForeignActions() throws {
        let event = ComputerHostOutbound.frame(
            action: "computer_response",
            payload: [
                "request_id": .string("creq_" + String(repeating: "a", count: 32)), "ok": .bool(true),
                "result": .object([:]),
            ])
        XCTAssertTrue(ComputerHostOutbound.isValid(event))
        XCTAssertFalse(
            ComputerHostOutbound.isValid(
                Outbound.uiEvent(action: "chat_message", sessionId: nil, payload: .object([:]))))
    }

    func testEveryHostVariantBindsFreshIdentityToCurrentRegistration() throws {
        let host = try ComputerHostDescriptor(
            hostId: session, name: "Synthetic Mac", clientVersion: "1.8.0",
            screens: [ComputerHostScreen(index: 0, width: 1000, height: 800, scale: 2, primary: true)],
            verbs: ["screenshot"])
        var frames = [
            ComputerHostOutbound.frame(
                action: "computer_event",
                payload: ["event": .string("announce"), "host_id": .string(session), "host": host.json]),
            ComputerHostOutbound.frame(
                action: "computer_event", payload: ["event": .string("withdraw"), "host_id": .string(session)]),
            ComputerHostOutbound.frame(
                action: "computer_response",
                payload: [
                    "request_id": .string("creq_" + String(repeating: "a", count: 32)), "ok": .bool(true),
                    "result": .object([:]),
                ]),
            ComputerHostOutbound.frame(
                action: "computer_response",
                payload: [
                    "request_id": .string("creq_" + String(repeating: "b", count: 32)), "ok": .bool(false),
                    "error": .object(["code": .string("interrupted"), "message": .string("Synthetic denial")]),
                ]),
        ]
        frames += ["paused", "resumed", "stopped", "heartbeat"].map {
            ComputerHostOutbound.frame(
                action: "computer_event",
                payload: ["event": .string($0), "host_id": .string(session), "session_id": .string(session)])
        }
        var identities = Set<String>()
        for frame in frames {
            XCTAssertFalse(ComputerHostOutbound.isBound(frame, connectionGeneration: session))
            let bound = try XCTUnwrap(ComputerHostOutbound.bindToConnection(frame, connectionGeneration: session))
            let value = try JSONValue.parse(Data(bound.utf8))
            XCTAssertTrue(ComputerHostOutbound.isBound(bound, connectionGeneration: session))
            XCTAssertFalse(ComputerHostOutbound.isBound(bound, connectionGeneration: UUID().uuidString.lowercased()))
            XCTAssertEqual(value["payload"], try JSONValue.parse(Data(frame.utf8))["payload"])
            XCTAssertEqual(
                Set(try XCTUnwrap(value.objectValue).keys),
                ["type", "action", "payload", "submission_id", "request_generation", "connection_generation"])
            for key in ["submission_id", "request_generation"] {
                let identity = try XCTUnwrap(value[key]?.stringValue)
                XCTAssertTrue(computerUUID(identity))
                XCTAssertTrue(identities.insert(identity).inserted)
            }
            XCTAssertNil(ComputerHostOutbound.bindToConnection(bound, connectionGeneration: session))
        }
        XCTAssertEqual(identities.count, frames.count * 2)
    }

    func testHostEnvelopeRejectsPartialMalformedConflictingAndForeignMetadata() throws {
        let frame = ComputerHostOutbound.frame(
            action: "computer_event", payload: ["event": .string("withdraw"), "host_id": .string(session)])
        XCTAssertNil(ComputerHostOutbound.bindToConnection(frame, connectionGeneration: "invalid"))
        XCTAssertNil(
            ComputerHostOutbound.bindToConnection(frame, connectionGeneration: session, submissionId: "invalid"))
        XCTAssertNil(
            ComputerHostOutbound.bindToConnection(frame, connectionGeneration: session, requestGeneration: "invalid"))
        let bound = try XCTUnwrap(ComputerHostOutbound.bindToConnection(frame, connectionGeneration: session))
        XCTAssertFalse(ComputerHostOutbound.isBound(bound, connectionGeneration: "invalid"))
        let original = try XCTUnwrap(JSONValue.parse(Data(bound.utf8)).objectValue)
        for key in ["submission_id", "request_generation", "connection_generation"] {
            for replacement: JSONValue? in [
                nil, .string("invalid"), .bool(true), .string("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
            ] {
                var value = original
                value[key] = replacement
                let text = String(decoding: try JSONValue.object(value).encoded(), as: UTF8.self)
                XCTAssertFalse(ComputerHostOutbound.isValid(text))
                XCTAssertFalse(ComputerHostOutbound.isBound(text, connectionGeneration: session))
                XCTAssertNil(ComputerHostOutbound.bindToConnection(text, connectionGeneration: session))
            }
        }
        for key in ["session_id", "owner_id", "config"] {
            var value = original
            value[key] = .string(session)
            XCTAssertFalse(
                ComputerHostOutbound.isValid(String(decoding: try JSONValue.object(value).encoded(), as: UTF8.self)))
        }
        var conflicting = original
        conflicting["payload"] = .object([
            "event": .string("withdraw"), "host_id": .string(session),
            "connection_generation": .string(UUID().uuidString.lowercased()),
        ])
        XCTAssertFalse(
            ComputerHostOutbound.isValid(String(decoding: try JSONValue.object(conflicting).encoded(), as: UTF8.self)))
    }

    func testKeyboardChunksPreserveNonBMPScalars() throws {
        let text = String(repeating: "a", count: 19) + "🪐" + "b"
        let chunks = ComputerHostText.keyboardChunks(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), text)
        XCTAssertThrowsError(
            try request("type_text", args: ["text": .string("a" + String(repeating: "\u{0301}", count: 4000))]))
    }

    func testDistributionMarkerCannotEnableSandboxedOrUnsealedHost() {
        XCTAssertFalse(
            ComputerHostDistribution.permits(
                marker: "direct-download", sandboxed: true, hardened: true, signatureValid: true, identityMatches: true,
                debuggerAllowed: false)
        )
        XCTAssertFalse(
            ComputerHostDistribution.permits(
                marker: "direct-download", sandboxed: false, hardened: false, signatureValid: true,
                identityMatches: true, debuggerAllowed: false))
        XCTAssertFalse(
            ComputerHostDistribution.permits(
                marker: "direct-download", sandboxed: false, hardened: true, signatureValid: false,
                identityMatches: true, debuggerAllowed: false))
        XCTAssertFalse(
            ComputerHostDistribution.permits(
                marker: "controller", sandboxed: false, hardened: true, signatureValid: true, identityMatches: true,
                debuggerAllowed: false))
        XCTAssertTrue(
            ComputerHostDistribution.permits(
                marker: "direct-download", sandboxed: false, hardened: true, signatureValid: true,
                identityMatches: true,
                debuggerAllowed: false
            ))
    }

    func testHardenedHostWithDebuggerEntitlementIsRejected() {
        XCTAssertFalse(
            ComputerHostDistribution.permits(
                marker: "direct-download", sandboxed: false, hardened: true, signatureValid: true,
                identityMatches: true, debuggerAllowed: true))
        XCTAssertTrue(
            ComputerHostDistribution.permits(
                marker: "direct-download", sandboxed: false, hardened: true, signatureValid: true,
                identityMatches: true, debuggerAllowed: false))
    }

    func testReviewedPointerTargetBoundsCoverStartEndAndExclusiveEdges() {
        let bounds = CGRect(x: -100, y: 20, width: 200, height: 100)
        XCTAssertNoThrow(
            try ComputerHostGeometry.validate(CGPoint(x: -100, y: 20), end: CGPoint(x: 99, y: 119), within: bounds))
        XCTAssertThrowsError(try ComputerHostGeometry.validate(CGPoint(x: -101, y: 50), end: nil, within: bounds))
        XCTAssertThrowsError(try ComputerHostGeometry.validate(CGPoint(x: 100, y: 50), end: nil, within: bounds))
        XCTAssertThrowsError(try ComputerHostGeometry.validate(CGPoint(x: 0, y: 120), end: nil, within: bounds))
        XCTAssertThrowsError(
            try ComputerHostGeometry.validate(CGPoint(x: 0, y: 50), end: CGPoint(x: 101, y: 50), within: bounds))
        XCTAssertThrowsError(
            try ComputerHostGeometry.validate(CGPoint(x: CGFloat.infinity, y: 50), end: nil, within: bounds))
    }
}
