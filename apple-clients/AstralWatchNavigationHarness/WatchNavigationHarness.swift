// Test-only navigation harness app, compiled by no shipped target, that drives WatchHomeView and
// WatchGuidanceSurfaceView UI tests against a scripted loopback peer with an optional controlled Work clock
// instead of WatchModel's real login and token store.

import AstralCore
import Observation
import SwiftUI

@main
struct WatchNavigationHarnessApp: App {
    @State private var session = WatchNavigationSession()

    init() {
        ConsoleTypography.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if session.ready {
                    WatchNavigationView()
                        .environment(session.model)
                        .font(ConsoleTypography.body)
                        .tint(session.model.theme.palette.primary)
                        .foregroundStyle(session.model.theme.palette.text)
                        .background(session.model.theme.palette.bg)
                } else {
                    Text("Connecting test peer")
                }
            }
            .task { await session.run() }
        }
    }
}

@MainActor
@Observable
private final class WatchNavigationSession {
    let model: WatchModel
    var ready = false
    private let socket: WSClient
    private let defaults: UserDefaults
    private let suite: String
    private let workClock: NavigationClock?

    init() {
        let raw = ProcessInfo.processInfo.environment["ASTRAL_WATCH_NAVIGATION_PEER"] ?? ""
        guard let url = URL(string: raw), url.scheme == "ws", url.host == "127.0.0.1",
            let port = url.port, (1...65535).contains(port), url.path == "/watch-navigation",
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { fatalError("A test-owned loopback peer is required") }
        suite = "WatchNavigationHarness.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        socket = WSClient(url: url)
        workClock =
            ProcessInfo.processInfo.environment["ASTRAL_WATCH_NAVIGATION_CLOCK"] == "controlled"
            ? NavigationClock() : nil
        model = WatchModel(conversationResumeStore: ConversationResumeStore(defaults: defaults), webSocket: socket)
        if let workClock { model.workReadClock = workClock }
        model.serverBase = URL(string: "http://127.0.0.1:\(port)")!
        model.phase = .signedIn
        model.accountName = "Synthetic local account"
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
    }

    func run() async {
        let events = await socket.events()
        let lifetime = Task {
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            await socket.stop()
        }
        defer {
            lifetime.cancel()
            defaults.removePersistentDomain(forName: suite)
        }
        await socket.start(onConnect: { [model] in
            await model.registrationFrame(token: "synthetic-loopback-only", resumed: false)
        })
        for await event in events {
            if Task.isCancelled { break }
            if case .frame(let frame) = event, frame.name == "navigation_test_clock" {
                await advanceClock(frame)
                continue
            }
            await model.handle(event)
            if case .frame(let frame) = event,
                case .content = WatchHistoryUpdate(frame: frame), !model.workControls.isEmpty
            {
                ready = true
            }
        }
        await socket.stop()
        await model.handle(.disconnected(reason: "The navigation test peer closed."))
    }

    private func advanceClock(_ frame: InboundFrame) async {
        guard let workClock, let command = frame.payload["command_id"]?.stringValue,
            UUID(uuidString: command)?.uuidString.lowercased() == command
        else { return }
        guard let fields = frame.payload.objectValue,
            Set(fields.keys) == ["type", "command_id", "request_generation", "milliseconds"]
                || Set(fields.keys)
                    == ["type", "command_id", "request_generation", "milliseconds", "empty_registration_probe"],
            let generation = frame.payload["request_generation"]?.stringValue,
            UUID(uuidString: generation)?.uuidString.lowercased() == generation,
            let milliseconds = frame.payload["milliseconds"]?.numberValue,
            milliseconds.rounded() == milliseconds, (0...10000).contains(milliseconds),
            fields["empty_registration_probe"] == nil
                || (fields["empty_registration_probe"] == .bool(true) && milliseconds == 0)
        else {
            await acknowledgeClock(command, status: "rejected")
            return
        }
        guard model.workReadState.generation == generation, model.workVisible else {
            await acknowledgeClock(command, status: "retired")
            return
        }
        let probe = fields["empty_registration_probe"] == .bool(true)
        let registrationClock = probe ? NavigationClock() : workClock
        let waiting = Task {
            await registrationClock.waitForSleeper {
                if probe { Task { await self.acknowledgeClock(command, status: "waiting") } }
            }
        }
        withObservationTracking {
            _ = model.workReadState.generation
        } onChange: {
            waiting.cancel()
        }
        let registered = await withTaskCancellationHandler {
            await waiting.value
        } onCancel: {
            waiting.cancel()
        }
        guard registered, !Task.isCancelled, model.workReadState.generation == generation, model.workVisible else {
            await acknowledgeClock(command, status: "retired")
            return
        }
        workClock.advance(by: .milliseconds(Int64(milliseconds)))
        await acknowledgeClock(command, status: "advanced")
    }

    private func acknowledgeClock(_ command: String, status: String) async {
        await socket.send(
            Outbound.uiEvent(
                action: "navigation_test_clock_ack", sessionId: nil,
                payload: .object(["command_id": .string(command), "status": .string(status)])))
    }
}

private nonisolated final class NavigationClock: Clock, @unchecked Sendable {
    nonisolated struct Instant: InstantProtocol {
        let offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var registration: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (outcome, waiter) = lock.withLock {
                    () -> (Result<Void, Error>?, CheckedContinuation<Bool, Never>?) in
                    if Task.isCancelled { return (.failure(CancellationError()), nil) }
                    if deadline <= current { return (.success(()), nil) }
                    sleepers[id] = (deadline, continuation)
                    defer { registration = nil }
                    return (nil, registration?.continuation)
                }
                if let outcome { continuation.resume(with: outcome) }
                waiter?.resume(returning: true)
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitForSleeper(onRegistration: @Sendable () -> Void) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let ready = lock.withLock { () -> Bool? in
                    if Task.isCancelled { return false }
                    guard sleepers.isEmpty else { return true }
                    registration = (id, continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) } else { onRegistration() }
            }
        } onCancel: {
            let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                guard registration?.id == id else { return nil }
                defer { registration = nil }
                return registration?.continuation
            }
            pending?.resume(returning: false)
        }
    }

    func advance(by duration: Swift.Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}
