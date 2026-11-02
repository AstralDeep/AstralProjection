// Checks the agent overlay contract: host banner states, driver cue order, panel flags and capture exclusion.
// A recording presenter stands in for AppKit windows; live panels are built but never ordered on screen.

#if os(macOS)
    import AppKit
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerOverlayTests: XCTestCase {
        private final class RecordingOverlay: MacComputerOverlayPresenting {
            var calls: [String] = []
            var cues: [MacComputerOverlayCue] = []
            var available = true
            func attach(_ host: MacComputerHost) { calls.append("attach") }
            func show(_ mode: MacComputerOverlayMode) -> Bool {
                calls.append("show:" + mode.rawValue)
                return available
            }
            func hide() { calls.append("hide") }
            func cue(_ cue: MacComputerOverlayCue) { cues.append(cue) }
        }

        private final class OverlayTestMonitor: MacComputerMonitoring {
            var running = false
            func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
                running = true
                return true
            }
            func stop() { running = false }
        }

        private actor OverlayTestDriver: MacComputerDriving {
            func execute(
                _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
                authorize: @escaping @Sendable () throws -> Void
            ) async throws -> [String: JSONValue] {
                try authorize()
                return [:]
            }
            func reset() {}
        }

        private actor CueRecorder {
            var cues: [MacComputerOverlayCue] = []
            func record(_ cue: MacComputerOverlayCue) { cues.append(cue) }
        }

        private func host(overlay: (any MacComputerOverlayPresenting)?, presented: @escaping () -> Void = {})
            -> MacComputerHost
        {
            let name = "overlay-tests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            addTeardownBlock { defaults.removePersistentDomain(forName: name) }
            let host = MacComputerHost(
                available: true, defaults: defaults, driver: OverlayTestDriver(), monitor: OverlayTestMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { _ in presented() }, overlay: overlay)
            host.bind(owner: "overlay-owner") { _ in true }
            host.setEnabled(true)
            addTeardownBlock { host.signedOut() }
            return host
        }

        private func session(_ host: MacComputerHost, id: String, state: String = "active") throws -> InboundFrame {
            let payload = JSONValue.object([
                "type": .string("computer_session"), "host_id": .string(try XCTUnwrap(host.descriptor).hostId),
                "session_id": .string(id), "state": .string(state), "controller_label": .string("Synthetic controller"),
            ])
            return try XCTUnwrap(InboundFrame.parse(String(decoding: payload.encoded(), as: UTF8.self)))
        }

        private func request(_ verb: String, _ args: [String: JSONValue]) throws -> ComputerHostRequest {
            try ComputerHostRequest(
                json: .object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(repeating: "c", count: 32)),
                    "session_id": .string("11111111-1111-4111-8111-111111111111"), "verb": .string(verb),
                    "args": .object(args), "deadline_ms": .number(30000),
                ]))
        }

        func testHostDrivesBannerStatesAndKeepsThePanelAsFallback() throws {
            let overlay = RecordingOverlay()
            var presentations = 0
            let host = host(overlay: overlay) { presentations += 1 }
            XCTAssertEqual(overlay.calls.first, "attach")
            XCTAssertFalse(overlay.calls.contains { $0.hasPrefix("show") })
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id: id))
            XCTAssertEqual(overlay.calls.last, "show:driving")
            host.approvalWaiting(true)
            XCTAssertEqual(overlay.calls.last, "show:approval")
            host.approvalWaiting(false)
            XCTAssertEqual(overlay.calls.last, "show:driving")
            host.pause()
            XCTAssertEqual(overlay.calls.last, "show:paused")
            host.consume(try session(host, id: id, state: "paused"))
            XCTAssertEqual(overlay.calls.last, "show:paused")
            XCTAssertEqual(presentations, 0)
            host.stop()
            XCTAssertEqual(overlay.calls.last, "hide")
            XCTAssertNil(host.session)
            overlay.available = false
            host.consume(try session(host, id: UUID().uuidString.lowercased()))
            XCTAssertEqual(overlay.calls.last, "show:driving")
            XCTAssertEqual(presentations, 1)
            host.stop()
            XCTAssertEqual(overlay.calls.last, "hide")
        }

        func testDriverSendsCuesInEffectOrderAndGlidesBeforePointerInput() async throws {
            let io = MacComputerTestSystem()
            io.configure { $0.bundles[200] = "com.apple.TextEdit" }
            io.set("TextEdit" as CFString, attribute: kAXTitleAttribute, of: io.app)
            let recorder = CueRecorder()
            let events = MacComputerInputTestEvents()
            let driver = MacComputerDriver(
                marker: 30, system: io, input: MacComputerInput(marker: 30, system: io, events: events),
                overlay: { await recorder.record($0) })
            _ = try await driver.execute(
                request("screenshot", ["max_width": .number(320)]), workspaces: [], authorize: {})
            events.configure { $0.onPost = { _, _ in io.effect("post") } }
            io.configure { $0.trace = [] }
            _ = try await driver.execute(
                request("click", ["x": .number(20), "y": .number(30)]), workspaces: [], authorize: {})
            XCTAssertEqual(
                io.configure { $0.trace.filter { ["delay", "post"].contains($0) } }, ["delay", "post", "post", "delay"])
            _ = try await driver.execute(
                request("scroll", ["x": .number(20), "y": .number(30), "dy": .number(5)]), workspaces: [],
                authorize: {})
            _ = try await driver.execute(
                request("drag", ["x1": .number(1), "y1": .number(1), "x2": .number(30), "y2": .number(30)]),
                workspaces: [], authorize: {})
            _ = try await driver.execute(
                request("press_keys", ["keys": .string("cmd+s")]), workspaces: [], authorize: {})
            let point = CGPoint(x: 40, y: 60)
            let settled = CGPoint(x: 20, y: 30)
            let cues = await recorder.cues
            XCTAssertEqual(
                cues,
                [
                    .app("TextEdit"), .point(point, label: nil), .click(point), .point(settled, label: nil),
                    .scroll(settled, dx: 0, dy: 5), .point(CGPoint(x: 1, y: 1), label: nil),
                    .drag(CGPoint(x: 1, y: 1), CGPoint(x: 30, y: 30)), .chord("⌘S"),
                ])
            let silent = MacComputerDriver(
                marker: 30, system: io, input: MacComputerInput(marker: 30, system: io, events: events))
            _ = try await silent.execute(
                request("screenshot", ["max_width": .number(320)]), workspaces: [], authorize: {})
            io.configure { $0.trace = [] }
            _ = try await silent.execute(
                request("click", ["x": .number(20), "y": .number(30)]), workspaces: [], authorize: {})
            XCTAssertEqual(
                io.configure { $0.trace.filter { ["delay", "post"].contains($0) } }, ["post", "post", "delay"])
        }

        func testChordLabelsUseMacModifierOrderAndKeySymbols() throws {
            let expected = [
                "cmd+s": "⌘S", "ctrl+alt+shift+cmd+k": "⌃⌥⇧⌘K", "shift+cmd+left": "⇧⌘←", "enter": "↩",
                "escape": "⎋", "shift+tab": "⇧⇥", "f5": "F5", "cmd+backspace": "⌘⌫", "space": "Space",
            ]
            for (keys, label) in expected {
                XCTAssertEqual(MacComputerOverlayCue.chordLabel(try ComputerHostChord(keys)), label, keys)
            }
        }

        func testLivePanelsAreClickThroughNonActivatingAndExcludedFromCapture() throws {
            guard let primary = NSScreen.screens.first?.frame else { throw XCTSkip("No display is attached.") }
            var presented: [NSPanel] = []
            let overlay = MacComputerOverlay(present: { presented.append($0) })
            XCTAssertFalse(overlay.show(.driving))
            let host = host(overlay: overlay)
            XCTAssertTrue(overlay.show(.driving))
            XCTAssertEqual(overlay.glyphPanels.count, NSScreen.screens.count)
            for panel in overlay.glyphPanels {
                XCTAssertTrue(panel.ignoresMouseEvents)
                XCTAssertEqual(panel.level, .screenSaver)
                XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
                XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
                XCTAssertFalse(panel.hidesOnDeactivate)
                XCTAssertFalse(panel.canBecomeKey)
                XCTAssertFalse(panel.canBecomeMain)
                XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
                XCTAssertEqual(panel.title, MacComputerOverlayIdentity.title)
            }
            let banner = try XCTUnwrap(overlay.banner)
            XCTAssertEqual(banner.title, MacComputerPanelIdentity.title)
            XCTAssertTrue(banner.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(banner.becomesKeyOnlyIfNeeded)
            XCTAssertFalse(banner.canBecomeMain)
            XCTAssertFalse(banner.hidesOnDeactivate)
            XCTAssertGreaterThan(banner.level.rawValue, NSWindow.Level.screenSaver.rawValue)
            XCTAssertEqual(presented.count, overlay.glyphPanels.count + 1)
            XCTAssertFalse(overlay.windowIDs.isEmpty)
            XCTAssertTrue(overlay.windowIDs.isSubset(of: MacComputerLiveSystem.shared.overlayWindows()))
            XCTAssertFalse(overlay.windowIDs.contains(CGWindowID(banner.windowNumber)))
            XCTAssertTrue(MacComputerLiveSystem.shared.controlsWindows().contains(CGWindowID(banner.windowNumber)))
            XCTAssertLessThan(abs(banner.frame.maxY - (NSScreen.screens[0].visibleFrame.maxY - 8)), 1)
            let canvas = try XCTUnwrap(overlay.glyphPanels.first?.contentView as? MacComputerOverlayCanvas)
            overlay.cue(.app("TextEdit"))
            XCTAssertEqual(overlay.model.app, "TextEdit")
            let point = CGPoint(x: primary.midX, y: primary.midY)
            overlay.cue(.point(point, label: "Save — TextEdit"))
            XCTAssertEqual(canvas.pointerPosition, CGPoint(x: primary.midX, y: primary.height - primary.midY))
            XCTAssertTrue(canvas.cueNames.contains("label"))
            overlay.cue(.click(point))
            overlay.cue(.drag(point, CGPoint(x: point.x + 40, y: point.y)))
            overlay.cue(.scroll(point, dx: 0, dy: -3))
            overlay.cue(.chord("⌘S"))
            let names = overlay.glyphPanels.compactMap { ($0.contentView as? MacComputerOverlayCanvas)?.cueNames }
                .flatMap { $0 }
            for name in ["ripple", "drag", "scroll", "toast"] { XCTAssertTrue(names.contains(name), name) }
            let bannerCenter = CGPoint(x: banner.frame.midX, y: primary.height - banner.frame.midY)
            overlay.cue(.point(bannerCenter, label: nil))
            XCTAssertLessThan(banner.frame.midY, NSScreen.screens[0].frame.midY)
            XCTAssertTrue(overlay.show(.approval))
            XCTAssertEqual(overlay.model.mode, .approval)
            overlay.hide()
            XCTAssertNil(overlay.mode)
            XCTAssertEqual(canvas.cueNames, ["pointer"])
            XCTAssertNil(canvas.pointerPosition)
            overlay.cue(.click(point))
            XCTAssertEqual(canvas.cueNames, ["pointer"])
            host.stop()
        }

        func testInputSkipsClickThroughOverlaysButStillRefusesAstralWindows() async throws {
            let system = MacComputerInputTestSystem()
            var overlayRow = MacComputerInputTestSystem.row(pid: 100)
            overlayRow[kCGWindowName as String] = MacComputerOverlayIdentity.title
            system.setWindows([overlayRow, MacComputerInputTestSystem.row(pid: 200)])
            let events = MacComputerInputTestEvents()
            let input = MacComputerInput(marker: 30, system: system, events: events)
            let click = try request("click", ["x": .number(20), "y": .number(30)])
            try await input.pointer(click, start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
            XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseUp])
            var astral = MacComputerInputTestSystem.row(pid: 100)
            astral[kCGWindowName as String] = "Astral"
            system.setWindows([overlayRow, astral])
            do {
                try await input.pointer(click, start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
                XCTFail("A click into Astral's own window under the overlay was posted")
            } catch let error as ComputerHostError { XCTAssertEqual(error.code, "permission_denied") }
            var banner = MacComputerInputTestSystem.row(pid: 100)
            banner[kCGWindowName as String] = MacComputerPanelIdentity.title
            system.setWindows([overlayRow, banner])
            do {
                try await input.pointer(click, start: CGPoint(x: 20, y: 30), end: nil, authorize: {})
                XCTFail("A click under the control banner was posted")
            } catch let error as ComputerHostError { XCTAssertEqual(error.code, "obscured_by_astral_panel") }
            XCTAssertEqual(events.posted.count, 2)
        }
    }
#endif
