// Exercises the native computer host's closed v1 wire models and physical-effect admission fence.
// These fixtures share the server's existing computer transport without granting authority from text.

import XCTest

@testable import AstralCore

final class ComputerHostProtocolTests: XCTestCase {
    let session = "88888888-8888-4888-8888-888888888888"

    func request(_ verb: String = "click", args: [String: JSONValue] = ["x": .number(1), "y": .number(2)]) throws
        -> ComputerHostRequest
    {
        try ComputerHostRequest(
            json: .object([
                "type": .string("computer_request"), "request_id": .string("creq_" + String(repeating: "a", count: 32)),
                "session_id": .string(session), "verb": .string(verb), "args": .object(args),
                "deadline_ms": .number(1000),
            ]))
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
        XCTAssertThrowsError(try request("run_command", args: [:]))
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
