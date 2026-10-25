// Records app-local hardware activation independently of computer-session monitoring.
// Consent consumes this one-use evidence and separately checks the active, unlocked Astral desktop.

#if os(macOS)
    import AppKit
    import AstralCore
    import Foundation

    @MainActor
    final class MacComputerLocalInput {
        private var proof: ComputerHostLocalInputProof
        private var monitor: Any?
        private let marker: Int64
        init(marker: Int64) {
            self.marker = marker
            proof = ComputerHostLocalInputProof(hostPID: ProcessInfo.processInfo.processIdentifier, marker: marker)
            let mask: NSEvent.EventTypeMask = [
                .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                .rightMouseUp, .otherMouseDown, .otherMouseUp,
            ]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.record(event.cgEvent)
                return event
            }
        }
        func record(_ event: CGEvent?) {
            guard let event else {
                invalidate()
                return
            }
            proof.record(
                sourcePID: Int32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID)),
                sourceState: event.getIntegerValueField(.eventSourceStateID),
                userData: event.getIntegerValueField(.eventSourceUserData),
                at: ProcessInfo.processInfo.systemUptime)
        }
        func consume(current: CGEvent?) -> Bool {
            if let current {
                let pid = current.getIntegerValueField(.eventSourceUnixProcessID)
                if pid != 0 || current.getIntegerValueField(.eventSourceStateID) != 1
                    || current.getIntegerValueField(.eventSourceUserData) == marker
                {
                    invalidate()
                    return false
                }
            }
            return proof.consume(at: ProcessInfo.processInfo.systemUptime)
        }
        func invalidate() { proof.invalidate() }
        func stop() {
            invalidate()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
#endif
