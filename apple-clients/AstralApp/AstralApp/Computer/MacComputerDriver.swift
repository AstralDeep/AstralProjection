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
        let system: any MacComputerSystemIO
        init(window: AXUIElement, bounds: CGRect, pid: pid_t, system: any MacComputerSystemIO) {
            self.window = window
            self.bounds = bounds
            self.pid = pid
            self.system = system
        }
        func verify() throws {
            try ComputerHostTargetPolicy.externalProcess(pid, hostPID: system.hostPID)
            let current = MacComputerObservation.context(system: system)
            guard current.pid == pid, let actual = current.window, CFEqual(actual, window), current.bounds == bounds
            else {
                throw ComputerHostError("stale_target", "The reviewed window identity or geometry changed.")
            }
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
        private let system: any MacComputerSystemIO
        private var geometry: Geometry?
        private var windows: [Int: AXUIElement] = [:]
        private var observedBounds: [Int: CGRect] = [:]
        private var lastObservation: MacComputerObservation?
        private var observationStale = false
        private var nextWindow = 1
        init(
            marker: Int64, system: any MacComputerSystemIO = MacComputerLiveSystem.shared,
            input: MacComputerInput? = nil
        ) {
            self.system = system
            self.input = input ?? MacComputerInput(marker: marker, system: system)
        }
        func reset() {
            geometry = nil
            windows = [:]
            observedBounds = [:]
            lastObservation = nil
            observationStale = false
        }
        private func foreground() -> pid_t? { MacComputerObservation.context(system: system).pid }
        private func displays() throws -> [CGDirectDisplayID] {
            try MacComputerObservation.displayIDs(system: system)
        }
        private func topology() throws -> String { try MacComputerObservation.topology(system: system) }
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
                guard try topology() == geometry.topology, system.displayBounds(geometry.display) == geometry.bounds
                else {
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
            guard system.screenCaptureAccess() else {
                throw ComputerHostError("permission_denied", "Allow Screen Recording in System Settings.")
            }
            let ids = try displays()
            let index = Int(request.args["screen_index"]?.numberValue ?? 0)
            guard ids.indices.contains(index) else {
                throw ComputerHostError("out_of_range", "The display is unavailable.")
            }
            let before = try topology()
            let observation = try MacComputerObservation.capture(screenshot: true, system: system)
            let content = try await system.shareableContent()
            guard let display = content.displays.first(where: { $0.id == ids[index] }) else {
                throw ComputerHostError("screen_locked", "The display cannot be captured.")
            }
            guard display.width > 0, display.height > 0 else {
                throw ComputerHostError("out_of_range", "The display dimensions are invalid.")
            }
            let excluded = await system.controlsWindows()
            let maximum = Int(request.args["max_width"]?.numberValue ?? 1280)
            let width = min(maximum, display.width)
            let height = max(1, Int(Double(display.height) * Double(width) / Double(display.width)))
            try authorize()
            let image = try await content.capture(
                MacComputerCapturePlan(
                    display: display.id, excludedWindows: Set(content.windows.filter { excluded.contains($0) }),
                    width: width, height: height))
            try authorize()
            guard before == (try topology()), system.screenCaptureAccess() else {
                throw ComputerHostError("stale_target", "Capture authority or geometry changed.")
            }
            guard let jpeg = system.jpeg(image), !jpeg.isEmpty, jpeg.count <= 2_900_000
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
                display: display.id, bounds: system.displayBounds(display.id), width: image.width,
                height: image.height, topology: before, foreground: knownForeground)
            observationStale = false
            observedBounds = windows.compactMapValues { rect($0) }
            return [
                "base64": .string(jpeg.base64EncodedString()), "media_type": .string("image/jpeg"),
                "width": .number(Double(image.width)), "height": .number(Double(image.height)),
                "scale": .number(Double(system.displayPixels(display.id).width) / Double(image.width)),
                "screen_index": .number(Double(index)),
            ]
        }
        private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            system.attribute(name, of: element)
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
            let pids = await system.runningApplications().filter(\.regular).map(\.pid)
            windows = [:]
            observedBounds = [:]
            var rows: [JSONValue] = []
            for pid in pids where rows.count < 100 {
                try authorize()
                let app = system.applicationElement(pid)
                system.messagingTimeout(0.2, for: app)
                guard let values = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                for window in values where rows.count < 100 {
                    try authorize()
                    system.messagingTimeout(0.2, for: window)
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
                    let name = system.bundleIdentifier(for: pid) ?? "unknown"
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
                    lastObservation = try? MacComputerObservation.capture(screenshot: false, system: system)
                }
            } else {
                lastObservation = try? MacComputerObservation.capture(screenshot: false, system: system)
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
            guard let pid = system.pid(of: window) else {
                throw ComputerHostError("window_not_found", "The window is unavailable.")
            }
            try ComputerHostTargetPolicy.externalProcess(pid, hostPID: system.hostPID)
            try authorize()
            _ = system.setAttribute(kAXMinimizedAttribute, of: window, to: kCFBooleanFalse)
            let os = system
            let activated = try await MainActor.run {
                try authorize()
                return os.activate(pid)
            }
            try authorize()
            guard activated, system.perform(kAXRaiseAction, on: window) == .success else {
                throw ComputerHostError("failed", "The window could not be focused.")
            }
            if !reviewedInput || geometry?.foreground != pid { observationStale = true }
            lastObservation = try? MacComputerObservation.capture(screenshot: false, system: system)
            return ["hwnd": .number(Double(id)), "title": .string(String(title.prefix(200)))]
        }
        func execute(
            _ request: ComputerHostRequest, workspaces: [ComputerWorkspace],
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            let system = system
            let baseCheck: @Sendable () throws -> Void = {
                try authorize()
                try Task.checkCancellation()
                guard system.accessibilityTrusted(), system.postEventAccess(), system.screenCaptureAccess(),
                    system.listenEventAccess(), MacComputerDesktopProbe.usable(system: system)
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
                guard let pid = system.pid(of: window) else {
                    throw ComputerHostError("window_not_found", "The reviewed window is unavailable.")
                }
                if ["type_text", "press_keys"].contains(request.verb) {
                    guard let bundle = system.bundleIdentifier(for: pid) else {
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
                let verified = MacComputerTarget(window: window, bounds: bounds, pid: pid, system: system)
                for attempt in 0..<10 {
                    try baseCheck()
                    do {
                        try verified.verify()
                        break
                    } catch {
                        if attempt == 9 { throw error }
                        try await system.delay(nanoseconds: 20_000_000)
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
                    bounds: target.bounds, system: system)
            } else {
                observation = lastObservation
            }
            let check: @Sendable () throws -> Void = {
                try baseCheck()
                if pointer || keyboard {
                    try ComputerHostTargetPolicy.externalProcess(
                        MacComputerObservation.context(system: system).pid, hostPID: system.hostPID)
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
                try await system.delay(nanoseconds: UInt64(seconds * 1_000_000_000))
                try check()
                return ["waited": .number(seconds)]
            case "get_clipboard":
                return try await MainActor.run {
                    try check()
                    let text = system.clipboardText() ?? ""
                    return [
                        "text": .string(String(text.unicodeScalars.prefix(16384))),
                        "truncated": .bool(text.unicodeScalars.count > 16384),
                    ]
                }
            case "set_clipboard":
                return try await MainActor.run {
                    try check()
                    system.clearClipboard()
                    try check()
                    guard system.setClipboard(request.args["text"]!.stringValue!) else {
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
                        system.applicationURL(bundleIdentifier: bundleId)
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
                guard Bundle(url: url)?.bundleIdentifier != system.hostBundleIdentifier else {
                    throw ComputerHostError("permission_denied", "Computer tools cannot launch Astral's own controls.")
                }
                try check()
                let launched: MacComputerApplication = try await withCheckedThrowingContinuation { continuation in
                    Task { @MainActor in
                        do {
                            try check()
                            continuation.resume(returning: try await system.openApplication(at: url))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                try check()
                try ComputerTerminalPolicy.validateLaunch(name, bundle: launched.bundleIdentifier)
                observationStale = true
                lastObservation = nil
                return [
                    "launched": .bool(true), "pid": .number(Double(launched.pid)),
                    "bundle_id": launched.bundleIdentifier.map(JSONValue.string) ?? .null, "app": .string(name),
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
