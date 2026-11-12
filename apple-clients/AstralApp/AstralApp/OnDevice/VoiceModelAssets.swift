// Offers on-device speech model downloads with their size shown first and downloads only after the owner confirms that exact offer.
// VoicePipeline setup uses it when the newest transcriber's assets are missing, and it never starts a download on its own.

import Foundation
import Speech

nonisolated struct VoiceModelDownloadOffer: Equatable, Sendable {
    let identifier: String
    let displayName: String
    let sizeBytes: Int64?

    var sizeDescription: String {
        guard let sizeBytes else { return "Size not reported by the system" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

nonisolated enum VoiceModelAssetStatus: Equatable, Sendable {
    case ready
    case downloadRequired(VoiceModelDownloadOffer)
    case downloading
    case unsupported
}

nonisolated protocol VoiceModelAssetProvider: Sendable {
    func status() async -> VoiceModelAssetStatus
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
}

@MainActor
final class VoiceModelDownloadCoordinator {
    enum State: Equatable {
        case idle
        case ready
        case offered(VoiceModelDownloadOffer)
        case confirmed(VoiceModelDownloadOffer)
        case downloading(fraction: Double)
        case failed(String)
        case unsupported
    }

    private(set) var state: State = .idle {
        didSet { onChange?(state) }
    }
    var onChange: ((State) -> Void)?

    private let provider: VoiceModelAssetProvider

    init(provider: VoiceModelAssetProvider) {
        self.provider = provider
    }

    func refresh() async {
        switch await provider.status() {
        case .ready: state = .ready
        case .unsupported: state = .unsupported
        case .downloading: state = .downloading(fraction: 0)
        case .downloadRequired(let offer): state = .offered(offer)
        }
    }

    func confirm() {
        guard case .offered(let offer) = state else { return }
        state = .confirmed(offer)
    }

    func decline() {
        guard case .confirmed(let offer) = state else { return }
        state = .offered(offer)
    }

    func download() async {
        guard case .confirmed = state else { return }
        state = .downloading(fraction: 0)
        do {
            try await provider.download { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction: min(1, max(0, fraction)))
                }
            }
            await refresh()
        } catch {
            state = .failed("download_failed")
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
nonisolated struct SpeechTranscriberAssetProvider: VoiceModelAssetProvider {
    let locale: Locale

    func status() async -> VoiceModelAssetStatus {
        guard SpeechTranscriber.isAvailable,
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return .unsupported }
        let module = Self.module(supported)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .ready
        case .downloading: return .downloading
        case .unsupported: return .unsupported
        case .supported:
            return .downloadRequired(
                VoiceModelDownloadOffer(
                    identifier: "speech_transcriber_\(supported.identifier)",
                    displayName: "On-device speech recognition (\(supported.identifier))",
                    sizeBytes: nil))
        @unknown default: return .unsupported
        }
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
            let request = try await AssetInventory.assetInstallationRequest(supporting: [Self.module(supported)])
        else { return }
        let watcher = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    private static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }
}
