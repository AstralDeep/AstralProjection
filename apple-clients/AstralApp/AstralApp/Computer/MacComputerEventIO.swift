// Binds native event creation, posting and monitor registration to public macOS APIs.
// Computer input keeps its authority checks and sequencing while tests replace only these raw effects.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import Foundation

    nonisolated protocol MacComputerEventIO: Sendable {
        func keyboard(key: CGKeyCode, down: Bool) -> CGEvent?
        func mouse(kind: CGEventType, point: CGPoint, button: CGMouseButton) -> CGEvent?
        func scroll(dy: Int32, dx: Int32) -> CGEvent?
        func cursor() -> CGPoint?
        func post(_ event: CGEvent)
    }

    nonisolated struct MacComputerLiveEvents: MacComputerEventIO {
        func keyboard(key: CGKeyCode, down: Bool) -> CGEvent? {
            CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
        }
        func mouse(kind: CGEventType, point: CGPoint, button: CGMouseButton) -> CGEvent? {
            CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: button)
        }
        func scroll(dy: Int32, dx: Int32) -> CGEvent? {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        }
        func cursor() -> CGPoint? { CGEvent(source: nil)?.location }
        func post(_ event: CGEvent) { event.post(tap: .cghidEventTap) }
    }

    @MainActor
    protocol MacComputerEventMonitoring {
        var uptime: TimeInterval { get }
        func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any?
        func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any?
        func remove(_ monitor: Any)
        func associatedWindowNumber(for event: NSEvent) -> Int?
    }

    @MainActor
    final class MacComputerLiveEventMonitoring: MacComputerEventMonitoring {
        nonisolated init() {}
        var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
        func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
            NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        }
        func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any?
        {
            NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        }
        func remove(_ monitor: Any) { NSEvent.removeMonitor(monitor) }
        func associatedWindowNumber(for event: NSEvent) -> Int? { event.window?.windowNumber }
    }
#endif
