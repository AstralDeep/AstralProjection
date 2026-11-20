// Covers the shared download machinery the voice pack store relies on: streaming SHA-256 digests, the background-session delegate and the mirror and path rules.
// Tiny local files and task fixtures stand in for downloads, so nothing contacts a model service.

import XCTest

@testable import AstralDeep

final class VoiceDownloadSupportTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: root)
    }

    func testDigestMatchesSHA256AcrossMultipleReadChunks() throws {
        let file = root.appendingPathComponent("multi-chunk-weights")
        try Data(repeating: 0x5a, count: (9 << 20) + 37).write(to: file)
        XCTAssertEqual(
            try VoiceModelDigest.sha256(of: file),
            "719beaba8d33a4cbc7c4e82a53987e5f15cfa9c6f0c8275abcab2480159401b1")
    }

    func testDigestMatchesSHA256ForAnEmptyFile() throws {
        let file = root.appendingPathComponent("empty-weights")
        try Data().write(to: file)
        XCTAssertEqual(
            try VoiceModelDigest.sha256(of: file),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testDigestPropagatesFileOpenAndReadFailures() throws {
        XCTAssertThrowsError(try VoiceModelDigest.sha256(of: root.appendingPathComponent("missing-weights")))
        XCTAssertThrowsError(try VoiceModelDigest.sha256(of: root))
    }

    func testOversizedTransferIsCancelledBeforeItCanFillStorage() {
        let staging = root.appendingPathComponent("staging")
        let delegate = VoiceModelDownloadDelegate(staging: { staging }, expectedSizes: ["model/rumble.gguf": 5])
        let task = VoiceDownloadTaskFixture(status: 200, path: "op|model/rumble.gguf")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        delegate.urlSession(
            session, downloadTask: task, didWriteData: 6, totalBytesWritten: 6, totalBytesExpectedToWrite: -1)
        XCTAssertTrue(task.wasCancelled)
    }

    func testSuccessfulHTTPDownloadMovesTheFileBeforeReportingCompletion() throws {
        let staging = root.appendingPathComponent("staging")
        let delegate = VoiceModelDownloadDelegate(staging: { staging })
        let received = DownloadCompletionRecorder()
        delegate.onCompletion = { _, result in received.append(result) }
        let source = root.appendingPathComponent("received")
        try Data("model".utf8).write(to: source)
        let task = VoiceDownloadTaskFixture(status: 200, path: "op|voice/phonon/arch.json")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertEqual(
            try Data(contentsOf: staging.appendingPathComponent("voice/phonon/arch.json")), Data("model".utf8))
        XCTAssertEqual(received.completions, [.arrived])
    }

    func testHTTPRefusalNeverStagesTheResponseAsAModelFile() throws {
        let staging = root.appendingPathComponent("staging")
        let delegate = VoiceModelDownloadDelegate(staging: { staging })
        let received = DownloadCompletionRecorder()
        delegate.onCompletion = { _, result in received.append(result) }
        let source = root.appendingPathComponent("received")
        try Data("not found".utf8).write(to: source)
        let task = VoiceDownloadTaskFixture(status: 404, path: "op|model/rumble.gguf")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(
            received.completions,
            [.failed(.server(status: 404, path: "model/rumble.gguf"), resumeData: nil)])
    }

    func testAnUnsafeTaskPathIsNeverStagedOrReported() throws {
        let staging = root.appendingPathComponent("staging")
        let delegate = VoiceModelDownloadDelegate(staging: { staging })
        let received = DownloadCompletionRecorder()
        delegate.onCompletion = { _, result in received.append(result) }
        let source = root.appendingPathComponent("received")
        try Data("x".utf8).write(to: source)
        let task = VoiceDownloadTaskFixture(status: 200, path: "op|model/../escape.gguf")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.gguf").path))
    }

    func testTheMirrorSettingNeedsAHostAndIgnoresBlankText() {
        let suite = "voice-download-support-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(VoiceDownloadSupport.configuredMirror(defaults: defaults))
        defaults.set("   ", forKey: VoiceDownloadSupport.mirrorDefaultsKey)
        XCTAssertNil(VoiceDownloadSupport.configuredMirror(defaults: defaults))
        defaults.set("not a url", forKey: VoiceDownloadSupport.mirrorDefaultsKey)
        XCTAssertNil(VoiceDownloadSupport.configuredMirror(defaults: defaults))
        defaults.set(" https://mirror.example.test/base ", forKey: VoiceDownloadSupport.mirrorDefaultsKey)
        XCTAssertEqual(
            VoiceDownloadSupport.configuredMirror(defaults: defaults)?.absoluteString,
            "https://mirror.example.test/base")
    }

    func testFreeSpaceIsReadForAnExistingAndAMissingFolder() {
        XCTAssertNotNil(VoiceDownloadSupport.systemFreeSpace(root))
        XCTAssertNotNil(VoiceDownloadSupport.systemFreeSpace(root.appendingPathComponent("not-created-yet")))
    }

    func testBackupExclusionMarksTheFolder() throws {
        VoiceDownloadSupport.excludeFromBackup(root)
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
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
