// Executes the existing computer verbs with public macOS capture, accessibility and application APIs.
// OS work stays on this actor while a separate synchronous authority gate can revoke every pending effect.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import Foundation
    import ScreenCaptureKit

    protocol MacComputerDriving: Actor {
        func execute(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue]
        func reset() async
    }

    private nonisolated final class MacComputerTarget: @unchecked Sendable {
        let window: AXUIElement
        let bounds: CGRect
        let pid: pid_t
        init(window: AXUIElement, bounds: CGRect, pid: pid_t) {
            self.window = window
            self.bounds = bounds
            self.pid = pid
        }
        func verify() throws {
            try ComputerHostTargetPolicy.externalProcess(pid, hostPID: ProcessInfo.processInfo.processIdentifier)
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                let focused, CFEqual(focused, window)
            else { throw ComputerHostError("stale_target", "The reviewed target window is no longer focused.") }
            let system = AXUIElementCreateSystemWide()
            var front: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &front) == .success,
                let front, CFGetTypeID(front) == AXUIElementGetTypeID()
            else { throw ComputerHostError("stale_target", "The foreground identity is unavailable.") }
            var actual: pid_t = 0
            guard AXUIElementGetPid(unsafeBitCast(front, to: AXUIElement.self), &actual) == .success, actual == pid
            else { throw ComputerHostError("stale_target", "The reviewed application is no longer in front.") }
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
                AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                let positionValue, let sizeValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
                CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else { throw ComputerHostError("stale_target", "The reviewed window geometry is unavailable.") }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
                AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size),
                CGRect(origin: point, size: size) == bounds
            else { throw ComputerHostError("stale_target", "The reviewed window moved or resized. Observe it again.") }
        }
    }

    actor MacComputerDriver: MacComputerDriving {
        private struct Geometry {
            let display: CGDirectDisplayID
            let bounds: CGRect
            let width: Int
            let height: Int
            let topology: String
            var foreground: pid_t?
        }
        private let input: MacComputerInput
        private var geometry: Geometry?
        private var windows: [Int: AXUIElement] = [:]
        private var observedBounds: [Int: CGRect] = [:]
        private var lastObservation: MacComputerObservation?
        private var observationStale = false
        private var nextWindow = 1
        init(marker: Int64) { input = MacComputerInput(marker: marker) }
        func reset() {
            geometry = nil
            windows = [:]
            observedBounds = [:]
            lastObservation = nil
            observationStale = false
        }
        private func foreground() -> pid_t? {
            let system = AXUIElementCreateSystemWide()
            var value: CFTypeRef?
            AXUIElementSetMessagingTimeout(system, 0.3)
            guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            var pid: pid_t = 0
            guard AXUIElementGetPid(unsafeBitCast(value, to: AXUIElement.self), &pid) == .success else { return nil }
            return pid
        }
        private func displays() throws -> [CGDirectDisplayID] {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, (1...8).contains(count) else {
                throw ComputerHostError("screen_locked", "The display is unavailable.")
            }
            var values = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &values, &count) == .success else {
                throw ComputerHostError("failed", "Cannot enumerate displays.")
            }
            return values.sorted { a, b in a == CGMainDisplayID() || (b != CGMainDisplayID() && a < b) }
        }
        private func topology() throws -> String { try MacComputerObservation.topology() }
        private func point(
            _ args: [String: JSONValue], _ x: String = "x", _ y: String = "y", checkForeground: Bool = true
        ) throws -> CGPoint {
            guard !observationStale else {
                throw ComputerHostError(
                    "stale_target", "Application focus changed. Take a new screenshot before pointer input.")
            }
            guard let px = args[x]?.numberValue, let py = args[y]?.numberValue else {
                throw ComputerHostError("out_of_range", "Missing pointer coordinates.")
            }
            if let geometry {
                guard geometry.foreground != nil else {
                    throw ComputerHostError("stale_target", "The screenshot has no known foreground identity.")
                }
                guard try topology() == geometry.topology, CGDisplayBounds(geometry.display) == geometry.bounds else {
                    throw ComputerHostError("stale_target", "Display geometry changed. Take a fresh screenshot.")
                }
                guard !checkForeground || foreground() == geometry.foreground else {
                    throw ComputerHostError(
                        "stale_target", "The foreground application changed. Take a fresh screenshot.")
                }
                guard px < Double(geometry.width), py < Double(geometry.height) else {
                    throw ComputerHostError("out_of_range", "The pointer is outside the observed display.")
                }
                return CGPoint(
                    x: geometry.bounds.minX + px * geometry.bounds.width / Double(geometry.width),
                    y: geometry.bounds.minY + py * geometry.bounds.height / Double(geometry.height))
            }
            throw ComputerHostError("stale_target", "Take a current screenshot before pointer input.")
        }
        private func screenshot(_ request: ComputerHostRequest, authorize: @Sendable () throws -> Void) async throws
            -> [String: JSONValue]
        {
            try authorize()
            guard CGPreflightScreenCaptureAccess() else {
                throw ComputerHostError("permission_denied", "Allow Screen Recording in System Settings.")
            }
            let ids = try displays()
            let index = Int(request.args["screen_index"]?.numberValue ?? 0)
            guard ids.indices.contains(index) else {
                throw ComputerHostError("out_of_range", "The display is unavailable.")
            }
            let before = try topology()
            let observation = try MacComputerObservation.capture(screenshot: true)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == ids[index] }) else {
                throw ComputerHostError("screen_locked", "The display cannot be captured.")
            }
            let excluded = await MainActor.run {
                Set(
                    NSApplication.shared.windows.filter { $0.title == "Astral computer session" }.map {
                        CGWindowID($0.windowNumber)
                    })
            }
            let filter = SCContentFilter(
                display: display, excludingWindows: content.windows.filter { excluded.contains($0.windowID) })
            let config = SCStreamConfiguration()
            let maximum = Int(request.args["max_width"]?.numberValue ?? 1280)
            config.width = min(maximum, display.width)
            config.height = max(1, Int(Double(display.height) * Double(config.width) / Double(display.width)))
            config.showsCursor = true
            config.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try authorize()
            guard before == (try topology()), CGPreflightScreenCaptureAccess() else {
                throw ComputerHostError("stale_target", "Capture authority or geometry changed.")
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]),
                jpeg.count <= 2_900_000
            else { throw ComputerHostError("out_of_range", "The screenshot exceeds the transport bound.") }
            var knownForeground: pid_t?
            do {
                try observation.verify(requireScreenshot: false, requireWindow: false)
                lastObservation = observation
                knownForeground = observation.identity.foreground
            } catch {
                lastObservation = nil
                knownForeground = nil
            }
            geometry = Geometry(
                display: display.displayID, bounds: CGDisplayBounds(display.displayID), width: image.width,
                height: image.height, topology: before, foreground: knownForeground)
            observationStale = false
            observedBounds = windows.compactMapValues { rect($0) }
            return [
                "base64": .string(jpeg.base64EncodedString()), "media_type": .string("image/jpeg"),
                "width": .number(Double(image.width)), "height": .number(Double(image.height)),
                "scale": .number(Double(CGDisplayPixelsWide(display.displayID)) / Double(image.width)),
                "screen_index": .number(Double(index)),
            ]
        }
        private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        private func rect(_ window: AXUIElement) -> CGRect? {
            guard let position = attribute(window, kAXPositionAttribute),
                let size = attribute(window, kAXSizeAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            var p = CGPoint.zero
            var s = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &p),
                AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &s)
            else { return nil }
            return CGRect(origin: p, size: s)
        }
        private func listWindows(authorize: @Sendable () throws -> Void) async throws -> [String: JSONValue] {
            let pids = await MainActor.run {
                NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(
                    \.processIdentifier)
            }
            windows = [:]
            observedBounds = [:]
            var rows: [JSONValue] = []
            for pid in pids where rows.count < 100 {
                try authorize()
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                guard let values = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                for window in values where rows.count < 100 {
                    try authorize()
                    AXUIElementSetMessagingTimeout(window, 0.2)
                    guard let bounds = rect(window), let title = attribute(window, kAXTitleAttribute) as? String,
                        title != "Astral computer session"
                    else { continue }
                    guard nextWindow < Int(Int32.max) else {
                        throw ComputerHostError("capacity_exceeded", "Window identity capacity is exhausted.")
                    }
                    let id = nextWindow
                    nextWindow += 1
                    windows[id] = window
                    observedBounds[id] = bounds
                    let name = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
                    rows.append(
                        .object([
                            "hwnd": .number(Double(id)), "title": .string(String(title.prefix(200))),
                            "process": .string(String(name.prefix(80))), "bundle_id": .string(String(name.prefix(160))),
                            "rect": .array(
                                [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].map { .number(Double($0)) }),
                            "focused": .bool((attribute(window, kAXFocusedAttribute) as? Bool) == true),
                            "minimized": .bool((attribute(window, kAXMinimizedAttribute) as? Bool) == true),
                        ]))
                }
            }
            if let previous = lastObservation {
                do { try previous.verify(requireScreenshot: false, requireWindow: false) } catch {
                    lastObservation = try? MacComputerObservation.capture(screenshot: false)
                }
            } else {
                lastObservation = try? MacComputerObservation.capture(screenshot: false)
            }
            return ["windows": .array(rows)]
        }
        private func focus(
            _ request: ComputerHostRequest, reviewedInput: Bool = false, authorize: @Sendable () throws -> Void
        ) async throws
            -> [String: JSONValue]
        {
            if windows.isEmpty { _ = try await listWindows(authorize: authorize) }
            let id: Int
            if let raw = request.args["hwnd"]?.numberValue {
                id = Int(raw)
            } else {
                let title = request.args["title"]!.stringValue!.lowercased()
                let matches = windows.filter {
                    (attribute($0.value, kAXTitleAttribute) as? String)?.lowercased().contains(title) == true
                }
                guard matches.count == 1, let match = matches.first else {
                    throw ComputerHostError(
                        "window_not_found", "The window title is missing or ambiguous. List windows again.")
                }
                id = match.key
            }
            guard let window = windows[id], let title = attribute(window, kAXTitleAttribute) as? String else {
                throw ComputerHostError("window_not_found", "The window is stale. List windows again.")
            }
            var pid: pid_t = 0
            guard AXUIElementGetPid(window, &pid) == .success else {
                throw ComputerHostError("window_not_found", "The window is unavailable.")
            }
            try ComputerHostTargetPolicy.externalProcess(pid, hostPID: ProcessInfo.processInfo.processIdentifier)
            try authorize()
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            let processID = pid
            let activated = try await MainActor.run {
                try authorize()
                return NSRunningApplication(processIdentifier: processID)?.activate(options: [.activateAllWindows])
                    ?? false
            }
            try authorize()
            guard activated, AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
                throw ComputerHostError("failed", "The window could not be focused.")
            }
            if !reviewedInput || geometry?.foreground != pid { observationStale = true }
            lastObservation = try? MacComputerObservation.capture(screenshot: false)
            return ["hwnd": .number(Double(id)), "title": .string(String(title.prefix(200)))]
        }
        func execute(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            let baseCheck: @Sendable () throws -> Void = {
                try authorize()
                try Task.checkCancellation()
                guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess(),
                    CGPreflightListenEventAccess(), MacComputerDesktopProbe.usable()
                else {
                    throw ComputerHostError("permission_denied", "Computer permissions changed. Review local access.")
                }
                try authorize()
            }
            try baseCheck()
            var target: MacComputerTarget?
            if request.verb != "focus_window", let raw = request.args["hwnd"]?.numberValue {
                guard let window = windows[Int(raw)], let bounds = observedBounds[Int(raw)], rect(window) == bounds
                else {
                    throw ComputerHostError(
                        "stale_target", "The reviewed window identity or geometry changed. List windows again.")
                }
                var pid: pid_t = 0
                guard AXUIElementGetPid(window, &pid) == .success else {
                    throw ComputerHostError("window_not_found", "The reviewed window is unavailable.")
                }
                if ["type_text", "press_keys"].contains(request.verb) {
                    guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
                        throw ComputerHostError(
                            "permission_denied", "The reviewed application's identity is unavailable.")
                    }
                    if let terminal = request.args["terminal_app"]?.stringValue {
                        try ComputerTerminalPolicy.authorize(
                            terminal, bundle: bundle, granted: request.args["terminal_ok"] == .bool(true))
                    } else if ComputerTerminalPolicy.requiresApproval(bundle),
                        request.args["terminal_ok"] != .bool(true)
                    {
                        throw ComputerHostError(
                            "confirmation_required", "The reviewed terminal input has no current grant.")
                    }
                } else {
                    let start = try point(
                        request.args, request.verb == "drag" ? "x1" : "x", request.verb == "drag" ? "y1" : "y",
                        checkForeground: false)
                    let end = request.verb == "drag" ? try point(request.args, "x2", "y2", checkForeground: false) : nil
                    try ComputerHostGeometry.validate(start, end: end, within: bounds)
                }
                _ = try await focus(request, reviewedInput: true, authorize: baseCheck)
                let verified = MacComputerTarget(window: window, bounds: bounds, pid: pid)
                for attempt in 0..<10 {
                    try baseCheck()
                    do {
                        try verified.verify()
                        break
                    } catch {
                        if attempt == 9 { throw error }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
                target = verified
            }
            let boundTarget = target
            let pointer = ["click", "double_click", "right_click", "move", "drag", "scroll"].contains(request.verb)
            let keyboard = ["type_text", "press_keys"].contains(request.verb)
            let observation: MacComputerObservation?
            if pointer, let target, let geometry, geometry.foreground != nil {
                observation = MacComputerObservation(
                    identity: ComputerHostObservationIdentity(
                        foreground: target.pid, topology: geometry.topology, screenshot: true), window: target.window,
                    bounds: target.bounds)
            } else {
                observation = lastObservation
            }
            let check: @Sendable () throws -> Void = {
                try baseCheck()
                if pointer || keyboard {
                    try ComputerHostTargetPolicy.externalProcess(
                        MacComputerObservation.context().pid, hostPID: ProcessInfo.processInfo.processIdentifier)
                }
                try boundTarget?.verify()
                if pointer || (keyboard && boundTarget == nil) {
                    guard let observation else {
                        throw ComputerHostError("stale_target", "Observe the target before input.")
                    }
                    try observation.verify(requireScreenshot: pointer, requireWindow: keyboard)
                }
            }
            try check()
            switch request.verb {
            case "screenshot": return try await screenshot(request, authorize: check)
            case "list_windows": return try await listWindows(authorize: check)
            case "focus_window": return try await focus(request, authorize: check)
            case "wait":
                let seconds = request.args["seconds"]?.numberValue ?? 1
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                try check()
                return ["waited": .number(seconds)]
            case "get_clipboard":
                return try await MainActor.run {
                    try check()
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    return [
                        "text": .string(String(text.unicodeScalars.prefix(16384))),
                        "truncated": .bool(text.unicodeScalars.count > 16384),
                    ]
                }
            case "set_clipboard":
                return try await MainActor.run {
                    try check()
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(request.args["text"]!.stringValue!, forType: .string) else {
                        throw ComputerHostError("failed", "The clipboard write failed.")
                    }
                    return [:]
                }
            case "read_file", "list_dir", "write_file", "delete_path":
                let path = request.args["path"]!.stringValue!
                guard
                    let root = workspaces.sorted(by: { $0.root.count > $1.root.count }).first(where: {
                        path == $0.root || path.hasPrefix($0.root + "/")
                    })
                else {
                    throw ComputerHostError(
                        "permission_denied", "Choose this workspace folder in local computer controls first.")
                }
                if request.verb == "read_file" {
                    return try root.read(path, maximum: Int(request.args["max_bytes"]?.numberValue ?? 65536))
                }
                if request.verb == "list_dir" { return try root.list(path) }
                if request.verb == "write_file" {
                    let text = request.args["content"]!.stringValue!
                    try root.write(
                        path, content: text, overwrite: request.args["if_exists"] == .string("overwrite"),
                        authorize: check)
                    return ["path": .string(path), "bytes": .number(Double(text.utf8.count))]
                }
                try root.delete(path, authorize: check)
                return ["path": .string(path), "deleted": .bool(true)]
            case "open_app":
                let name = request.args["app"]!.stringValue!
                let aliases = [
                    "terminal": "com.apple.Terminal", "safari": "com.apple.Safari", "chrome": "com.google.Chrome",
                    "google chrome": "com.google.Chrome", "textedit": "com.apple.TextEdit",
                    "finder": "com.apple.finder",
                ]
                let bundleId = ComputerTerminalPolicy.launchBundle(name) ?? aliases[name.lowercased()] ?? name
                let resolved: URL?
                if name.hasPrefix("/") {
                    resolved = URL(fileURLWithPath: name)
                } else {
                    resolved = await MainActor.run {
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
                    }
                }
                let candidates =
                    resolved.map { [$0] }
                    ?? [
                        "/Applications", "/System/Applications",
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
                    ].map {
                        URL(fileURLWithPath: $0).appendingPathComponent(
                            name.lowercased().hasSuffix(".app") ? name : name + ".app")
                    }
                guard
                    let url = candidates.first(where: {
                        $0.pathExtension.lowercased() == "app"
                            && Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
                    })
                else { throw ComputerHostError("not_found", "The application bundle could not be found.") }
                try ComputerTerminalPolicy.validateLaunch(name, bundle: Bundle(url: url)?.bundleIdentifier)
                guard Bundle(url: url)?.bundleIdentifier != Bundle.main.bundleIdentifier else {
                    throw ComputerHostError("permission_denied", "Computer tools cannot launch Astral's own controls.")
                }
                try check()
                let launched: (pid_t, String?) = try await withCheckedThrowingContinuation { continuation in
                    Task { @MainActor in
                        do {
                            try check()
                            let configuration = NSWorkspace.OpenConfiguration()
                            configuration.activates = true
                            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                                if let error {
                                    continuation.resume(throwing: error)
                                } else if let app {
                                    continuation.resume(returning: (app.processIdentifier, app.bundleIdentifier))
                                } else {
                                    continuation.resume(
                                        throwing: ComputerHostError("failed", "The application did not launch."))
                                }
                            }
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                try check()
                try ComputerTerminalPolicy.validateLaunch(name, bundle: launched.1)
                observationStale = true
                lastObservation = nil
                return [
                    "launched": .bool(true), "pid": .number(Double(launched.0)),
                    "bundle_id": launched.1.map(JSONValue.string) ?? .null, "app": .string(name),
                ]
            case "type_text":
                try await input.type(request.args["text"]!.stringValue!, args: request.args, authorize: check)
                return ["chars": .number(Double(request.args["text"]!.stringValue!.unicodeScalars.count))]
            case "press_keys":
                try await input.press(
                    ComputerHostChord(request.args["keys"]!.stringValue!), args: request.args, authorize: check)
                return ["keys": request.args["keys"]!]
            default:
                let start = try point(
                    request.args, request.verb == "drag" ? "x1" : "x", request.verb == "drag" ? "y1" : "y")
                let end = request.verb == "drag" ? try point(request.args, "x2", "y2") : nil
                if let boundTarget { try ComputerHostGeometry.validate(start, end: end, within: boundTarget.bounds) }
                try await input.pointer(request, start: start, end: end, authorize: check)
                if let geometry, geometry.foreground != foreground() { observationStale = true }
                return ["attempted": .bool(true)]
            }
        }
    }
#endif
