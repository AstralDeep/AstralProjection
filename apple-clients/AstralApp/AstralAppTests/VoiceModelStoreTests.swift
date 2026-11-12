// Exercises the pinned voice model's validation, installation and recovery using tiny local files.
// No test downloads production weights or contacts a model service.

import CryptoKit
import XCTest

@testable import AstralDeep

@MainActor
final class VoiceModelStoreTests: XCTestCase {
    private var root: URL!
    private let supported = VoiceDeviceProfile(
        platform: .mac, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 16 << 30)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: root)
    }

    private func manifest(overrides: [String: Any] = [:]) throws -> VoiceModelManifest {
        var fields: [String: Any] = [
            "display_name": "LFM3-Audio-2B (3-bit)", "format": VoiceModelManifest.supportedFormat,
            "id": "lfm3-audio-2b-3bit-mlx", "license": "LFM Open License v1.0",
            "repository": "Kentucky-Open-Science/LFM3-Audio-2B-MLX-3bit", "revision": "main", "runtime": "mlx",
            "source": "LiquidAI/LFM3-Audio-2B-MLX-bf16@452469a1afe66dd4932d0e9237603229fa606c0d",
        ]
        let files = VoiceModelManifest.requiredFiles.map { path -> [String: Any] in
            let data = Data(path.utf8)
            return [
                "path": path, "bytes": data.count,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            ]
        }
        fields["files"] = files
        fields["total_bytes"] = VoiceModelManifest.requiredFiles.reduce(0) { $0 + $1.utf8.count }
        for (key, value) in overrides { fields[key] = value }
        return try VoiceModelManifest.decode(JSONSerialization.data(withJSONObject: fields))
    }

    private func store(_ manifest: VoiceModelManifest, space: Int64 = .max) -> VoiceModelStore {
        VoiceModelStore(
            manifest: manifest, root: root, device: supported, freeSpace: { _ in space },
            noticeText: { "Model attribution" })
    }

    private func stage(_ manifest: VoiceModelManifest) throws {
        for file in manifest.files {
            let url = root.appendingPathComponent("staging").appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.path.utf8).write(to: url)
        }
    }

    func testManifestRejectsAnUnrelatedRepository() throws {
        XCTAssertThrowsError(try manifest(overrides: ["repository": "other/unreviewed-model"]))
    }

    func testManifestRejectsTraversalDuplicateDigestAndTotals() throws {
        let valid = try manifest()
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var files = try XCTUnwrap(fields["files"] as? [[String: Any]])
        for path in ["../config.json", "/config.json", "a//b", "a\\b", ".installed.json", "NOTICE", "a?b"] {
            files[0]["path"] = path
            fields["files"] = files
            XCTAssertThrowsError(try VoiceModelManifest.decode(JSONSerialization.data(withJSONObject: fields)), path)
        }
        fields["files"] = valid.files.map { ["path": $0.path, "bytes": $0.bytes, "sha256": $0.sha256] } + [files[1]]
        XCTAssertThrowsError(try VoiceModelManifest.decode(JSONSerialization.data(withJSONObject: fields)))
        XCTAssertThrowsError(try manifest(overrides: ["total_bytes": -1]))
        XCTAssertThrowsError(try manifest(overrides: ["runtime": "system_speech"]))
    }

    func testCompleteVerifiedFilesInstallAtomicallyWithAttribution() async throws {
        let manifest = try manifest()
        try stage(manifest)
        let store = store(manifest)
        XCTAssertNil(store.installedDirectory)
        await store.startDownload(allowMetered: false)
        XCTAssertEqual(store.state, .installed)
        let installed = try XCTUnwrap(store.installedDirectory)
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("NOTICE"), encoding: .utf8), "Model attribution")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingDirectory.path))
        XCTAssertEqual(self.store(manifest).state, .installed)
    }

    func testCorruptDownloadIsDiscardedAndCanBeRetried() async throws {
        let manifest = try manifest()
        try stage(manifest)
        let first = manifest.files[0]
        let url = root.appendingPathComponent("staging").appendingPathComponent(first.path)
        try Data(repeating: 0, count: Int(first.bytes)).write(to: url)
        let store = store(manifest)
        await store.startDownload(allowMetered: false)
        XCTAssertEqual(store.state, .failed(.checksumMismatch(path: first.path)))
        XCTAssertNil(store.installedDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try Data(first.path.utf8).write(to: url)
        await store.startDownload(allowMetered: false)
        XCTAssertEqual(store.state, .installed)
    }

    func testTruncatedFileFailsSizeValidation() async throws {
        let manifest = try manifest()
        try stage(manifest)
        let first = manifest.files[0]
        try Data().write(to: root.appendingPathComponent("staging").appendingPathComponent(first.path))
        let store = store(manifest)
        await store.startDownload(allowMetered: false)
        XCTAssertEqual(store.state, .failed(.sizeMismatch(path: first.path)))
    }

    func testStorageGateStopsBeforeAnyDownload() async throws {
        let store = store(try manifest(), space: 0)
        await store.startDownload(allowMetered: false)
        guard case .failed(.insufficientSpace) = store.state else { return XCTFail("Expected a free-space refusal") }
        XCTAssertNil(store.installedDirectory)
    }

    func testSameSizeTamperingIsNotAcceptedOnRelaunch() async throws {
        let manifest = try manifest()
        try stage(manifest)
        let store = store(manifest)
        await store.startDownload(allowMetered: false)
        let file = manifest.files[0]
        let installed = try XCTUnwrap(store.installedDirectory)
        try Data(repeating: 0, count: Int(file.bytes)).write(to: installed.appendingPathComponent(file.path))
        let reloaded = self.store(manifest)
        await reloaded.refresh()
        XCTAssertEqual(reloaded.state, .notInstalled)
    }

    func testDeleteRemovesInstalledAndPartialFiles() async throws {
        let manifest = try manifest()
        try stage(manifest)
        let store = store(manifest)
        await store.startDownload(allowMetered: false)
        await store.delete()
        XCTAssertEqual(store.state, .notInstalled)
        XCTAssertNil(store.installedDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("model").path))
    }

    func testRelaunchFinishesAnAuthorizedCompletedDownload() async throws {
        let manifest = try manifest()
        try stage(manifest)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
        try JSONSerialization.data(withJSONObject: ["manifest": object, "allowMetered": false])
            .write(to: root.appendingPathComponent("download-request.json"))
        let reloaded = store(manifest)
        await reloaded.attach()
        XCTAssertEqual(reloaded.state, .installed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("download-request.json").path))
    }

    func testInstallationMarkerBindsTheEntireManifest() async throws {
        let manifest = try manifest()
        try stage(manifest)
        let original = store(manifest)
        await original.startDownload(allowMetered: false)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        var files = try XCTUnwrap(fields["files"] as? [[String: Any]])
        files[0]["sha256"] = String(repeating: "0", count: 64)
        fields["files"] = files
        let changed = try VoiceModelManifest.decode(JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(store(changed).state, .notInstalled)
    }

    func testReinstallAtomicallyReplacesACorruptPriorModel() async throws {
        let manifest = try manifest()
        try stage(manifest)
        let store = store(manifest)
        await store.startDownload(allowMetered: false)
        let installed = try XCTUnwrap(store.installedDirectory)
        try Data().write(to: installed.appendingPathComponent(manifest.files[0].path))
        await store.refresh()
        XCTAssertEqual(store.state, .notInstalled)
        try stage(manifest)
        await store.startDownload(allowMetered: false)
        XCTAssertEqual(store.state, .installed)
        XCTAssertEqual(
            try Data(contentsOf: installed.appendingPathComponent(manifest.files[0].path)),
            Data(manifest.files[0].path.utf8))
    }

    func testOversizedTransferIsCancelledBeforeItCanFillStorage() {
        let staging = root.appendingPathComponent("staging")
        let delegate = VoiceModelDownloadDelegate(staging: { staging }, expectedSizes: ["model.safetensors": 5])
        let task = VoiceDownloadTaskFixture(status: 200, path: "model.safetensors")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        delegate.urlSession(
            session, downloadTask: task, didWriteData: 6, totalBytesWritten: 6, totalBytesExpectedToWrite: -1)
        XCTAssertTrue(task.wasCancelled)
    }

    func testUnsupportedHardwareNeverOffersOrStartsADownload() async throws {
        let profiles = [
            VoiceDeviceProfile(
                platform: .mac, isAppleSilicon: false, isSimulator: false, physicalMemoryBytes: 16 << 30),
            VoiceDeviceProfile(
                platform: .phone, isAppleSilicon: true, isSimulator: true, physicalMemoryBytes: 16 << 30),
            VoiceDeviceProfile(
                platform: .phone, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 4 << 30),
        ]
        for profile in profiles {
            let store = VoiceModelStore(manifest: try manifest(), root: root, device: profile)
            await store.startDownload(allowMetered: true)
            guard case .unsupported = store.state else {
                return XCTFail("Unsupported hardware must remain unavailable")
            }
            XCTAssertNil(store.installedDirectory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingDirectory.path))
        }
    }

    func testSuccessfulHTTPDownloadMovesTheFileBeforeReportingCompletion() throws {
        let staging = root.appendingPathComponent("staging")
        let delegate = VoiceModelDownloadDelegate(staging: { staging })
        let received = DownloadCompletionRecorder()
        delegate.onCompletion = { _, result in received.append(result) }
        let source = root.appendingPathComponent("received")
        try Data("model".utf8).write(to: source)
        let task = VoiceDownloadTaskFixture(status: 200, path: "audio_tokenizer/config.json")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertEqual(
            try Data(contentsOf: staging.appendingPathComponent("audio_tokenizer/config.json")), Data("model".utf8))
        XCTAssertEqual(received.completions, [.arrived])
    }

    func testHTTPRefusalNeverStagesTheResponseAsAModelFile() throws {
        let staging = root.appendingPathComponent("staging")
        let delegate = VoiceModelDownloadDelegate(staging: { staging })
        let received = DownloadCompletionRecorder()
        delegate.onCompletion = { _, result in received.append(result) }
        let source = root.appendingPathComponent("received")
        try Data("not found".utf8).write(to: source)
        let task = VoiceDownloadTaskFixture(status: 404, path: "model.safetensors")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(
            received.completions, [.failed(.server(status: 404, path: "model.safetensors"), resumeData: nil)])
    }
}

private nonisolated final class VoiceDownloadTaskFixture: URLSessionDownloadTask, @unchecked Sendable {
    private let fixtureResponse: HTTPURLResponse
    private(set) var wasCancelled = false
    override func cancel() { wasCancelled = true }
    override var response: URLResponse? { fixtureResponse }
    init(status: Int, path: String) {
        fixtureResponse = HTTPURLResponse(
            url: URL(string: "https://example.test/model")!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: nil)!
        super.init()
        taskDescription = path
    }
}

private nonisolated final class DownloadCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VoiceModelDownloadDelegate.Completion] = []
    var completions: [VoiceModelDownloadDelegate.Completion] { lock.withLock { values } }
    func append(_ completion: VoiceModelDownloadDelegate.Completion) { lock.withLock { values.append(completion) } }
}
