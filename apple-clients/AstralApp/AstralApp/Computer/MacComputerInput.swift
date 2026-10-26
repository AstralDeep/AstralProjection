// Injects bounded marked native input and detects human takeover outside Astral's own windows.
// The driver rechecks current authority, focused identity and secure-input status before keyboard effects.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import Foundation

    nonisolated enum MacComputerPanelIdentity {
        static let title = "Astral computer session"
    }

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
            guard system.accessibilityTrusted(), system.postEventAccess() else {
                throw ComputerHostError("permission_denied", "Accessibility access or keyboard input is unavailable.")
            }
            guard !system.secureInputEnabled() else {
                throw ComputerHostError(
                    "secure_input_active",
                    "Secure keyboard entry is active, so keyboard input is refused. Pointer actions still work.")
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
                    "secure_input_active",
                    "A password field is focused, so keyboard input is refused. Complete it yourself; pointer actions work."
                )
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
                "f9": 101, "f10": 109, "f11": 103, "f12": 111, "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41,
                "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50,
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
            let visible = rows.compactMap { row -> (window: ComputerHostTargetWindow, name: String?)? in
                guard (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                    let raw = row[kCGWindowBounds as String] as? [String: Any],
                    let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
                else { return nil }
                return (
                    ComputerHostTargetWindow(
                        pid: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, bounds: bounds),
                    row[kCGWindowName as String] as? String
                )
            }
            if let top = visible.first(where: { $0.window.bounds.contains(point) }), top.window.pid == system.hostPID,
                top.name == MacComputerPanelIdentity.title
            {
                throw ComputerHostError(
                    "obscured_by_astral_panel",
                    "Astral's session panel covers this point. Move the panel, take a new screenshot and retry.")
            }
            try ComputerHostTargetPolicy.externalPoint(
                point, hostPID: system.hostPID, windows: visible.map(\.window))
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
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool
        func stop()
    }

    @MainActor
    final class MacComputerInputMonitor: MacComputerMonitoring {
        static let movementThreshold: CGFloat = 24
        static let movementWindow: TimeInterval = 0.25
        static let frontmostDelay: TimeInterval = 0.3
        private var global: Any?
        let marker: Int64
        private let monitors: any MacComputerEventMonitoring
        private let frontmost: @MainActor () -> String?
        private let hostBundle: String?
        private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
        private var samples: [(time: TimeInterval, point: CGPoint)] = []
        private var pending = false
        private var generation = 0
        init(
            marker: Int64, monitors: any MacComputerEventMonitoring = MacComputerLiveEventMonitoring(),
            frontmost: @escaping @MainActor () -> String? = {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            },
            hostBundle: String? = Bundle.main.bundleIdentifier,
            schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, body in
                Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                    body()
                }
            }
        ) {
            self.marker = marker
            self.monitors = monitors
            self.frontmost = frontmost
            self.hostBundle = hostBundle
            self.schedule = schedule
        }
        var running: Bool { global != nil }
        func start(_ humanInput: @escaping @MainActor () -> Void) -> Bool {
            if running { return true }
            let mask: NSEvent.EventTypeMask = [
                .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
            ]
            generation += 1
            let current = generation
            global = monitors.addGlobal(matching: mask) { [weak self] event in
                self?.observe(event, generation: current, humanInput: humanInput)
            }
            return running
        }
        func stop() {
            if let global { monitors.remove(global) }
            global = nil
            generation += 1
            samples = []
            pending = false
        }
        private func observe(_ event: NSEvent, generation current: Int, humanInput: @escaping @MainActor () -> Void) {
            guard current == generation, event.cgEvent?.getIntegerValueField(.eventSourceUserData) != marker else {
                return
            }
            if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) {
                guard moved(event) else { return }
            }
            guard !pending else { return }
            pending = true
            schedule(Self.frontmostDelay) { [weak self] in
                guard let self, self.generation == current else { return }
                self.pending = false
                if let host = self.hostBundle, self.frontmost() == host { return }
                humanInput()
            }
        }
        private func moved(_ event: NSEvent) -> Bool {
            let now = monitors.uptime
            let point = event.cgEvent?.location ?? event.locationInWindow
            guard now.isFinite else {
                samples = []
                return true
            }
            samples.removeAll { now < $0.time || now - $0.time > Self.movementWindow }
            let crossed = samples.contains {
                hypot($0.point.x - point.x, $0.point.y - point.y) > Self.movementThreshold
            }
            if crossed {
                samples = []
                return true
            }
            samples.append((now, point))
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
            return false
        }
    }
#endif
