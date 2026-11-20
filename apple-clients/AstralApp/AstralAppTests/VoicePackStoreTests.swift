// Exercises the voice pack manifest and its two-repository store against a stubbed network that serves tiny files.
// No test contacts a model service, downloads production weights or asserts how long anything takes.

import CryptoKit
import XCTest

@testable import AstralDeep

private nonisolated final class PackServer: @unchecked Sendable {
    enum Reply {
        case body(Data, status: Int)
        case failure(code: Int)
        case hold
    }

    private let lock = NSLock()
    private var log: [URLRequest] = []
    private var bodies: [String: Data] = [:]
    private var paths: [String: String] = [:]
    private var failures: [String: Int] = [:]
    private var statuses: [String: Int] = [:]
    private var held: Set<String> = []

    func serve(_ manifest: VoicePackManifest, contents: [String: Data], mirror: URL? = nil) {
        lock.withLock {
            for file in manifest.files {
                guard let url = manifest.url(for: file, mirror: mirror)?.absoluteString else { continue }
                bodies[url] = contents[file.path]
                paths[url] = file.path
            }
        }
    }

    func replace(_ path: String, with data: Data) {
        lock.withLock { for (url, name) in paths where name == path { bodies[url] = data } }
    }

    func fail(_ path: String, code: Int?) {
        lock.withLock { for (url, name) in paths where name == path { failures[url] = code } }
    }

    func refuse(_ path: String, status: Int?) {
        lock.withLock { for (url, name) in paths where name == path { statuses[url] = status } }
    }

    func hold(_ path: String) {
        lock.withLock { for (url, name) in paths where name == path { held.insert(url) } }
    }

    func clearLog() { lock.withLock { log = [] } }

    var requests: [URLRequest] { lock.withLock { log } }

    var requestedPaths: [String] {
        lock.withLock { log.compactMap { $0.url.flatMap { paths[$0.absoluteString] } } }
    }

    func reply(to request: URLRequest) -> Reply {
        lock.withLock {
            log.append(request)
            let key = request.url?.absoluteString ?? ""
            if held.contains(key) { return .hold }
            if let code = failures[key] { return .failure(code: code) }
            if let status = statuses[key] { return .body(Data("refused".utf8), status: status) }
            guard let body = bodies[key] else { return .body(Data("missing".utf8), status: 404) }
            return .body(body, status: 200)
        }
    }
}

private nonisolated final class PackStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server = PackServer()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        switch Self.server.reply(to: request) {
        case .hold:
            break
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: code))
        case .body(let data, let status):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private nonisolated struct FixedNetwork: VoiceModelNetworkCost {
    let isMetered: Bool
}

@MainActor
final class VoicePackStoreTests: XCTestCase {
    private var root: URL!
    private var server: PackServer!
    private var contents: [String: Data] = [:]
    private var manifest: VoicePackManifest!
    private let supported = VoiceDeviceProfile(
        platform: .mac, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 16 << 30)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundled = try VoicePackManifest.bundled(in: Bundle(for: VoicePackStore.self))
        var files: [VoicePackManifest.File] = []
        for (index, file) in bundled.files.enumerated() {
            let text = "fixture \(file.path)"
            let data = Data((text + String(repeating: ".", count: 120 + index - text.count)).utf8)
            contents[file.path] = data
            files.append(
                VoicePackManifest.File(
                    repository: file.repository, revision: file.revision, path: file.path, bytes: Int64(data.count),
                    sha256: Self.digest(data), part: file.part))
        }
        manifest = VoicePackManifest(
            displayName: bundled.displayName, format: bundled.format, id: bundled.id, origin: bundled.origin,
            totalBytes: files.reduce(0) { $0 + $1.bytes }, files: files)
        server = PackServer()
        PackStubProtocol.server = server
        server.serve(manifest, contents: contents)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: root)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func store(
        _ manifest: VoicePackManifest? = nil, metered: Bool = false, mirror: URL? = nil, space: Int64 = .max,
        device: VoiceDeviceProfile? = nil, localVoice: Bool = true
    ) -> VoicePackStore {
        VoicePackStore(
            manifest: manifest ?? self.manifest, root: root, device: device ?? supported,
            localVoiceSupported: localVoice,
            network: FixedNetwork(isMetered: metered), mirror: { mirror }, freeSpace: { _ in space },
            makeSession: { delegate in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [PackStubProtocol.self]
                return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            })
    }

    private func settle(_ store: VoicePackStore, _ done: (VoicePackState) -> Bool) async throws {
        for _ in 0..<4000 {
            if done(store.state) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("State never settled: \(store.state)")
    }

    private func isFinished(_ state: VoicePackState) -> Bool {
        switch state {
        case .installed, .failed, .modelOnly(.failed): return true
        default: return false
        }
    }

    private func stage(_ unit: VoicePackManifest.Unit, skipping skipped: Set<String> = []) throws {
        for file in manifest.files(in: unit) where !skipped.contains(file.path) {
            let url = root.appendingPathComponent("staging").appendingPathComponent(file.stagedPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(contents[file.path]).write(to: url)
        }
    }

    private func isModelPath(_ path: String) -> Bool {
        VoicePackManifest.requiredModelFiles[path] != nil
    }

    private func object(of manifest: VoicePackManifest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
    }

    private func assertInvalid(
        _ expected: VoicePackManifest.Invalid, line: UInt = #line,
        _ change: (inout [String: Any], inout [[String: Any]]) -> Void
    ) throws {
        var fields = try object(of: manifest)
        var files = try XCTUnwrap(fields["files"] as? [[String: Any]])
        let before = fields["total_bytes"] as? NSNumber
        change(&fields, &files)
        fields["files"] = files
        if (fields["total_bytes"] as? NSNumber) == before {
            fields["total_bytes"] = files.reduce(Int64(0)) { $0 + (($1["bytes"] as? NSNumber)?.int64Value ?? 0) }
        }
        let data = try JSONSerialization.data(withJSONObject: fields)
        XCTAssertThrowsError(try VoicePackManifest.decode(data), line: line) {
            XCTAssertEqual($0 as? VoicePackManifest.Invalid, expected, line: line)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<4000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition never held")
    }

    private func alteredManifest() throws -> VoicePackManifest {
        var files = manifest.files
        let index = try XCTUnwrap(files.firstIndex { $0.part == .voice })
        let changed = files[index]
        files[index] = VoicePackManifest.File(
            repository: changed.repository, revision: changed.revision, path: changed.path, bytes: changed.bytes,
            sha256: String(repeating: "0", count: 64), part: changed.part)
        return VoicePackManifest(
            displayName: manifest.displayName, format: manifest.format, id: manifest.id, origin: manifest.origin,
            totalBytes: manifest.totalBytes, files: files)
    }

    func testBundledManifestParsesAndItsTotalsMatchItsEntries() throws {
        let bundled = try VoicePackManifest.bundled(in: Bundle(for: VoicePackStore.self))
        XCTAssertEqual(bundled.totalBytes, bundled.files.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(bundled.totalBytes, 1_364_861_708)
        XCTAssertEqual(bundled.bytes(in: .model), 1_228_712_832)
        XCTAssertEqual(bundled.bytes(in: .voice), 136_148_876)
        XCTAssertEqual(Set(bundled.files(in: .voice).map(\.path)), Set(VoicePackManifest.requiredVoiceFiles))
        XCTAssertEqual(bundled.files(in: .model).count, 3)
        XCTAssertEqual(
            Set(bundled.files.map(\.repository)),
            [VoicePackManifest.rumbleRepository, VoicePackManifest.voiceRepository])
        XCTAssertEqual(
            Set(bundled.files.map(\.revision)),
            ["b1b5a9dea24885fa348a7fa9f8ce23efefb08b2c", "c2e998e269e4d4b51f74061faddb8450cd8f9a9a"])
        XCTAssertTrue(bundled.files(in: .voice).allSatisfy { $0.path.hasPrefix("phonon/phonon-31m-en/") })
        XCTAssertFalse(bundled.files.contains { $0.path.lowercased().contains("piper") })
        XCTAssertEqual(bundled, try VoicePackManifest.decode(JSONEncoder().encode(bundled)))
    }

    func testManifestRejectsEveryUnsafeOrMalformedForm() throws {
        XCTAssertThrowsError(try VoicePackManifest.decode(Data("nope".utf8))) {
            XCTAssertEqual($0 as? VoicePackManifest.Invalid, .notJSON)
        }
        try assertInvalid(.notJSON) { _, files in files[0]["part"] = "bogus" }
        try assertInvalid(.unsupportedFormat) { fields, _ in fields["format"] = "astral.voice-pack-manifest/v2" }
        try assertInvalid(.unexpectedOrigin) { fields, _ in fields["origin"] = "http://huggingface.co" }
        try assertInvalid(.unexpectedOrigin) { fields, _ in fields["origin"] = "https://example.test" }
        try assertInvalid(.emptyFileList) { fields, files in
            files = []
            fields["total_bytes"] = 0
        }
        try assertInvalid(.unexpectedRepository("other/unreviewed")) { _, files in
            files[0]["repository"] = "other/unreviewed"
        }
        for path in ["../escape", "/absolute", "a//b", "a/../b", "a\\b", "a b", ".installed.json", "x.resume", "./a"] {
            try assertInvalid(.unsafePath(path)) { _, files in files[0]["path"] = path }
        }
        try assertInvalid(.duplicatePath(manifest.files[0].path)) { _, files in files.append(files[0]) }
        try assertInvalid(.duplicatePath(manifest.files[0].path.uppercased())) { _, files in
            var copy = files[0]
            copy["path"] = manifest.files[0].path.uppercased()
            files.append(copy)
        }
        try assertInvalid(.duplicatePath("rumble")) { _, files in
            var copy = files[0]
            copy["path"] = "rumble"
            files.append(copy)
        }
        try assertInvalid(.badSize(manifest.files[0].path)) { _, files in files[0]["bytes"] = 0 }
        try assertInvalid(.badSize(manifest.files[0].path)) { _, files in files[0]["bytes"] = -5 }
        try assertInvalid(.badDigest(manifest.files[0].path)) { _, files in files[0]["sha256"] = "abc" }
        try assertInvalid(.badDigest(manifest.files[0].path)) { _, files in
            files[0]["sha256"] = String(repeating: "A", count: 64)
        }
        for revision in ["main", String(repeating: "a", count: 39), String(repeating: "A", count: 40), ""] {
            try assertInvalid(.badRevision(manifest.files[0].path)) { _, files in files[0]["revision"] = revision }
        }
        try assertInvalid(.inconsistentRevision(VoicePackManifest.voiceRepository)) { _, files in
            files[files.count - 1]["revision"] = String(repeating: "1", count: 40)
        }
        try assertInvalid(.misplacedPart(manifest.files(in: .model)[0].path)) { _, files in
            files[files.firstIndex { ($0["part"] as? String) != "voice" }!]["part"] = "voice"
        }
        try assertInvalid(.misplacedPart(manifest.files(in: .voice)[0].path)) { _, files in
            files[files.firstIndex { ($0["part"] as? String) == "voice" }!]["part"] = "recognition"
        }
        try assertInvalid(.missingRequiredFile("phonon/phonon-31m-en/arch.json")) { _, files in
            files.removeAll { ($0["path"] as? String) == "phonon/phonon-31m-en/arch.json" }
        }
        try assertInvalid(.misplacedPart("phonon/phonon-31m-en/voices/default.safetensors")) { _, files in
            var extra = files[files.count - 1]
            extra["path"] = "phonon/phonon-31m-en/voices/default.safetensors"
            files.append(extra)
        }
        try assertInvalid(.totalMismatch) { fields, _ in fields["total_bytes"] = manifest.totalBytes + 1 }
    }

    func testURLsAreHTTPSAndPinnedAndMirrorsKeepTheirRule() throws {
        let file = try XCTUnwrap(manifest.files(in: .voice).first { $0.path.hasSuffix("weights/weight.bin") })
        let url = try XCTUnwrap(manifest.url(for: file))
        XCTAssertEqual(
            url.absoluteString, "https://huggingface.co/\(file.repository)/resolve/\(file.revision)/\(file.path)")
        let mirrored = try XCTUnwrap(manifest.url(for: file, mirror: URL(string: "https://mirror.example.test/base")))
        XCTAssertEqual(
            mirrored.absoluteString,
            "https://mirror.example.test/base/\(file.repository)/resolve/\(file.revision)/\(file.path)")
        XCTAssertNotNil(manifest.url(for: file, mirror: URL(string: "http://127.0.0.1:8080/base")))
        XCTAssertNotNil(manifest.url(for: file, mirror: URL(string: "http://localhost:8080")))
        for refused in [
            "http://mirror.example.test/base", "https://user:pass@mirror.example.test",
            "https://mirror.example.test?a=b",
            "https://mirror.example.test#frag", "ftp://mirror.example.test",
        ] {
            XCTAssertNil(manifest.url(for: file, mirror: URL(string: refused)), refused)
        }
    }

    func testCleanInstallFetchesBothRepositoriesAtTheirPinnedRevisions() async throws {
        let store = store()
        XCTAssertEqual(store.state, .notInstalled)
        XCTAssertNil(store.modelDirectory)
        XCTAssertNil(store.voicePackDirectory)
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .installed)
        XCTAssertEqual(server.requestedPaths.sorted(), manifest.files.map(\.path).sorted())
        for request in server.requests {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertTrue(
                url.path.contains("/resolve/b1b5a9dea24885fa348a7fa9f8ce23efefb08b2c/")
                    || url.path.contains("/resolve/c2e998e269e4d4b51f74061faddb8450cd8f9a9a/"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), VoicePackStore.userAgent)
            XCTAssertFalse(
                request.allHTTPHeaderFields?.values.contains { $0.localizedCaseInsensitiveContains("astral") } ?? false)
            XCTAssertFalse(request.allowsExpensiveNetworkAccess)
        }
        let model = try XCTUnwrap(store.modelDirectory)
        let voice = try XCTUnwrap(store.voicePackDirectory)
        XCTAssertEqual(voice, root.appendingPathComponent("voice/phonon/phonon-31m-en"))
        for file in manifest.files(in: .model) {
            XCTAssertEqual(try Data(contentsOf: model.appendingPathComponent(file.path)), contents[file.path])
        }
        for path in VoicePackManifest.requiredVoiceFiles {
            let relative = String(path.dropFirst(VoicePackManifest.voiceSubdirectory.count + 1))
            XCTAssertTrue(FileManager.default.fileExists(atPath: voice.appendingPathComponent(relative).path), path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingDirectory.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("download-request.json").path))
        XCTAssertEqual(self.store().state, .installed)
        let excluded = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)
    }

    func testTamperedFileOfTheSameSizeIsRefusedAndDiscarded() async throws {
        let victim = "rumble/Rumble-2-Flash-AD-Q5_K_M.gguf"
        server.replace(victim, with: Data(repeating: 0x41, count: try XCTUnwrap(contents[victim]).count))
        let store = store()
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .failed(.checksumMismatch(path: victim)))
        XCTAssertNil(store.modelDirectory)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("staging/model/\(victim)").path))
        server.replace(victim, with: try XCTUnwrap(contents[victim]))
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .installed)
    }

    func testWrongSizeIsRefusedAndTheVoiceIsNeverFetchedBeforeTheModel() async throws {
        let victim = "chat-1.2b/LFM2.5-1.2B-Instruct-Q4_K_M.gguf"
        server.replace(victim, with: Data("short".utf8))
        let store = store()
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .failed(.sizeMismatch(path: victim)))
        XCTAssertNil(store.modelDirectory)
        XCTAssertTrue(server.requestedPaths.allSatisfy(isModelPath))
    }

    func testAnEscapingPathIsRefusedBeforeAnyRequestOrWrite() async throws {
        var files = manifest.files
        files[0] = VoicePackManifest.File(
            repository: files[0].repository, revision: files[0].revision, path: "../escape.gguf",
            bytes: files[0].bytes, sha256: files[0].sha256, part: files[0].part)
        let hostile = VoicePackManifest(
            displayName: "x", format: VoicePackManifest.supportedFormat, id: "x", origin: VoicePackManifest.origin,
            totalBytes: manifest.totalBytes, files: files)
        let store = store(hostile)
        await store.startDownload(allowMetered: false)
        XCTAssertEqual(store.state, .failed(.manifestUnavailable))
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingDirectory.path))
        XCTAssertNil(VoiceModelDownloadDelegate.filePath(in: "op|model/../escape.gguf"))
    }

    func testInterruptedModelDownloadResumesAfterRelaunchWithoutRepeatingVerifiedFiles() async throws {
        let interrupted = "rumble/mmproj-Rumble-2-Flash-Q8_0.gguf"
        server.fail(interrupted, code: NSURLErrorNetworkConnectionLost)
        let first = store()
        await first.startDownload(allowMetered: false)
        try await settle(first, isFinished)
        XCTAssertEqual(first.state, .failed(.network(code: NSURLErrorNetworkConnectionLost)))
        let delivered = Set(server.requestedPaths).subtracting([interrupted])
        server.fail(interrupted, code: nil)
        server.clearLog()
        let relaunched = store()
        XCTAssertEqual(relaunched.state, .notInstalled)
        await relaunched.startDownload(allowMetered: false)
        try await settle(relaunched, isFinished)
        XCTAssertEqual(relaunched.state, .installed)
        let second = Set(server.requestedPaths)
        XCTAssertTrue(second.contains(interrupted))
        XCTAssertTrue(second.isDisjoint(with: delivered))
        XCTAssertEqual(second.union(delivered), Set(manifest.files.map(\.path)))
    }

    func testCompleteStagedFilesInstallOnRelaunchWithoutAnyRequest() async throws {
        try stage(.model)
        try stage(.voice)
        let store = store()
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .installed)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testVoiceFailureLeavesTheModelUsableAndRetryFetchesOnlyTheVoice() async throws {
        let stuck = "phonon/phonon-31m-en/pocket_state.mlmodelc/weights/weight.bin"
        server.fail(stuck, code: NSURLErrorTimedOut)
        let store = store()
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .modelOnly(.failed(.network(code: NSURLErrorTimedOut))))
        XCTAssertNotNil(store.modelDirectory)
        XCTAssertNil(store.voicePackDirectory)
        for file in manifest.files(in: .model) {
            XCTAssertEqual(
                try Data(contentsOf: XCTUnwrap(store.modelDirectory).appendingPathComponent(file.path)),
                contents[file.path])
        }
        XCTAssertTrue(Set(manifest.files(in: .model).map(\.path)).isSubset(of: Set(server.requestedPaths)))
        let relaunched = self.store()
        XCTAssertEqual(relaunched.state, .modelOnly(.pending))
        server.fail(stuck, code: nil)
        server.clearLog()
        await relaunched.retryVoice()
        try await settle(relaunched, isFinished)
        XCTAssertEqual(relaunched.state, .installed)
        XCTAssertFalse(server.requestedPaths.isEmpty)
        XCTAssertFalse(server.requestedPaths.contains(where: isModelPath))
        XCTAssertNotNil(relaunched.voicePackDirectory)
    }

    func testRetryOnTheSameStoreAfterAVoiceFailureReusesTheVerifiedVoiceFiles() async throws {
        let stuck = "phonon/phonon-31m-en/pocket_state.mlmodelc/weights/weight.bin"
        server.fail(stuck, code: NSURLErrorNetworkConnectionLost)
        let store = store()
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        let deliveredVoice = Set(server.requestedPaths).subtracting([stuck]).filter { !isModelPath($0) }
        XCTAssertFalse(deliveredVoice.isEmpty)
        server.fail(stuck, code: nil)
        server.clearLog()
        await store.retryVoice()
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .installed)
        XCTAssertEqual(server.requestedPaths, [stuck])
    }

    func testVoiceRetryNeverEscalatesMeteredConsent() async throws {
        let stuck = "phonon/phonon-31m-en/arch.json"
        server.fail(stuck, code: NSURLErrorNetworkConnectionLost)
        let declined = store(metered: true)
        await declined.startDownload(allowMetered: false)
        try await settle(declined, isFinished)
        server.fail(stuck, code: nil)
        server.clearLog()
        await declined.retryVoice()
        try await settle(declined, isFinished)
        XCTAssertFalse(server.requests.isEmpty)
        XCTAssertTrue(
            server.requests.allSatisfy { !$0.allowsExpensiveNetworkAccess && !$0.allowsConstrainedNetworkAccess })
        await declined.delete()
        server.fail(stuck, code: NSURLErrorNetworkConnectionLost)
        let granted = store(metered: true)
        await granted.startDownload(allowMetered: true)
        try await settle(granted, isFinished)
        server.fail(stuck, code: nil)
        server.clearLog()
        await granted.retryVoice()
        try await settle(granted, isFinished)
        XCTAssertTrue(server.requests.allSatisfy { $0.allowsExpensiveNetworkAccess })
        XCTAssertTrue(granted.needsMeteredConfirmation)
    }

    func testFreeSpaceIsSizedToTheBytesStillMissing() async throws {
        let margin = VoicePackStore.spaceMarginBytes
        let short = store(space: margin + manifest.totalBytes - 1)
        await short.startDownload(allowMetered: false)
        guard case .failed(.insufficientSpace) = short.state else { return XCTFail("Expected a space refusal") }
        XCTAssertTrue(server.requests.isEmpty)
        try stage(.model)
        let model = store(space: margin + manifest.bytes(in: .voice))
        await model.startDownload(allowMetered: false)
        try await settle(model, isFinished)
        XCTAssertEqual(model.state, .installed)
        await model.delete()
        let unknown = VoicePackStore(
            manifest: manifest, root: root, device: supported, network: FixedNetwork(isMetered: false),
            freeSpace: { _ in nil })
        await unknown.startDownload(allowMetered: false)
        XCTAssertEqual(unknown.state, .failed(.storage("free_space_unknown")))
    }

    func testVoiceSpaceRefusalKeepsTheInstalledModel() async throws {
        server.fail("phonon/phonon-31m-en/arch.json", code: NSURLErrorNetworkConnectionLost)
        let first = store()
        await first.startDownload(allowMetered: false)
        try await settle(first, isFinished)
        let tight = store(space: VoicePackStore.spaceMarginBytes)
        await tight.retryVoice()
        guard case .modelOnly(.failed(.insufficientSpace)) = tight.state else {
            return XCTFail("Expected a space refusal, got \(tight.state)")
        }
        XCTAssertNotNil(tight.modelDirectory)
    }

    func testMirrorServesBothRepositoriesAndABadMirrorStopsBeforeAnyRequest() async throws {
        let mirror = try XCTUnwrap(URL(string: "https://mirror.example.test/hf"))
        server.serve(manifest, contents: contents, mirror: mirror)
        let mirrored = store(mirror: mirror)
        await mirrored.startDownload(allowMetered: false)
        try await settle(mirrored, isFinished)
        XCTAssertEqual(mirrored.state, .installed)
        XCTAssertTrue(server.requests.allSatisfy { $0.url?.host == "mirror.example.test" })
        XCTAssertEqual(Set(server.requestedPaths), Set(manifest.files.map(\.path)))
        await mirrored.delete()
        server.clearLog()
        let insecure = store(mirror: URL(string: "http://mirror.example.test/hf"))
        await insecure.startDownload(allowMetered: false)
        XCTAssertEqual(insecure.state, .failed(.storage("bad_mirror")))
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAServerRefusalNeverStagesTheResponse() async throws {
        let refused = "rumble/mmproj-Rumble-2-Flash-Q8_0.gguf"
        server.refuse(refused, status: 404)
        let store = store()
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .failed(.server(status: 404, path: "model/\(refused)")))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("staging/model/\(refused)").path))
    }

    func testStrayStagedFilesNeverReachTheInstalledFolder() async throws {
        try stage(.model)
        let stray = root.appendingPathComponent("staging/model/rumble/extra.bin")
        try Data("x".utf8).write(to: stray)
        let store = store()
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .installed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("model/rumble/extra.bin").path))
    }

    func testTamperingWithAnInstalledUnitIsCaughtOnRefresh() async throws {
        let store = store()
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        let voiceFile = try XCTUnwrap(manifest.files(in: .voice).first)
        let target = root.appendingPathComponent("voice").appendingPathComponent(voiceFile.path)
        try Data(repeating: 0, count: Int(voiceFile.bytes)).write(to: target)
        await store.refresh()
        XCTAssertEqual(store.state, .modelOnly(.pending))
        XCTAssertNil(store.voicePackDirectory)
        let modelFile = try XCTUnwrap(manifest.files(in: .model).first)
        try Data(repeating: 0, count: Int(modelFile.bytes)).write(
            to: root.appendingPathComponent("model").appendingPathComponent(modelFile.path))
        await store.refresh()
        XCTAssertEqual(store.state, .notInstalled)
    }

    func testAMarkerBindsOnlyItsOwnUnit() async throws {
        let first = store()
        await first.startDownload(allowMetered: false)
        try await settle(first, isFinished)
        XCTAssertEqual(store(try alteredManifest()).state, .modelOnly(.pending))
    }

    func testDeleteRemovesEveryUnitAndPartialFile() async throws {
        try stage(.voice)
        let store = store()
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        await store.delete()
        XCTAssertEqual(store.state, .notInstalled)
        for name in ["model", "voice", "staging", "download-request.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
    }

    func testCancelStopsTheTransferAndWithdrawsConsent() async throws {
        let held = "chat-1.2b/LFM2.5-1.2B-Instruct-Q4_K_M.gguf"
        server.hold(held)
        let store = store()
        await store.startDownload(allowMetered: false)
        try await waitUntil { !server.requests.isEmpty }
        guard case .downloading = store.state else { return XCTFail("Expected a running download") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("download-request.json").path))
        await store.cancelDownload()
        XCTAssertEqual(store.state, .notInstalled)
        XCTAssertFalse(store.isDownloading)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("download-request.json").path))
    }

    func testDevicesWithoutLocalVoiceCompleteWithTheModelAlone() async throws {
        let store = store(localVoice: false)
        XCTAssertEqual(store.requiredBytes, manifest.bytes(in: .model))
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .installed)
        XCTAssertNotNil(store.modelDirectory)
        XCTAssertNil(store.voicePackDirectory)
        XCTAssertTrue(server.requestedPaths.allSatisfy(isModelPath))
        XCTAssertEqual(Set(server.requestedPaths).count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("voice").path))
        XCTAssertEqual(self.store(localVoice: false).state, .installed)
        XCTAssertEqual(self.store(localVoice: true).state, .modelOnly(.pending))
    }

    func testDevicesWithoutLocalVoiceSizeSpaceToTheModelAlone() async throws {
        let store = store(space: VoicePackStore.spaceMarginBytes + manifest.bytes(in: .model), localVoice: false)
        await store.startDownload(allowMetered: false)
        try await settle(store, isFinished)
        XCTAssertEqual(store.state, .installed)
    }

    func testUnsupportedHardwareNeverStartsADownload() async throws {
        let phone = VoiceDeviceProfile(
            platform: .phone, isAppleSilicon: true, isSimulator: true, physicalMemoryBytes: 16 << 30)
        let store = store(device: phone)
        await store.startDownload(allowMetered: true)
        guard case .unsupported = store.state else { return XCTFail("Expected unsupported") }
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingDirectory.path))
    }

    func testRelaunchResumesAnAuthorizedDownloadAndRefusesOneForAnotherManifest() async throws {
        server.fail("phonon/phonon-31m-en/arch.json", code: NSURLErrorNetworkConnectionLost)
        let first = store()
        await first.startDownload(allowMetered: false)
        try await settle(first, isFinished)
        server.fail("phonon/phonon-31m-en/arch.json", code: nil)
        server.clearLog()
        let relaunched = store()
        await relaunched.attach()
        try await settle(relaunched, isFinished)
        XCTAssertEqual(relaunched.state, .installed)
        XCTAssertFalse(server.requestedPaths.contains(where: isModelPath))
        await relaunched.delete()
        server.clearLog()
        server.fail("phonon/phonon-31m-en/arch.json", code: NSURLErrorNetworkConnectionLost)
        let other = store()
        await other.startDownload(allowMetered: false)
        try await settle(other, isFinished)
        server.fail("phonon/phonon-31m-en/arch.json", code: nil)
        server.clearLog()
        let different = store(try alteredManifest())
        await different.attach()
        XCTAssertTrue(server.requests.isEmpty)
    }
}
