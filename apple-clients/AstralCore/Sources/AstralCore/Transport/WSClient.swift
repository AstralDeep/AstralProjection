// Actor-based WebSocket transport with the reconnect contract shared across Windows/Android/Apple clients:
// capped exponential backoff, a bounded drop-oldest outbound queue, and sends fenced to the currently
// established connection.

import Foundation

public struct BackoffPolicy: Sendable {
    public let base: TimeInterval
    public let factor: Double
    public let cap: TimeInterval
    private(set) var attempt: Int = 0

    public init(base: TimeInterval = 1.0, factor: Double = 2.0, cap: TimeInterval = 30.0) {
        self.base = base
        self.factor = factor
        self.cap = cap
    }

    public mutating func next() -> TimeInterval {
        let delay = min(base * pow(factor, Double(attempt)), cap)
        attempt += 1
        return delay
    }

    public mutating func reset() { attempt = 0 }
}

public struct BoundedQueue<Element>: Sendable where Element: Sendable {
    public let limit: Int
    private(set) var elements: [Element] = []
    public private(set) var droppedCount: Int = 0

    public init(limit: Int = 64) {
        self.limit = limit
    }

    @discardableResult
    public mutating func append(_ element: Element) -> Bool {
        appendReturningDropped(element) != nil
    }

    public mutating func appendReturningDropped(_ element: Element) -> Element? {
        var dropped: Element?
        if elements.count >= limit {
            dropped = elements.removeFirst()
            droppedCount += 1
        }
        elements.append(element)
        return dropped
    }

    public mutating func drainAll() -> [Element] {
        let out = elements
        elements = []
        return out
    }

    public var count: Int { elements.count }
}

public enum WSEvent: Sendable {
    case connected
    case disconnected(reason: String)
    case frame(InboundFrame)
    case sendDropped(total: Int)
    case queuedOperationDropped(QueuedOperationReplay, reason: String)
    case sendRejected(action: String)
}

private struct QueuedOutboundFrame: Sendable {
    let text: String
    let replay: QueuedOperationReplay
}

public actor WSClient {
    public let url: URL
    private var task: URLSessionWebSocketTask?
    private var backoff = BackoffPolicy()
    private var queue = BoundedQueue<QueuedOutboundFrame>(limit: 64)
    private var running = false
    // Socket running does not mean registered; queue until true
    private var established = false
    private var continuation: AsyncStream<WSEvent>.Continuation?
    private var onConnect: (@Sendable () async -> String?)?
    private var onReplay: (@Sendable (QueuedOperationReplay) async -> Bool)?

    public init(url: URL) {
        self.url = url
    }

    public func events() -> AsyncStream<WSEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func start(
        onConnect: @escaping @Sendable () async -> String?,
        onReplay: @escaping @Sendable (QueuedOperationReplay) async -> Bool = { _ in true }
    ) {
        guard !running else { return }
        running = true
        self.onConnect = onConnect
        self.onReplay = onReplay
        Task { await self.runLoop() }
    }

    public func stop() {
        running = false
        established = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        continuation?.finish()
    }

    public func send(_ text: String) {
        guard !WorkReadRequest.claimsCurrentConnectionSemantics(frameText: text),
            !GuidanceRequest.claimsCurrentConnectionSemantics(frameText: text)
        else {
            continuation?.yield(.sendRejected(action: Self.actionHint(text)))
            return
        }
        if let voiceFrame = VoiceCurrentConnectionFrame(frameText: text) {
            _ = sendCurrentConnectionVoice(voiceFrame)
            return
        }
        guard let replay = QueuedOperationReplay(frameText: text) else {
            continuation?.yield(.sendRejected(action: Self.actionHint(text)))
            return
        }
        let queued = QueuedOutboundFrame(text: text, replay: replay)
        if established, let task, task.state == .running {
            transmit(queued, using: task)
        } else {
            retain(queued)
        }
    }

    @discardableResult
    public func sendCurrentComponentEvent(
        _ text: String, isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard let replay = QueuedOperationReplay(frameText: text),
            ["component_refine", "component_restore"].contains(replay.action),
            established, let current = task, current.state == .running,
            await isCurrent(), !Task.isCancelled,
            established, task === current, current.state == .running
        else { return false }
        do {
            try await current.send(.string(text))
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func sendCurrentWorkEvent(
        _ text: String, isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard WorkReadRequest.isCurrentConnectionEvent(text),
            established, let current = task, current.state == .running
        else { return false }
        return await sendCurrentOwnerSurfaceEvent(text, using: current, isCurrent: isCurrent)
    }

    @discardableResult
    public func sendCurrentGuidanceEvent(
        _ text: String, isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard GuidanceRequest(frameText: text) != nil,
            established, let current = task, current.state == .running
        else { return false }
        return await sendCurrentOwnerSurfaceEvent(text, using: current, isCurrent: isCurrent)
    }

    private func sendCurrentOwnerSurfaceEvent(
        _ text: String, using current: URLSessionWebSocketTask,
        isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard await isCurrent(), !Task.isCancelled,
            established, task === current, current.state == .running
        else { return false }
        do {
            try await current.send(.string(text))
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func sendCurrentConnectionVoice(_ text: String) -> Bool {
        guard let frame = VoiceCurrentConnectionFrame(frameText: text) else {
            continuation?.yield(.sendRejected(action: Self.actionHint(text)))
            return false
        }
        return sendCurrentConnectionVoice(frame)
    }

    @discardableResult
    public func sendCurrentConnectionVoice(_ frame: VoiceCurrentConnectionFrame) -> Bool {
        guard established, let task, task.state == .running else { return false }
        task.send(.string(frame.frameText)) { _ in }
        return true
    }

    private func runLoop() async {
        while running {
            let task = NoStoreHTTP.session.webSocketTask(with: url)
            self.task = task
            established = false
            task.resume()

            guard let register = await onConnect?(), running else {
                task.cancel(with: .normalClosure, reason: nil)
                self.task = nil
                guard running else { break }
                continuation?.yield(.disconnected(reason: "waiting for credentials"))
                try? await Task.sleep(nanoseconds: UInt64(backoffNext() * 1_000_000_000))
                continue
            }
            task.send(.string(register)) { _ in }

            receive: while running {
                do {
                    let message = try await task.receive()
                    if !established {
                        established = true
                        backoff.reset()
                        continuation?.yield(.connected)
                        for queued in queue.drainAll() {
                            guard await onReplay?(queued.replay) == true else {
                                continuation?.yield(
                                    .queuedOperationDropped(
                                        queued.replay,
                                        reason: "replay fence rejected"))
                                continue
                            }
                            transmit(queued, using: task)
                        }
                    }
                    switch message {
                    case .string(let text):
                        if let frame = InboundFrame.parse(text) {
                            continuation?.yield(.frame(frame))
                        }
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8),
                            let frame = InboundFrame.parse(text)
                        {
                            continuation?.yield(.frame(frame))
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    established = false
                    continuation?.yield(.disconnected(reason: error.localizedDescription))
                    break receive
                }
            }
            established = false
            self.task = nil
            guard running else { break }
            let delay = backoffNext()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func backoffNext() -> TimeInterval {
        backoff.next()
    }

    private func transmit(
        _ queued: QueuedOutboundFrame,
        using task: URLSessionWebSocketTask
    ) {
        task.send(.string(queued.text)) { [weak self] error in
            guard error != nil else { return }
            Task { await self?.retain(queued) }
        }
    }

    private func retain(_ queued: QueuedOutboundFrame) {
        if let dropped = queue.appendReturningDropped(queued) {
            continuation?.yield(
                .queuedOperationDropped(dropped.replay, reason: "offline queue full"))
            continuation?.yield(.sendDropped(total: queue.droppedCount))
        }
    }

    private static func actionHint(_ text: String) -> String {
        InboundFrame.parse(text)?.payload["action"]?.stringValue ?? "message"
    }
}
