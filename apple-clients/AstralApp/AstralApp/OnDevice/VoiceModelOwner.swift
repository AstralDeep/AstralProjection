// Owns the loaded recognizer and text generator so the voice session and the kernel's on-device model share one LFM2.5 instance and one RuntimeScheduler.
// The next layer supplies loaders built on AstralVoiceRuntime; this file only decides when they run, when their models unload and how a load that was overtaken by an unload is discarded.

import AstralVoiceRuntime
import Foundation

nonisolated protocol LoadedVoiceModel: Sendable {
    func unload() async
}

nonisolated protocol VoiceRecognitionModel: VoiceRecognizing, LoadedVoiceModel {}

nonisolated protocol VoiceTextModel: VoiceTextGenerating, LoadedVoiceModel {}

actor VoiceModelOwner {
    struct Loaders: Sendable {
        let recognizer: @Sendable (RuntimeScheduler) async throws -> any VoiceRecognitionModel
        let generator: @Sendable (RuntimeScheduler) async throws -> any VoiceTextModel
    }

    static let defaultIdleLimit = Duration.seconds(60)

    nonisolated let scheduler: RuntimeScheduler
    private let loaders: Loaders
    private let idleLimit: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var recognizerLoad: Task<any VoiceRecognitionModel, Error>?
    private var generatorLoad: Task<any VoiceTextModel, Error>?
    private var generation = 0
    private var holders = 0
    private var idleTimer: Task<Void, Never>?
    private var idleEpoch = 0

    init(
        loaders: Loaders,
        scheduler: RuntimeScheduler = .shared,
        idleLimit: Duration = VoiceModelOwner.defaultIdleLimit,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.loaders = loaders
        self.scheduler = scheduler
        self.idleLimit = idleLimit
        self.sleep = sleep
    }

    var isLoaded: Bool { recognizerLoad != nil || generatorLoad != nil }

    func recognizer() async throws -> any VoiceRecognitionModel {
        let attempt = generation
        if recognizerLoad == nil {
            let load = loaders.recognizer
            let scheduler = scheduler
            recognizerLoad = Task { try await load(scheduler) }
        }
        do {
            let model = try await recognizerLoad!.value
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            return model
        } catch {
            if generation == attempt { recognizerLoad = nil }
            throw error
        }
    }

    func textGenerator() async throws -> any VoiceTextModel {
        let attempt = generation
        if generatorLoad == nil {
            let load = loaders.generator
            let scheduler = scheduler
            generatorLoad = Task { try await load(scheduler) }
        }
        do {
            let model = try await generatorLoad!.value
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            return model
        } catch {
            if generation == attempt { generatorLoad = nil }
            throw error
        }
    }

    func open() {
        holders += 1
        cancelIdleTimer()
    }

    func close() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        cancelIdleTimer()
        let epoch = idleEpoch
        let sleep = sleep
        let limit = idleLimit
        idleTimer = Task { [weak self] in
            do { try await sleep(limit) } catch { return }
            await self?.idleLimitReached(epoch)
        }
    }

    func memoryPressure() async {
        await unload()
    }

    func unload() async {
        generation += 1
        cancelIdleTimer()
        let recognizer = recognizerLoad
        let generator = generatorLoad
        recognizerLoad = nil
        generatorLoad = nil
        recognizer?.cancel()
        generator?.cancel()
        if let model = try? await recognizer?.value { await model.unload() }
        if let model = try? await generator?.value { await model.unload() }
    }

    private func idleLimitReached(_ epoch: Int) async {
        guard epoch == idleEpoch, holders == 0 else { return }
        await unload()
    }

    private func cancelIdleTimer() {
        idleEpoch += 1
        idleTimer?.cancel()
        idleTimer = nil
    }
}
