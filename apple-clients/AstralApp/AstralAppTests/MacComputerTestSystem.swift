// Supplies raw synthetic accessibility and display data to the real native computer adapter.
// Recorded boundary calls are test observations and never actuate the desktop.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import Foundation
    @testable import AstralDeep

    nonisolated final class MacComputerTestSystem: MacComputerSystemIO, @unchecked Sendable {
        struct Node {
            let element: AXUIElement
            var pid: pid_t?
            var attributes: [String: CFTypeRef] = [:]
        }
        struct State {
            var accessibility = true
            var posting = true
            var screen = true
            var monitoring = true
            var secure = false
            var session: [String: Any]? = [
                kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true,
            ]
            var nodes: [Node] = []
            var bundles: [pid_t: String] = [100: "fixture.host", 200: "com.google.Chrome"]
            var rows: [[String: Any]]? = []
            var displays: [CGDirectDisplayID] = [77]
            var countError: CGError = .success
            var enumerationError: CGError = .success
            var countOverride: UInt32?
            var bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
            var pixels = CGSize(width: 1280, height: 960)
            var captureDisplays = [MacComputerCaptureDisplay(id: 77, width: 640, height: 480)]
            var captureWindows: [CGWindowID] = [4, 5]
            var controls: Set<CGWindowID> = [5]
            var plans: [MacComputerCapturePlan] = []
            var trace: [String] = []
            var captureFailure = false
            var contentFailure = false
            var jpegFailure = false
            var jpegOverride: Data?
            var apps = [MacComputerApplication(pid: 200, bundleIdentifier: "com.google.Chrome")]
            var activation = true
            var actionResult: AXError = .success
            var applicationURL: URL?
            var launched = MacComputerApplication(pid: 300, bundleIdentifier: "fixture.editor")
            var launchFailure = false
            var clipboard: String?
            var clipboardWrite = true
            var hook: (@Sendable (String) -> Void)?
            var delayHook: (@Sendable (UInt64) async throws -> Void)?
        }
        let hostPID: pid_t = 100
        let hostBundleIdentifier: String? = "fixture.host"
        let system = AXUIElementCreateSystemWide()
        let app = AXUIElementCreateApplication(200)
        let window = AXUIElementCreateApplication(900001)
        let field = AXUIElementCreateApplication(900002)
        private let lock = NSRecursiveLock()
        private var state = State()
        init() {
            state.nodes = [
                Node(element: system, pid: nil, attributes: [kAXFocusedApplicationAttribute: app]),
                Node(
                    element: app, pid: 200,
                    attributes: [
                        kAXFocusedWindowAttribute: window, kAXFocusedUIElementAttribute: field,
                        kAXWindowsAttribute: [window] as CFArray,
                    ]),
                Node(
                    element: window, pid: 200,
                    attributes: [
                        kAXTitleAttribute: "Synthetic browser" as CFString, kAXFocusedAttribute: kCFBooleanTrue,
                        kAXMinimizedAttribute: kCFBooleanFalse,
                    ]),
                Node(element: field, pid: 200, attributes: [kAXSubroleAttribute: "AXTextField" as CFString]),
            ]
            setBounds(state.bounds, of: window)
        }
        @discardableResult func configure<T>(_ body: (inout State) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(&state)
        }
        func set(_ value: CFTypeRef?, attribute: String, of element: AXUIElement) {
            configure {
                let index = $0.nodes.firstIndex { CFEqual($0.element, element) }!
                $0.nodes[index].attributes[attribute] = value
            }
        }
        func setBounds(_ bounds: CGRect, of element: AXUIElement) {
            var point = bounds.origin
            var size = bounds.size
            set(AXValueCreate(.cgPoint, &point), attribute: kAXPositionAttribute, of: element)
            set(AXValueCreate(.cgSize, &size), attribute: kAXSizeAttribute, of: element)
        }
        func effect(_ name: String) {
            let hook = configure {
                $0.trace.append(name)
                return $0.hook
            }
            hook?(name)
        }
        func accessibilityTrusted() -> Bool { configure { $0.accessibility } }
        func postEventAccess() -> Bool { configure { $0.posting } }
        func screenCaptureAccess() -> Bool { configure { $0.screen } }
        func listenEventAccess() -> Bool { configure { $0.monitoring } }
        func secureInputEnabled() -> Bool { configure { $0.secure } }
        func systemElement() -> AXUIElement { system }
        func applicationElement(_ pid: pid_t) -> AXUIElement {
            configure { $0.nodes.first { $0.pid == pid }?.element ?? AXUIElementCreateApplication(pid) }
        }
        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            configure { $0.nodes.first { CFEqual($0.element, element) }?.attributes[name] }
        }
        func pid(of element: AXUIElement) -> pid_t? {
            configure { $0.nodes.first { CFEqual($0.element, element) }?.pid }
        }
        func bundleIdentifier(for pid: pid_t) -> String? { configure { $0.bundles[pid] } }
        func messagingTimeout(_ seconds: Float, for element: AXUIElement) { effect("timeout") }
        func visibleWindows() -> [[String: Any]]? { configure { $0.rows } }
        func setAttribute(_ name: String, of element: AXUIElement, to value: CFTypeRef) -> AXError {
            effect("setAttribute")
            set(value, attribute: name, of: element)
            return .success
        }
        func perform(_ action: String, on element: AXUIElement) -> AXError {
            effect("raise")
            return configure { $0.actionResult }
        }
        func sessionDictionary() -> [String: Any]? { configure { $0.session } }
        func displayCount() -> (CGError, UInt32) {
            configure { ($0.countError, $0.countOverride ?? UInt32($0.displays.count)) }
        }
        func displayIDs(capacity: UInt32) -> (CGError, [CGDirectDisplayID]) {
            configure { ($0.enumerationError, $0.displays) }
        }
        func mainDisplay() -> CGDirectDisplayID { 77 }
        func displayBounds(_ display: CGDirectDisplayID) -> CGRect { configure { $0.bounds } }
        func displayPixels(_ display: CGDirectDisplayID) -> CGSize { configure { $0.pixels } }
        func jpeg(_ image: CGImage) -> Data? {
            configure { $0.jpegFailure ? nil : ($0.jpegOverride ?? MacComputerLiveSystem.shared.jpeg(image)) }
        }
        func delay(nanoseconds: UInt64) async throws {
            effect("delay")
            try Task.checkCancellation()
            if let delay = configure({ $0.delayHook }) { try await delay(nanoseconds) }
            try Task.checkCancellation()
        }
        @MainActor func runningApplications() -> [MacComputerApplication] { configure { $0.apps } }
        @MainActor func activate(_ pid: pid_t) -> Bool {
            effect("activate")
            return configure { $0.activation }
        }
        @MainActor func applicationURL(bundleIdentifier: String) -> URL? { configure { $0.applicationURL } }
        @MainActor func openApplication(at url: URL) async throws -> MacComputerApplication {
            effect("launch")
            return try configure {
                if $0.launchFailure { throw CocoaError(.executableNotLoadable) }
                return $0.launched
            }
        }
        @MainActor func controlsWindows() -> Set<CGWindowID> { configure { $0.controls } }
        @MainActor func clipboardText() -> String? {
            effect("clipboardRead")
            return configure { $0.clipboard }
        }
        @MainActor func clearClipboard() {
            effect("clipboardClear")
            configure { $0.clipboard = nil }
        }
        @MainActor func setClipboard(_ text: String) -> Bool {
            effect("clipboardWrite")
            return configure {
                $0.clipboard = text
                return $0.clipboardWrite
            }
        }
        func shareableContent() async throws -> MacComputerCaptureSource {
            effect("content")
            return try configure {
                if $0.contentFailure { throw CocoaError(.fileReadUnknown) }
                return MacComputerCaptureSource(displays: $0.captureDisplays, windows: $0.captureWindows) { plan in
                    self.effect("capture")
                    return try self.configure {
                        $0.plans.append(plan)
                        if $0.captureFailure { throw CocoaError(.fileReadUnknown) }
                        let context = CGContext(
                            data: nil, width: plan.width, height: plan.height, bitsPerComponent: 8,
                            bytesPerRow: plan.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        return context.makeImage()!
                    }
                }
            }
        }
    }
#endif
