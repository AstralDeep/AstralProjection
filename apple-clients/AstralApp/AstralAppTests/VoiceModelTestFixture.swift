// Creates a verified tiny voice installation for tests of app readiness and project routing.
// It uses the production model store without loading MLX or contacting a download service.

import CryptoKit
import Foundation

@testable import AstralDeep

@MainActor
struct VoiceModelTestFixture {
    let controller: OnDeviceVoiceController
    let root: URL

    static func installed() async throws -> VoiceModelTestFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data("x".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let files = VoiceModelManifest.requiredFiles.map { VoiceModelManifest.File(path: $0, bytes: 1, sha256: digest) }
        let manifest = VoiceModelManifest(
            displayName: "LFM3-Audio-2B (3-bit)", format: VoiceModelManifest.supportedFormat,
            id: "lfm3-audio-2b-3bit-mlx", license: "LFM Open License v1.0",
            repository: "Kentucky-Open-Science/LFM3-Audio-2B-MLX-3bit", revision: "main", runtime: "mlx",
            source: "LiquidAI/LFM3-Audio-2B-MLX-bf16", totalBytes: Int64(files.count), files: files)
        let device = VoiceDeviceProfile(
            platform: .mac, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 16 << 30)
        let store = VoiceModelStore(manifest: manifest, root: root, device: device, freeSpace: { _ in .max })
        for file in files {
            let url = store.stagingDirectory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        await store.startDownload(allowMetered: false)
        guard store.state == .installed else { throw CocoaError(.fileWriteUnknown) }
        return VoiceModelTestFixture(controller: OnDeviceVoiceController(store: store), root: root)
    }
}
