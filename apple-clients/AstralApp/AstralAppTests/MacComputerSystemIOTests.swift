// Checks native configuration, encoding and self-process metadata at the public API boundary.
// Tests use synthetic pixels and read-only probes without capture, input posting or application launch.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import ScreenCaptureKit
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerSystemIOTests: XCTestCase {
        func testNativeCaptureConfigurationBindsDimensionsAndNeverCapturesAudio() {
            let plan = MacComputerCapturePlan(display: 77, excludedWindows: [5], width: 320, height: 240)
            let configuration = plan.configuration()
            XCTAssertEqual(configuration.width, 320)
            XCTAssertEqual(configuration.height, 240)
            XCTAssertTrue(configuration.showsCursor)
            XCTAssertFalse(configuration.capturesAudio)
        }
        func testNativeJPEGEncodingProducesActualJPEGFromSyntheticPixels() throws {
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            let image = try XCTUnwrap(context.makeImage())
            let bytes = try XCTUnwrap(MacComputerLiveSystem.shared.jpeg(image))
            XCTAssertEqual(Array(bytes.prefix(2)), [0xff, 0xd8])
            XCTAssertEqual(Array(bytes.suffix(2)), [0xff, 0xd9])
            XCTAssertNotNil(NSBitmapImageRep(data: bytes))
        }
        func testDriverPermissionFactsAgreeWithDisplayedRawPermissions() {
            let io = MacComputerLiveSystem.shared
            let permissions = MacComputerPermissions.current()
            XCTAssertEqual(io.accessibilityTrusted(), permissions.accessibility)
            XCTAssertEqual(io.postEventAccess(), permissions.posting)
            XCTAssertEqual(io.screenCaptureAccess(), permissions.screen)
            XCTAssertEqual(io.listenEventAccess(), permissions.monitoring)
        }
        func testNativeAXSelfIdentityAndDisplayMetadataRemainReadOnly() {
            let io = MacComputerLiveSystem.shared
            XCTAssertEqual(io.hostPID, ProcessInfo.processInfo.processIdentifier)
            let application = io.applicationElement(io.hostPID)
            XCTAssertEqual(io.pid(of: application), io.hostPID)
            XCTAssertEqual(CFGetTypeID(io.systemElement()), AXUIElementGetTypeID())
            io.messagingTimeout(0.2, for: application)
            if let role = io.attribute(kAXRoleAttribute, of: application) {
                XCTAssertEqual(CFGetTypeID(role), CFStringGetTypeID())
            }
            XCTAssertNil(io.bundleIdentifier(for: pid_t.max))
            let (status, count) = io.displayCount()
            if status == .success, count <= 8 {
                let (enumeration, ids) = io.displayIDs(capacity: count)
                if enumeration == .success { XCTAssertLessThanOrEqual(ids.count, Int(count)) }
            }
            let bounds = io.displayBounds(io.mainDisplay())
            let pixels = io.displayPixels(io.mainDisplay())
            XCTAssertTrue(bounds.width.isFinite && bounds.height.isFinite)
            XCTAssertGreaterThanOrEqual(pixels.width, 0)
            XCTAssertGreaterThanOrEqual(pixels.height, 0)
            XCTAssertTrue(io.runningApplications().allSatisfy { $0.pid > 0 })
            XCTAssertNil(io.applicationURL(bundleIdentifier: "fixture.missing." + UUID().uuidString))
        }
        func testNonexistentApplicationCannotActivateOrAcceptAXMutation() {
            let io = MacComputerLiveSystem.shared
            XCTAssertNil(io.bundleIdentifier(for: pid_t.max))
            XCTAssertFalse(io.activate(pid_t.max))
            let missing = io.applicationElement(pid_t.max)
            let minimized = io.setAttribute(kAXMinimizedAttribute, of: missing, to: kCFBooleanFalse)
            let raised = io.perform(kAXRaiseAction, on: missing)
            XCTAssertNotEqual(minimized, .success)
            XCTAssertNotEqual(raised, .success)
            print("Nonexistent PID AX results: set=\(minimized.rawValue), raise=\(raised.rawValue); activation=false")
        }
        func testNativeSessionMetadataAndZeroDelayPreserveFailureAndCancellation() async throws {
            let io = MacComputerLiveSystem.shared
            let session = io.sessionDictionary()
            if let session {
                XCTAssertNotNil(session[kCGSessionOnConsoleKey as String] as? Bool)
                XCTAssertNotNil(session[kCGSessionLoginDoneKey as String] as? Bool)
            }
            print("Native session dictionary available: \(session != nil)")
            try await io.delay(nanoseconds: 0)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    try await io.delay(nanoseconds: 0)
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            let cancelledBeforeDelay = await cancelled.value
            XCTAssertTrue(cancelledBeforeDelay)
        }
    }
#endif
