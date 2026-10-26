// Binds the native computer adapter to public accessibility, display and workspace APIs.
// Driver decisions consume raw readings while tests supply synthetic operating-system data.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import Carbon
    import Foundation
    import ScreenCaptureKit

    nonisolated protocol MacComputerSystemReading: Sendable {
        var hostPID: pid_t { get }
        var hostBundleIdentifier: String? { get }
        func accessibilityTrusted() -> Bool
        func postEventAccess() -> Bool
        func screenCaptureAccess() -> Bool
        func listenEventAccess() -> Bool
        func secureInputEnabled() -> Bool
        func systemElement() -> AXUIElement
        func applicationElement(_ pid: pid_t) -> AXUIElement
        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef?
        func pid(of element: AXUIElement) -> pid_t?
        func bundleIdentifier(for pid: pid_t) -> String?
        func messagingTimeout(_ seconds: Float, for element: AXUIElement)
        func visibleWindows() -> [[String: Any]]?
    }

    nonisolated struct MacComputerApplication: Sendable {
        let pid: pid_t
        let bundleIdentifier: String?
        var regular = true
    }

    nonisolated struct MacComputerCaptureDisplay: Sendable {
        let id: CGDirectDisplayID
        let width: Int
        let height: Int
    }

    nonisolated struct MacComputerCapturePlan: Sendable {
        let display: CGDirectDisplayID
        let excludedWindows: Set<CGWindowID>
        let width: Int
        let height: Int
        func configuration() -> SCStreamConfiguration {
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = true
            configuration.capturesAudio = false
            return configuration
        }
    }

    nonisolated struct MacComputerCaptureSource: Sendable {
        let displays: [MacComputerCaptureDisplay]
        let windows: [CGWindowID]
        let capture: @Sendable (MacComputerCapturePlan) async throws -> CGImage
    }

    nonisolated protocol MacComputerSystemIO: MacComputerSystemReading {
        func setAttribute(_ name: String, of element: AXUIElement, to value: CFTypeRef) -> AXError
        func perform(_ action: String, on element: AXUIElement) -> AXError
        func sessionDictionary() -> [String: Any]?
        func displayCount() -> (CGError, UInt32)
        func displayIDs(capacity: UInt32) -> (CGError, [CGDirectDisplayID])
        func mainDisplay() -> CGDirectDisplayID
        func displayBounds(_ display: CGDirectDisplayID) -> CGRect
        func displayPixels(_ display: CGDirectDisplayID) -> CGSize
        func shareableContent() async throws -> MacComputerCaptureSource
        func jpeg(_ image: CGImage) -> Data?
        func delay(nanoseconds: UInt64) async throws
        @MainActor func runningApplications() -> [MacComputerApplication]
        @MainActor func activate(_ pid: pid_t) -> Bool
        @MainActor func applicationURL(bundleIdentifier: String) -> URL?
        @MainActor func openApplication(at url: URL) async throws -> MacComputerApplication
        @MainActor func controlsWindows() -> Set<CGWindowID>
        @MainActor func clipboardText() -> String?
        @MainActor func clearClipboard()
        @MainActor func setClipboard(_ text: String) -> Bool
    }
    nonisolated final class MacComputerLiveSystem: MacComputerSystemIO {
        static let shared = MacComputerLiveSystem()
        let hostPID = ProcessInfo.processInfo.processIdentifier
        let hostBundleIdentifier = Bundle.main.bundleIdentifier
        private init() {}
        func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }
        func postEventAccess() -> Bool { CGPreflightPostEventAccess() }
        func screenCaptureAccess() -> Bool { CGPreflightScreenCaptureAccess() }
        func listenEventAccess() -> Bool { CGPreflightListenEventAccess() }
        func secureInputEnabled() -> Bool { IsSecureEventInputEnabled() }
        func systemElement() -> AXUIElement { AXUIElementCreateSystemWide() }
        func applicationElement(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func pid(of element: AXUIElement) -> pid_t? {
            var value: pid_t = 0
            return AXUIElementGetPid(element, &value) == .success ? value : nil
        }
        func bundleIdentifier(for pid: pid_t) -> String? {
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        func messagingTimeout(_ seconds: Float, for element: AXUIElement) {
            AXUIElementSetMessagingTimeout(element, seconds)
        }
        func visibleWindows() -> [[String: Any]]? {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        }
        func setAttribute(_ name: String, of element: AXUIElement, to value: CFTypeRef) -> AXError {
            AXUIElementSetAttributeValue(element, name as CFString, value)
        }
        func perform(_ action: String, on element: AXUIElement) -> AXError {
            AXUIElementPerformAction(element, action as CFString)
        }
        func sessionDictionary() -> [String: Any]? { CGSessionCopyCurrentDictionary() as? [String: Any] }
        func displayCount() -> (CGError, UInt32) {
            var count: UInt32 = 0
            let result = CGGetActiveDisplayList(0, nil, &count)
            return (result, count)
        }
        func displayIDs(capacity: UInt32) -> (CGError, [CGDirectDisplayID]) {
            var count = capacity
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
            let result = CGGetActiveDisplayList(capacity, &ids, &count)
            return (result, Array(ids.prefix(Int(count))))
        }
        func mainDisplay() -> CGDirectDisplayID { CGMainDisplayID() }
        func displayBounds(_ display: CGDirectDisplayID) -> CGRect { CGDisplayBounds(display) }
        func displayPixels(_ display: CGDirectDisplayID) -> CGSize {
            CGSize(width: CGDisplayPixelsWide(display), height: CGDisplayPixelsHigh(display))
        }
        func jpeg(_ image: CGImage) -> Data? {
            NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        }
        func delay(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
        @MainActor func runningApplications() -> [MacComputerApplication] {
            NSWorkspace.shared.runningApplications.map {
                MacComputerApplication(
                    pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                    regular: $0.activationPolicy == .regular)
            }
        }
        @MainActor func activate(_ pid: pid_t) -> Bool {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) ?? false
        }
        @MainActor func applicationURL(bundleIdentifier: String) -> URL? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        @MainActor func openApplication(at url: URL) async throws -> MacComputerApplication {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let app {
                        continuation.resume(
                            returning: MacComputerApplication(
                                pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier))
                    } else {
                        continuation.resume(throwing: CocoaError(.executableNotLoadable))
                    }
                }
            }
        }
        @MainActor func controlsWindows() -> Set<CGWindowID> {
            Set(
                NSApplication.shared.windows.filter { $0.title == MacComputerPanelIdentity.title }.map {
                    CGWindowID($0.windowNumber)
                })
        }
        @MainActor func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }
        @MainActor func clearClipboard() { NSPasteboard.general.clearContents() }
        @MainActor func setClipboard(_ text: String) -> Bool { NSPasteboard.general.setString(text, forType: .string) }
        func shareableContent() async throws -> MacComputerCaptureSource {
            let native = MacComputerNativeCapture(
                content: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
            return MacComputerCaptureSource(
                displays: native.content.displays.map {
                    MacComputerCaptureDisplay(id: $0.displayID, width: $0.width, height: $0.height)
                }, windows: native.content.windows.map(\.windowID),
                capture: { plan in try await native.capture(plan) })
        }
    }

    private nonisolated final class MacComputerNativeCapture: @unchecked Sendable {
        let content: SCShareableContent
        init(content: SCShareableContent) { self.content = content }
        func capture(_ plan: MacComputerCapturePlan) async throws -> CGImage {
            guard let display = content.displays.first(where: { $0.displayID == plan.display }) else {
                throw CocoaError(.fileReadUnknown)
            }
            let filter = SCContentFilter(
                display: display,
                excludingWindows: content.windows.filter { plan.excludedWindows.contains($0.windowID) })
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: plan.configuration())
        }
    }
#endif
