// Executes the desktop computer verbs with public macOS capture, accessibility and application APIs.
// OS work stays on this actor; input results carry a settled screenshot and a synchronous gate revokes effects.
// Accessibility snapshots come from MacComputerAccessibility and agent cues go to the host's overlay presenter.

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

    private nonisolated final class MacComputerAXGuard: @unchecked Sendable {
        let element: AXUIElement
        let role: String
        let frame: CGRect
        let pid: pid_t
        let ref: String
        let system: any MacComputerSystemIO
        init(_ target: MacComputerAXTarget, system: any MacComputerSystemIO) {
            element = target.element
            role = target.entry.role
            frame = target.frame
            pid = target.pid
            ref = target.ref
            self.system = system
        }
        func verify(at point: CGPoint) throws {
            system.messagingTimeout(0.25, for: element)
            let values = system.attributes([kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute], of: element)
            guard system.pid(of: element) == pid, values[kAXRoleAttribute] as? String == role,
                MacComputerAccessibility.frame(values) == frame
            else {
                throw ComputerHostError("stale_ref", "\(ref) moved or changed. Take a new ax_tree or ax_find.")
            }
            let rows = system.visibleWindows() ?? []
            for row in rows {
                guard (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                    let raw = row[kCGWindowBounds as String] as? [String: Any],
                    let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.contains(point)
                else { continue }
                let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                let name = row[kCGWindowName as String] as? String
                if owner == system.hostPID, name == MacComputerOverlayIdentity.title { continue }
                let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
                if owner == pid || owner == system.hostPID || layer != 0 { return }
                throw ComputerHostError(
                    "stale_target", "Another application's window covers \(ref). Call focus_window, then retry.")
            }
        }
    }

    actor MacComputerDriver: MacComputerDriving {
        static let inputVerbs: Set<String> = [
            "click", "double_click", "right_click", "move", "drag", "scroll", "type_text", "press_keys", "focus_window",
            "open_app", "ax_action", "menu",
        ]
        static let pointerVerbs: Set<String> = ["click", "double_click", "right_click", "move", "drag"]
        static let windowObservations: Set<String> = ["focus_window", "ax_tree", "ax_find", "zoom"]
        static let settleNanoseconds: UInt64 = 250_000_000
        static let glideNanoseconds: UInt64 = 150_000_000
        private struct Geometry {
            let display: CGDirectDisplayID
            let bounds: CGRect
            let width: Int
            let height: Int
            let topology: String
            var foreground: pid_t?
        }
        private struct Scope {
            let pid: pid_t
            let bundle: String
            let app: String
            let window: AXUIElement
            let hwnd: Int
            let title: String
            let frame: CGRect?
        }
        private let input: MacComputerInput
        private let system: any MacComputerSystemIO
        private let accessibility: MacComputerAccessibility
        private let overlay: (@Sendable (MacComputerOverlayCue) async -> Void)?
        private let bypass: @Sendable () async -> Bool
        private var cuedApp: String?
        private var geometry: Geometry?
        private var windows: [Int: AXUIElement] = [:]
        private var observedBounds: [Int: CGRect] = [:]
        private var lastObservation: MacComputerObservation?
        private var observationStale = false
        private var nextWindow = 1
        init(
            marker: Int64, system: any MacComputerSystemIO = MacComputerLiveSystem.shared,
            input: MacComputerInput? = nil, overlay: (@Sendable (MacComputerOverlayCue) async -> Void)? = nil,
            bypass: @escaping @Sendable () async -> Bool = { false }
        ) {
            self.system = system
            self.input = input ?? MacComputerInput(marker: marker, system: system)
            accessibility = MacComputerAccessibility(system: system)
            self.overlay = overlay
            self.bypass = bypass
        }
        func reset() {
            geometry = nil
            windows = [:]
            observedBounds = [:]
            lastObservation = nil
            observationStale = false
            cuedApp = nil
            accessibility.reset()
        }
        private func foreground() -> pid_t? { MacComputerObservation.context(system: system).pid }
        private func displays() throws -> [CGDirectDisplayID] {
            try MacComputerObservation.displayIDs(system: system)
        }
        private func topology() throws -> String { try MacComputerObservation.topology(system: system) }
        private func observed(checkForeground: Bool) throws -> Geometry {
            guard !observationStale else {
                throw ComputerHostError(
                    "stale_target", "Application focus changed. Take a new screenshot before pointer input.")
            }
            guard let geometry else {
                throw ComputerHostError("stale_target", "Take a current screenshot before pointer input.")
            }
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
            return geometry
        }
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
            let geometry = try observed(checkForeground: checkForeground)
            guard px < Double(geometry.width), py < Double(geometry.height) else {
                throw ComputerHostError("out_of_range", "The pointer is outside the observed display.")
            }
            return CGPoint(
                x: geometry.bounds.minX + px * geometry.bounds.width / Double(geometry.width),
                y: geometry.bounds.minY + py * geometry.bounds.height / Double(geometry.height))
        }
        private func point(of element: MacComputerAXTarget, checkForeground: Bool) throws -> CGPoint {
            let geometry = try observed(checkForeground: checkForeground)
            guard geometry.bounds.contains(element.center) else {
                throw ComputerHostError(
                    "out_of_range", "\(element.ref) is outside the observed display. Take a screenshot of its screen.")
            }
            guard !checkForeground || foreground() == element.pid else {
                throw ComputerHostError(
                    "stale_target",
                    "\(element.snapshot.app) is not the frontmost application. Call focus_window with hwnd "
                        + "\(element.snapshot.hwnd), then retry.")
            }
            return element.center
        }
        private func pointerTargets(
            _ request: ComputerHostRequest, element: MacComputerAXTarget?, end endElement: MacComputerAXTarget?,
            checkForeground: Bool
        ) throws -> (CGPoint, CGPoint?) {
            let drag = request.verb == "drag"
            if let element {
                let start = try point(of: element, checkForeground: checkForeground)
                guard drag else { return (start, nil) }
                if let endElement { return (start, try point(of: endElement, checkForeground: checkForeground)) }
                return (start, try point(request.args, "x2", "y2", checkForeground: checkForeground))
            }
            let start = try point(
                request.args, drag ? "x1" : "x", drag ? "y1" : "y", checkForeground: checkForeground)
            return (start, drag ? try point(request.args, "x2", "y2", checkForeground: checkForeground) : nil)
        }
        private func displayRects() throws -> [CGRect] { try displays().map { system.displayBounds($0) } }
        private func excluded(_ content: MacComputerCaptureSource) async -> Set<CGWindowID> {
            let controls = await system.controlsWindows()
            let overlays = await system.overlayWindows()
            return Set(content.windows.filter { controls.contains($0) || overlays.contains($0) })
        }
        private func cue(_ value: MacComputerOverlayCue) async {
            guard let overlay else { return }
            await overlay(value)
        }
        private func cueApp(_ pid: pid_t?) async {
            guard overlay != nil, let pid, pid != system.hostPID else { return }
            let app = system.applicationElement(pid)
            system.messagingTimeout(0.2, for: app)
            let name = (system.attribute(kAXTitleAttribute, of: app) as? String) ?? system.bundleIdentifier(for: pid)
            guard let name, name != cuedApp else { return }
            cuedApp = name
            await cue(.app(name))
        }
        private func glide(to point: CGPoint, label: String?) async throws {
            guard overlay != nil else { return }
            await cue(.point(point, label: label))
            try await system.delay(nanoseconds: Self.glideNanoseconds)
        }
        private func screenshot(index: Int, maximum: Int, authorize: @Sendable () throws -> Void) async throws
            -> [String: JSONValue]
        {
            try authorize()
            guard system.screenCaptureAccess() else {
                throw ComputerHostError("permission_denied", "Allow Screen Recording in System Settings.")
            }
            let ids = try displays()
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
            let excluded = await excluded(content)
            let width = min(maximum, display.width)
            let height = max(1, Int(Double(display.height) * Double(width) / Double(display.width)))
            try authorize()
            let image = try await content.capture(
                MacComputerCapturePlan(display: display.id, excludedWindows: excluded, width: width, height: height))
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
        private func settled(_ result: [String: JSONValue], authorize: @Sendable () throws -> Void) async
            -> [String: JSONValue]
        {
            var value = result
            do {
                try await system.delay(nanoseconds: Self.settleNanoseconds)
                let ids = try displays()
                let index = geometry.flatMap { ids.firstIndex(of: $0.display) } ?? 0
                value["screenshot"] = .object(try await screenshot(index: index, maximum: 1280, authorize: authorize))
            } catch {
                value["screenshot"] = nil
            }
            return value
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
                        title != MacComputerPanelIdentity.title, title != MacComputerOverlayIdentity.title
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
        private func bypassed(_ request: ComputerHostRequest) async -> Bool {
            request.approvalSource == "bypass" ? await bypass() : false
        }
        private func register(_ window: AXUIElement, bounds: CGRect?) throws -> Int {
            if let known = windows.first(where: { CFEqual($0.value, window) })?.key {
                if let bounds { observedBounds[known] = bounds }
                return known
            }
            guard nextWindow < Int(Int32.max) else {
                throw ComputerHostError("capacity_exceeded", "Window identity capacity is exhausted.")
            }
            let id = nextWindow
            nextWindow += 1
            windows[id] = window
            if let bounds { observedBounds[id] = bounds }
            return id
        }
        private func targetApp(_ args: [String: JSONValue]) throws -> pid_t {
            if let raw = args["pid"]?.numberValue {
                let pid = pid_t(raw)
                try ComputerHostTargetPolicy.externalProcess(pid, hostPID: system.hostPID)
                return pid
            }
            guard let pid = foreground() else {
                throw ComputerHostError("window_not_found", "No application is focused. Pass a pid from list_apps.")
            }
            guard pid != system.hostPID else {
                throw ComputerHostError(
                    "permission_denied",
                    "Astral is frontmost and its own windows are not inspectable. Pass the pid or hwnd of the target.")
            }
            return pid
        }
        private func identity(_ pid: pid_t) throws -> (bundle: String, app: String) {
            guard let bundle = system.bundleIdentifier(for: pid) else {
                throw ComputerHostError("permission_denied", "The application's identity is unavailable.")
            }
            let element = system.applicationElement(pid)
            system.messagingTimeout(0.2, for: element)
            let title = (attribute(element, kAXTitleAttribute) as? String).map(MacComputerAccessibility.clean) ?? ""
            return (bundle, String((title.isEmpty ? bundle : title).prefix(80)))
        }
        private func scope(_ args: [String: JSONValue]) throws -> Scope {
            let window: AXUIElement
            let pid: pid_t
            if let raw = args["hwnd"]?.numberValue {
                guard let known = windows[Int(raw)], let owner = system.pid(of: known) else {
                    throw ComputerHostError("window_not_found", "The window is stale. List windows again.")
                }
                if let requested = args["pid"]?.numberValue, pid_t(requested) != owner {
                    throw ComputerHostError("out_of_range", "The hwnd and pid name different applications.")
                }
                try ComputerHostTargetPolicy.externalProcess(owner, hostPID: system.hostPID)
                window = known
                pid = owner
            } else {
                pid = try targetApp(args)
                let app = system.applicationElement(pid)
                system.messagingTimeout(0.25, for: app)
                let listed = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
                guard
                    let found = MacComputerAccessibility.element(attribute(app, kAXFocusedWindowAttribute))
                        ?? MacComputerAccessibility.element(attribute(app, kAXMainWindowAttribute)) ?? listed.first
                else {
                    throw ComputerHostError(
                        "window_not_found", "The application has no accessible window. Use menu for its menu bar.")
                }
                window = found
            }
            let (bundle, app) = try identity(pid)
            system.messagingTimeout(0.25, for: window)
            let title = (attribute(window, kAXTitleAttribute) as? String) ?? ""
            guard title != MacComputerPanelIdentity.title, title != MacComputerOverlayIdentity.title else {
                throw ComputerHostError("permission_denied", "Computer input cannot operate Astral's own controls.")
            }
            let frame = rect(window)
            return Scope(
                pid: pid, bundle: bundle, app: app, window: window, hwnd: try register(window, bounds: frame),
                title: String(MacComputerAccessibility.clean(title).prefix(200)), frame: frame)
        }
        private func mapping(for frame: CGRect?, authorize: @Sendable () throws -> Void) async throws
            -> MacComputerAXMapping
        {
            let ids = try displays()
            let current = try topology()
            if geometry == nil || geometry?.topology != current
                || geometry.map({ system.displayBounds($0.display) != $0.bounds }) == true
            {
                let center = frame.map { CGPoint(x: $0.midX, y: $0.midY) }
                let index = center.flatMap { point in ids.firstIndex { system.displayBounds($0).contains(point) } } ?? 0
                _ = try await screenshot(index: index, maximum: 1280, authorize: authorize)
            }
            guard let geometry else {
                throw ComputerHostError("stale_target", "Take a screenshot before reading the accessibility tree.")
            }
            return mapping(geometry, ids: ids)
        }
        private func mapping(_ geometry: Geometry, ids: [CGDirectDisplayID]) -> MacComputerAXMapping {
            MacComputerAXMapping(
                bounds: geometry.bounds, width: geometry.width, height: geometry.height,
                screenIndex: ids.firstIndex(of: geometry.display) ?? 0)
        }
        private func header(_ scope: Scope, snapshot: String, mapping: MacComputerAXMapping, truncated: Bool)
            -> [String: JSONValue]
        {
            [
                "snapshot_id": .string(snapshot), "hwnd": .number(Double(scope.hwnd)),
                "pid": .number(Double(scope.pid)),
                "bundle_id": .string(scope.bundle), "app": .string(scope.app),
                "window": .object(["hwnd": .number(Double(scope.hwnd)), "title": .string(scope.title)]),
                "truncated": .bool(truncated), "screen_index": .number(Double(mapping.screenIndex)),
            ]
        }
        private static func text(_ value: String?, _ limit: Int = 200) -> JSONValue {
            value.map { .string(MacComputerAccessibility.bounded(MacComputerAccessibility.clean($0), limit)) } ?? .null
        }
        private func listApps(authorize: @Sendable () throws -> Void) async throws -> [String: JSONValue] {
            let apps = await system.runningApplications().filter { $0.regular && $0.pid != system.hostPID }
            var rows: [JSONValue] = []
            for app in apps.prefix(100) {
                try authorize()
                let element = system.applicationElement(app.pid)
                system.messagingTimeout(0.2, for: element)
                let count = (attribute(element, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
                rows.append(
                    .object([
                        "pid": .number(Double(app.pid)),
                        "name": Self.text(app.name ?? app.bundleIdentifier ?? "unknown", 80),
                        "bundle_id": app.bundleIdentifier.map { .string(String($0.prefix(160))) } ?? .null,
                        "active": .bool(app.active), "hidden": .bool(app.hidden),
                        "window_count": .number(Double(count)),
                    ]))
            }
            return ["apps": .array(rows)]
        }
        private func tree(_ args: [String: JSONValue], authorize: @Sendable () throws -> Void) async throws
            -> [String: JSONValue]
        {
            let scope = try scope(args)
            let mapping = try await mapping(for: scope.frame, authorize: authorize)
            try authorize()
            let mode: MacComputerAXMode = args["mode"]?.stringValue == "all" ? .all : .interactive
            let walked = accessibility.walk(
                scope.window, depth: Int(args["depth"]?.numberValue ?? 6),
                nodes: Int(args["max_nodes"]?.numberValue ?? 300)
            ) { node, parent, web in MacComputerAccessibility.wanted(node, parent: parent, web: web, mode: mode) }
            try authorize()
            let recorded = try accessibility.record(
                pid: scope.pid, bundle: scope.bundle, app: scope.app, hwnd: scope.hwnd, nodes: walked.nodes)
            var result = header(scope, snapshot: recorded.id, mapping: mapping, truncated: walked.truncated)
            result["lines"] = .array(
                zip(recorded.refs, walked.nodes).map { ref, node in
                    .string(MacComputerAccessibility.line(ref, node, mapping: mapping, window: scope.frame))
                })
            return result
        }
        private func find(_ args: [String: JSONValue], authorize: @Sendable () throws -> Void) async throws
            -> [String: JSONValue]
        {
            let scope = try scope(args)
            let mapping = try await mapping(for: scope.frame, authorize: authorize)
            try authorize()
            let query = MacComputerAccessibility.clean(args["query"]?.stringValue ?? "").lowercased()
            let role = args["role"]?.stringValue
            let walked = accessibility.walk(scope.window, depth: 10, nodes: Int(args["max"]?.numberValue ?? 20)) {
                node, _, _ in MacComputerAccessibility.matches(node, query: query, role: role)
            }
            try authorize()
            let recorded = try accessibility.record(
                pid: scope.pid, bundle: scope.bundle, app: scope.app, hwnd: scope.hwnd, nodes: walked.nodes)
            var result = header(scope, snapshot: recorded.id, mapping: mapping, truncated: walked.truncated)
            result["matches"] = .array(
                zip(recorded.refs, walked.nodes).map { ref, node in
                    let frame = mapping.rect(node.frame ?? .zero)
                    return .object([
                        "ref": .string(ref), "role": .string(node.name), "title": Self.text(node.label ?? ""),
                        "value": Self.text(MacComputerAccessibility.value(node)),
                        "frame": .object([
                            "x": .number(Double(frame[0])), "y": .number(Double(frame[1])),
                            "w": .number(Double(frame[2])), "h": .number(Double(frame[3])),
                        ]),
                        "enabled": .bool(node.enabled), "focused": .bool(node.focused),
                        "actions": .array(accessibility.actions(node).map(JSONValue.string)),
                    ])
                })
            return result
        }
        private func reviewed(
            _ request: ComputerHostRequest, line: String, key: String, once: Bool,
            permit matches: ([String: JSONValue]) -> Bool
        ) async throws -> Bool {
            if await bypassed(request) { return true }
            if once, accessibility.isConsumed(key) {
                throw ComputerHostError(
                    "stale_ref",
                    "That reviewed control was already used. Take a new ax_find or ax_tree to review it again.")
            }
            guard request.args["confirm_element"]?.stringValue == line,
                let permit = request.args["permit"]?.objectValue, matches(permit), accessibility.isIssued(key)
            else {
                accessibility.issue(key)
                return false
            }
            return accessibility.redeem(key, once: once)
        }
        private func action(
            _ request: ComputerHostRequest, authorize: @Sendable () throws -> Void, settle: @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            let args = request.args
            let ref = args["ref"]?.stringValue ?? ""
            let snapshot = args["snapshot_id"]?.stringValue ?? ""
            let verb = args["action"]?.stringValue ?? ""
            let value = args["value"]?.stringValue
            let target = try accessibility.resolve(ref, snapshot: snapshot, displays: try displayRects())
            if ["press", "set_value", "pick"].contains(verb),
                ComputerTerminalPolicy.canonical(target.snapshot.bundle) != nil
            {
                throw ComputerHostError("terminal_target", "Use run_command for terminal work.")
            }
            if verb == "set_value", accessibility.secure(target) {
                throw ComputerHostError(
                    "secure_input_active", "That is a password field, so Astral will not set it. Complete it yourself.")
            }
            let entered = ["set_value", "pick"].contains(verb) ? value : nil
            if ["press", "confirm", "pick", "set_value"].contains(verb),
                MacComputerAccessibility.consequential([target.entry.label, target.entry.name, entered])
            {
                let line = MacComputerAccessibility.reviewLine(target, value: entered)
                let hwnd = Double(target.snapshot.hwnd)
                let approved = try await reviewed(
                    request, line: line, key: "ax|\(snapshot)|\(ref)", once: true,
                    permit: { permit in
                        permit["ref"]?.stringValue == ref && permit["snapshot_id"]?.stringValue == snapshot
                            && (permit["hwnd"].map { $0.numberValue == hwnd } ?? true)
                    })
                guard approved else {
                    throw ComputerHostError("confirmation_required", "The user must review this control first: " + line)
                }
            }
            try authorize()
            await cueApp(target.pid)
            try await glide(to: target.center, label: target.label)
            try authorize()
            let element = target.element
            var result: [String: JSONValue] = [
                "performed": .bool(true), "action": .string(verb), "ref": .string(ref),
                "role": .string(target.entry.name), "title": Self.text(target.entry.label ?? ""),
            ]
            switch verb {
            case "focus":
                try MacComputerAccessibility.check(
                    system.setAttribute(kAXFocusedAttribute, of: element, to: kCFBooleanTrue), "focus")
            case "set_value":
                let text = value ?? ""
                let replacement: CFTypeRef
                if let current = system.attribute(kAXValueAttribute, of: element),
                    CFGetTypeID(current) == CFNumberGetTypeID()
                {
                    guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else {
                        throw ComputerHostError("out_of_range", "\(ref) takes a number.")
                    }
                    replacement = NSNumber(value: number)
                } else {
                    replacement = text as CFString
                }
                try MacComputerAccessibility.check(
                    system.setAttribute(kAXValueAttribute, of: element, to: replacement), "set_value")
            case "raise":
                guard
                    let window = target.entry.role == "AXWindow"
                        ? element : MacComputerAccessibility.element(attribute(element, kAXWindowAttribute))
                else { throw ComputerHostError("unsupported", "\(ref) has no window to raise.") }
                let os = system
                let pid = target.pid
                let activated = try await MainActor.run {
                    try authorize()
                    return os.activate(pid)
                }
                try authorize()
                guard activated else {
                    throw ComputerHostError("failed", "\(target.snapshot.app) could not be activated.")
                }
                try MacComputerAccessibility.check(system.perform(kAXRaiseAction, on: window), "raise")
                observationStale = true
            case "pick":
                result["picked"] = .string(try await pick(element, value: value ?? "", authorize: authorize))
            default:
                let names = [
                    "press": kAXPressAction, "show_menu": kAXShowMenuAction, "confirm": kAXConfirmAction,
                    "cancel": kAXCancelAction, "increment": kAXIncrementAction, "decrement": kAXDecrementAction,
                ]
                guard let name = names[verb] else { throw ComputerHostError("unsupported", "Unknown action.") }
                try MacComputerAccessibility.check(system.perform(name, on: element), verb)
            }
            await cue(.click(target.center))
            result["frontmost"] = .bool(foreground() == target.pid)
            return await settled(result, authorize: settle)
        }
        private func pick(_ element: AXUIElement, value: String, authorize: @Sendable () throws -> Void) async throws
            -> String
        {
            if system.perform(kAXPressAction, on: element) != .success {
                try MacComputerAccessibility.check(system.perform(kAXShowMenuAction, on: element), "pick")
            }
            var choice = accessibility.menuChoice(under: element, title: value)
            var attempts = 0
            while choice.item == nil, choice.titles.isEmpty, attempts < 10 {
                attempts += 1
                try await system.delay(nanoseconds: 50_000_000)
                try authorize()
                choice = accessibility.menuChoice(under: element, title: value)
            }
            guard let item = choice.item else {
                if let menu = choice.menu { _ = system.perform(kAXCancelAction, on: menu) }
                let titles = choice.titles.prefix(30).joined(separator: ", ")
                throw ComputerHostError(
                    "not_found",
                    titles.isEmpty ? "No menu opened for that element." : "No item matches. Items: \(titles)")
            }
            try authorize()
            try MacComputerAccessibility.check(system.perform(kAXPressAction, on: item), "pick")
            return MacComputerAccessibility.clean((attribute(item, kAXTitleAttribute) as? String) ?? value)
        }
        private func menu(
            _ request: ComputerHostRequest, authorize: @Sendable () throws -> Void, settle: @Sendable () throws -> Void
        ) async throws -> [String: JSONValue] {
            let args = request.args
            let path = args["path"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let pid = try targetApp(args)
            let (bundle, app) = try identity(pid)
            let element = system.applicationElement(pid)
            system.messagingTimeout(0.25, for: element)
            guard let bar = MacComputerAccessibility.element(attribute(element, kAXMenuBarAttribute)) else {
                throw ComputerHostError("not_found", "\(app) has no accessible menu bar.")
            }
            try authorize()
            var level = accessibility.menuItems(of: bar)
            var matched: [MacComputerAXMenuItem] = []
            for (index, title) in path.enumerated() {
                let wanted = MacComputerAccessibility.menuTitle(title)
                guard let item = level.first(where: { MacComputerAccessibility.menuTitle($0.title) == wanted }) else {
                    let place = matched.isEmpty ? "the menu bar" : matched.map(\.title).joined(separator: " › ")
                    let choices = level.prefix(40).map(\.title).joined(separator: ", ")
                    throw ComputerHostError("not_found", "No such item under \(place). Choices: \(choices)")
                }
                matched.append(item)
                if index < path.count - 1 {
                    guard let submenu = item.submenu else {
                        throw ComputerHostError("not_found", "\(item.title) has no submenu.")
                    }
                    level = accessibility.menuItems(of: submenu)
                }
            }
            guard let leaf = matched.last else { throw ComputerHostError("out_of_range", "Invalid menu path.") }
            let titles = matched.map(\.title)
            var result: [String: JSONValue] = [
                "app": .string(app), "pid": .number(Double(pid)), "bundle_id": .string(bundle),
                "path": .array(titles.map(JSONValue.string)),
            ]
            if args["list"]?.boolValue == true || leaf.submenu != nil {
                let items = leaf.submenu.map { accessibility.menuItems(of: $0) } ?? level
                result["items"] = .array(items.prefix(100).map(\.json))
                return result
            }
            if ComputerTerminalPolicy.canonical(bundle) != nil {
                throw ComputerHostError("terminal_target", "Use run_command for terminal work.")
            }
            guard leaf.enabled else {
                throw ComputerHostError("target_disabled", "\(leaf.title) is disabled in \(app).")
            }
            if MacComputerAccessibility.consequential([leaf.title]) {
                let line = MacComputerAccessibility.menuLine(titles, app: app)
                let key = "menu|\(pid)|" + titles.map(MacComputerAccessibility.menuTitle).joined(separator: "\u{1F}")
                let approved = try await reviewed(
                    request, line: line, key: key, once: false,
                    permit: { permit in
                        permit["path"] == args["path"]
                            && (permit["pid"].map { $0.numberValue == Double(pid) } ?? true)
                    })
                guard approved else {
                    throw ComputerHostError(
                        "confirmation_required", "The user must review this menu command first: " + line)
                }
            }
            try authorize()
            await cueApp(pid)
            let anchor = matched.first?.frame.flatMap { frame in
                frame.width > 0 && frame.height > 0 ? CGPoint(x: frame.midX, y: frame.midY) : nil
            }
            if let anchor { try await glide(to: anchor, label: "\(leaf.title) — \(app)") }
            try authorize()
            try MacComputerAccessibility.check(system.perform(kAXPressAction, on: leaf.element), "the menu command")
            if let anchor { await cue(.click(anchor)) }
            result["invoked"] = .bool(true)
            result["frontmost"] = .bool(foreground() == pid)
            return await settled(result, authorize: settle)
        }
        private func zoom(_ args: [String: JSONValue], authorize: @Sendable () throws -> Void) async throws
            -> [String: JSONValue]
        {
            try authorize()
            guard system.screenCaptureAccess() else {
                throw ComputerHostError("permission_denied", "Allow Screen Recording in System Settings.")
            }
            guard let geometry, try topology() == geometry.topology,
                system.displayBounds(geometry.display) == geometry.bounds
            else { throw ComputerHostError("stale_target", "Take a current screenshot before zooming.") }
            let x = args["x"]?.numberValue ?? 0
            let y = args["y"]?.numberValue ?? 0
            guard x < Double(geometry.width), y < Double(geometry.height) else {
                throw ComputerHostError("out_of_range", "The region is outside the last screenshot.")
            }
            let sx = geometry.bounds.width / Double(geometry.width)
            let sy = geometry.bounds.height / Double(geometry.height)
            let w = min(args["w"]?.numberValue ?? 1, Double(geometry.width) - x)
            let h = min(args["h"]?.numberValue ?? 1, Double(geometry.height) - y)
            var region = CGRect(
                x: geometry.bounds.minX + x * sx, y: geometry.bounds.minY + y * sy, width: w * sx, height: h * sy)
            if let raw = args["hwnd"]?.numberValue {
                guard let window = windows[Int(raw)], let bounds = observedBounds[Int(raw)], rect(window) == bounds
                else {
                    throw ComputerHostError(
                        "stale_target", "The reviewed window identity or geometry changed. List windows again.")
                }
                region = region.intersection(bounds)
                guard !region.isNull, region.width >= 1, region.height >= 1 else {
                    throw ComputerHostError("out_of_range", "The region does not overlap the window.")
                }
            }
            let ids = try displays()
            let before = try topology()
            let content = try await system.shareableContent()
            guard let display = content.displays.first(where: { $0.id == geometry.display }) else {
                throw ComputerHostError("screen_locked", "The display cannot be captured.")
            }
            let native = system.displayPixels(geometry.display).width / max(1, geometry.bounds.width)
            let scale = args["scale"]?.numberValue ?? 2
            var width = region.width / sx * scale
            var height = region.height / sy * scale
            let ceiling = min(1, region.width * native / max(1, width), 1920 / max(width, height))
            width = max(1, (width * ceiling).rounded())
            height = max(1, (height * ceiling).rounded())
            let excluded = await excluded(content)
            try authorize()
            let image = try await content.capture(
                MacComputerCapturePlan(
                    display: display.id, excludedWindows: excluded, width: Int(width), height: Int(height),
                    sourceRect: region.offsetBy(dx: -geometry.bounds.minX, dy: -geometry.bounds.minY)))
            try authorize()
            guard before == (try topology()), system.screenCaptureAccess() else {
                throw ComputerHostError("stale_target", "Capture authority or geometry changed.")
            }
            guard let jpeg = system.jpeg(image), !jpeg.isEmpty, jpeg.count <= 2_900_000 else {
                throw ComputerHostError("out_of_range", "The zoomed image exceeds the transport bound.")
            }
            return [
                "base64": .string(jpeg.base64EncodedString()), "media_type": .string("image/jpeg"),
                "width": .number(Double(image.width)), "height": .number(Double(image.height)),
                "scale": .number(region.width * native / Double(image.width)),
                "screen_index": .number(Double(ids.firstIndex(of: geometry.display) ?? 0)),
                "region": .object([
                    "x": .number(((region.minX - geometry.bounds.minX) / sx).rounded()),
                    "y": .number(((region.minY - geometry.bounds.minY) / sy).rounded()),
                    "w": .number((region.width / sx).rounded()), "h": .number((region.height / sy).rounded()),
                ]),
            ]
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
            var element: MacComputerAXTarget?
            var endElement: MacComputerAXTarget?
            if Self.pointerVerbs.contains(request.verb), let ref = request.args["ref"]?.stringValue,
                let snapshot = request.args["snapshot_id"]?.stringValue
            {
                let rects = try displayRects()
                element = try accessibility.resolve(ref, snapshot: snapshot, displays: rects)
                if let second = request.args["ref2"]?.stringValue {
                    endElement = try accessibility.resolve(second, snapshot: snapshot, displays: rects)
                }
            }
            var target: MacComputerTarget?
            if !Self.windowObservations.contains(request.verb), let raw = request.args["hwnd"]?.numberValue {
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
                    if let element, element.pid != pid {
                        throw ComputerHostError("out_of_range", "\(element.ref) is not in the reviewed window.")
                    }
                    let (start, end) = try pointerTargets(
                        request, element: element, end: endElement, checkForeground: false)
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
            let elementGuard =
                request.verb == "drag" ? nil : element.map { MacComputerAXGuard($0, system: system) }
            let elementPoint = element?.center ?? .zero
            let check: @Sendable () throws -> Void = {
                try baseCheck()
                try elementGuard?.verify(at: elementPoint)
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
            case "screenshot":
                return try await screenshot(
                    index: Int(request.args["screen_index"]?.numberValue ?? 0),
                    maximum: Int(request.args["max_width"]?.numberValue ?? 1280), authorize: check)
            case "list_windows": return try await listWindows(authorize: check)
            case "list_apps": return try await listApps(authorize: check)
            case "ax_tree": return try await tree(request.args, authorize: check)
            case "ax_find": return try await find(request.args, authorize: check)
            case "ax_action": return try await action(request, authorize: check, settle: baseCheck)
            case "menu": return try await menu(request, authorize: check, settle: baseCheck)
            case "zoom": return try await zoom(request.args, authorize: check)
            case "focus_window": return await settled(try await focus(request, authorize: check), authorize: baseCheck)
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
                return await settled(
                    [
                        "launched": .bool(true), "pid": .number(Double(launched.pid)),
                        "bundle_id": launched.bundleIdentifier.map(JSONValue.string) ?? .null, "app": .string(name),
                    ], authorize: baseCheck)
            case "type_text":
                await cueApp(foreground())
                try await input.type(request.args["text"]!.stringValue!, args: request.args, authorize: check)
                return await settled(
                    ["chars": .number(Double(request.args["text"]!.stringValue!.unicodeScalars.count))],
                    authorize: baseCheck)
            case "press_keys":
                let chord = try ComputerHostChord(request.args["keys"]!.stringValue!)
                await cueApp(foreground())
                try await input.press(chord, args: request.args, authorize: check)
                await cue(.chord(MacComputerOverlayCue.chordLabel(chord)))
                return await settled(["keys": request.args["keys"]!], authorize: baseCheck)
            default:
                let (start, end) = try pointerTargets(request, element: element, end: endElement, checkForeground: true)
                if let boundTarget { try ComputerHostGeometry.validate(start, end: end, within: boundTarget.bounds) }
                let ids = try displays()
                let observed = geometry.map { mapping($0, ids: ids) }
                await cueApp(element?.pid ?? foreground())
                try await glide(to: start, label: element?.label)
                if let element { try MacComputerAXGuard(element, system: system).verify(at: start) }
                try await input.pointer(request, start: start, end: end, authorize: check)
                switch request.verb {
                case "drag": if let end { await cue(.drag(start, end)) }
                case "scroll":
                    await cue(
                        .scroll(
                            start, dx: Int(request.args["dx"]?.numberValue ?? 0),
                            dy: Int(request.args["dy"]?.numberValue ?? -3)))
                case "move": break
                default: await cue(.click(start))
                }
                if let geometry, geometry.foreground != foreground() { observationStale = true }
                var result: [String: JSONValue] = ["attempted": .bool(true)]
                if let element {
                    result["ref"] = .string(element.ref)
                    result["role"] = .string(element.entry.name)
                    result["title"] = Self.text(element.entry.label ?? "")
                    result["screen_point"] = .object([
                        "x": .number(Double(start.x.rounded())), "y": .number(Double(start.y.rounded())),
                    ])
                    if let observed {
                        let point = observed.point(start)
                        result["point"] = .object(["x": .number(Double(point[0])), "y": .number(Double(point[1]))])
                    }
                }
                return await settled(result, authorize: baseCheck)
            }
        }
    }
#endif
