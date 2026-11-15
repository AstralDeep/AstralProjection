// Completes an interactive companion send once, including cancellation and a bounded missing-reply timeout.
// Both WatchConnectivity delegates use this guard so late framework callbacks cannot resume retired work twice.

import Foundation

public final class CompanionVoiceReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var timeout: DispatchWorkItem?

    public init() {}

    public func install(_ continuation: CheckedContinuation<Void, Error>) {
        let completed = lock.withLock { () -> Result<Void, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed {
            continuation.resume(with: completed)
            return
        }
        let deadline = DispatchWorkItem { [weak self] in self?.finish(CompanionVoiceError.notReachable) }
        lock.withLock {
            if result == nil { timeout = deadline } else { deadline.cancel() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
    }

    public func finish(_ error: Error? = nil) {
        let next: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard result == nil else { return nil }
            result = next
            timeout?.cancel()
            timeout = nil
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: next)
    }
}

public final class CompanionVoiceInboundReply: @unchecked Sendable {
    private let reply: (Data) -> Void

    public init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
    public func send(_ data: Data) { reply(data) }
}
