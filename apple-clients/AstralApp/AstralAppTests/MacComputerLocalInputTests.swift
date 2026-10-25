// Exercises local HID proof and takeover monitors through inert native events.
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

        func testIncompleteMonitorRegistrationFailsAndStopsOnlyAcquiredHandles() {
            for (global, local) in [(false, true), (true, false), (false, false)] {
                let monitors = MacComputerTestMonitors()
                monitors.globalAvailable = global
                monitors.localAvailable = local
                let input = MacComputerInputMonitor(marker: 30, monitors: monitors)
                XCTAssertFalse(input.start {})
                XCTAssertFalse(input.running)
                input.stop()
                XCTAssertEqual(monitors.removed.count, [global, local].filter { $0 }.count)
            }
        }

        func testHostControlsWindowIsExcludedFromLocalTakeover() throws {
            let monitors = MacComputerTestMonitors()
            let monitor = MacComputerInputMonitor(marker: 30, monitors: monitors)
            monitors.associatedWindow = 100
            monitor.controlsWindow = 100
            var takeovers = 0
            XCTAssertTrue(monitor.start { takeovers += 1 })
            defer { monitor.stop() }
            let native = try XCTUnwrap(NSEvent(cgEvent: event()))
            XCTAssertTrue(monitors.emitLocal(native) === native)
            XCTAssertEqual(takeovers, 0)
            monitors.associatedWindow = 200
            XCTAssertTrue(monitors.emitLocal(native) === native)
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

        func testMonitorStartIsIdempotentAndStopRemovesBothRegistrations() {
            let monitors = MacComputerTestMonitors()
            let monitor = MacComputerInputMonitor(marker: 30, monitors: monitors)
            XCTAssertFalse(monitor.running)
            XCTAssertTrue(monitor.start {})
            XCTAssertTrue(monitor.start {})
            XCTAssertEqual(monitors.globals.count, 1)
            XCTAssertEqual(monitors.locals.count, 1)
            XCTAssertTrue(monitors.globalMasks[0].contains([.keyDown, .flagsChanged, .mouseMoved, .scrollWheel]))
            monitor.stop()
            monitor.stop()
            XCTAssertFalse(monitor.running)
            XCTAssertEqual(monitors.removed, [1, 2])
        }

        func testGlobalAndLocalTakeoverIgnoreMarkedPostsAndPreserveEvent() throws {
            let monitors = MacComputerTestMonitors()
            let monitor = MacComputerInputMonitor(marker: 30, monitors: monitors)
            monitor.controlsWindow = 100
            var takeovers = 0
            XCTAssertTrue(monitor.start { takeovers += 1 })
            defer { monitor.stop() }
            let marked = try XCTUnwrap(NSEvent(cgEvent: event(marker: 30)))
            monitors.emitGlobal(marked)
            XCTAssertTrue(monitors.emitLocal(marked) === marked)
            XCTAssertEqual(takeovers, 0)
            let physical = try XCTUnwrap(NSEvent(cgEvent: event()))
            monitors.emitGlobal(physical)
            XCTAssertTrue(monitors.emitLocal(physical) === physical)
            XCTAssertEqual(takeovers, 2)
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
