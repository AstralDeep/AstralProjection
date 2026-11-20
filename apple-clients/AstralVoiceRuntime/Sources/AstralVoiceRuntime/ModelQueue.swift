// Gives each model actor its own serial dispatch queue as its executor, so a long native decode never occupies the cooperative thread pool.
// It also runs the blocking model load off the caller's thread.
import Dispatch
import Foundation

enum ModelQueue {
    static func make(_ label: String) -> DispatchSerialQueue {
        DispatchSerialQueue(label: "astral.voice.runtime.\(label)", qos: .userInitiated)
    }

    static func load<T: Sendable>(on queue: DispatchSerialQueue, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}

func textStream(_ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await work { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
