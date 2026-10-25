// Denies native computer mutations against the host's own process and visible controls.
// The Mac adapter supplies current front-to-back window geometry before each pointer effect.

import Foundation

public struct ComputerHostTargetWindow: Sendable {
    public let pid: Int32?
    public let bounds: CGRect
    public init(pid: Int32?, bounds: CGRect) {
        self.pid = pid
        self.bounds = bounds
    }
}

public enum ComputerHostTargetPolicy {
    public static func externalProcess(_ pid: Int32?, hostPID: Int32) throws {
        guard let pid, pid > 0, pid != hostPID else {
            throw ComputerHostError("permission_denied", "Computer input cannot operate Astral's own controls.")
        }
    }
    public static func externalPoint(_ point: CGPoint, hostPID: Int32, windows: [ComputerHostTargetWindow]) throws {
        if let target = windows.first(where: { $0.bounds.contains(point) }) {
            try externalProcess(target.pid, hostPID: hostPID)
        }
    }
}
