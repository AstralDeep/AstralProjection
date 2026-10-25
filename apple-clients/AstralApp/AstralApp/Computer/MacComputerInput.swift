// Injects bounded marked native input and detects human takeover for the computer host.
// The driver rechecks current authority, focused identity and secure-field status before keyboard effects.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import Foundation

    actor MacComputerInput {
        let marker: Int64
        private let system: any MacComputerSystemReading
        private let events: any MacComputerEventIO
        init(
            marker: Int64, system: any MacComputerSystemReading = MacComputerLiveSystem.shared,
            events: any MacComputerEventIO = MacComputerLiveEvents()
        ) {
            self.marker = marker
            self.system = system
            self.events = events
        }
        private nonisolated func post(_ event: CGEvent?) throws {
            guard let event else { throw ComputerHostError("failed", "The input event could not be created.") }
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            events.post(event)
        }
        private nonisolated func keyboardAuthority(_ args: [String: JSONValue]) throws {
            guard system.accessibilityTrusted(), system.postEventAccess(), !system.secureInputEnabled() else {
                throw ComputerHostError("permission_denied", "Accessibility access or keyboard input is unavailable.")
            }
            let root = system.systemElement()
            guard let appValue = system.attribute(kAXFocusedApplicationAttribute, of: root),
                CFGetTypeID(appValue) == AXUIElementGetTypeID()
            else { throw ComputerHostError("permission_denied", "The focused application cannot be verified.") }
            let app = unsafeBitCast(appValue, to: AXUIElement.self)
            system.messagingTimeout(0.3, for: app)
            guard let pid = system.pid(of: app), let bundle = system.bundleIdentifier(for: pid)
            else { throw ComputerHostError("permission_denied", "The focused application identity is unknown.") }
            try ComputerHostTargetPolicy.externalProcess(pid, hostPID: system.hostPID)
            if let terminal = args["terminal_app"]?.stringValue {
                try ComputerTerminalPolicy.authorize(
                    terminal, bundle: bundle, granted: args["terminal_ok"] == .bool(true))
            }
            guard let focused = system.attribute(kAXFocusedUIElementAttribute, of: app),
                CFGetTypeID(focused) == AXUIElementGetTypeID()
            else { throw ComputerHostError("permission_denied", "The focused control cannot be verified.") }
            let element = unsafeBitCast(focused, to: AXUIElement.self)
            system.messagingTimeout(0.3, for: element)
            if (system.attribute(kAXSubroleAttribute, of: element) as? String) == kAXSecureTextFieldSubrole as String {
                throw ComputerHostError(
                    "permission_denied", "Astral cannot type into a secure field. Complete authentication yourself.")
            }
            if ComputerTerminalPolicy.requiresApproval(bundle), args["terminal_ok"] != .bool(true) {
                throw ComputerHostError(
                    "confirmation_required",
                    "Terminal-capable keyboard input requires a current approved terminal grant.")
            }
        }
        func type(_ text: String, args: [String: JSONValue], authorize: @Sendable () throws -> Void) async throws {
            try await ComputerHostInputSequence.type(
                text,
                authorize: {
                    try authorize()
                    try self.keyboardAuthority(args)
                    try authorize()
                },
                post: { chunk, down in
                    let event = self.events.keyboard(key: 0, down: down)
                    if down { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk) }
                    try self.post(event)
                })
        }
        func press(_ chord: ComputerHostChord, args: [String: JSONValue], authorize: @Sendable () throws -> Void) throws
        {
            let keys: [String: CGKeyCode] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
                "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
                "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "enter": 36, "l": 37, "j": 38,
                "k": 40, "n": 45, "m": 46, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "home": 115,
                "pageup": 116, "delete": 117, "end": 119, "pagedown": 121, "left": 123, "right": 124, "down": 125,
                "up": 126, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
                "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            ]
            guard let key = keys[chord.key] else { throw ComputerHostError("unsupported", "The key is unsupported.") }
            try authorize()
            try keyboardAuthority(args)
            try authorize()
            var flags: CGEventFlags = []
            if chord.modifiers.contains("cmd") { flags.insert(.maskCommand) }
            if chord.modifiers.contains("ctrl") { flags.insert(.maskControl) }
            if chord.modifiers.contains("alt") { flags.insert(.maskAlternate) }
            if chord.modifiers.contains("shift") { flags.insert(.maskShift) }
            let down = events.keyboard(key: key, down: true)
            down?.flags = flags
            try post(down)
            try post(events.keyboard(key: key, down: false))
        }
        nonisolated func mouse(_ kind: CGEventType, at point: CGPoint, button: CGMouseButton = .left, count: Int64 = 1)
            throws
        {
            let event = events.mouse(kind: kind, point: point, button: button)
            event?.setIntegerValueField(.mouseEventClickState, value: count)
            try post(event)
        }
        private nonisolated func release(button: CGMouseButton, count: Int64 = 1) throws {
            guard let current = events.cursor() else {
                throw ComputerHostError("interrupted", "The current cursor could not be read for safe button release.")
            }
            let kind: CGEventType =
                button == .right ? .rightMouseUp : (button == .center ? .otherMouseUp : .leftMouseUp)
            try mouse(kind, at: current, button: button, count: count)
        }
        private nonisolated func pointerAuthority(at point: CGPoint) throws {
            guard let rows = system.visibleWindows()
            else {
                throw ComputerHostError("permission_denied", "Visible computer controls cannot be verified.")
            }
            let windows = rows.compactMap { row -> ComputerHostTargetWindow? in
                guard (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                    let raw = row[kCGWindowBounds as String] as? [String: Any],
                    let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
                else { return nil }
                return ComputerHostTargetWindow(
                    pid: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, bounds: bounds)
            }
            try ComputerHostTargetPolicy.externalPoint(
                point, hostPID: system.hostPID, windows: windows)
        }
        func pointer(
            _ request: ComputerHostRequest, start: CGPoint, end: CGPoint?, authorize: @Sendable () throws -> Void
        ) async throws {
            try authorize()
            if request.verb == "move" {
                try pointerAuthority(at: start)
                try authorize()
                try mouse(.mouseMoved, at: start)
                return
            }
            if request.verb == "scroll" {
                try pointerAuthority(at: start)
                try authorize()
                try mouse(.mouseMoved, at: start)
                try authorize()
                try pointerAuthority(at: start)
                try authorize()
                let event = events.scroll(
                    dy: Int32(request.args["dy"]?.numberValue ?? -3),
                    dx: Int32(request.args["dx"]?.numberValue ?? 0))
                event?.location = start
                try post(event)
                return
            }
            if let end {
                try await ComputerHostInputSequence.drag(
                    from: start, to: end, authorize: authorize,
                    post: { step in
                        switch step {
                        case .down(let point):
                            try self.pointerAuthority(at: point)
                            try authorize()
                            try self.mouse(.leftMouseDown, at: point)
                        case .drag(let point):
                            try self.pointerAuthority(at: point)
                            try authorize()
                            try self.mouse(.leftMouseDragged, at: point)
                        case .release: try self.release(button: .left)
                        }
                    })
                return
            }
            let name = request.args["button"]?.stringValue ?? (request.verb == "right_click" ? "right" : "left")
            let button: CGMouseButton = name == "right" ? .right : (name == "middle" ? .center : .left)
            let down: CGEventType =
                button == .right ? .rightMouseDown : (button == .center ? .otherMouseDown : .leftMouseDown)
            let count = request.verb == "double_click" ? 2 : Int(request.args["count"]?.numberValue ?? 1)
            for index in 1...count {
                try authorize()
                try pointerAuthority(at: start)
                try authorize()
                try mouse(down, at: start, button: button, count: Int64(index))
                try release(button: button, count: Int64(index))
            }
        }
    }

    @MainActor
    protocol MacComputerMonitoring: AnyObject {
        var running: Bool { get }
        var controlsWindow: Int? { get set }
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool
        func stop()
    }

    @MainActor
    final class MacComputerInputMonitor: MacComputerMonitoring {
        private var global: Any?
        private var local: Any?
        let marker: Int64
        var controlsWindow: Int?
        private let monitors: any MacComputerEventMonitoring
        init(marker: Int64, monitors: any MacComputerEventMonitoring = MacComputerLiveEventMonitoring()) {
            self.marker = marker
            self.monitors = monitors
        }
        var running: Bool { global != nil && local != nil }
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
            if running { return true }
            let mask: NSEvent.EventTypeMask = [
                .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved,
                .leftMouseDragged, .rightMouseDragged, .scrollWheel,
            ]
            let marker = marker
            let monitors = monitors
            global = monitors.addGlobal(matching: mask) { event in
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != marker { humanInput() }
            }
            local = monitors.addLocal(matching: mask) { [weak self] event in
                if monitors.associatedWindowNumber(for: event) != self?.controlsWindow,
                    event.cgEvent?.getIntegerValueField(.eventSourceUserData) != marker
                {
                    humanInput()
                }
                return event
            }
            return running
        }
        func stop() {
            if let global { monitors.remove(global) }
            if let local { monitors.remove(local) }
            global = nil
            local = nil
        }
    }
#endif
