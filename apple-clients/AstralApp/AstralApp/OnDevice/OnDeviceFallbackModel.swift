// Prefers Apple's model and falls back to verified installed LFM3 weights for plain local answers on eligible devices.
// Voice and text share one lazy inference instance; retirement fences answers from deleted assets.

import AstralVoiceModel
import Foundation

nonisolated struct PreferredOnDeviceModel: AstralOnDeviceModelWarmable {
    let preferred: any AstralOnDeviceModel
    let fallback: any AstralOnDeviceModel

    init(
        preferred: any AstralOnDeviceModel = FoundationModelsOnDeviceModel(),
        fallback: any AstralOnDeviceModel = VerifiedLFM3OnDeviceModel()
    ) {
        self.preferred = preferred
        self.fallback = fallback
    }

    func available() -> Bool { preferred.available() || fallback.available() }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        if preferred.available() { return await preferred.complete(request) }
        return await fallback.complete(request)
    }

    func prewarm() async {
        if preferred.available(), let warmable = preferred as? any AstralOnDeviceModelWarmable {
            await warmable.prewarm()
        }
    }
}

nonisolated struct VerifiedLFM3OnDeviceModel: AstralOnDeviceModel {
    private let cache: VoiceInferenceCache
    private let installed: @Sendable () -> Bool
    private let verifiedDirectory: @Sendable () async -> URL?

    init(
        cache: VoiceInferenceCache = .shared, installed: @escaping @Sendable () -> Bool,
        verifiedDirectory: @escaping @Sendable () async -> URL?
    ) {
        self.cache = cache
        self.installed = installed
        self.verifiedDirectory = verifiedDirectory
    }

    init() {
        let assets = InstalledVoiceModel()
        self.init(installed: { assets.available() }, verifiedDirectory: { await assets.verifiedDirectory() })
    }

    func available() -> Bool { installed() }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        guard request.schemaJSON == nil else { return .failed(.schemaUnsupported) }
        guard OnDevicePromptComposer.compose(request.messages) != nil else { return .failed(.emptyRequest) }
        guard request.messages.count <= 128,
            request.messages.reduce(0, { $0 + $1.text.utf8.count }) <= 65_536
        else { return .failed(.contextTooLarge) }
        guard available() else { return .unavailable(.modelNotReady) }
        do {
            try Task.checkCancellation()
            guard let directory = await verifiedDirectory() else { return .unavailable(.modelNotReady) }
            try Task.checkCancellation()
            let bounded = OnDeviceRequest(
                messages: request.messages, schemaJSON: nil, maxTokens: min(2_048, max(1, request.maxTokens)))
            let text = try await cache.text(bounded, directory: directory)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed(.generationFailed)
            }
            return .text(text)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.generationFailed)
        }
    }
}

nonisolated struct InstalledVoiceModel {
    let manifest: VoiceModelManifest?
    let root: URL
    let device: VoiceDeviceProfile

    init(
        manifest: VoiceModelManifest? = try? .bundled(), root: URL = VoiceModelStore.defaultRoot(),
        device: VoiceDeviceProfile = .current
    ) {
        self.manifest = manifest
        self.root = root
        self.device = device
    }

    func available() -> Bool {
        guard VoiceDeviceSupport.unsupportedReason(for: device) == nil, let manifest else { return false }
        return VoiceModelStore.installedState(manifest: manifest, root: root) == .installed
    }

    func verifiedDirectory() async -> URL? {
        guard VoiceDeviceSupport.unsupportedReason(for: device) == nil, let manifest else { return nil }
        let root = root
        let verified = await Task.detached {
            VoiceModelStore.installedState(manifest: manifest, root: root, verifyDigests: true) == .installed
        }.value
        return verified ? root.appendingPathComponent("model", isDirectory: true) : nil
    }
}

actor VoiceInferenceCache {
    static let shared = VoiceInferenceCache { directory in
        try await Task.detached { MLXVoiceInference(engine: try LFM3AudioEngine(directory: directory)) }.value
    }

    private let makeInference: @Sendable (URL) async throws -> any VoiceModelInference
    private var directory: URL?
    private var loading: Task<any VoiceModelInference, Error>?
    private var generation = UUID()
    private var deletions = 0

    init(makeInference: @escaping @Sendable (URL) async throws -> any VoiceModelInference) {
        self.makeInference = makeInference
    }

    func inference(directory: URL) async throws -> any VoiceModelInference {
        try await lease(directory: directory).0
    }

    private func lease(directory: URL) async throws -> (any VoiceModelInference, UUID) {
        guard deletions == 0 else { throw CancellationError() }
        if self.directory != directory {
            retire()
            self.directory = directory
        }
        if loading == nil {
            generation = UUID()
            let makeInference = makeInference
            loading = Task { try await makeInference(directory) }
        }
        let attempt = generation
        let inference: any VoiceModelInference
        do {
            inference = try await loading!.value
        } catch {
            if generation == attempt { loading = nil }
            throw error
        }
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        return (inference, attempt)
    }

    func text(_ request: OnDeviceRequest, directory: URL) async throws -> String {
        let (inference, attempt) = try await lease(directory: directory)
        let text = try await inference.acknowledgement(request)
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        return text
    }

    func retire() {
        generation = UUID()
        loading?.cancel()
        loading = nil
        directory = nil
    }

    func beginDeletion() {
        deletions += 1
        retire()
    }

    func endDeletion() {
        guard deletions > 0 else { return }
        retire()
        deletions -= 1
    }
}
