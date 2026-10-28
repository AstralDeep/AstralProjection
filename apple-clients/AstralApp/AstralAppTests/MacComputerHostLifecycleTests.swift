// Exercises real host lifecycle decisions through raw native IO and protocol parsers.
// Recorded input, controlled delays and process-local notifications never actuate the desktop.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import Observation
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerHostLifecycleTests: XCTestCase {
        func testApprovalTimeoutUsesTheRawDelayAndLateAcknowledgmentCannotApproveIt() async throws {
            let fixture = try MacComputerLifecycleFixture()
            defer { fixture.close() }
            try fixture.enableAndStart()
            let barrier = fixture.host.recordApprovalInteraction()
            let allowed = await fixture.host.flushApprovalPause(barrier)
            XCTAssertFalse(allowed)
            XCTAssertEqual(fixture.io.configure { $0.trace.filter { $0 == "delay" }.count }, 1)
            fixture.host.consume(try fixture.session(state: "paused"))
            XCTAssertEqual(fixture.host.session?.state, "paused")
            XCTAssertFalse(fixture.channel.events.contains("resumed"))
        }

        func testMonitorFailureRequiresFreshLocalEvidenceBeforeEnabling() throws {
            let fixture = try MacComputerLifecycleFixture()
            defer { fixture.close() }
            fixture.monitor.allowed = false
            try fixture.enable(expected: false)
            XCTAssertNil(fixture.host.descriptor)
            XCTAssertTrue(fixture.host.lastError?.contains("monitoring could not start") == true)
            XCTAssertFalse(fixture.channel.events.contains("announce"))
            XCTAssertFalse(fixture.store.dictionaryRepresentation().contains { $0.key.hasPrefix("computer.consent.") })
            fixture.monitor.allowed = true
            fixture.host.setEnabled(true)
            XCTAssertFalse(fixture.host.enabled)
            try fixture.enable()
            XCTAssertTrue(fixture.host.enabled)
            XCTAssertEqual(fixture.monitor.starts, 2)
        }

        func testPermissionRequestRefreshesFactsWithoutGrantingAuthority() {
            for returned in [false, true] {
                var ready = false
                var rearms = 0
                var opened = 0
                let suite = UUID().uuidString
                let store = UserDefaults(suiteName: suite)!
                let host = MacComputerHost(
                    available: true, defaults: store,
                    driver: MacComputerDriver(marker: 30, system: MacComputerTestSystem()),
                    monitor: MacComputerLifecycleMonitor(),
                    permissionProvider: {
                        MacComputerPermissions(accessibility: ready, screen: ready, monitoring: ready)
                    },
                    permissionRequester: { _ in
                        ready = true
                        return returned
                    },
                    settingsOpener: { _ in
                        opened += 1
                        return true
                    }, desktopProbe: { true },
                    desktopRearm: {
                        rearms += 1
                        return false
                    }, system: MacComputerTestSystem(), panelPresenter: { _ in })
                host.bind(owner: "lifecycle-owner") { _ in true }
                host.requestScreen()
                XCTAssertTrue(host.screenAllowed)
                XCTAssertFalse(host.enabled)
                XCTAssertFalse(host.desktopAvailable)
                XCTAssertEqual(rearms, 0)
                XCTAssertEqual(opened, 0)
                if returned {
                    XCTAssertNil(host.lastError)
                } else {
                    XCTAssertTrue(host.lastError?.contains("current macOS check is now granted") == true)
                }
                host.showControls()
                XCTAssertTrue(host.controlsPresented)
                XCTAssertFalse(host.enabled)
                XCTAssertEqual(rearms, 0)
                host.signedOut()
                store.removePersistentDomain(forName: suite)
            }
        }

        func testActualDriverFailureReturnsCorrelatedErrorAndContinuesTheQueue() async throws {
            let fixture = try MacComputerLifecycleFixture()
            defer { fixture.close() }
            try fixture.enableAndStart()
            fixture.io.configure {
                $0.captureFailure = true
                $0.clipboard = "Synthetic queued value"
            }
            let failed = fixture.requestID()
            let continued = fixture.requestID()
            let first = fixture.channel.expectResponse(failed)
            let second = fixture.channel.expectResponse(continued)
            fixture.host.consume(try fixture.request("screenshot", id: failed))
            fixture.host.consume(try fixture.request("get_clipboard", id: continued))
            await fulfillment(of: [first, second], timeout: 5)
            XCTAssertEqual(fixture.channel.response(failed)?["ok"], .bool(false))
            XCTAssertEqual(fixture.channel.response(failed)?["error"]?["code"], .string("failed"))
            XCTAssertEqual(
                fixture.channel.response(failed)?["error"]?["message"], .string("The computer operation failed."))
            XCTAssertEqual(fixture.channel.response(continued)?["ok"], .bool(true))
            XCTAssertEqual(
                fixture.channel.response(continued)?["result"]?["text"], .string("Synthetic queued value"))
            XCTAssertEqual(Array(fixture.channel.responseIDs.suffix(2)), [failed, continued])
            XCTAssertNotNil(fixture.host.lastError)
            XCTAssertTrue(fixture.events.posted.isEmpty)
        }

        func testDesktopLossAfterOneKeyboardChunkCannotReportFalseSuccess() async throws {
            let fixture = try MacComputerLifecycleFixture()
            defer { fixture.close() }
            try fixture.enableAndStart()
            let observed = fixture.requestID()
            let observation = fixture.channel.expectResponse(observed)
            fixture.host.consume(try fixture.request("list_windows", id: observed))
            await fulfillment(of: [observation], timeout: 5)
            let interrupted = expectation(description: "host records interrupted partial input")
            withObservationTracking {
                _ = fixture.host.lastError
            } onChange: {
                Task { @MainActor in interrupted.fulfill() }
            }
            let io = fixture.io
            fixture.events.configure {
                $0.onPost = { _, count in
                    if count == 1 { io.configure { $0.session = nil } }
                }
            }
            let id = fixture.requestID()
            fixture.host.consume(
                try fixture.request("type_text", ["text": .string(String(repeating: "x", count: 200))], id: id))
            await fulfillment(of: [interrupted], timeout: 5)
            XCTAssertEqual(fixture.events.posted.map(\.type), [.keyDown, .keyUp])
            XCTAssertTrue(fixture.host.lastError?.contains("operation was interrupted") == true)
            _ = await fixture.host.flushCurrentSends()
            let answer = try XCTUnwrap(fixture.channel.response(id))
            XCTAssertEqual(answer["ok"], .bool(false))
            XCTAssertEqual(answer["error"]?["code"], .string("interrupted"))
            XCTAssertNil(answer["result"])
            XCTAssertNil(fixture.host.descriptor)
            fixture.host.refreshPermissions()
            XCTAssertFalse(fixture.host.enabled)
            XCTAssertNil(fixture.host.session)
        }

        func testProcessLocalSleepNotificationRevokesBeforeUIHandlerRuns() async throws {
            let fixture = try MacComputerLifecycleFixture()
            defer { fixture.close() }
            try fixture.enableAndStart()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            XCTAssertNil(fixture.host.descriptor)
            let id = fixture.requestID()
            let denied = fixture.channel.expectResponse(id)
            fixture.host.consume(try fixture.request("get_clipboard", id: id))
            await fulfillment(of: [denied], timeout: 5)
            XCTAssertEqual(fixture.channel.response(id)?["ok"], .bool(false))
            XCTAssertFalse(fixture.io.configure { $0.trace.contains("clipboardRead") })
            XCTAssertFalse(fixture.host.enabled)
            XCTAssertNil(fixture.host.session)
            XCTAssertFalse(fixture.monitor.running)
        }

        func testTakeoverThenActivationRefreshKeepsThePausedSessionResumable() async throws {
            let fixture = try MacComputerLifecycleFixture()
            defer { fixture.close() }
            try fixture.enableAndStart()
            let takeover = try XCTUnwrap(fixture.monitor.humanInput)
            takeover()
            XCTAssertEqual(fixture.host.session?.state, "paused")
            fixture.host.consume(try fixture.session(state: "paused"))
            fixture.io.set(nil, attribute: kAXFocusedApplicationAttribute, of: fixture.io.system)
            XCTAssertNil(MacComputerObservation.context(system: fixture.io).pid)
            let refreshed = expectation(description: "activation refresh ran")
            fixture.onPermissionRead = { refreshed.fulfill() }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            await fulfillment(of: [refreshed], timeout: 5)
            fixture.onPermissionRead = nil
            fixture.host.refreshPermissions()
            _ = await fixture.host.flushCurrentSends()
            XCTAssertFalse(fixture.channel.events.contains("withdraw"))
            XCTAssertEqual(fixture.channel.events.last, "paused")
            XCTAssertTrue(fixture.host.enabled)
            XCTAssertNotNil(fixture.host.descriptor)
            XCTAssertEqual(fixture.host.session?.state, "paused")
            XCTAssertTrue(fixture.host.canResume)
            fixture.io.configure { $0.session?["CGSSessionScreenIsLocked"] = true }
            fixture.host.refreshPermissions()
            XCTAssertEqual(fixture.host.session?.state, "paused")
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            for _ in 0..<200 where fixture.host.session != nil { await Task.yield() }
            XCTAssertNil(fixture.host.session)
            XCTAssertFalse(fixture.host.enabled)
        }

        func testUnresolvableForegroundNeverWithdrawsAnActiveSessionButARealLockDoes() async throws {
            let fixture = try MacComputerLifecycleFixture()
            defer { fixture.close() }
            try fixture.enableAndStart()
            fixture.io.set(nil, attribute: kAXFocusedApplicationAttribute, of: fixture.io.system)
            fixture.host.refreshPermissions()
            fixture.io.configure { $0.bundles[200] = "com.apple.loginwindow" }
            fixture.host.refreshPermissions()
            _ = await fixture.host.flushCurrentSends()
            XCTAssertFalse(fixture.channel.events.contains("withdraw"))
            XCTAssertEqual(fixture.host.session?.state, "active")
            fixture.io.configure { $0.session?["CGSSessionScreenIsLocked"] = true }
            fixture.host.refreshPermissions()
            _ = await fixture.host.flushCurrentSends()
            XCTAssertTrue(fixture.channel.events.contains("withdraw"))
            XCTAssertNil(fixture.host.session)
        }

        func testWrongHostAndUnmatchedEndCannotRetireCurrentSession() throws {
            let fixture = try MacComputerLifecycleFixture()
            defer { fixture.close() }
            try fixture.enableAndStart()
            fixture.host.consume(try fixture.session(hostID: UUID().uuidString.lowercased()))
            XCTAssertEqual(fixture.host.session?.id, fixture.sessionID)
            fixture.host.consume(try fixture.session(id: UUID().uuidString.lowercased(), state: "ended"))
            XCTAssertEqual(fixture.host.session?.id, fixture.sessionID)
            fixture.host.consume(try fixture.session(state: "ended"))
            XCTAssertNil(fixture.host.session)
            XCTAssertTrue(fixture.host.enabled)
        }
    }

    @MainActor
    final class MacComputerLifecycleFixture {
        let io = MacComputerTestSystem()
        let events = MacComputerInputTestEvents()
        let monitor = MacComputerLifecycleMonitor()
        let channel = MacComputerLifecycleChannel()
        let proof = MacComputerLocalInput(marker: 30, monitors: MacComputerTestMonitors())
        let store: UserDefaults
        let host: MacComputerHost
        let suite = UUID().uuidString
        var onPermissionRead: (() -> Void)?
        let sessionID = UUID().uuidString.lowercased()
        init() throws {
            store = UserDefaults(suiteName: suite)!
            let io = io
            let proof = proof
            weak var current: MacComputerLifecycleFixture?
            host = MacComputerHost(
                available: true, defaults: store,
                driver: MacComputerDriver(
                    marker: 30, system: io, input: MacComputerInput(marker: 30, system: io, events: events)),
                monitor: monitor,
                permissionProvider: {
                    current?.onPermissionRead?()
                    return MacComputerPermissions(
                        accessibility: io.accessibilityTrusted(), screen: io.screenCaptureAccess(),
                        monitoring: io.listenEventAccess(), posting: io.postEventAccess())
                }, desktopProbe: { MacComputerDesktopProbe.usable(system: io) },
                desktopRearm: {
                    proof.consume(current: nil) && MacComputerDesktopProbe.localRearm(system: io, appActive: true)
                }, system: io, panelPresenter: { _ in })
            let channel = channel
            host.bind(owner: "lifecycle-owner|lifecycle-server") { channel.send($0) }
            current = self
        }
        func enable(expected: Bool = true) throws {
            io.configure { $0.nodes[1].pid = 100 }
            let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
            source.userData = 0
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            proof.record(event)
            host.setEnabled(true)
            io.configure { $0.nodes[1].pid = 200 }
            XCTAssertEqual(host.enabled, expected)
        }
        func enableAndStart() throws {
            try enable()
            host.consume(try session())
            XCTAssertEqual(host.session?.state, "active")
        }
        func session(id: String? = nil, state: String = "active", hostID: String? = nil) throws -> InboundFrame {
            let boundHost = try hostID ?? XCTUnwrap(host.descriptor).hostId
            let json = JSONValue.object([
                "type": .string("computer_session"), "session_id": .string(id ?? sessionID),
                "host_id": .string(boundHost), "state": .string(state),
                "controller_label": .string("Synthetic lifecycle controller"),
            ])
            _ = try ComputerHostSession(json: json)
            return try XCTUnwrap(InboundFrame.parse(String(decoding: json.encoded(), as: UTF8.self)))
        }
        func requestID() -> String { "creq_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        func request(_ verb: String, _ args: [String: JSONValue] = [:], id: String) throws -> InboundFrame {
            let json = JSONValue.object([
                "type": .string("computer_request"), "request_id": .string(id), "session_id": .string(sessionID),
                "verb": .string(verb), "args": .object(args), "deadline_ms": .number(30000),
            ])
            _ = try ComputerHostRequest(json: json)
            return try XCTUnwrap(InboundFrame.parse(String(decoding: json.encoded(), as: UTF8.self)))
        }
        func close() {
            host.signedOut()
            proof.stop()
            store.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    final class MacComputerLifecycleMonitor: MacComputerMonitoring {
        var allowed = true
        var running = false
        var controlsWindow: Int?
        var starts = 0
        var stops = 0
        var humanInput: (@MainActor () -> Void)?
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
            starts += 1
            self.humanInput = humanInput
            running = allowed
            return running
        }
        func stop() {
            stops += 1
            running = false
        }
    }

    @MainActor
    final class MacComputerLifecycleChannel {
        private var frames: [JSONValue] = []
        private var expectations: [String: XCTestExpectation] = [:]
        var events: [String] { frames.compactMap { $0["payload"]?["event"]?.stringValue } }
        var responseIDs: [String] {
            frames.filter { $0["action"] == .string("computer_response") }.compactMap {
                $0["payload"]?["request_id"]?.stringValue
            }
        }
        func send(_ text: String) -> Bool {
            guard let json = try? JSONValue.parse(Data(text.utf8)) else { return false }
            frames.append(json)
            if json["action"] == .string("computer_response"), let id = json["payload"]?["request_id"]?.stringValue {
                expectations.removeValue(forKey: id)?.fulfill()
            }
            return true
        }
        func expectResponse(_ id: String) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: "correlated response " + id)
            expectations[id] = expectation
            return expectation
        }
        func response(_ id: String) -> JSONValue? {
            frames.last {
                $0["action"] == .string("computer_response") && $0["payload"]?["request_id"] == .string(id)
            }?["payload"]
        }
    }
#endif
