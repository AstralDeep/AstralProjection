// Fakes shared by the Rumble recognition and text tests: a model that scripts its answers and failures, a load log and a counter with waiters.
// They stand in for AstralVoiceRuntime so no test loads a model or waits on the clock.

import AstralVoiceRuntime
import XCTest

@testable import AstralDeep

actor RumbleCounter {
    private(set) var value = 0
    private var watchers: [(Int, CheckedContinuation<Void, Never>)] = []

    func increment() {
        value += 1
        let ready = watchers.filter { $0.0 <= value }
        watchers.removeAll { $0.0 <= value }
        for (_, continuation) in ready { continuation.resume() }
    }

    func wait(for target: Int) async {
        if value >= target { return }
        await withCheckedContinuation { watchers.append((target, $0)) }
    }
}

actor RumbleGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

final class RumbleFakeModel: VoiceRecognitionModel, VoiceTextModel, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Error] = []
    private var requestLog: [OnDeviceRequest] = []
    var reply = "four"
    let unloads = RumbleCounter()

    var requests: [OnDeviceRequest] { lock.withLock { requestLog } }

    func failNext(_ error: Error) { lock.withLock { failures.append(error) } }

    private func nextFailure() -> Error? { lock.withLock { failures.isEmpty ? nil : failures.removeFirst() } }

    func unload() async { await unloads.increment() }

    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String {
        if let failure = nextFailure() { throw failure }
        return "heard"
    }

    func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { requestLog.append(request) }
        let failure = nextFailure()
        let reply = reply
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.yield(reply)
                continuation.finish()
            }
        }
    }
}

final class RumbleLoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [RumbleFakeModel] = []
    private var schedulerLog: [RuntimeScheduler] = []
    var failure: Error?

    var created: [RumbleFakeModel] { lock.withLock { models } }
    var schedulers: [RuntimeScheduler] { lock.withLock { schedulerLog } }

    func load(_ scheduler: RuntimeScheduler) async throws -> RumbleFakeModel {
        if let failure { throw failure }
        let model = RumbleFakeModel()
        lock.withLock {
            models.append(model)
            schedulerLog.append(scheduler)
        }
        return model
    }
}

struct RumbleHarness {
    let owner: VoiceModelOwner
    let recognition: RumbleLoadLog
    let generation: RumbleLoadLog
    let idleSleeps: RumbleCounter
    let idleGate: RumbleGate
    let durations: RumbleDurations

    init(scheduler: RuntimeScheduler = RuntimeScheduler()) {
        let recognition = RumbleLoadLog()
        let generation = RumbleLoadLog()
        let sleeps = RumbleCounter()
        let gate = RumbleGate()
        let durations = RumbleDurations()
        owner = VoiceModelOwner(
            loaders: VoiceModelOwner.Loaders(
                recognizer: { try await recognition.load($0) }, generator: { try await generation.load($0) }),
            scheduler: scheduler,
            sleep: { duration in
                await durations.record(duration)
                await sleeps.increment()
                await gate.wait()
            })
        self.recognition = recognition
        self.generation = generation
        idleSleeps = sleeps
        idleGate = gate
        self.durations = durations
    }
}

actor RumbleDurations {
    private(set) var values: [Duration] = []
    func record(_ duration: Duration) { values.append(duration) }
}

func rumbleRequest(_ text: String = "What is two plus two?", maxTokens: Int = 80) -> OnDeviceRequest {
    OnDeviceRequest(messages: [.init(role: .user, text: text)], schemaJSON: nil, maxTokens: maxTokens)
}
