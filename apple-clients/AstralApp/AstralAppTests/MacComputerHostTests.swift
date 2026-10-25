// Tests the native computer host's distribution, consent and local revocation behavior.
// Physical syscall behavior is covered by AstralCore's selected-workspace tests and live qualification.

#if os(macOS)
    import AppKit
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerHostTests: XCTestCase {
        func testGrantedReviewOpensFixedSettingsWithoutRequestOrAuthorityChange() {
            for succeeds in [true, false] {
                var requested = 0
                var opened: [URL] = []
                var rearms = 0
                let host = MacComputerHost(
                    available: true, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                    driver: ComputerTestDriver(), monitor: ComputerTestMonitor(),
                    permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                    permissionRequester: { _ in
                        requested += 1
                        return true
                    },
                    settingsOpener: {
                        opened.append($0)
                        return succeeds
                    }, desktopProbe: { true },
                    desktopRearm: {
                        rearms += 1
                        return true
                    })
                host.bind(owner: "synthetic-review-owner") { _ in true }
                host.setEnabled(true)
                defer { host.stop() }
                let identity = host.descriptor?.hostId
                for review in [host.requestAccessibility, host.requestScreen, host.requestMonitoring] {
                    review()
                    XCTAssertTrue(host.enabled)
                    XCTAssertTrue(host.desktopAvailable)
                    XCTAssertEqual(host.descriptor?.hostId, identity)
                    XCTAssertEqual(rearms, 1)
                    if succeeds {
                        XCTAssertNil(host.lastError)
                    } else {
                        XCTAssertTrue(host.lastError?.contains("Open System Settings") == true)
                    }
                }
                XCTAssertEqual(requested, 0)
                XCTAssertEqual(
                    opened.map(\.absoluteString),
                    [
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                    ])
            }
        }

        func testPermissionDenialShowsRequestResultAndFixedSettingsFallback() {
            for granted in [true, false] {
                var requested: [MacComputerPermission] = []
                var opened: [URL] = []
                let host = MacComputerHost(
                    available: true, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                    driver: ComputerTestDriver(), monitor: ComputerTestMonitor(),
                    permissionProvider: {
                        MacComputerPermissions(accessibility: true, screen: true, monitoring: false, posting: false)
                    },
                    permissionRequester: {
                        requested.append($0)
                        return granted
                    },
                    settingsOpener: {
                        opened.append($0)
                        return true
                    },
                    desktopProbe: { true },
                    desktopRearm: {
                        XCTFail("A permission request cannot rearm control")
                        return true
                    })
                host.requestMonitoring()
                XCTAssertEqual(requested, [.monitoring])
                XCTAssertEqual(
                    opened.map(\.absoluteString),
                    ["x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"])
                XCTAssertTrue(host.lastError?.contains(granted ? "returned granted" : "returned not granted") == true)
                XCTAssertTrue(host.lastError?.contains("System Settings") == true)
                XCTAssertTrue(host.lastError?.contains("Refresh permissions") == true)
                XCTAssertTrue(host.accessibilityTrusted)
                XCTAssertFalse(host.eventPostingAllowed)
                XCTAssertFalse(host.accessibilityAllowed)
                XCTAssertFalse(host.monitoringAllowed)
                XCTAssertFalse(host.enabled)
                XCTAssertNil(host.descriptor)
            }
        }

        func testActivationRefreshesRawPermissionFactsWithoutRearming() async {
            let refreshed = expectation(description: "activation refreshed OS permissions")
            var returned = false
            let host = MacComputerHost(
                available: true, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                driver: ComputerTestDriver(), monitor: ComputerTestMonitor(),
                permissionProvider: {
                    if returned { refreshed.fulfill() }
                    return MacComputerPermissions(
                        accessibility: returned, screen: returned, monitoring: returned, posting: returned)
                }, desktopProbe: { true },
                desktopRearm: {
                    XCTFail("Activation cannot rearm control")
                    return true
                })
            returned = true
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            await fulfillment(of: [refreshed], timeout: 5)
            XCTAssertTrue(host.accessibilityTrusted)
            XCTAssertTrue(host.eventPostingAllowed)
            XCTAssertTrue(host.accessibilityAllowed)
            XCTAssertTrue(host.monitoringAllowed)
            XCTAssertFalse(host.enabled)
            XCTAssertFalse(host.desktopAvailable)
            XCTAssertNil(host.descriptor)
        }

        func testConsentAdapterRequiresHardwareEvidenceForAsyncOrCurrentActivation() throws {
            let input = MacComputerLocalInput(marker: 30)
            defer { input.stop() }
            func event(userData: Int64 = 0, pid: Int64 = 0) throws -> CGEvent {
                let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
                source.userData = userData
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
                event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
                return event
            }
            let physical = try event()
            XCTAssertFalse(input.consume(current: nil))
            input.record(physical)
            XCTAssertTrue(input.consume(current: nil))
            XCTAssertFalse(input.consume(current: physical))
            input.record(physical)
            XCTAssertTrue(input.consume(current: physical))
            input.record(physical)
            let marked = try event(userData: 30)
            XCTAssertEqual(marked.getIntegerValueField(.eventSourceUserData), 30)
            XCTAssertFalse(input.consume(current: marked))
            input.record(physical)
            input.record(try event(pid: Int64(ProcessInfo.processInfo.processIdentifier)))
            XCTAssertFalse(input.consume(current: nil))
            input.record(nil)
            XCTAssertFalse(input.consume(current: nil))
        }

        func testQueuedInjectedResumeAfterPauseCannotReactivateSession() async throws {
            let input = MacComputerLocalInput(marker: 30)
            defer { input.stop() }
            let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
            let physical = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
            physical.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            let host = MacComputerHost(
                available: true, defaults: UserDefaults(suiteName: UUID().uuidString)!, driver: ComputerTestDriver(),
                monitor: ComputerTestMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { input.consume(current: nil) })
            var sent: [String] = []
            host.bind(owner: "synthetic-owner") { text in
                if let frame = try? JSONValue.parse(Data(text.utf8)),
                    let event = frame["payload"]?["event"]?.stringValue
                {
                    sent.append(event)
                }
                return true
            }
            input.record(physical)
            host.setEnabled(true)
            defer { host.stop() }
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id: id))
            host.pause()
            host.consume(try session(host, id: id, state: "paused"))
            let injectedSource = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
            injectedSource.userData = 30
            let injected = try XCTUnwrap(CGEvent(keyboardEventSource: injectedSource, virtualKey: 0, keyDown: true))
            input.record(injected)
            host.resume()
            _ = await host.flushCurrentSends()
            XCTAssertFalse(sent.contains("resumed"))
            XCTAssertEqual(host.session?.state, "paused")
            input.record(physical)
            host.resume()
            _ = await host.flushCurrentSends()
            XCTAssertTrue(sent.contains("resumed"))
        }

        private func makeHost(
            driver: any MacComputerDriving,
            access: @escaping @MainActor () -> MacComputerPermissions = {
                MacComputerPermissions(accessibility: true, screen: true, monitoring: true)
            }
        ) -> MacComputerHost {
            let defaults = UserDefaults(suiteName: "computer-tests-" + UUID().uuidString)!
            let host = MacComputerHost(
                available: true, defaults: defaults, driver: driver, monitor: ComputerTestMonitor(),
                permissionProvider: access, desktopProbe: { true }, desktopRearm: { true })
            host.bind(owner: "synthetic-owner|synthetic-server") { _ in true }
            host.setEnabled(true)
            return host
        }

        private func session(_ host: MacComputerHost, id: String, state: String = "active") throws -> InboundFrame {
            let payload = JSONValue.object([
                "type": .string("computer_session"), "host_id": .string(try XCTUnwrap(host.descriptor).hostId),
                "session_id": .string(id), "state": .string(state), "controller_label": .string("Test controller"),
            ])
            return try XCTUnwrap(InboundFrame.parse(String(decoding: payload.encoded(), as: UTF8.self)))
        }

        private func request(id: String, session: String) throws -> InboundFrame {
            let payload = JSONValue.object([
                "type": .string("computer_request"), "request_id": .string(id), "session_id": .string(session),
                "verb": .string("click"), "args": .object(["x": .number(1), "y": .number(1)]),
                "deadline_ms": .number(1000),
            ])
            return try XCTUnwrap(InboundFrame.parse(String(decoding: payload.encoded(), as: UTF8.self)))
        }

        func testPauseStopAndStaleSessionRetireAuthority() throws {
            let host = makeHost(driver: ComputerTestDriver())
            defer { host.stop() }
            let id = UUID().uuidString.lowercased()
            let frame = try session(host, id: id)
            host.consume(frame)
            XCTAssertEqual(host.session?.state, "active")
            host.pause()
            XCTAssertEqual(host.session?.state, "paused")
            host.consume(frame)
            XCTAssertEqual(host.session?.state, "paused")
            host.stop()
            host.consume(frame)
            XCTAssertNil(host.session)
        }

        func testApprovalBarrierFlushesLocalPauseBeforeDecision() async throws {
            let host = makeHost(driver: ComputerTestDriver())
            var sent: [String] = []
            host.bind(owner: "synthetic-owner|synthetic-server") { text in
                if let frame = try? JSONValue.parse(Data(text.utf8)),
                    let event = frame["payload"]?["event"]?.stringValue
                {
                    sent.append(event)
                }
                return true
            }
            host.setEnabled(true)
            defer { host.stop() }
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id: id))
            let barrier = host.recordApprovalInteraction()
            XCTAssertEqual(barrier, id)
            XCTAssertFalse(host.approvalPauseReady(barrier))
            host.consume(try session(host, id: id))
            XCTAssertFalse(host.approvalPauseReady(barrier))
            host.consume(try session(host, id: id, state: "paused"))
            XCTAssertTrue(host.approvalPauseReady(barrier))
            let ready = await host.flushApprovalPause(barrier)
            XCTAssertTrue(ready)
            sent.append("decision")
            XCTAssertEqual(Array(sent.suffix(2)), ["paused", "decision"])
        }

        func testApprovalCannotOverrideManualPauseOrStop() async throws {
            let host = makeHost(driver: ComputerTestDriver())
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id: id))
            host.pause()
            let barrier = host.recordApprovalInteraction()
            let manual = await host.flushApprovalPause(barrier)
            XCTAssertFalse(manual)
            host.stop()
            XCTAssertFalse(host.approvalStillCurrent(barrier))
        }

        func testStopReleasesPausedAcknowledgmentWaiterWithoutApproval() async throws {
            let host = makeHost(driver: ComputerTestDriver())
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id: id))
            let barrier = host.recordApprovalInteraction()
            let pending = Task { await host.flushApprovalPause(barrier) }
            host.stop()
            let ready = await pending.value
            XCTAssertFalse(ready)
        }

        func testLockLatchesOutNewSessionAndRequestUntilLocalRearm() async throws {
            let driver = ComputerTestDriver()
            let host = makeHost(driver: driver)
            let id = UUID().uuidString.lowercased()
            let incoming = try session(host, id: id)
            host.sessionLocked()
            host.consume(incoming)
            host.consume(try request(id: "creq_" + String(repeating: "c", count: 32), session: id))
            let effects = await driver.effects
            XCTAssertEqual(effects, 0)
            XCTAssertFalse(host.desktopAvailable)
            XCTAssertFalse(host.enabled)
            XCTAssertNil(host.descriptor)
            XCTAssertNil(host.session)
            host.bind(owner: "synthetic-owner|synthetic-server") { _ in true }
            XCTAssertNil(host.descriptor)
            host.setEnabled(true)
            XCTAssertTrue(host.desktopAvailable)
            XCTAssertNotNil(host.descriptor)
            host.stop()
        }

        func testDuplicateRequestNeverPerformsSecondPhysicalEffect() async throws {
            let completed = expectation(description: "one physical invocation")
            let driver = ComputerTestDriver(onExecution: { completed.fulfill() })
            let host = makeHost(driver: driver)
            defer { host.stop() }
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id: id))
            let frame = try request(id: "creq_" + String(repeating: "a", count: 32), session: id)
            host.consume(frame)
            host.consume(frame)
            await fulfillment(of: [completed], timeout: 5)
            let effects = await driver.effects
            XCTAssertEqual(effects, 1)
        }

        func testPermissionLossBeforePhysicalBoundaryDeniesQueuedEffect() async throws {
            let attempted = expectation(description: "driver checked authority")
            let driver = ComputerTestDriver(onExecution: { attempted.fulfill() })
            let access = ComputerTestAccess()
            let host = makeHost(
                driver: driver,
                access: {
                    MacComputerPermissions(
                        accessibility: access.allowed, screen: access.allowed, monitoring: access.allowed)
                })
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id: id))
            host.consume(try request(id: "creq_" + String(repeating: "b", count: 32), session: id))
            access.allowed = false
            host.refreshPermissions()
            await fulfillment(of: [attempted], timeout: 5)
            let effects = await driver.effects
            XCTAssertEqual(effects, 0)
            XCTAssertFalse(host.enabled)
            XCTAssertNil(host.session)
        }
        func testStoreDistributionCannotEnableHosting() {
            let host = MacComputerHost(available: false)
            host.setEnabled(true)
            XCTAssertFalse(host.enabled)
            XCTAssertNil(host.descriptor)
            XCTAssertTrue(host.statusLabel.contains("controller"))
        }

        func testLocalConsentNeverEntersServerOperationQueue() {
            let model = AppModel(
                tokenStore: InMemoryTokenStore(),
                defaults: UserDefaults(suiteName: "local-consent-" + UUID().uuidString)!)
            var sent: [String] = []
            model.outboundTap = { sent.append($0) }
            model.emit("computer_host_consent", payload: ["enabled": .bool(true)])
            XCTAssertTrue(sent.isEmpty)
            XCTAssertFalse(model.macComputerHost.enabled)
        }

        func testDisconnectedHostCannotAdvertiseOrAcceptSession() {
            let host = MacComputerHost(available: true)
            XCTAssertFalse(host.enabled)
            XCTAssertNil(host.descriptor)
            host.pause()
            host.stop()
            XCTAssertNil(host.session)
        }
    }

    @MainActor
    private final class ComputerTestAccess { var allowed = true }

    @MainActor
    private final class ComputerTestMonitor: MacComputerMonitoring {
        var running = false
        var controlsWindow: Int?
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
            running = true
            return true
        }
        func stop() { running = false }
    }

    private actor ComputerTestDriver: MacComputerDriving {
        var effects = 0
        let onExecution: @Sendable () -> Void
        init(onExecution: @escaping @Sendable () -> Void = {}) { self.onExecution = onExecution }
        func execute(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            defer { onExecution() }
            try authorize()
            effects += 1
            return ["attempted": .bool(true)]
        }
        func reset() {}
    }
#endif
