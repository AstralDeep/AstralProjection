// Captures immutable display and accessibility identities for per-event input fencing.
// Raw OS readings remain injectable while desktop admission and local rearming retain independent checks.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import Foundation

    nonisolated enum MacComputerDesktopProbe: Sendable {
        static func usable() -> Bool { usable(system: MacComputerLiveSystem.shared) }
        static func usable(system: any MacComputerSystemIO) -> Bool {
            guard let session = system.sessionDictionary() else { return false }
            return session[kCGSessionOnConsoleKey as String] as? Bool == true
                && session[kCGSessionLoginDoneKey as String] as? Bool == true
                && session["CGSSessionScreenIsLocked"] as? Bool != true
        }
        @MainActor static func localRearm() -> Bool {
            localRearm(system: MacComputerLiveSystem.shared, appActive: NSApp.isActive)
        }
        @MainActor static func localRearm(system: any MacComputerSystemIO, appActive: Bool) -> Bool {
            appActive && MacComputerObservation.context(system: system).pid == system.hostPID && usable(system: system)
        }
    }

    nonisolated final class MacComputerObservation: @unchecked Sendable {
        let identity: ComputerHostObservationIdentity
        private let window: AXUIElement?
        private let bounds: CGRect?
        private let system: any MacComputerSystemIO
        init(
            identity: ComputerHostObservationIdentity, window: AXUIElement?, bounds: CGRect?,
            system: any MacComputerSystemIO = MacComputerLiveSystem.shared
        ) {
            self.identity = identity
            self.window = window
            self.bounds = bounds
            self.system = system
        }
        static func context(system: any MacComputerSystemReading = MacComputerLiveSystem.shared)
            -> (pid: pid_t?, window: AXUIElement?, bounds: CGRect?)
        {
            let root = system.systemElement()
            system.messagingTimeout(0.2, for: root)
            guard let appValue = system.attribute(kAXFocusedApplicationAttribute, of: root),
                CFGetTypeID(appValue) == AXUIElementGetTypeID()
            else { return (nil, nil, nil) }
            let app = unsafeBitCast(appValue, to: AXUIElement.self)
            system.messagingTimeout(0.2, for: app)
            guard let pid = system.pid(of: app) else { return (nil, nil, nil) }
            guard let windowValue = system.attribute(kAXFocusedWindowAttribute, of: app),
                CFGetTypeID(windowValue) == AXUIElementGetTypeID()
            else { return (pid, nil, nil) }
            let window = unsafeBitCast(windowValue, to: AXUIElement.self)
            system.messagingTimeout(0.2, for: window)
            guard let position = system.attribute(kAXPositionAttribute, of: window),
                let size = system.attribute(kAXSizeAttribute, of: window),
                CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { return (pid, window, nil) }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
            else { return (pid, window, nil) }
            return (pid, window, CGRect(origin: point, size: dimensions))
        }
        static func displayIDs(system: any MacComputerSystemIO) throws -> [CGDirectDisplayID] {
            let (countResult, count) = system.displayCount()
            guard countResult == .success, (1...8).contains(count) else {
                throw ComputerHostError("screen_locked", "The displays are unavailable.")
            }
            let (result, ids) = system.displayIDs(capacity: count)
            guard result == .success, ids.count == Int(count), Set(ids).count == ids.count, !ids.contains(0) else {
                throw ComputerHostError("screen_locked", "Display enumeration failed.")
            }
            let primary = system.mainDisplay()
            return ids.sorted { a, b in a == primary || (b != primary && a < b) }
        }
        static func topology(system: any MacComputerSystemIO = MacComputerLiveSystem.shared) throws -> String {
            try displayIDs(system: system).map {
                let pixels = system.displayPixels($0)
                return "\($0):\(system.displayBounds($0)):\(Int(pixels.width)):\(Int(pixels.height))"
            }.joined(separator: ";")
        }
        static func capture(screenshot: Bool, system: any MacComputerSystemIO = MacComputerLiveSystem.shared) throws
            -> MacComputerObservation
        {
            let current = context(system: system)
            return MacComputerObservation(
                identity: ComputerHostObservationIdentity(
                    foreground: current.pid, topology: try topology(system: system), screenshot: screenshot),
                window: current.window, bounds: current.bounds, system: system)
        }
        func verify(requireScreenshot: Bool, requireWindow: Bool) throws {
            let current = Self.context(system: system)
            try ComputerHostObservationGate.validate(
                expected: identity,
                current: ComputerHostObservationIdentity(
                    foreground: current.pid, topology: try Self.topology(system: system), screenshot: false),
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
