// Consumes fresh, one-use local HID evidence before native computer consent can be rearmed.
// The Mac event adapter records provenance and clears evidence on synthetic input or authority changes.

import Foundation

public struct ComputerHostLocalInputProof: Sendable {
    private let hostPID: Int32
    private let marker: Int64
    private var recordedAt: Double?

    public init(hostPID: Int32, marker: Int64) {
        self.hostPID = hostPID
        self.marker = marker
    }
    public mutating func record(sourcePID: Int32, sourceState: Int64, userData: Int64, at time: Double) {
        guard sourcePID == 0, sourcePID != hostPID, sourceState == 1, userData != marker, time.isFinite else {
            invalidate()
            return
        }
        recordedAt = time
    }
    public mutating func invalidate() { recordedAt = nil }
    public mutating func consume(at time: Double) -> Bool {
        defer { invalidate() }
        guard let recordedAt, time.isFinite, time >= recordedAt, time - recordedAt <= 2 else { return false }
        return true
    }
}
