// Downloads, verifies, installs and deletes the voice pack as two units, the three model files and the on-device voice, each staged, checked against its SHA-256 and swapped in atomically.
// It reuses the voice model store's download delegate, digest and gates, keeps the model usable when the voice is still pending, and retries only the voice later; it is the only code that fetches pack files.

import Foundation
import Observation

nonisolated enum VoicePackVoiceStatus: Equatable, Sendable {
    case pending
    case downloading(VoiceModelDownloadProgress)
    case failed(VoiceModelFailure)
}

nonisolated enum VoicePackState: Equatable, Sendable {
    case unsupported(VoiceUnsupportedReason)
    case notInstalled
    case downloading(VoiceModelDownloadProgress)
    case modelOnly(VoicePackVoiceStatus)
    case installed
    case failed(VoiceModelFailure)
}

@MainActor
@Observable
final class VoicePackStore {
    nonisolated static let backgroundIdentifier = "com.personalailabs.astraldeep.voice-pack"
    nonisolated static let userAgent = "model-pack-downloader"
    nonisolated static let spaceMarginBytes: Int64 = 200 << 20

    private(set) var state: VoicePackState

    let manifest: VoicePackManifest
    private let root: URL
    private let device: VoiceDeviceProfile
    private let units: [VoicePackManifest.Unit]
    private let network: VoiceModelNetworkCost
    private let mirror: @Sendable () -> URL?
    private let freeSpace: @Sendable (URL) -> Int64?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private let delegate: VoiceModelDownloadDelegate
    @ObservationIgnored private let makeSession: (VoiceModelDownloadDelegate) -> URLSession
    @ObservationIgnored private var installed: Set<VoicePackManifest.Unit>
    @ObservationIgnored private var verified = Set<String>()
    @ObservationIgnored private var failure: VoiceModelFailure?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var activePath: String?
    @ObservationIgnored private var activeIdentifier: String?
    @ObservationIgnored private var activeBytes: Int64 = 0
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var allowMetered = false
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var verifying = false
    @ObservationIgnored private var retiringTasks = false

    init(
        manifest: VoicePackManifest, root: URL, device: VoiceDeviceProfile = .current,
        localVoiceSupported: Bool = VoicePackStore.systemSupportsLocalVoice,
        network: VoiceModelNetworkCost = PathMonitorNetworkCost(),
        mirror: @escaping @Sendable () -> URL? = { VoiceModelManifest.configuredMirror() },
        freeSpace: @escaping @Sendable (URL) -> Int64? = VoiceModelStore.systemFreeSpace,
        makeSession: @escaping (VoiceModelDownloadDelegate) -> URLSession = VoicePackStore.systemSession
    ) {
        self.manifest = manifest
        self.root = root
        self.device = device
        units = localVoiceSupported ? VoicePackManifest.Unit.allCases : [.model]
        self.network = network
        self.mirror = mirror
        self.freeSpace = freeSpace
        self.makeSession = makeSession
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        delegate = VoiceModelDownloadDelegate(
            staging: { staging },
            expectedSizes: Dictionary(
                manifest.files.map { ($0.stagedPath, $0.bytes) }, uniquingKeysWith: { first, _ in first }))
        installed = Self.installedUnits(manifest: manifest, root: root, units: units)
        state = .notInstalled
        publish()
        delegate.onProgress = { [weak self] path, written in
            Task { @MainActor [weak self] in self?.progress(path: path, written: written) }
        }
        delegate.onCompletion = { [weak self] path, completion in
            Task { @MainActor [weak self] in await self?.completed(path: path, completion) }
        }
        delegate.onBackgroundEventsFinished = {
            VoiceModelBackgroundEvents.complete(VoicePackStore.backgroundIdentifier)
        }
    }

    var modelDirectory: URL? {
        installed.contains(.model) ? installDirectory(.model) : nil
    }

    var voicePackDirectory: URL? {
        installed.contains(.voice)
            ? installDirectory(.voice).appendingPathComponent(VoicePackManifest.voiceSubdirectory, isDirectory: true)
            : nil
    }

    var isDownloading: Bool { running }

    var requiredBytes: Int64 { units.reduce(0) { $0 + manifest.bytes(in: $1) } }

    nonisolated static var systemSupportsLocalVoice: Bool {
        if #available(iOS 18, macOS 15, *) { return true }
        return false
    }

    var needsMeteredConfirmation: Bool { network.isMetered }

    var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }
    private var downloadRequestURL: URL { root.appendingPathComponent("download-request.json") }

    private func installDirectory(_ unit: VoicePackManifest.Unit) -> URL {
        root.appendingPathComponent(unit.folder, isDirectory: true)
    }

    func attach() async {
        guard VoiceDeviceSupport.unsupportedReason(for: device) == nil,
            let data = try? Data(contentsOf: downloadRequestURL),
            let request = try? JSONDecoder().decode(DownloadRequest.self, from: data), request.manifest == manifest,
            state != .installed
        else { return }
        await reattachBackgroundTasks()
        if !running { await startDownload(allowMetered: request.allowMetered) }
    }

    func refresh() async {
        guard !running else { return }
        let expectedOperation = operation
        let manifest = manifest
        let root = root
        let units = units
        let checked = await Task.detached {
            Self.installedUnits(manifest: manifest, root: root, units: units, verifyDigests: true)
        }.value
        if !running, expectedOperation == operation {
            installed = checked
            publish()
        }
    }

    func retryVoice() async {
        guard installed.contains(.model), !isComplete, !running else { return }
        let consent =
            (try? Data(contentsOf: downloadRequestURL)).flatMap {
                try? JSONDecoder().decode(DownloadRequest.self, from: $0)
            }
            .map { $0.manifest == manifest && $0.allowMetered } ?? false
        await startDownload(allowMetered: consent)
    }

    func startDownload(allowMetered: Bool) async {
        guard !retiringTasks, !running, VoiceDeviceSupport.unsupportedReason(for: device) == nil,
            !isComplete
        else { return }
        guard (try? manifest.validate()) != nil else {
            failure = .manifestUnavailable
            publish()
            return
        }
        operation = UUID()
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            VoiceModelStore.excludeFromBackup(root)
        } catch {
            failure = .storage("create_failed")
            publish()
            return
        }
        self.allowMetered = allowMetered
        let remaining = manifest.files.filter {
            units.contains($0.unit) && !installed.contains($0.unit) && !fileIsComplete($0)
        }
        .reduce(Int64(0)) { $0 + $1.bytes }
        guard let available = freeSpace(root) else {
            failure = .storage("free_space_unknown")
            publish()
            return
        }
        if available < remaining + Self.spaceMarginBytes {
            failure = .insufficientSpace(requiredBytes: remaining + Self.spaceMarginBytes, availableBytes: available)
            publish()
            return
        }
        do {
            try JSONEncoder().encode(DownloadRequest(manifest: manifest, allowMetered: allowMetered))
                .write(to: downloadRequestURL, options: .atomic)
        } catch {
            failure = .storage("consent_save_failed")
            publish()
            return
        }
        verified = []
        failure = nil
        running = true
        publish()
        await reconcile()
    }

    func cancelDownload() async {
        guard running, !retiringTasks else { return }
        retiringTasks = true
        defer { retiringTasks = false }
        operation = UUID()
        running = false
        failure = nil
        verifying = false
        activeIdentifier = nil
        try? FileManager.default.removeItem(at: downloadRequestURL)
        publish()
        if let session {
            for task in await session.pendingTasks.compactMap({ $0 as? URLSessionDownloadTask }) {
                if let identifier = task.taskDescription, let path = VoiceModelDownloadDelegate.filePath(in: identifier)
                {
                    if let data = await task.cancelProducingResumeData() { saveResumeData(data, for: path) }
                }
            }
        }
        activePath = nil
        activeIdentifier = nil
        activeBytes = 0
    }

    func delete() async {
        guard !retiringTasks else { return }
        retiringTasks = true
        defer { retiringTasks = false }
        operation = UUID()
        running = false
        failure = nil
        verifying = false
        if let session {
            for task in await session.pendingTasks { task.cancel() }
        }
        activePath = nil
        activeIdentifier = nil
        activeBytes = 0
        verified = []
        installed = []
        publish()
        do {
            for target in [
                installDirectory(.model), installDirectory(.voice), stagingDirectory, downloadRequestURL,
            ] where FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        } catch {
            failure = .storage("delete_failed")
            publish()
        }
    }

    nonisolated static func installedUnits(
        manifest: VoicePackManifest, root: URL, units: [VoicePackManifest.Unit] = VoicePackManifest.Unit.allCases,
        verifyDigests: Bool = false
    ) -> Set<VoicePackManifest.Unit> {
        Set(
            units.filter {
                unitIsInstalled($0, manifest: manifest, root: root, verifyDigests: verifyDigests)
            })
    }

    private nonisolated static func unitIsInstalled(
        _ unit: VoicePackManifest.Unit, manifest: VoicePackManifest, root: URL, verifyDigests: Bool
    ) -> Bool {
        let directory = root.appendingPathComponent(unit.folder, isDirectory: true)
        let files = manifest.files(in: unit)
        guard !files.isEmpty, let data = try? Data(contentsOf: directory.appendingPathComponent(".installed.json")),
            let marker = try? JSONDecoder().decode(UnitMarker.self, from: data), marker.unit == unit.rawValue,
            marker.files == files
        else { return false }
        for file in files {
            let url = directory.appendingPathComponent(file.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                (attributes?[.size] as? NSNumber)?.int64Value == file.bytes
            else { return false }
            if verifyDigests, (try? VoiceModelDigest.sha256(of: url)) != file.sha256 { return false }
        }
        return true
    }

    private nonisolated struct UnitMarker: Codable, Sendable {
        let unit: String
        let files: [VoicePackManifest.File]
    }

    private nonisolated struct DownloadRequest: Codable, Sendable {
        let manifest: VoicePackManifest
        let allowMetered: Bool
    }

    private var isComplete: Bool { units.allSatisfy { installed.contains($0) } }

    private func publish() {
        if let reason = VoiceDeviceSupport.unsupportedReason(for: device) {
            state = .unsupported(reason)
            return
        }
        let progress = VoiceModelDownloadProgress(
            completedBytes: completedBytes(), totalBytes: requiredBytes, verifying: verifying)
        if installed.contains(.model) {
            if isComplete {
                state = .installed
            } else if running {
                state = .modelOnly(.downloading(progress))
            } else if let failure {
                state = .modelOnly(.failed(failure))
            } else {
                state = .modelOnly(.pending)
            }
        } else if running {
            state = .downloading(progress)
        } else if let failure {
            state = .failed(failure)
        } else {
            state = .notInstalled
        }
    }

    private func completedBytes() -> Int64 {
        manifest.files.filter {
            units.contains($0.unit) && (installed.contains($0.unit) || verified.contains($0.stagedPath))
        }
        .reduce(0) { $0 + $1.bytes } + activeBytes
    }

    private func fileIsComplete(_ file: VoicePackManifest.File) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: stagingDirectory.appendingPathComponent(file.stagedPath).path)
        return (attributes?[.size] as? NSNumber)?.int64Value == file.bytes
    }

    private func resumeURL(_ stagedPath: String) -> URL {
        stagingDirectory.appendingPathComponent(stagedPath + ".resume")
    }

    private func saveResumeData(_ data: Data, for stagedPath: String) {
        let url = resumeURL(stagedPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            fail(.storage("resume_failed"))
        }
    }

    private func progress(path: String, written: Int64) {
        guard running, path == activeIdentifier else { return }
        activeBytes = written
        publish()
    }

    private func fail(_ reason: VoiceModelFailure) {
        activePath = nil
        activeIdentifier = nil
        activeBytes = 0
        verifying = false
        running = false
        failure = reason
        publish()
    }

    private func completed(path identifier: String, _ completion: VoiceModelDownloadDelegate.Completion) async {
        guard running, identifier == activeIdentifier, let path = activePath else { return }
        activePath = nil
        activeIdentifier = nil
        activeBytes = 0
        switch completion {
        case .arrived:
            try? FileManager.default.removeItem(at: resumeURL(path))
            await reconcile()
        case .cancelled(let data):
            if let data { saveResumeData(data, for: path) }
            if running {
                running = false
                publish()
            }
        case .failed(let reason, let data):
            if let data { saveResumeData(data, for: path) }
            if case .server = reason { try? FileManager.default.removeItem(at: resumeURL(path)) }
            fail(reason)
        }
    }

    private func ensureSession() -> URLSession {
        if let session { return session }
        let created = makeSession(delegate)
        session = created
        return created
    }

    private func reattachBackgroundTasks() async {
        let tasks = await ensureSession().pendingTasks.compactMap { $0 as? URLSessionDownloadTask }
        if let task = tasks.first(where: { $0.state == .running || $0.state == .suspended }),
            let identifier = task.taskDescription, let path = VoiceModelDownloadDelegate.filePath(in: identifier),
            let file = manifest.files.first(where: { $0.stagedPath == path }), !installed.contains(file.unit), !running
        {
            activePath = path
            activeIdentifier = identifier
            failure = nil
            running = true
            publish()
            task.resume()
        }
    }

    private func reconcile() async {
        if reconciling {
            rerun = true
            return
        }
        reconciling = true
        let expectedOperation = operation
        defer {
            reconciling = false
            if rerun, running { Task { await reconcile() } }
        }
        repeat {
            rerun = false
            guard running, expectedOperation == operation else { return }
            guard let unit = units.first(where: { !installed.contains($0) }) else {
                finish()
                return
            }
            let files = manifest.files(in: unit).sorted { $0.bytes < $1.bytes }
            for file in files
            where !verified.contains(file.stagedPath) && fileIsComplete(file)
                && activePath != file.stagedPath
            {
                verifying = true
                publish()
                let url = stagingDirectory.appendingPathComponent(file.stagedPath)
                let digest = await Task.detached { try? VoiceModelDigest.sha256(of: url) }.value
                verifying = false
                guard running, expectedOperation == operation else { return }
                if digest == file.sha256 {
                    verified.insert(file.stagedPath)
                    publish()
                } else {
                    try? FileManager.default.removeItem(at: url)
                    fail(.checksumMismatch(path: file.path))
                    return
                }
            }
            for file in files where activePath != file.stagedPath && !verified.contains(file.stagedPath) {
                let url = stagingDirectory.appendingPathComponent(file.stagedPath)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                if let size = (attributes?[.size] as? NSNumber)?.int64Value, size != file.bytes {
                    try? FileManager.default.removeItem(at: url)
                    fail(.sizeMismatch(path: file.path))
                    return
                }
            }
            if let next = files.first(where: { !verified.contains($0.stagedPath) }) {
                if activePath == nil { startTask(for: next) }
                if running { publish() }
                continue
            }
            if install(unit) { rerun = true }
        } while rerun
    }

    private func startTask(for file: VoicePackManifest.File) {
        guard let url = manifest.url(for: file, mirror: mirror()) else {
            fail(.storage("bad_mirror"))
            return
        }
        let session = ensureSession()
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeURL(file.stagedPath)) {
            task = session.downloadTask(withResumeData: resume)
        } else {
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.allowsExpensiveNetworkAccess = allowMetered
            request.allowsConstrainedNetworkAccess = allowMetered
            task = session.downloadTask(with: request)
        }
        let identifier = "\(operation.uuidString)|\(file.stagedPath)"
        task.taskDescription = identifier
        activePath = file.stagedPath
        activeIdentifier = identifier
        activeBytes = 0
        task.resume()
    }

    private func install(_ unit: VoicePackManifest.Unit) -> Bool {
        let staged = stagingDirectory.appendingPathComponent(unit.folder, isDirectory: true)
        let destination = installDirectory(unit)
        do {
            try Self.prune(staged, keeping: Set(manifest.files(in: unit).map(\.path)))
            try JSONEncoder().encode(UnitMarker(unit: unit.rawValue, files: manifest.files(in: unit)))
                .write(to: staged.appendingPathComponent(".installed.json"), options: .atomic)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
            VoiceModelStore.excludeFromBackup(root)
            installed.insert(unit)
            publish()
            return true
        } catch {
            fail(.storage("install_failed"))
            return false
        }
    }

    private func finish() {
        try? FileManager.default.removeItem(at: downloadRequestURL)
        try? FileManager.default.removeItem(at: stagingDirectory)
        running = false
        failure = nil
        verifying = false
        publish()
    }

    private nonisolated static func prune(_ directory: URL, keeping expected: Set<String>) throws {
        guard
            let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else { return }
        let base = directory.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            if !expected.contains(relative) { try FileManager.default.removeItem(at: url) }
        }
    }

    nonisolated static func defaultRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AstralDeep", isDirectory: true).appendingPathComponent(
            "VoicePack", isDirectory: true)
    }

    nonisolated static func systemSession(_ delegate: VoiceModelDownloadDelegate) -> URLSession {
        #if os(iOS)
            let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            configuration.sessionSendsLaunchEvents = true
        #else
            let configuration = URLSessionConfiguration.default
        #endif
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

extension URLSession {
    fileprivate var pendingTasks: [URLSessionTask] {
        get async {
            await withCheckedContinuation { continuation in
                getAllTasks { continuation.resume(returning: $0) }
            }
        }
    }
}

extension URLSessionDownloadTask {
    fileprivate func cancelProducingResumeData() async -> Data? {
        await withCheckedContinuation { continuation in
            cancel { continuation.resume(returning: $0) }
        }
    }
}
