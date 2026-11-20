// Lets one inference run at a time across the recognizer and the text generator, and serves waiting recognition before waiting generation.
// Both engines take a slot here before touching their models, which is what keeps them off the GPU at the same instant.
import Foundation

public actor RuntimeScheduler {
    public enum Priority: Sendable {
        case recognition
        case generation
    }

    public static let shared = RuntimeScheduler()

    private struct Waiter {
        let id: UInt64
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }

    private var busy = false
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    private var registering: Set<UInt64> = []
    private var cancelledEarly: Set<UInt64> = []

    public init() {}

    public var waitingCount: Int { waiters.count }
    public var isBusy: Bool { busy }

    public func perform<T: Sendable>(_ priority: Priority, _ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(priority)
        defer { release() }
        return try await operation()
    }

    private func acquire(_ priority: Priority) async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = nextID
        nextID += 1
        registering.insert(id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                registering.remove(id)
                if cancelledEarly.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if registering.contains(id) {
            cancelledEarly.insert(id)
        }
    }

    private func release() {
        let index = waiters.firstIndex(where: { $0.priority == .recognition }) ?? (waiters.isEmpty ? nil : 0)
        guard let index else {
            busy = false
            return
        }
        waiters.remove(at: index).continuation.resume()
    }
}
