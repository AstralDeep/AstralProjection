// Captures immutable display and accessibility identities for per-event input fencing.
// Desktop probes independently deny unavailable sessions while the host requires explicit local rearming.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import Carbon
    import Foundation

    nonisolated enum MacComputerDesktopProbe: Sendable {
        nonisolated static func usable() -> Bool {
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
                session[kCGSessionOnConsoleKey as String] as? Bool == true,
                session[kCGSessionLoginDoneKey as String] as? Bool == true,
                session["CGSSessionScreenIsLocked"] as? Bool != true,
                !IsSecureEventInputEnabled(), let pid = MacComputerObservation.context().pid,
                let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleIdentifier,
                bundle != "com.apple.loginwindow"
            else { return false }
            return true
        }
        @MainActor static func localRearm() -> Bool {
            NSApp.isActive && MacComputerObservation.context().pid == ProcessInfo.processInfo.processIdentifier
                && usable()
        }
    }

    nonisolated final class MacComputerObservation: @unchecked Sendable {
        let identity: ComputerHostObservationIdentity
        private let window: AXUIElement?
        private let bounds: CGRect?
        init(identity: ComputerHostObservationIdentity, window: AXUIElement?, bounds: CGRect?) {
            self.identity = identity
            self.window = window
            self.bounds = bounds
        }
        nonisolated static func context() -> (pid: pid_t?, window: AXUIElement?, bounds: CGRect?) {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            var appValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appValue)
                    == .success,
                let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID()
            else { return (nil, nil, nil) }
            let app = unsafeBitCast(appValue, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var pid: pid_t = 0
            var windowValue: CFTypeRef?
            guard AXUIElementGetPid(app, &pid) == .success else { return (nil, nil, nil) }
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
                let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID()
            else { return (pid, nil, nil) }
            let window = unsafeBitCast(windowValue, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(window, 0.2)
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
                CFGetTypeID(size) == AXValueGetTypeID()
            else { return (pid, window, nil) }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
            else { return (pid, window, nil) }
            return (pid, window, CGRect(origin: point, size: dimensions))
        }
        nonisolated static func topology() throws -> String {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, (1...8).contains(count) else {
                throw ComputerHostError("screen_locked", "The displays are unavailable.")
            }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
                throw ComputerHostError("screen_locked", "Display enumeration failed.")
            }
            ids.sort { a, b in a == CGMainDisplayID() || (b != CGMainDisplayID() && a < b) }
            return ids.map { "\($0):\(CGDisplayBounds($0)):\(CGDisplayPixelsWide($0)):\(CGDisplayPixelsHigh($0))" }
                .joined(separator: ";")
        }
        nonisolated static func capture(screenshot: Bool) throws -> MacComputerObservation {
            let current = context()
            return MacComputerObservation(
                identity: ComputerHostObservationIdentity(
                    foreground: current.pid, topology: try topology(), screenshot: screenshot), window: current.window,
                bounds: current.bounds)
        }
        nonisolated func verify(requireScreenshot: Bool, requireWindow: Bool) throws {
            let current = Self.context()
            try ComputerHostObservationGate.validate(
                expected: identity,
                current: ComputerHostObservationIdentity(
                    foreground: current.pid, topology: try Self.topology(), screenshot: false),
                requireScreenshot: requireScreenshot)
            if requireWindow || window != nil {
                guard let window, let actual = current.window, CFEqual(window, actual), let bounds,
                    current.bounds == bounds
                else {
                    throw ComputerHostError("stale_target", "The observed window changed. Observe the target again.")
                }
            }
        }
    }
#endif
