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
        private let monitors: any MacComputerEventMonitoring
        init(marker: Int64, monitors: any MacComputerEventMonitoring = MacComputerLiveEventMonitoring()) {
            self.marker = marker
            self.monitors = monitors
            proof = ComputerHostLocalInputProof(hostPID: ProcessInfo.processInfo.processIdentifier, marker: marker)
            let mask: NSEvent.EventTypeMask = [
                .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                .rightMouseUp, .otherMouseDown, .otherMouseUp,
            ]
            monitor = monitors.addLocal(matching: mask) { [weak self] event in
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
                at: monitors.uptime)
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
            return proof.consume(at: monitors.uptime)
        }
        func invalidate() { proof.invalidate() }
        func stop() {
            invalidate()
            if let monitor { monitors.remove(monitor) }
            monitor = nil
        }
    }
#endif
