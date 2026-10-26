// Renders the native computer controls without showing windows or requesting macOS permissions.
// Existing host actions are exercised with private defaults and inert native IO boundaries.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import Vision
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerControlsTests: XCTestCase {
        private func defaults() -> UserDefaults {
            let name = "controls-tests-" + UUID().uuidString
            let value = UserDefaults(suiteName: name)!
            addTeardownBlock { value.removePersistentDomain(forName: name) }
            return value
        }
        private func folder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }
        private func render<V: View>(_ content: V) -> NSHostingView<V> {
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: 560, height: 900)
            view.layoutSubtreeIfNeeded()
            XCTAssertNil(view.window)
            XCTAssertGreaterThan(view.fittingSize.width, 0)
            XCTAssertGreaterThan(view.fittingSize.height, 0)
            return view
        }
        private func session(_ host: MacComputerHost, id: String, state: String = "active") throws -> InboundFrame {
            let payload = JSONValue.object([
                "type": .string("computer_session"), "host_id": .string(try XCTUnwrap(host.descriptor).hostId),
                "session_id": .string(id), "state": .string(state), "controller_label": .string("Synthetic controller"),
            ])
            return try XCTUnwrap(InboundFrame.parse(String(decoding: payload.encoded(), as: UTF8.self)))
        }
        func testOffscreenControlsRenderControllerConsentAndWorkspaceFailureStates() throws {
            let root = try folder()
            for available in [false, true] {
                let store = defaults()
                let grants = MacComputerTestWorkspaceGrants()
                grants.selection = [root, root.appendingPathComponent("missing")]
                let files = MacComputerFiles(defaults: store, grants: grants.port)
                let host = MacComputerHost(
                    available: available, defaults: store, files: files,
                    driver: MacComputerControlsTestDriver(), monitor: MacComputerControlsTestMonitor(),
                    permissionProvider: {
                        MacComputerPermissions(accessibility: false, screen: false, monitoring: false)
                    }, desktopProbe: { true }, desktopRearm: { false }, system: MacComputerTestSystem())
                let signedOut = render(MacComputerControls(host: host))
                XCTAssertNil(signedOut.window)
                host.bind(owner: "controls-owner") { _ in true }
                files.choose()
                host.setEnabled(true)
                let denied = render(MacComputerControls(host: host))
                XCTAssertNil(denied.window)
                XCTAssertFalse(host.enabled)
                XCTAssertEqual(files.roots, [root.path])
                XCTAssertNotNil(files.errorMessage)
                if available { XCTAssertNotNil(host.lastError) }
                files.bind(nil)
                host.signedOut()
            }
        }
        func testControlsGroupPermissionsAndWorkspacesAndDrawOnlyTheLeadSentenceOfState() throws {
            for available in [false, true] {
                let host = MacComputerHost(
                    available: available, defaults: defaults(), driver: MacComputerControlsTestDriver(),
                    monitor: MacComputerControlsTestMonitor(),
                    permissionProvider: {
                        MacComputerPermissions(accessibility: false, screen: false, monitoring: false)
                    },
                    permissionRequester: { _ in false }, settingsOpener: { _ in false },
                    desktopProbe: { true }, desktopRearm: { false }, system: MacComputerTestSystem())
                if available { MacComputerControlCommand.permission(.accessibility).perform(on: host) }
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 560, height: 900), styleMask: .borderless,
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let view = NSHostingView(rootView: MacComputerControls(host: host).environment(ThemeStore()))
                window.contentView = view
                defer {
                    window.contentView = nil
                    window.close()
                    host.signedOut()
                }
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                let kept = ["Computer access on this Mac", "Permissions", "Workspaces", "Accessibility", host.statusLabel]
                for kept in kept {
                    XCTAssertTrue(text.contains(kept), "Missing \(kept) in \(text)")
                }
                for cut in [
                    "macOS checks", "Install the direct-download", "Saved for this account", "Astral can observe",
                    "File tools can access only", "Writes and deletes", "permission check immediately",
                ] {
                    XCTAssertFalse(text.contains(cut), "Unexpected \(cut)")
                }
                if available {
                    XCTAssertTrue(host.lastError?.contains("permission check immediately") == true)
                    XCTAssertTrue(text.contains("returned not granted"))
                } else {
                    XCTAssertEqual(host.statusLabel, "This build is a computer controller")
                }
            }
        }

        func testCommandAdapterKeepsNativeConsentAndHIDRearmGuards() {
            var hardware = false
            let host = MacComputerHost(
                available: true, defaults: defaults(), driver: MacComputerControlsTestDriver(),
                monitor: MacComputerControlsTestMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { hardware }, system: MacComputerTestSystem())
            let binding = MacComputerControlCommand.enabledBinding(on: host)
            XCTAssertFalse(binding.wrappedValue)
            binding.wrappedValue = true
            XCTAssertFalse(host.enabled)
            host.bind(owner: "controls-owner") { _ in true }
            MacComputerControlCommand.setEnabled(true).perform(on: host)
            XCTAssertFalse(host.enabled)
            hardware = true
            binding.wrappedValue = true
            XCTAssertTrue(host.enabled)
            XCTAssertTrue(binding.wrappedValue)
            MacComputerControlCommand.pause.perform(on: host)
            MacComputerControlCommand.resume.perform(on: host)
            XCTAssertNil(host.session)
            MacComputerControlCommand.stop.perform(on: host)
            MacComputerControlCommand.setEnabled(false).perform(on: host)
            XCTAssertFalse(host.enabled)
            host.controlsPresented = true
            MacComputerControlCommand.done.action(on: host)()
            XCTAssertFalse(host.controlsPresented)
            host.signedOut()
        }
        func testPermissionCommandsUseExistingPermissionRequestsAndRefreshOnly() {
            var calls: [MacComputerPermission] = []
            var ready = false
            var reads = 0
            let host = MacComputerHost(
                available: true, defaults: defaults(), driver: MacComputerControlsTestDriver(),
                monitor: MacComputerControlsTestMonitor(),
                permissionProvider: {
                    reads += 1
                    return MacComputerPermissions(accessibility: ready, screen: ready, monitoring: ready)
                },
                permissionRequester: {
                    calls.append($0)
                    return false
                }, settingsOpener: { _ in false },
                desktopProbe: { true }, desktopRearm: { false }, system: MacComputerTestSystem())
            for permission in [MacComputerPermission.accessibility, .screen, .monitoring] {
                MacComputerControlCommand.permission(permission).perform(on: host)
            }
            XCTAssertEqual(calls, [.accessibility, .screen, .monitoring])
            XCTAssertFalse(host.enabled)
            let previous = reads
            ready = true
            MacComputerControlCommand.refreshPermissions.perform(on: host)
            XCTAssertGreaterThan(reads, previous)
            XCTAssertTrue(host.accessibilityAllowed && host.screenAllowed && host.monitoringAllowed)
            XCTAssertFalse(host.enabled)
            _ = render(MacComputerControls(host: host))
            _ = render(MacComputerSessionControls(host: host))
            host.signedOut()
        }
        func testWorkspaceCommandsPersistGrantBeforeNewAnnouncementAndRemoveCapability() async throws {
            let root = try folder()
            let store = defaults()
            let grants = MacComputerTestWorkspaceGrants()
            grants.selection = [root]
            let files = MacComputerFiles(defaults: store, grants: grants.port)
            var presentations = 0
            let host = MacComputerHost(
                available: true, defaults: store, files: files,
                driver: MacComputerControlsTestDriver(), monitor: MacComputerControlsTestMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { panel in
                    presentations += 1
                    XCTAssertFalse(panel.isVisible)
                })
            var advertised: [[String]] = []
            var events: [String] = []
            host.bind(owner: "controls-owner") { text in
                let frame = try? JSONValue.parse(Data(text.utf8))
                if let event = frame?["payload"]?["event"]?.stringValue { events.append(event) }
                if frame?["payload"]?["event"]?.stringValue == "announce" {
                    advertised.append(frame?["payload"]?["host"]?["verbs"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                }
                return true
            }
            host.setEnabled(true)
            _ = await host.flushCurrentSends()
            host.consume(try session(host, id: UUID().uuidString.lowercased()))
            grants.onChoose = { XCTAssertNil(host.session) }
            MacComputerControlCommand.chooseWorkspaces.perform(on: host)
            _ = await host.flushCurrentSends()
            XCTAssertEqual(files.roots, [root.path])
            XCTAssertTrue(host.descriptor?.verbs.contains("read_file") == true)
            XCTAssertEqual(Array(events.suffix(2)), ["stopped", "announce"])
            host.consume(try session(host, id: UUID().uuidString.lowercased()))
            MacComputerControlCommand.removeWorkspace(root.path).perform(on: host)
            _ = await host.flushCurrentSends()
            XCTAssertTrue(files.roots.isEmpty)
            XCTAssertFalse(host.descriptor?.verbs.contains("read_file") == true)
            XCTAssertEqual(advertised.count, 3)
            XCTAssertEqual(advertised.map { $0.contains("read_file") }, [false, true, false])
            XCTAssertEqual(Array(events.suffix(2)), ["stopped", "announce"])
            XCTAssertEqual(presentations, 2)
            host.signedOut()
            let restored = MacComputerFiles(defaults: store, grants: grants.port)
            restored.bind("controls-owner")
            XCTAssertTrue(restored.roots.isEmpty)
            restored.bind(nil)
        }
        func testOffscreenSessionControlsFollowAcknowledgmentAndKeepLocalResumeGuard() async throws {
            var hardware = true
            var presentations = 0
            let host = MacComputerHost(
                available: true, defaults: defaults(), driver: MacComputerControlsTestDriver(),
                monitor: MacComputerControlsTestMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { hardware }, system: MacComputerTestSystem(),
                panelPresenter: { panel in
                    presentations += 1
                    XCTAssertFalse(panel.isVisible)
                })
            var events: [String] = []
            host.bind(owner: "controls-owner") { text in
                let frame = try? JSONValue.parse(Data(text.utf8))
                if let event = frame?["payload"]?["event"]?.stringValue { events.append(event) }
                return true
            }
            host.setEnabled(true)
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id: id))
            XCTAssertEqual(host.session?.state, "active")
            _ = render(MacComputerControls(host: host))
            _ = render(MacComputerSessionControls(host: host))
            MacComputerControlCommand.pause.perform(on: host)
            XCTAssertTrue(host.awaitingPause)
            XCTAssertFalse(host.canResume)
            _ = render(MacComputerSessionControls(host: host))
            MacComputerControlCommand.resume.perform(on: host)
            _ = await host.flushCurrentSends()
            XCTAssertFalse(events.contains("resumed"))
            host.consume(try session(host, id: id, state: "paused"))
            XCTAssertFalse(host.awaitingPause)
            XCTAssertTrue(host.canResume)
            _ = render(MacComputerSessionControls(host: host))
            hardware = false
            MacComputerControlCommand.resume.perform(on: host)
            _ = await host.flushCurrentSends()
            XCTAssertFalse(events.contains("resumed"))
            XCTAssertEqual(host.session?.state, "paused")
            hardware = true
            MacComputerControlCommand.resume.perform(on: host)
            _ = await host.flushCurrentSends()
            XCTAssertTrue(events.contains("resumed"))
            MacComputerControlCommand.stop.perform(on: host)
            XCTAssertNil(host.session)
            XCTAssertGreaterThan(presentations, 0)
            host.signedOut()
        }
        private func enabledHost(system: MacComputerTestSystem, driver: MacComputerControlsTestDriver)
            -> MacComputerHost
        {
            let host = MacComputerHost(
                available: true, defaults: defaults(), driver: driver, monitor: MacComputerControlsTestMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: system, panelPresenter: { _ in })
            host.bind(owner: "controls-owner") { _ in true }
            host.setEnabled(true)
            return host
        }
        func testFractionalDisplayPixelsAreRejectedBeforeIntegerConversion() {
            let system = MacComputerTestSystem()
            system.configure { $0.pixels.width = 1280.5 }
            let host = enabledHost(system: system, driver: MacComputerControlsTestDriver())
            defer { host.signedOut() }
            XCTAssertNil(host.descriptor)
        }
        func testDescriptorReadsCurrentRawDisplaysAndOrdersThePrimaryFirst() throws {
            let system = MacComputerTestSystem()
            system.configure { $0.displays = [88, 77] }
            let host = enabledHost(system: system, driver: MacComputerControlsTestDriver())
            defer { host.signedOut() }
            let descriptor = try XCTUnwrap(host.descriptor)
            XCTAssertEqual(descriptor.screens.map(\.index), [0, 1])
            XCTAssertEqual(descriptor.screens.map(\.primary), [true, false])
            XCTAssertEqual(descriptor.screens.map(\.width), [1280, 1280])
            XCTAssertEqual(descriptor.screens.map(\.height), [960, 960])
            XCTAssertEqual(descriptor.screens.map(\.scale), [2, 2])
            XCTAssertFalse(descriptor.verbs.contains("read_file"))
            system.configure { $0.displays = [] }
            XCTAssertNil(host.descriptor)
        }
        func testInvalidRawDisplayFactsCannotAdvertiseOrReachTheDriver() async throws {
            for invalid in 0..<17 {
                let system = MacComputerTestSystem()
                system.configure {
                    switch invalid {
                    case 0: $0.displays = []
                    case 1: $0.countOverride = 9
                    case 2: $0.countError = .failure
                    case 3: $0.enumerationError = .failure
                    case 4: $0.countOverride = 2
                    case 5: $0.displays = [77, 77]
                    case 6: $0.pixels.width = 0
                    case 7: $0.pixels.height = 0
                    case 8: $0.pixels.width = 16385
                    case 9: $0.pixels.height = .nan
                    case 10: $0.pixels.width = .infinity
                    case 11: $0.bounds.size.width = 0
                    case 12: $0.bounds.size.height = 0
                    case 13: $0.bounds.size.width = .nan
                    case 14: $0.pixels.width = 1280.5
                    case 15: $0.displays = [88]
                    default: $0.pixels.width = 0.5
                    }
                }
                let driver = MacComputerControlsTestDriver()
                let host = enabledHost(system: system, driver: driver)
                var frames: [JSONValue] = []
                host.bind(owner: "controls-owner") { text in
                    if let frame = try? JSONValue.parse(Data(text.utf8)) { frames.append(frame) }
                    return true
                }
                host.setEnabled(true)
                defer { host.signedOut() }
                XCTAssertNil(host.descriptor, "invalid display facts \(invalid)")
                let request = JSONValue.object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(repeating: "a", count: 32)),
                    "session_id": .string("11111111-1111-4111-8111-111111111111"), "verb": .string("click"),
                    "args": .object(["x": .number(1), "y": .number(1)]), "deadline_ms": .number(1000),
                ])
                host.consume(try XCTUnwrap(InboundFrame.parse(String(decoding: request.encoded(), as: UTF8.self))))
                let delivered = await host.flushCurrentSends()
                XCTAssertTrue(delivered)
                XCTAssertFalse(frames.contains { $0["payload"]?["event"]?.stringValue == "announce" })
                XCTAssertEqual(frames.last?["payload"]?["error"]?["code"], .string("permission_denied"))
                let effects = await driver.effects
                XCTAssertEqual(effects, 0)
            }
        }
    }

    @MainActor
    private final class MacComputerControlsTestMonitor: MacComputerMonitoring {
        var running = false
        var controlsWindow: Int?
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
            running = true
            return true
        }
        func stop() { running = false }
    }
    private actor MacComputerControlsTestDriver: MacComputerDriving {
        var effects = 0
        func execute(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            try authorize()
            effects += 1
            return [:]
        }
        func reset() {}
    }
#endif
