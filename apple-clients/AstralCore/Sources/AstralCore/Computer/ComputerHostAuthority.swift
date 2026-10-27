// Synchronizes computer admission tickets across the UI owner and the asynchronous physical driver.
// Revocation is immediate even while the operating-system API worker is suspended or blocked.

import Foundation

public final class ComputerHostAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var fence = ComputerHostFence()
    private var desktopAvailable = false
    private var desktopRearmRequired = false
    private let now: @Sendable () -> Double
    public init(now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }
    public func begin(_ session: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard desktopAvailable else {
            throw ComputerHostError("screen_locked", "Enable this Mac again from its active local desktop.")
        }
        try fence.begin(sessionId: session)
    }
    public func setDesktopAvailable(_ value: Bool, requiresLocalRearm: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        desktopAvailable = value
        if value {
            desktopRearmRequired = false
        } else {
            desktopRearmRequired = desktopRearmRequired || requiresLocalRearm
            fence.invalidate()
        }
    }
    public func restoreDesktopAvailability() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !desktopRearmRequired else { return false }
        desktopAvailable = true
        return true
    }
    public var desktopIsAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return desktopAvailable
    }
    public func pause() {
        lock.lock()
        defer { lock.unlock() }
        fence.pause()
    }
    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        fence.resume()
    }
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        fence.invalidate()
    }
    public func admit(_ request: ComputerHostRequest) throws -> ComputerHostTicket {
        lock.lock()
        defer { lock.unlock() }
        guard desktopAvailable else { throw ComputerHostError("screen_locked", "This desktop is unavailable.") }
        return try fence.admit(request, now: now())
    }
    public func verify(_ ticket: ComputerHostTicket) throws {
        lock.lock()
        defer { lock.unlock() }
        guard desktopAvailable, fence.permits(ticket, now: now()) else {
            throw ComputerHostError(
                "interrupted", "The request expired or computer authority changed. Inspect the result before retrying.")
        }
    }
    public func complete(_ ticket: ComputerHostTicket) {
        lock.lock()
        defer { lock.unlock() }
        fence.complete(ticket)
    }
}
