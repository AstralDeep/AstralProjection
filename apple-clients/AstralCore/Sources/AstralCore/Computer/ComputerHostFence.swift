// Keeps computer effects scoped to one current local session and monotonic request deadline.
// The platform host rechecks immutable tickets before each physical operation and never replays an ID.

import Foundation

public struct ComputerHostTicket: Sendable, Equatable {
    public let requestId: String
    public let sessionId: String
    public let digest: String
    public let epoch: UUID
    public let expiresAt: Double
}

public struct ComputerHostFence: Sendable {
    public private(set) var sessionId: String?
    public private(set) var active = false
    private var epoch = UUID()
    private var seen: [String: String] = [:]
    private var pending: Set<String> = []
    private var retired: Set<String> = []
    private var exhausted = false
    public init() {}
    public mutating func begin(sessionId: String) throws {
        guard computerUUID(sessionId), !retired.contains(sessionId), !exhausted else {
            throw ComputerHostError("no_session", "This session is retired. Start a new session.")
        }
        if self.sessionId != sessionId {
            invalidate()
            guard !exhausted else {
                throw ComputerHostError("no_session", "Restart the application before starting another session.")
            }
            self.sessionId = sessionId
            seen = [:]
        }
        active = true
    }
    public mutating func pause() {
        active = false
        epoch = UUID()
        pending = []
    }
    public mutating func resume() {
        if sessionId != nil && !exhausted {
            active = true
            epoch = UUID()
        }
    }
    public mutating func invalidate() {
        if let sessionId { retired.insert(sessionId) }
        if retired.count >= 128 { exhausted = true }
        sessionId = nil
        active = false
        epoch = UUID()
        pending = []
    }
    public mutating func admit(_ request: ComputerHostRequest, now: Double) throws -> ComputerHostTicket {
        guard active, request.sessionId == sessionId else {
            throw ComputerHostError(active ? "no_session" : "paused", "No active matching computer session.")
        }
        guard now.isFinite, seen[request.id] == nil else {
            throw ComputerHostError("duplicate_request", "A request ID cannot be executed again.")
        }
        guard seen.count < 4096, pending.count < 33 else {
            throw ComputerHostError("capacity_exceeded", "The computer request capacity is full.")
        }
        seen[request.id] = request.digest
        pending.insert(request.id)
        return ComputerHostTicket(
            requestId: request.id, sessionId: request.sessionId, digest: request.digest, epoch: epoch,
            expiresAt: now + request.deadline)
    }
    public func permits(_ ticket: ComputerHostTicket, now: Double) -> Bool {
        active && ticket.epoch == epoch && ticket.sessionId == sessionId && seen[ticket.requestId] == ticket.digest
            && pending.contains(ticket.requestId) && now.isFinite && now < ticket.expiresAt
    }
    public mutating func complete(_ ticket: ComputerHostTicket) { pending.remove(ticket.requestId) }
}
