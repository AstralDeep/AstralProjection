// Exercises native observation and desktop admission against raw synthetic AX and session data.
// The real verifier must reject changed identities without reading or actuating the user's desktop.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import XCTest
    @testable import AstralDeep

    final class MacComputerObservationTests: XCTestCase {
        func testRawContextAndImmutableWindowVerification() throws {
            let io = MacComputerTestSystem()
            let current = MacComputerObservation.context(system: io)
            XCTAssertEqual(current.pid, 200)
            XCTAssertTrue(CFEqual(current.window, io.window))
            XCTAssertEqual(current.bounds, CGRect(x: 0, y: 0, width: 640, height: 480))
            let observation = try MacComputerObservation.capture(screenshot: true, system: io)
            try observation.verify(requireScreenshot: true, requireWindow: true)
            io.setBounds(CGRect(x: 1, y: 0, width: 640, height: 480), of: io.window)
            XCTAssertThrowsError(try observation.verify(requireScreenshot: true, requireWindow: true))
        }
        func testMissingAndWrongTypedAXValuesNeverInventContext() {
            for name in [
                kAXFocusedApplicationAttribute, kAXFocusedWindowAttribute, kAXPositionAttribute, kAXSizeAttribute,
            ] {
                let io = MacComputerTestSystem()
                let element =
                    name == kAXFocusedApplicationAttribute
                    ? io.system
                    : (name == kAXFocusedWindowAttribute ? io.app : io.window)
                for value: CFTypeRef? in [nil, "wrong" as CFString] {
                    io.set(value, attribute: name, of: element)
                    let result = MacComputerObservation.context(system: io)
                    XCTAssertNil(result.bounds)
                    if name == kAXFocusedApplicationAttribute { XCTAssertNil(result.pid) }
                }
            }
            let io = MacComputerTestSystem()
            io.configure { $0.nodes[1].pid = nil }
            XCTAssertNil(MacComputerObservation.context(system: io).pid)
            var number: CFRange = CFRange(location: 0, length: 1)
            io.set(AXValueCreate(.cfRange, &number), attribute: kAXPositionAttribute, of: io.window)
            io.configure { $0.nodes[1].pid = 200 }
            XCTAssertNil(MacComputerObservation.context(system: io).bounds)
        }
        func testEachObservationRequirementAndDisplayMutationFailsClosed() throws {
            for scenario in 0..<5 {
                let io = MacComputerTestSystem()
                let before = try MacComputerObservation.capture(screenshot: scenario != 0, system: io)
                switch scenario {
                case 1: io.set(nil, attribute: kAXFocusedWindowAttribute, of: io.app)
                case 2: io.configure { $0.nodes[1].pid = 201 }
                case 3: io.configure { $0.bounds.origin.x = 10 }
                case 4: io.setBounds(CGRect(x: 0, y: 0, width: 600, height: 480), of: io.window)
                default: break
                }
                XCTAssertThrowsError(try before.verify(requireScreenshot: true, requireWindow: true))
            }
        }
        func testDisplayEnumerationDenialsAndStableOrdering() throws {
            let io = MacComputerTestSystem()
            io.configure { $0.displays = [90, 77] }
            XCTAssertTrue(try MacComputerObservation.topology(system: io).hasPrefix("77:"))
            for count in [UInt32(0), 9] {
                io.configure { $0.countOverride = count }
                XCTAssertThrowsError(try MacComputerObservation.topology(system: io))
            }
            io.configure {
                $0.countOverride = nil
                $0.countError = .failure
            }
            XCTAssertThrowsError(try MacComputerObservation.topology(system: io))
            io.configure {
                $0.countError = .success
                $0.enumerationError = .failure
            }
            XCTAssertThrowsError(try MacComputerObservation.topology(system: io))
        }
        func testDesktopAdmissionUsesRawSessionSecureInputAndProcessFacts() {
            let io = MacComputerTestSystem()
            XCTAssertTrue(MacComputerDesktopProbe.usable(system: io))
            for session: [String: Any]? in [
                nil, [:], [kCGSessionOnConsoleKey as String: false],
                [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: false],
                [
                    kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true,
                    "CGSSessionScreenIsLocked": true,
                ],
            ] {
                io.configure { $0.session = session }
                XCTAssertFalse(MacComputerDesktopProbe.usable(system: io))
            }
            io.configure {
                $0.session = [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
                $0.secure = true
            }
            XCTAssertFalse(MacComputerDesktopProbe.usable(system: io))
            io.configure {
                $0.secure = false
                $0.bundles[200] = "com.apple.loginwindow"
            }
            XCTAssertFalse(MacComputerDesktopProbe.usable(system: io))
            io.configure { $0.bundles[200] = nil }
            XCTAssertFalse(MacComputerDesktopProbe.usable(system: io))
        }
        @MainActor func testLocalDesktopRearmRequiresActualOwnForegroundAndActiveApp() {
            let io = MacComputerTestSystem()
            XCTAssertFalse(MacComputerDesktopProbe.localRearm(system: io, appActive: true))
            io.configure { $0.nodes[1].pid = 100 }
            XCTAssertFalse(MacComputerDesktopProbe.localRearm(system: io, appActive: false))
            XCTAssertTrue(MacComputerDesktopProbe.localRearm(system: io, appActive: true))
        }
    }
#endif
