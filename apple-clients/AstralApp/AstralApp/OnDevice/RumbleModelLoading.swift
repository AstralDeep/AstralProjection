// Builds the VoiceModelOwner loaders: it finds the three installed GGUF files, re-checks each one's size and SHA-256 against the pack manifest, then loads it through AstralVoiceRuntime.
// Devices load with the default accelerated configuration and the simulator loads CPU-only; a file that is missing or fails its digest is never handed to the runtime.

import AstralVoiceRuntime
import Foundation

nonisolated struct RumbleModelLoading: Sendable {
    static let recognitionPath = "rumble/Rumble-2-Flash-AD-Q5_K_M.gguf"
    static let audioEncoderPath = "rumble/mmproj-Rumble-2-Flash-Q8_0.gguf"
    static let textPath = "chat-1.2b/LFM2.5-1.2B-Instruct-Q4_K_M.gguf"

    typealias RecognizerLoad =
        @Sendable (URL, URL, RuntimeConfiguration, RuntimeScheduler) async throws ->
        SpeechRecognizer
    typealias GeneratorLoad = @Sendable (URL, RuntimeConfiguration, RuntimeScheduler) async throws -> TextGenerator

    let manifest: VoicePackManifest
    let root: URL
    let device: VoiceDeviceProfile
    let loadRecognizer: RecognizerLoad
    let loadGenerator: GeneratorLoad

    init(
        manifest: VoicePackManifest, root: URL = VoicePackStore.defaultRoot(), device: VoiceDeviceProfile = .current,
        loadRecognizer: @escaping RecognizerLoad = {
            try await SpeechRecognizer.load(model: $0, audioEncoder: $1, configuration: $2, scheduler: $3)
        },
        loadGenerator: @escaping GeneratorLoad = {
            try await TextGenerator.load(model: $0, configuration: $1, scheduler: $2)
        }
    ) {
        self.manifest = manifest
        self.root = root
        self.device = device
        self.loadRecognizer = loadRecognizer
        self.loadGenerator = loadGenerator
    }

    var loaders: VoiceModelOwner.Loaders {
        VoiceModelOwner.Loaders(
            recognizer: { scheduler in
                let (model, encoder) = try await self.verified(Self.recognitionPath, Self.audioEncoderPath)
                try Task.checkCancellation()
                let recognizer = try await self.loadRecognizer(
                    model, encoder, self.configuration(contextTokens: 2_048), scheduler)
                return RumbleRecognitionModel(recognizer: recognizer)
            },
            generator: { scheduler in
                let (model, _) = try await self.verified(Self.textPath, nil)
                try Task.checkCancellation()
                let generator = try await self.loadGenerator(model, self.configuration(contextTokens: 4_096), scheduler)
                return RumbleTextModel(generator: generator)
            })
    }

    func configuration(contextTokens: Int) -> RuntimeConfiguration {
        RuntimeConfiguration(compute: device.isSimulator ? .cpuOnly : .automatic, contextTokens: contextTokens)
    }

    var isInstalled: Bool {
        guard supportsDevice else { return false }
        return VoicePackStore.installedUnits(manifest: manifest, root: root, units: [.model]).contains(.model)
    }

    private var supportsDevice: Bool {
        guard let reason = VoiceDeviceSupport.unsupportedReason(for: device) else { return true }
        return reason == .simulator
    }

    private func verified(_ first: String, _ second: String?) async throws -> (URL, URL) {
        guard supportsDevice else { throw VoiceModelRuntimeError.deviceUnsupported }
        let paths = [first] + (second.map { [$0] } ?? [])
        let directory = root.appendingPathComponent(VoicePackManifest.Unit.model.folder, isDirectory: true)
        var urls: [URL] = []
        for path in paths {
            guard let file = manifest.files.first(where: { $0.path == path }) else {
                throw VoiceModelRuntimeError.filesMissing(path)
            }
            let url = directory.appendingPathComponent(path)
            let outcome = await Task.detached { Self.check(url, against: file) }.value
            if let failure = outcome { throw failure }
            urls.append(url)
        }
        return (urls[0], urls.count > 1 ? urls[1] : urls[0])
    }

    private nonisolated static func check(_ url: URL, against file: VoicePackManifest.File) -> VoiceModelRuntimeError? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else { return .filesMissing(file.path) }
        guard (attributes?[.size] as? NSNumber)?.int64Value == file.bytes,
            (try? VoiceModelDigest.sha256(of: url)) == file.sha256
        else { return .digestMismatch(file.path) }
        return nil
    }
}
