// Tests the native computer host's distribution, consent and local revocation behavior.
// Physical syscall behavior is covered by AstralCore's selected-workspace tests and live qualification.

#if os(macOS)
    import AppKit
    import AstralCore
    import CryptoKit
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
                    }, system: MacComputerTestSystem(), panelPresenter: { _ in })
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
                    }, system: MacComputerTestSystem(), panelPresenter: { _ in })
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

        func testRepeatedMissingPermissionOpensItsPaneWithAddGuidanceInsteadOfPrompting() {
            var requested: [MacComputerPermission] = []
            var opened: [URL] = []
            var opens = true
            let host = MacComputerHost(
                available: true, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                driver: ComputerTestDriver(), monitor: ComputerTestMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: false, screen: false, monitoring: false) },
                permissionRequester: {
                    requested.append($0)
                    return false
                },
                settingsOpener: {
                    opened.append($0)
                    return opens
                }, desktopProbe: { true }, desktopRearm: { false }, system: MacComputerTestSystem(),
                panelPresenter: { _ in })
            let panes: [(MacComputerPermission, () -> Void, String, String)] = [
                (.accessibility, host.requestAccessibility, "Device Control and Data Access", "Privacy_Accessibility"),
                (.screen, host.requestScreen, "Screen & System Audio Recording", "Privacy_ScreenCapture"),
                (.monitoring, host.requestMonitoring, "Input Monitoring", "Privacy_ListenEvent"),
            ]
            for (permission, request, pane, anchor) in panes {
                request()
                XCTAssertEqual(requested.last, permission)
                XCTAssertTrue(host.lastError?.contains("returned not granted") == true)
                let prompts = requested.count
                request()
                XCTAssertEqual(requested.count, prompts)
                XCTAssertEqual(
                    host.lastError, "macOS no longer prompts for this app; open \(pane) and add AstralDeep with +")
                XCTAssertEqual(
                    opened.last?.absoluteString, "x-apple.systempreferences:com.apple.preference.security?" + anchor)
            }
            XCTAssertEqual(
                MacComputerPermission.accessibility.noPromptGuidance,
                "macOS no longer prompts for this app; open Device Control and Data Access and add AstralDeep with +")
            opens = false
            host.requestAccessibility()
            XCTAssertTrue(host.lastError?.hasSuffix("AstralDeep could not open that pane.") == true)
            XCTAssertFalse(host.enabled)
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
                }, system: MacComputerTestSystem(), panelPresenter: { _ in })
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
            let input = MacComputerLocalInput(marker: 30, monitors: MacComputerTestMonitors())
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
            let input = MacComputerLocalInput(marker: 30, monitors: MacComputerTestMonitors())
            defer { input.stop() }
            let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
            let physical = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
            physical.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            let host = MacComputerHost(
                available: true, defaults: UserDefaults(suiteName: UUID().uuidString)!, driver: ComputerTestDriver(),
                monitor: ComputerTestMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { input.consume(current: nil) }, system: MacComputerTestSystem(),
                panelPresenter: { _ in })
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

        func testNewerOwnerBindingSurvivesWorkspaceAndDisconnectCallbacks() async throws {
            for boundary in ["scope_stop", "bookmark_resolve", "monitor_stop", "sign_out"] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .resolvingSymlinksInPath()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let suite = "reentrant-host-" + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                var selection: [URL] = []
                var onStop: (() -> Void)?
                var onResolve: (() -> Void)?
                let grants = MacComputerWorkspaceGrantIO(
                    chooseDirectories: { selection },
                    resolveBookmark: { data in
                        let callback = onResolve
                        onResolve = nil
                        callback?()
                        return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
                    },
                    makeBookmark: { Data($0.path.utf8) }, startAccess: { _ in true },
                    stopAccess: { _ in
                        let callback = onStop
                        onStop = nil
                        callback?()
                    })
                let files = MacComputerFiles(defaults: defaults, grants: grants)
                var folders: [String: URL] = [:]
                for owner in ["older", "newer", "initial"] {
                    let folder = directory.appendingPathComponent(owner)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    folders[owner] = folder
                    selection = [folder]
                    files.bind(owner)
                    files.choose()
                }
                let monitor = ComputerTestMonitor()
                let host = MacComputerHost(
                    available: true, defaults: defaults, files: files, driver: ComputerTestDriver(), monitor: monitor,
                    permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                    desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                    panelPresenter: { _ in })
                host.bind(owner: "initial") { _ in true }
                var olderSends = 0
                var newerSends = 0
                let rebind = {
                    host.bind(owner: "newer") { _ in
                        newerSends += 1
                        return true
                    }
                }
                switch boundary {
                case "scope_stop": onStop = rebind
                case "bookmark_resolve": onResolve = rebind
                default: monitor.onStop = rebind
                }
                if boundary == "sign_out" {
                    host.signedOut()
                } else {
                    host.bind(owner: "older") { _ in
                        olderSends += 1
                        return true
                    }
                }
                XCTAssertEqual(files.roots, [try XCTUnwrap(folders["newer"]).path], boundary)
                XCTAssertTrue(host.ownerBound, boundary)
                host.setEnabled(true)
                XCTAssertTrue(host.enabled, boundary)
                let sent = await host.flushCurrentSends()
                XCTAssertTrue(sent, boundary)
                XCTAssertEqual(olderSends, 0, boundary)
                XCTAssertEqual(newerSends, 1, boundary)
                func consentKey(_ owner: String) -> String {
                    "computer.consent."
                        + SHA256.hash(data: Data(owner.utf8))
                        .map { String(format: "%02x", $0) }.joined()
                }
                XCTAssertTrue(defaults.bool(forKey: consentKey("newer")), boundary)
                XCTAssertFalse(defaults.bool(forKey: consentKey("older")), boundary)
                host.signedOut()
            }
        }

        func testRelaunchRestoresRememberedChoiceButNotPreviousSession() async throws {
            let suite = "remembered-consent-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = rememberingHost(defaults: defaults)
            first.bind(owner: "owner-a|server-a") { _ in true }
            first.setEnabled(true)
            let identity = try XCTUnwrap(first.descriptor).hostId
            let previous = UUID().uuidString.lowercased()
            first.consume(try session(first, id: previous))
            first.applicationWillTerminate()
            let driver = ComputerTestDriver()
            let restored = rememberingHost(defaults: defaults, driver: driver)
            restored.signedOut()
            restored.bind(owner: "owner-a|server-a") { _ in true }
            defer { restored.applicationWillTerminate() }
            XCTAssertTrue(MacComputerControlCommand.enabledBinding(on: restored).wrappedValue)
            XCTAssertTrue(restored.enabled)
            XCTAssertEqual(restored.descriptor?.hostId, identity)
            XCTAssertNil(restored.session)
            restored.consume(try request(id: "creq_" + String(repeating: "d", count: 32), session: previous))
            let effects = await driver.effects
            XCTAssertEqual(effects, 0)
        }

        func testRememberedChoiceDoesNotCrossAccountServerOrExplicitOff() throws {
            let suite = "scoped-consent-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = rememberingHost(defaults: defaults)
            first.bind(owner: "owner-a|server-a") { _ in true }
            first.setEnabled(true)
            first.applicationWillTerminate()
            let restored = rememberingHost(defaults: defaults)
            defer { restored.applicationWillTerminate() }
            for scope in ["owner-b|server-a", "owner-a|server-b"] {
                restored.bind(owner: scope) { _ in true }
                XCTAssertFalse(MacComputerControlCommand.enabledBinding(on: restored).wrappedValue)
                XCTAssertNil(restored.descriptor)
            }
            restored.bind(owner: "owner-a|server-a") { _ in true }
            XCTAssertTrue(restored.enabled)
            restored.setEnabled(false)
            let reopened = rememberingHost(defaults: defaults)
            reopened.bind(owner: "owner-a|server-a") { _ in true }
            defer { reopened.applicationWillTerminate() }
            XCTAssertFalse(MacComputerControlCommand.enabledBinding(on: reopened).wrappedValue)
            XCTAssertFalse(reopened.enabled)
            XCTAssertNil(reopened.descriptor)
        }

        func testLockKeepsRememberedChoiceAndBlocksReconnectUntilLocalRearm() throws {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let host = rememberingHost(defaults: defaults)
            host.bind(owner: "owner-a|server-a") { _ in true }
            host.setEnabled(true)
            host.sessionLocked()
            XCTAssertTrue(MacComputerControlCommand.enabledBinding(on: host).wrappedValue)
            XCTAssertFalse(host.enabled)
            host.bind(owner: "owner-a|server-a") { _ in true }
            XCTAssertNil(host.descriptor)
            XCTAssertFalse(host.enabled)
            host.setEnabled(true)
            XCTAssertNotNil(host.descriptor)
            host.sessionLocked()
            host.applicationWillTerminate()
            let reopened = rememberingHost(defaults: defaults)
            reopened.bind(owner: "owner-a|server-a") { _ in true }
            defer { reopened.applicationWillTerminate() }
            XCTAssertTrue(reopened.enabled)
        }

        func testSynchronousLockRevocationCannotBeUndoneBeforeMainActorCleanup() throws {
            let host = makeHost(driver: ComputerTestDriver())
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            host.bind(owner: "synthetic-owner|synthetic-server") { _ in true }
            XCTAssertTrue(MacComputerControlCommand.enabledBinding(on: host).wrappedValue)
            XCTAssertFalse(host.enabled)
            XCTAssertNil(host.descriptor)
            host.applicationWillTerminate()
        }

        func testDescriptorReportsTheBundleShortVersionToTheServer() throws {
            let host = makeHost(driver: ComputerTestDriver())
            defer { host.stop() }
            let bundled = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            let descriptor = try XCTUnwrap(host.descriptor)
            XCTAssertEqual(descriptor.clientVersion, bundled)
            XCTAssertEqual(descriptor.json.objectValue?["client_version"]?.stringValue, bundled)
        }

        func testUnavailableDesktopOrPermissionKeepsChoiceWithoutAdvertisingAccess() throws {
            for unavailable in ["desktop", "permission", "distribution", "monitor"] {
                let defaults = UserDefaults(suiteName: UUID().uuidString)!
                let first = rememberingHost(defaults: defaults)
                first.bind(owner: "owner-a|server-a") { _ in true }
                first.setEnabled(true)
                first.applicationWillTerminate()
                let monitor = ComputerTestMonitor()
                monitor.startAllowed = unavailable != "monitor"
                let host = MacComputerHost(
                    available: unavailable != "distribution", defaults: defaults,
                    driver: ComputerTestDriver(), monitor: monitor,
                    permissionProvider: {
                        MacComputerPermissions(
                            accessibility: true, screen: unavailable != "permission", monitoring: true)
                    }, desktopProbe: { unavailable != "desktop" }, desktopRearm: { false },
                    system: MacComputerTestSystem(), panelPresenter: { _ in })
                host.bind(owner: "owner-a|server-a") { _ in true }
                defer { host.applicationWillTerminate() }
                XCTAssertFalse(host.enabled, unavailable)
                XCTAssertNil(host.descriptor, unavailable)
                if unavailable != "distribution" {
                    XCTAssertTrue(MacComputerControlCommand.enabledBinding(on: host).wrappedValue, unavailable)
                }
            }
        }

        func testPermissionRevocationKeepsChoiceButRequiresFreshLocalRearm() {
            let access = ComputerTestAccess()
            let host = makeHost(
                driver: ComputerTestDriver(),
                access: {
                    MacComputerPermissions(
                        accessibility: access.allowed, screen: access.allowed, monitoring: access.allowed)
                })
            access.allowed = false
            host.refreshPermissions()
            XCTAssertTrue(MacComputerControlCommand.enabledBinding(on: host).wrappedValue)
            XCTAssertFalse(host.enabled)
            access.allowed = true
            host.refreshPermissions()
            host.bind(owner: "synthetic-owner|synthetic-server") { _ in true }
            XCTAssertFalse(host.enabled)
            XCTAssertNil(host.descriptor)
            host.setEnabled(true)
            XCTAssertNotNil(host.descriptor)
            host.applicationWillTerminate()
        }

        func testDesktopProbeCannotRestoreOverNewerOwnerOrSignOut() throws {
            for boundary in ["newer_owner", "sign_out"] {
                let suite = "probe-reentry-" + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let first = rememberingHost(defaults: defaults)
                for scope in ["owner-a|server-a", "owner-b|server-a"] {
                    first.bind(owner: scope) { _ in true }
                    first.setEnabled(true)
                }
                first.applicationWillTerminate()
                let access = ComputerTestAccess()
                let monitor = ComputerTestMonitor()
                let host = MacComputerHost(
                    available: true, defaults: defaults, driver: ComputerTestDriver(), monitor: monitor,
                    permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                    desktopProbe: {
                        MainActor.assumeIsolated {
                            let callback = access.onProbe
                            access.onProbe = nil
                            callback?()
                            return true
                        }
                    }, desktopRearm: { true }, system: MacComputerTestSystem(), panelPresenter: { _ in })
                access.onProbe = {
                    if boundary == "newer_owner" {
                        host.bind(owner: "owner-b|server-a") { _ in true }
                    } else {
                        host.signedOut()
                    }
                    monitor.startAllowed = false
                }
                host.bind(owner: "owner-a|server-a") { _ in true }
                if boundary == "newer_owner" {
                    XCTAssertTrue(host.enabled)
                    XCTAssertNotNil(host.descriptor)
                } else {
                    XCTAssertFalse(host.ownerBound)
                    XCTAssertFalse(host.desktopAvailable)
                    XCTAssertNil(host.descriptor)
                }
                host.applicationWillTerminate()
            }
        }

        private func rememberingHost(
            defaults: UserDefaults, driver: any MacComputerDriving = ComputerTestDriver()
        ) -> MacComputerHost {
            MacComputerHost(
                available: true, defaults: defaults, driver: driver, monitor: ComputerTestMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { _ in })
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
                permissionProvider: access, desktopProbe: { true }, desktopRearm: { true },
                system: MacComputerTestSystem(), panelPresenter: { _ in })
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
            let host = MacComputerHost(
                available: false, desktopRearm: { false }, system: MacComputerTestSystem(), panelPresenter: { _ in })
            host.setEnabled(true)
            XCTAssertFalse(host.enabled)
            XCTAssertNil(host.descriptor)
            XCTAssertTrue(host.statusLabel.contains("controller"))
        }

        func testDisconnectedHostCannotAdvertiseOrAcceptSession() {
            let host = MacComputerHost(
                available: true, desktopRearm: { false }, system: MacComputerTestSystem(), panelPresenter: { _ in })
            XCTAssertFalse(host.enabled)
            XCTAssertNil(host.descriptor)
            host.pause()
            host.stop()
            XCTAssertNil(host.session)
        }
    }

    @MainActor
    private final class ComputerTestAccess {
        var allowed = true
        var onProbe: (() -> Void)?
    }

    @MainActor
    private final class ComputerTestMonitor: MacComputerMonitoring {
        var running = false
        var startAllowed = true
        var controlsWindow: Int?
        var onStop: (() -> Void)?
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
            running = startAllowed
            return running
        }
        func stop() {
            running = false
            let callback = onStop
            onStop = nil
            callback?()
        }
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
