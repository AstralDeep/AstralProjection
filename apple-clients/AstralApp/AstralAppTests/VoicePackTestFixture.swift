// Creates a verified tiny voice pack installation and fake session parts for tests of app readiness, the controller and the Watch relay.
// It uses the production pack store on staged local files, so no test loads a model, speaks or contacts a download service.

import AstralVoiceRuntime
import AstralVoiceSpeech
import CryptoKit
import Foundation

@testable import AstralDeep

nonisolated final class SessionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var events: [String] { lock.withLock { log } }
    func record(_ event: String) { lock.withLock { log.append(event) } }
}

nonisolated struct SilentRecognizer: VoiceRecognizing {
    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String { "" }
}

nonisolated struct SilentGenerator: VoiceTextGenerating {
    func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

nonisolated struct SilentSpeech: VoiceSpeaking {
    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

extension VoiceSessionParts {
    static func recording(
        _ recorder: SessionRecorder = SessionRecorder(), recognizer: any VoiceRecognizing = SilentRecognizer(),
        textGenerator: any VoiceTextGenerating = SilentGenerator(), speech: any VoiceSpeaking = SilentSpeech(),
        beginError: (any Error)? = nil
    ) -> VoiceSessionParts {
        VoiceSessionParts(
            recognizer: recognizer, textGenerator: textGenerator, speech: speech,
            begin: {
                recorder.record("begin")
                if let beginError { throw beginError }
            }, end: { recorder.record("end") },
            unload: { recorder.record("unload") })
    }

    static var silent: VoiceSessionParts { recording() }
}

@MainActor
struct VoicePackTestFixture {
    let controller: OnDeviceVoiceController
    let store: VoicePackStore
    let root: URL
    let recorder: SessionRecorder
    let manifest: VoicePackManifest

    static let supported = VoiceDeviceProfile(
        platform: .mac, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 16 << 30)

    static func tinyManifest() throws -> (VoicePackManifest, [String: Data]) {
        let bundled = try VoicePackManifest.bundled(in: Bundle(for: VoicePackStore.self))
        var contents: [String: Data] = [:]
        var files: [VoicePackManifest.File] = []
        for file in bundled.files {
            let data = Data("fixture \(file.path)".utf8)
            contents[file.path] = data
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files.append(
                VoicePackManifest.File(
                    repository: file.repository, revision: file.revision, path: file.path, bytes: Int64(data.count),
                    sha256: digest, part: file.part))
        }
        let manifest = VoicePackManifest(
            displayName: bundled.displayName, format: bundled.format, id: bundled.id, origin: bundled.origin,
            totalBytes: files.reduce(0) { $0 + $1.bytes }, files: files)
        return (manifest, contents)
    }

    static func make(
        installed: Bool, voice: Bool = true, device: VoiceDeviceProfile = supported,
        requestPermission: @escaping () async -> Bool = { true },
        makePipeline: @escaping OnDeviceVoiceController.PipelineFactory = { $0.pipeline(link: $1) },
        parts: ((SessionRecorder) -> VoiceSessionParts)? = nil
    ) async throws -> VoicePackTestFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (manifest, contents) = try tinyManifest()
        let store = VoicePackStore(
            manifest: manifest, root: root, device: device, localVoiceSupported: voice,
            network: FixedMeteredNetwork(isMetered: false), freeSpace: { _ in .max })
        if installed {
            for file in manifest.files where voice || file.unit == .model {
                let url = store.stagingDirectory.appendingPathComponent(file.stagedPath)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents[file.path]!.write(to: url)
            }
            await store.startDownload(allowMetered: false)
            guard store.state == .installed else { throw CocoaError(.fileWriteUnknown) }
        }
        let recorder = SessionRecorder()
        let controller = OnDeviceVoiceController(
            store: store, parts: parts?(recorder) ?? .recording(recorder), requestPermission: requestPermission,
            makePipeline: makePipeline)
        return VoicePackTestFixture(
            controller: controller, store: store, root: root, recorder: recorder, manifest: manifest)
    }

    func removeVoiceUnit() async {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("voice"))
        await store.refresh()
    }
}

nonisolated struct FixedMeteredNetwork: VoiceModelNetworkCost {
    let isMetered: Bool
}
