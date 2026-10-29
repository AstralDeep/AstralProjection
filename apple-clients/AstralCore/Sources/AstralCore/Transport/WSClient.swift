// Actor-based WebSocket transport with the reconnect contract shared across Windows/Android/Apple clients:
// capped exponential backoff, a bounded drop-oldest outbound queue, and sends fenced to the currently
// established connection. A liveness policy pings a quiet socket and abandons one that stops answering, so the
// loop reconnects and replays queued operations through the caller's fence.

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

public struct LivenessPolicy: Sendable, Equatable {
    public let interval: TimeInterval
    public let timeout: TimeInterval
    public let freshness: TimeInterval

    public init(interval: TimeInterval, timeout: TimeInterval, freshness: TimeInterval) {
        self.interval = interval
        self.timeout = timeout
        self.freshness = freshness
    }

    public static let standard = LivenessPolicy(interval: 20, timeout: 5, freshness: 10)
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

private final class PingAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ answered: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: answered)
    }
}

public actor WSClient {
    public let url: URL
    private var task: URLSessionWebSocketTask?
    private var backoff = BackoffPolicy()
    private var queue = BoundedQueue<QueuedOutboundFrame>(limit: 64)
    private var running = false
    // Socket running does not mean registered; queue until true
    private var established = false
    private var registeredConnectionGeneration: String?
    private var continuation: AsyncStream<WSEvent>.Continuation?
    private var onConnect: (@Sendable () async -> String?)?
    private var onReplay: (@Sendable (QueuedOperationReplay) async -> Bool)?
    private var onRegistration: (@Sendable (InboundFrame, String) async -> Bool)?
    private let liveness: LivenessPolicy?
    private var lastInbound = ContinuousClock.now
    private var keepalive: Task<Void, Never>?

    private let requestHeaders: @Sendable () async -> [String: String]?

    public init(
        url: URL, liveness: LivenessPolicy? = nil,
        requestHeaders: @escaping @Sendable () async -> [String: String]? = { [:] }
    ) {
        self.url = url
        self.liveness = liveness
        self.requestHeaders = requestHeaders
    }

    public func events() -> AsyncStream<WSEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func start(
        onConnect: @escaping @Sendable () async -> String?,
        onReplay: @escaping @Sendable (QueuedOperationReplay) async -> Bool = { _ in true },
        onRegistration: (@Sendable (InboundFrame, String) async -> Bool)? = nil
    ) {
        guard !running else { return }
        running = true
        self.onConnect = onConnect
        self.onReplay = onReplay
        self.onRegistration = onRegistration
        Task { await self.runLoop() }
    }

    public func stop() {
        running = false
        established = false
        registeredConnectionGeneration = nil
        keepalive?.cancel()
        keepalive = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        continuation?.finish()
    }

    public func send(_ text: String) {
        guard !Self.claimsCurrentConnection(text) else {
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

    public func sendThroughReplay(_ text: String) async {
        guard !Self.claimsCurrentConnection(text), VoiceCurrentConnectionFrame(frameText: text) == nil,
            let replay = QueuedOperationReplay(frameText: text)
        else {
            continuation?.yield(.sendRejected(action: Self.actionHint(text)))
            return
        }
        let queued = QueuedOutboundFrame(text: text, replay: replay)
        guard established, let current = task, current.state == .running else {
            retain(queued)
            return
        }
        guard await onReplay?(replay) == true else {
            continuation?.yield(.queuedOperationDropped(replay, reason: "replay fence rejected"))
            return
        }
        if established, task === current, current.state == .running {
            transmit(queued, using: current)
        } else {
            retain(queued)
        }
    }

    public func confirmLive() async -> Bool {
        guard established, let current = task, current.state == .running else { return false }
        return await probe(current, policy: liveness ?? .standard)
    }

    private func probe(_ current: URLSessionWebSocketTask, policy: LivenessPolicy) async -> Bool {
        guard established, task === current else { return false }
        if ContinuousClock.now - lastInbound < Self.duration(policy.freshness) { return true }
        let answered = await Self.ping(current, within: policy.timeout)
        guard established, task === current else { return false }
        if answered {
            lastInbound = .now
            return true
        }
        established = false
        registeredConnectionGeneration = nil
        current.cancel(with: .goingAway, reason: nil)
        return false
    }

    private func startKeepalive(_ current: URLSessionWebSocketTask) {
        keepalive?.cancel()
        keepalive = nil
        guard let policy = liveness else { return }
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, policy.interval) * 1_000_000_000))
                guard !Task.isCancelled, let self, await self.probe(current, policy: policy) else { return }
            }
        }
    }

    private static func ping(_ task: URLSessionWebSocketTask, within timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let answer = PingAnswer(continuation)
            task.sendPing { error in answer.resolve(error == nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout)) { answer.resolve(false) }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> Duration {
        .milliseconds(Int64(max(0, min(seconds, 86400)) * 1000))
    }

    private static func claimsCurrentConnection(_ text: String) -> Bool {
        WorkReadRequest.claimsCurrentConnectionSemantics(frameText: text)
            || GuidanceRequest.claimsCurrentConnectionSemantics(frameText: text)
            || ConsoleSurfaceRequest.claimsCurrentConnectionSemantics(frameText: text)
            || SafetySurfaceRequest.claimsCurrentConnectionSemantics(frameText: text)
            || MeshSurfaceRequest.claimsCurrentConnectionSemantics(frameText: text)
            || ViewportSnapshotRequest.claimsCurrentConnectionSemantics(frameText: text)
            || ComputerHostOutbound.claimsCurrentConnectionSemantics(frameText: text)
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
        if WorkContinuityRequest(frameText: text) != nil {
            guard let connection = InboundFrame.parse(text)?.payload["connection_generation"]?.stringValue,
                registeredConnectionGeneration == connection
            else { return false }
            return await sendCurrentOwnerSurfaceEvent(
                text, using: current,
                connectionGeneration: connection, isCurrent: isCurrent)
        }
        return await sendCurrentOwnerSurfaceEvent(text, using: current, isCurrent: isCurrent)
    }

    @discardableResult
    public func sendCurrentChromeEvent(
        _ text: String, isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard
            ConsoleSurfaceRequest(frameText: text) != nil || SafetySurfaceRequest(frameText: text) != nil
                || MeshSurfaceRequest(frameText: text) != nil,
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

    @discardableResult
    public func sendCurrentViewportEvent(
        _ text: String, isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard ViewportSnapshotRequest(frameText: text) != nil,
            established, let current = task, current.state == .running
        else { return false }
        return await sendCurrentOwnerSurfaceEvent(text, using: current, isCurrent: isCurrent)
    }

    @discardableResult
    public func sendCurrentComputerEvent(
        _ text: String, connectionGeneration: String, isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard ComputerHostOutbound.isBound(text, connectionGeneration: connectionGeneration),
            registeredConnectionGeneration == connectionGeneration, established,
            let current = task,
            current.state == .running
        else { return false }
        return await sendCurrentOwnerSurfaceEvent(
            text, using: current, connectionGeneration: connectionGeneration, isCurrent: isCurrent)
    }

    @discardableResult
    public func sendCurrentComputerDecision(
        _ text: String, isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard ComputerHostOutbound.isReviewDecision(text), established, let current = task,
            current.state == .running
        else { return false }
        return await sendCurrentOwnerSurfaceEvent(text, using: current, isCurrent: isCurrent)
    }

    @discardableResult
    public func sendCurrentApprovalDecision(
        _ text: String, connectionGeneration: String, isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard Self.isApprovalDecision(text), continuityUUID4(connectionGeneration) != nil,
            registeredConnectionGeneration == connectionGeneration, established,
            let current = task, current.state == .running
        else { return false }
        return await sendCurrentOwnerSurfaceEvent(
            text, using: current, connectionGeneration: connectionGeneration, isCurrent: isCurrent)
    }

    private static func isApprovalDecision(_ text: String) -> Bool {
        guard text.utf8.count <= 16384,
            let value = try? JSONValue.parse(Data(text.utf8)),
            let frame = value.objectValue,
            Set(frame.keys) == ["type", "action", "session_id", "submission_id", "request_generation", "payload"],
            frame["type"] == .string("ui_event"),
            let action = frame["action"]?.stringValue,
            ["authorize_action", "remote_op_decision"].contains(action),
            let submission = continuityUUID4(frame["submission_id"]?.stringValue),
            let request = continuityUUID4(frame["request_generation"]?.stringValue),
            let payload = frame["payload"]?.objectValue,
            payload["submission_id"] == .string(submission),
            payload["request_generation"] == .string(request),
            let decision = payload["decision"]?.stringValue,
            ["approve", "approve_and_resume", "grant_task", "decline"].contains(decision)
        else { return false }
        let idKey = action == "authorize_action" ? "hitl_request_id" : "proposal_id"
        return payload[idKey]?.stringValue.map { !$0.isEmpty && $0.count <= 200 } == true
            && Set(payload.keys).isSubset(of: [idKey, "decision", "submission_id", "request_generation"])
    }

    private func sendCurrentOwnerSurfaceEvent(
        _ text: String, using current: URLSessionWebSocketTask,
        connectionGeneration: String? = nil,
        isCurrent: @Sendable () async -> Bool
    ) async -> Bool {
        guard await isCurrent(), !Task.isCancelled,
            established, task === current, current.state == .running,
            connectionGeneration == nil || registeredConnectionGeneration == connectionGeneration
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
            guard let headers = await requestHeaders(), running else {
                continuation?.yield(.disconnected(reason: "waiting for session custody"))
                guard running else { break }
                try? await Task.sleep(nanoseconds: UInt64(backoffNext() * 1_000_000_000))
                continue
            }
            var request = NoStoreHTTP.request(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let task = NoStoreHTTP.session.webSocketTask(with: request)
            self.task = task
            established = false
            registeredConnectionGeneration = nil
            task.resume()

            guard let register = await onConnect?(), running else {
                task.cancel(with: .normalClosure, reason: nil)
                self.task = nil
                guard running else { break }
                continuation?.yield(.disconnected(reason: "waiting for credentials"))
                try? await Task.sleep(nanoseconds: UInt64(backoffNext() * 1_000_000_000))
                continue
            }
            if let registration = try? JSONValue.parse(Data(register.utf8)),
                registration["type"] == .string("register_ui"),
                let generation = registration["connection_generation"]?.stringValue, computerUUID(generation)
            {
                registeredConnectionGeneration = generation
            }
            task.send(.string(register)) { _ in }

            receive: while running {
                do {
                    let message = try await task.receive()
                    guard task.state == .running else { continue }
                    lastInbound = .now
                    let frame: InboundFrame?
                    switch message {
                    case .string(let text): frame = InboundFrame.parse(text)
                    case .data(let data):
                        frame = String(data: data, encoding: .utf8).flatMap(InboundFrame.parse)
                    @unknown default: frame = nil
                    }
                    var consumed = false
                    if !established, let onRegistration {
                        guard let frame, frame.name == "rote_config",
                            frame.payload["device_profile"]?["device_type"]?.stringValue == "macos",
                            !["chat_id", "connection_generation", "request_generation"].contains(where: {
                                frame.payload[$0] != nil
                            }), let generation = registeredConnectionGeneration
                        else {
                            if let frame, frame.name != "rote_config" { continuation?.yield(.frame(frame)) }
                            continue
                        }
                        guard await onRegistration(frame, generation), running, self.task === task else {
                            task.cancel(with: .normalClosure, reason: nil)
                            break receive
                        }
                        consumed = true
                    }
                    if !established {
                        established = true
                        backoff.reset()
                        startKeepalive(task)
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
                    if let frame, !consumed { continuation?.yield(.frame(frame)) }
                } catch {
                    established = false
                    registeredConnectionGeneration = nil
                    continuation?.yield(.disconnected(reason: error.localizedDescription))
                    break receive
                }
            }
            established = false
            registeredConnectionGeneration = nil
            keepalive?.cancel()
            keepalive = nil
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
