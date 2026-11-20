// Covers the voice model owner's load sharing, scheduler sharing, unload, memory pressure and idle timer against fake models.
// No test loads a real model or waits on the clock: loads and the idle sleep are held and released by latches.

import AstralVoiceRuntime
import XCTest

@testable import AstralDeep

private actor Latch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var arrived = false

    func wait() async {
        arrived = true
        for arrival in arrivals { arrival.resume() }
        arrivals.removeAll()
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilWaiting() async {
        if arrived { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor Count {
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

private final class FakeModel: VoiceRecognitionModel, VoiceTextModel, @unchecked Sendable {
    let unloads = Count()
    func unload() async { await unloads.increment() }
    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String { "heard" }
    func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class LoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var schedulers: [RuntimeScheduler] = []
    private var models: [FakeModel] = []
    let cancellations = Count()
    var gate: Latch?
    var failures = 0

    var loads: Int { lock.withLock { models.count } }
    var seenSchedulers: [RuntimeScheduler] { lock.withLock { schedulers } }
    var created: [FakeModel] { lock.withLock { models } }

    func load(_ scheduler: RuntimeScheduler) async throws -> FakeModel {
        let held = lock.withLock { () -> (Latch?, Bool) in
            schedulers.append(scheduler)
            let fail = failures > 0
            if fail { failures -= 1 }
            return (gate, fail)
        }
        if let latch = held.0 {
            await withTaskCancellationHandler {
                await latch.wait()
            } onCancel: {
                Task { await self.cancellations.increment() }
            }
        }
        if held.1 { throw VoiceRuntimeError.invalidConfiguration("fake load failed") }
        let model = FakeModel()
        lock.withLock { models.append(model) }
        return model
    }
}

final class VoiceModelOwnerTests: XCTestCase {
    private func makeOwner(
        recognition: LoadLog = LoadLog(), generation: LoadLog = LoadLog(),
        scheduler: RuntimeScheduler = RuntimeScheduler(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    ) -> VoiceModelOwner {
        VoiceModelOwner(
            loaders: VoiceModelOwner.Loaders(
                recognizer: { try await recognition.load($0) }, generator: { try await generation.load($0) }),
            scheduler: scheduler, sleep: sleep)
    }

    func testConcurrentRequestsShareOneLoadedInstance() async throws {
        let generation = LoadLog()
        let owner = makeOwner(generation: generation)
        async let first = owner.textGenerator()
        async let second = owner.textGenerator()
        let models = try await [first, second]
        XCTAssertTrue(models[0] as AnyObject === models[1] as AnyObject)
        let third = try await owner.textGenerator()
        XCTAssertTrue(models[0] as AnyObject === third as AnyObject)
        XCTAssertEqual(generation.loads, 1)
    }

    func testBothLoadersReceiveTheOwnersOneScheduler() async throws {
        let recognition = LoadLog()
        let generation = LoadLog()
        let scheduler = RuntimeScheduler()
        let owner = makeOwner(recognition: recognition, generation: generation, scheduler: scheduler)
        _ = try await owner.recognizer()
        _ = try await owner.textGenerator()
        XCTAssertTrue(owner.scheduler === scheduler)
        XCTAssertEqual(recognition.seenSchedulers.count, 1)
        XCTAssertEqual(generation.seenSchedulers.count, 1)
        XCTAssertTrue(recognition.seenSchedulers[0] === scheduler)
        XCTAssertTrue(generation.seenSchedulers[0] === scheduler)
    }

    func testTheSharedSchedulerIsTheDefault() async {
        let owner = VoiceModelOwner(
            loaders: VoiceModelOwner.Loaders(
                recognizer: { _ in FakeModel() }, generator: { _ in FakeModel() }))
        XCTAssertTrue(owner.scheduler === RuntimeScheduler.shared)
        XCTAssertEqual(VoiceModelOwner.defaultIdleLimit, .seconds(60))
    }

    func testUnloadReleasesBothModelsAndTheNextRequestLoadsAgain() async throws {
        let recognition = LoadLog()
        let generation = LoadLog()
        let owner = makeOwner(recognition: recognition, generation: generation)
        _ = try await owner.recognizer()
        _ = try await owner.textGenerator()
        let loaded = await owner.isLoaded
        XCTAssertTrue(loaded)
        await owner.unload()
        let unloaded = await owner.isLoaded
        XCTAssertFalse(unloaded)
        let recognizerUnloads = await recognition.created[0].unloads.value
        let generatorUnloads = await generation.created[0].unloads.value
        XCTAssertEqual(recognizerUnloads, 1)
        XCTAssertEqual(generatorUnloads, 1)
        _ = try await owner.textGenerator()
        XCTAssertEqual(generation.loads, 2)
    }

    func testUnloadWithNothingLoadedDoesNothing() async {
        let owner = makeOwner()
        await owner.unload()
        await owner.memoryPressure()
        let loaded = await owner.isLoaded
        XCTAssertFalse(loaded)
    }

    func testMemoryPressureDuringALoadDiscardsAndUnloadsTheLateModel() async throws {
        let generation = LoadLog()
        let gate = Latch()
        generation.gate = gate
        let owner = makeOwner(generation: generation)
        let request = Task { try await owner.textGenerator() }
        await gate.waitUntilWaiting()
        let pressure = Task { await owner.memoryPressure() }
        await generation.cancellations.wait(for: 1)
        await gate.release()
        await pressure.value
        do {
            _ = try await request.value
            XCTFail("the overtaken load must not be handed out")
        } catch is CancellationError {}
        XCTAssertEqual(generation.loads, 1)
        let unloads = await generation.created[0].unloads.value
        XCTAssertEqual(unloads, 1)
        let loaded = await owner.isLoaded
        XCTAssertFalse(loaded)
    }

    func testAFailedLoadIsNotCached() async throws {
        let generation = LoadLog()
        generation.failures = 1
        let owner = makeOwner(generation: generation)
        do {
            _ = try await owner.textGenerator()
            XCTFail("the first load fails")
        } catch let error as VoiceRuntimeError {
            XCTAssertEqual(error, .invalidConfiguration("fake load failed"))
        }
        _ = try await owner.textGenerator()
        XCTAssertEqual(generation.loads, 1)
    }

    func testTheModelsUnloadWhenTheIdleLimitPassesAfterTheLastHolderCloses() async throws {
        let generation = LoadLog()
        let gate = Latch()
        let owner = makeOwner(generation: generation) { _ in await gate.wait() }
        _ = try await owner.textGenerator()
        await owner.open()
        await owner.open()
        await owner.close()
        await owner.close()
        await gate.waitUntilWaiting()
        await gate.release()
        await generation.created[0].unloads.wait(for: 1)
        let loaded = await owner.isLoaded
        XCTAssertFalse(loaded)
    }

    func testReopeningBeforeTheIdleLimitKeepsTheModelsLoaded() async throws {
        let generation = LoadLog()
        let gate = Latch()
        let returned = Count()
        let owner = makeOwner(generation: generation) { _ in
            await gate.wait()
            await returned.increment()
        }
        _ = try await owner.textGenerator()
        await owner.open()
        await owner.close()
        await gate.waitUntilWaiting()
        await owner.open()
        await gate.release()
        await returned.wait(for: 1)
        for _ in 0..<20 { await Task.yield() }
        let stillLoaded = await owner.isLoaded
        XCTAssertTrue(stillLoaded)
        let unloads = await generation.created[0].unloads.value
        XCTAssertEqual(unloads, 0)
    }

    func testAnUnloadCancelsThePendingIdleTimer() async throws {
        let generation = LoadLog()
        let gate = Latch()
        let owner = makeOwner(generation: generation) { _ in await gate.wait() }
        _ = try await owner.textGenerator()
        await owner.open()
        await owner.close()
        await gate.waitUntilWaiting()
        await owner.unload()
        await gate.release()
        _ = try await owner.textGenerator()
        for _ in 0..<20 { await Task.yield() }
        let loaded = await owner.isLoaded
        XCTAssertTrue(loaded)
        XCTAssertEqual(generation.loads, 2)
    }

    func testClosingMoreThanOpenedIsIgnored() async {
        let owner = makeOwner()
        await owner.close()
        let loaded = await owner.isLoaded
        XCTAssertFalse(loaded)
    }
}
