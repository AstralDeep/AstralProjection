// Exercises local HID proof and the takeover monitor through inert native events and a manual scheduler.
// Registration is recorded without installing monitors or generating desktop effects.

#if os(macOS)
    import AppKit
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerLocalInputTests: XCTestCase {
        private func event(pid: Int64 = 0, state: Int64 = 1, marker: Int64 = 0) throws -> CGEvent {
            let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
            event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
            event.setIntegerValueField(.eventSourceStateID, value: state)
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            return event
        }

        func testRegisteredLocalHardwareProofIsFreshAndConsumedOnce() throws {
            let monitors = MacComputerTestMonitors()
            let input = MacComputerLocalInput(marker: 30, monitors: monitors)
            defer { input.stop() }
            XCTAssertEqual(monitors.locals.count, 1)
            XCTAssertTrue(monitors.localMasks[0].contains([.keyDown, .keyUp, .leftMouseDown, .leftMouseUp]))
            XCTAssertFalse(input.consume(current: nil))
            let physical = try event()
            let native = try XCTUnwrap(NSEvent(cgEvent: physical))
            XCTAssertTrue(monitors.emitLocal(native) === native)
            XCTAssertTrue(input.consume(current: nil))
            XCTAssertFalse(input.consume(current: physical))
            input.record(physical)
            XCTAssertTrue(input.consume(current: physical))
            XCTAssertFalse(input.consume(current: nil))
        }

        func testCurrentHardwareEventWithoutRecordedProofAndMissingMonitorCannotConsent() throws {
            let monitors = MacComputerTestMonitors()
            monitors.localAvailable = false
            let input = MacComputerLocalInput(marker: 30, monitors: monitors)
            XCTAssertFalse(input.consume(current: try event()))
            input.stop()
            XCTAssertTrue(monitors.removed.isEmpty)
        }

        func testGlobalRegistrationAloneDecidesMonitorAvailability() {
            for global in [false, true] {
                let monitors = MacComputerTestMonitors()
                monitors.globalAvailable = global
                monitors.localAvailable = false
                let input = MacComputerInputMonitor(marker: 30, monitors: monitors)
                XCTAssertEqual(input.start {}, global)
                XCTAssertEqual(input.running, global)
                XCTAssertTrue(monitors.locals.isEmpty)
                input.stop()
                XCTAssertEqual(monitors.removed.count, global ? 1 : 0)
            }
        }

        func testInputInsideAstralWindowsNeverRegistersTakeover() throws {
            let monitors = MacComputerTestMonitors()
            let scheduler = MacComputerTestScheduler()
            let monitor = MacComputerInputMonitor(
                marker: 30, monitors: monitors, frontmost: { "com.personalailabs.astraldeep" },
                hostBundle: "com.personalailabs.astraldeep", schedule: scheduler.schedule)
            var takeovers = 0
            XCTAssertTrue(monitor.start { takeovers += 1 })
            defer { monitor.stop() }
            XCTAssertTrue(monitors.locals.isEmpty)
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: event())))
            XCTAssertEqual(scheduler.delays, [MacComputerInputMonitor.frontmostDelay])
            scheduler.runAll()
            XCTAssertEqual(takeovers, 0)
        }

        func testDiscreteInputOutsideAstralPausesOnlyWhenAnotherAppIsFrontmostLater() throws {
            for (frontmost, expected) in [("com.apple.TextEdit", 1), (nil, 1), ("com.personalailabs.astraldeep", 0)] {
                let kinds: [CGEvent] = [
                    try event(),
                    try XCTUnwrap(
                        CGEvent(
                            mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero,
                            mouseButton: .left)),
                    try XCTUnwrap(
                        CGEvent(
                            mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: .zero,
                            mouseButton: .right)),
                    try XCTUnwrap(
                        CGEvent(
                            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0,
                            wheel3: 0)),
                ]
                for kind in kinds {
                    let monitors = MacComputerTestMonitors()
                    let scheduler = MacComputerTestScheduler()
                    let current = MacComputerTestFrontmost()
                    let monitor = MacComputerInputMonitor(
                        marker: 30, monitors: monitors, frontmost: { current.bundle },
                        hostBundle: "com.personalailabs.astraldeep", schedule: scheduler.schedule)
                    var takeovers = 0
                    XCTAssertTrue(monitor.start { takeovers += 1 })
                    monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: kind)))
                    XCTAssertEqual(takeovers, 0)
                    current.bundle = frontmost
                    scheduler.runAll()
                    XCTAssertEqual(takeovers, expected, "\(kind.type) \(String(describing: frontmost))")
                    monitor.stop()
                }
            }
        }

        func testPointerMovementMustExceedTheThresholdWithinTheWindow() throws {
            func move(_ x: Double, _ y: Double) throws -> NSEvent {
                try XCTUnwrap(
                    NSEvent(
                        cgEvent: XCTUnwrap(
                            CGEvent(
                                mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y),
                                mouseButton: .left))))
            }
            let monitors = MacComputerTestMonitors()
            let scheduler = MacComputerTestScheduler()
            let monitor = MacComputerInputMonitor(
                marker: 30, monitors: monitors, frontmost: { "com.apple.TextEdit" },
                hostBundle: "com.personalailabs.astraldeep", schedule: scheduler.schedule)
            var takeovers = 0
            XCTAssertTrue(monitor.start { takeovers += 1 })
            defer { monitor.stop() }
            monitors.uptime = 10
            monitors.emitGlobal(try move(100, 100))
            monitors.uptime = 10.1
            monitors.emitGlobal(try move(110, 110))
            monitors.uptime = 10.2
            monitors.emitGlobal(try move(116, 116))
            XCTAssertTrue(scheduler.delays.isEmpty)
            monitors.uptime = 10.6
            monitors.emitGlobal(try move(130, 130))
            monitors.uptime = 10.9
            monitors.emitGlobal(try move(140, 140))
            XCTAssertTrue(scheduler.delays.isEmpty)
            monitors.uptime = 11.0
            monitors.emitGlobal(try move(165, 140))
            XCTAssertEqual(scheduler.delays.count, 1)
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: event())))
            XCTAssertEqual(scheduler.delays.count, 1)
            scheduler.runAll()
            XCTAssertEqual(takeovers, 1)
            let marked = try XCTUnwrap(
                CGEvent(
                    mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 900, y: 900),
                    mouseButton: .left))
            marked.setIntegerValueField(.eventSourceUserData, value: 30)
            monitors.uptime = 11.05
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: marked)))
            XCTAssertEqual(scheduler.delays.count, 1)
        }

        func testPointerInputEndingOverAstralWindowsIsNotTakeoverButKeysAre() throws {
            let monitors = MacComputerTestMonitors()
            let scheduler = MacComputerTestScheduler()
            let pointer = MacComputerTestFlag(true)
            let monitor = MacComputerInputMonitor(
                marker: 30, monitors: monitors, frontmost: { "com.apple.TextEdit" },
                hostBundle: "com.personalailabs.astraldeep", pointerOverHost: { pointer.value },
                schedule: scheduler.schedule)
            var takeovers = 0
            XCTAssertTrue(monitor.start { takeovers += 1 })
            defer { monitor.stop() }
            let click = try XCTUnwrap(
                CGEvent(
                    mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: click)))
            for x in [0.0, 30, 60] {
                monitors.uptime += 0.05
                monitors.emitGlobal(
                    try XCTUnwrap(
                        NSEvent(
                            cgEvent: XCTUnwrap(
                                CGEvent(
                                    mouseEventSource: nil, mouseType: .mouseMoved,
                                    mouseCursorPosition: CGPoint(x: x, y: 0), mouseButton: .left)))))
            }
            scheduler.runAll()
            XCTAssertEqual(takeovers, 0)
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: event())))
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: click)))
            scheduler.runAll()
            XCTAssertEqual(takeovers, 1)
            pointer.value = false
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: click)))
            scheduler.runAll()
            XCTAssertEqual(takeovers, 2)
        }

        func testStopCancelsAPendingFrontmostCheck() throws {
            let monitors = MacComputerTestMonitors()
            let scheduler = MacComputerTestScheduler()
            let monitor = MacComputerInputMonitor(
                marker: 30, monitors: monitors, frontmost: { "com.apple.TextEdit" },
                hostBundle: "com.personalailabs.astraldeep", schedule: scheduler.schedule)
            var takeovers = 0
            XCTAssertTrue(monitor.start { takeovers += 1 })
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: event())))
            monitor.stop()
            XCTAssertTrue(monitor.start { takeovers += 1 })
            defer { monitor.stop() }
            scheduler.runAll()
            XCTAssertEqual(takeovers, 0)
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: event())))
            scheduler.runAll()
            XCTAssertEqual(takeovers, 1)
        }

        func testExpiredBackwardsAndNonfiniteClocksInvalidateProof() throws {
            for time in [12.1, 9.0, Double.infinity, Double.nan] {
                let monitors = MacComputerTestMonitors()
                let input = MacComputerLocalInput(marker: 30, monitors: monitors)
                input.record(try event())
                monitors.uptime = time
                XCTAssertFalse(input.consume(current: nil))
                monitors.uptime = 10
                XCTAssertFalse(input.consume(current: nil))
                input.stop()
            }
        }

        func testSyntheticOrUnknownRecordAndCurrentActivationCannotConsumeHardwareProof() throws {
            let monitors = MacComputerTestMonitors()
            let input = MacComputerLocalInput(marker: 30, monitors: monitors)
            defer { input.stop() }
            let physical = try event()
            let invalid: [CGEvent?] = [nil, try event(pid: 999), try event(state: 0), try event(marker: 30)]
            for value in invalid {
                input.record(physical)
                input.record(value)
                XCTAssertFalse(input.consume(current: physical))
            }
            for value in invalid.compactMap({ $0 }) {
                input.record(physical)
                XCTAssertFalse(input.consume(current: value))
                XCTAssertFalse(input.consume(current: physical))
            }
        }

        func testStopRemovesRegistrationAndClearsEvidenceOnce() throws {
            let monitors = MacComputerTestMonitors()
            let input = MacComputerLocalInput(marker: 30, monitors: monitors)
            input.record(try event())
            input.stop()
            input.stop()
            XCTAssertEqual(monitors.removed, [1])
            XCTAssertFalse(input.consume(current: nil))
        }

        func testMonitorStartIsIdempotentAndStopRemovesTheRegistration() {
            let monitors = MacComputerTestMonitors()
            let monitor = MacComputerInputMonitor(marker: 30, monitors: monitors)
            XCTAssertFalse(monitor.running)
            XCTAssertTrue(monitor.start {})
            XCTAssertTrue(monitor.start {})
            XCTAssertEqual(monitors.globals.count, 1)
            XCTAssertTrue(monitors.locals.isEmpty)
            XCTAssertTrue(
                monitors.globalMasks[0].contains([.keyDown, .flagsChanged, .mouseMoved, .scrollWheel, .leftMouseDown]))
            monitor.stop()
            monitor.stop()
            XCTAssertFalse(monitor.running)
            XCTAssertEqual(monitors.removed, [1])
        }

        func testMarkedPostsNeverScheduleTakeover() throws {
            let monitors = MacComputerTestMonitors()
            let scheduler = MacComputerTestScheduler()
            let monitor = MacComputerInputMonitor(
                marker: 30, monitors: monitors, frontmost: { "com.apple.TextEdit" },
                hostBundle: "com.personalailabs.astraldeep", schedule: scheduler.schedule)
            var takeovers = 0
            XCTAssertTrue(monitor.start { takeovers += 1 })
            defer { monitor.stop() }
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: event(marker: 30))))
            XCTAssertTrue(scheduler.delays.isEmpty)
            monitors.emitGlobal(try XCTUnwrap(NSEvent(cgEvent: event())))
            scheduler.runAll()
            XCTAssertEqual(takeovers, 1)
        }
    }

    @MainActor
    final class MacComputerTestFlag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    @MainActor
    final class MacComputerTestFrontmost {
        var bundle: String? = "com.personalailabs.astraldeep"
    }

    @MainActor
    final class MacComputerTestScheduler {
        private(set) var delays: [TimeInterval] = []
        private var pending: [@MainActor () -> Void] = []
        var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void {
            { [unowned self] delay, body in
                self.delays.append(delay)
                self.pending.append(body)
            }
        }
        func runAll() {
            let work = pending
            pending = []
            for body in work { body() }
        }
    }

    @MainActor
    final class MacComputerTestMonitors: MacComputerEventMonitoring {
        var uptime: TimeInterval = 10
        var globals: [(@MainActor (NSEvent) -> Void)] = []
        var locals: [(@MainActor (NSEvent) -> NSEvent?)] = []
        var globalMasks: [NSEvent.EventTypeMask] = []
        var localMasks: [NSEvent.EventTypeMask] = []
        var removed: [Int] = []
        var globalAvailable = true
        var localAvailable = true
        var associatedWindow: Int?
        private var next = 0

        func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
            globalMasks.append(mask)
            globals.append(handler)
            guard globalAvailable else { return nil }
            next += 1
            return next
        }

        func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any?
        {
            localMasks.append(mask)
            locals.append(handler)
            guard localAvailable else { return nil }
            next += 1
            return next
        }

        func remove(_ monitor: Any) { removed.append(monitor as! Int) }
        func associatedWindowNumber(for event: NSEvent) -> Int? { associatedWindow }
        func emitGlobal(_ event: NSEvent) { globals.last?(event) }
        func emitLocal(_ event: NSEvent) -> NSEvent? { locals.last?(event) }
    }
#endif
