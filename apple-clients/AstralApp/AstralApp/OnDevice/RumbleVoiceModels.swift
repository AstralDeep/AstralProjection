// Composes the one VoiceModelOwner, the system lifecycle observer and the recognizer, text generator and kernel model that all read from it.
// The voice session opens and closes it around a conversation, and the kernel's on-device fallback shares the same loaded LFM2.5 and RuntimeScheduler.

import Foundation

nonisolated final class RumbleVoiceModels: Sendable {
    static let shared = RumbleVoiceModels.standard()

    let owner: VoiceModelOwner
    let recognizer: any VoiceRecognizing
    let textGenerator: any VoiceTextGenerating
    let onDeviceModel: LFM25OnDeviceModel
    private let observer: VoiceModelLifecycleObserver

    init(
        owner: VoiceModelOwner, installed: @escaping @Sendable () -> Bool,
        lifecycle: VoiceModelLifecycleObserver.Sources = .system()
    ) {
        self.owner = owner
        recognizer = OwnedRecognizer(owner: owner)
        textGenerator = OwnedTextGenerator(owner: owner)
        onDeviceModel = LFM25OnDeviceModel(owner: owner, installed: installed)
        observer = VoiceModelLifecycleObserver(owner: owner, sources: lifecycle)
        observer.start()
    }

    static func standard(
        root: URL = VoicePackStore.defaultRoot(), device: VoiceDeviceProfile = .current
    ) -> RumbleVoiceModels {
        guard let manifest = try? VoicePackManifest.bundled() else {
            let unavailable = VoiceModelRuntimeError.filesMissing("voice-pack-manifest.json")
            return RumbleVoiceModels(
                owner: VoiceModelOwner(
                    loaders: VoiceModelOwner.Loaders(recognizer: { _ in throw unavailable }, generator: { _ in throw unavailable })),
                installed: { false })
        }
        let loading = RumbleModelLoading(manifest: manifest, root: root, device: device)
        return RumbleVoiceModels(owner: VoiceModelOwner(loaders: loading.loaders), installed: { loading.isInstalled })
    }

    func beginSession() async {
        await owner.open()
        async let recognition = try? owner.recognizer()
        async let generation = try? owner.textGenerator()
        _ = await (recognition, generation)
    }

    func endSession() async {
        await owner.close()
    }

    deinit { observer.stop() }
}
