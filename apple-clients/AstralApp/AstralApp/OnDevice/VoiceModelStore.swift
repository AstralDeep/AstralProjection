// Downloads, verifies, installs and deletes the on-device voice model: sequential file downloads with resume, streaming SHA-256 checks, free-space and cellular gates, and an atomic install into Application Support.
// OnDeviceVoiceController drives it from the mic flow and the settings screens, and the engine loads the installed directory it reports.

import CryptoKit
import Foundation
import Network
import Observation

nonisolated enum VoiceModelFailure: Equatable, Sendable {
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case network(code: Int)
    case server(status: Int, path: String)
    case sizeMismatch(path: String)
    case checksumMismatch(path: String)
    case storage(String)
    case manifestUnavailable

    var message: String {
        switch self {
        case .insufficientSpace(let required, let available):
            let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough free space. The voice model needs \(need) and \(have) is available."
        case .network:
            return "The download was interrupted. Check your connection and try again."
        case .server(let status, _):
            return "The download server refused the request (\(status))."
        case .sizeMismatch, .checksumMismatch:
            return "A downloaded file did not match its expected checksum and was discarded."
        case .storage:
            return "The voice model could not be saved on this device."
        case .manifestUnavailable:
            return "The voice model description is missing from this build."
        }
    }
}

nonisolated struct VoiceModelDownloadProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64
    let verifying: Bool

    var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : 0
    }
}

nonisolated enum VoiceModelState: Equatable, Sendable {
    case unsupported(VoiceUnsupportedReason)
    case notInstalled
    case downloading(VoiceModelDownloadProgress)
    case installed
    case failed(VoiceModelFailure)
}

nonisolated protocol VoiceModelNetworkCost: Sendable {
    var isMetered: Bool { get }
}

nonisolated final class PathMonitorNetworkCost: VoiceModelNetworkCost, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var metered = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock { self?.metered = path.isExpensive || path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "voice-model.path"))
    }

    deinit { monitor.cancel() }

    var isMetered: Bool { lock.withLock { metered } }
}

nonisolated enum VoiceModelDigest {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum VoiceModelBackgroundEvents {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: () -> Void] = [:]

    static func store(_ handler: @escaping () -> Void, for identifier: String) {
        lock.withLock { handlers[identifier] = handler }
    }

    static func complete(_ identifier: String) {
        let handler = lock.withLock { handlers.removeValue(forKey: identifier) }
        DispatchQueue.main.async { handler?() }
    }
}

nonisolated final class VoiceModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Completion: Equatable, Sendable {
        case arrived
        case failed(VoiceModelFailure, resumeData: Data?)
        case cancelled(resumeData: Data?)
    }

    private let staging: @Sendable () -> URL
    private let expectedSizes: [String: Int64]
    var onProgress: (@Sendable (String, Int64) -> Void)?
    var onCompletion: (@Sendable (String, Completion) -> Void)?
    var onBackgroundEventsFinished: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var arrived = Set<String>()
    private var failures = [String: VoiceModelFailure]()

    init(staging: @escaping @Sendable () -> URL, expectedSizes: [String: Int64] = [:]) {
        self.staging = staging
        self.expectedSizes = expectedSizes
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let path = downloadTask.taskDescription else { return }
        if let filePath = Self.filePath(in: path), let maximum = expectedSizes[filePath], totalBytesWritten > maximum {
            lock.withLock { failures[path] = .sizeMismatch(path: filePath) }
            downloadTask.cancel()
            return
        }
        onProgress?(path, totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let identifier = downloadTask.taskDescription, let path = Self.filePath(in: identifier) else { return }
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, ![200, 206].contains(status) {
            lock.withLock { failures[identifier] = .server(status: status, path: path) }
            return
        }
        let destination = staging().appendingPathComponent(path)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { _ = arrived.insert(identifier) }
        } catch {
            lock.withLock { failures[identifier] = .storage("move_failed") }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let path = task.taskDescription else { return }
        let (didArrive, failure) = lock.withLock { () -> (Bool, VoiceModelFailure?) in
            (arrived.remove(path) != nil, failures.removeValue(forKey: path))
        }
        if let failure {
            onCompletion?(path, .failed(failure, resumeData: nil))
        } else if let error {
            let nsError = error as NSError
            let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if nsError.code == NSURLErrorCancelled {
                onCompletion?(path, .cancelled(resumeData: resume))
            } else {
                onCompletion?(path, .failed(.network(code: nsError.code), resumeData: resume))
            }
        } else if didArrive {
            onCompletion?(path, .arrived)
        } else {
            onCompletion?(path, .failed(.storage("no_file"), resumeData: nil))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onBackgroundEventsFinished?()
    }

    static func filePath(in identifier: String) -> String? {
        let path = String(identifier.split(separator: "|", maxSplits: 1).last ?? "")
        return VoiceModelManifest.isSafePath(path) ? path : nil
    }
}

@MainActor
@Observable
final class VoiceModelStore {
    nonisolated static let backgroundIdentifier = "com.personalailabs.astraldeep.voice-model"
    nonisolated static let spaceMarginBytes: Int64 = 200 << 20

    private(set) var state: VoiceModelState

    let manifest: VoiceModelManifest
    private let root: URL
    private let device: VoiceDeviceProfile
    private let network: VoiceModelNetworkCost
    private let mirror: @Sendable () -> URL?
    private let freeSpace: @Sendable (URL) -> Int64?
    private let noticeText: @Sendable () -> String?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private let delegate: VoiceModelDownloadDelegate
    @ObservationIgnored private let makeSession: (VoiceModelDownloadDelegate) -> URLSession
    @ObservationIgnored private var verified = Set<String>()
    @ObservationIgnored private var activePath: String?
    @ObservationIgnored private var activeIdentifier: String?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var activeBytes: Int64 = 0
    @ObservationIgnored private var allowMetered = false
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var verifying = false
    @ObservationIgnored private var retiringTasks = false

    init(
        manifest: VoiceModelManifest, root: URL, device: VoiceDeviceProfile = .current,
        network: VoiceModelNetworkCost = PathMonitorNetworkCost(),
        mirror: @escaping @Sendable () -> URL? = { VoiceModelManifest.configuredMirror() },
        freeSpace: @escaping @Sendable (URL) -> Int64? = VoiceModelStore.systemFreeSpace,
        noticeText: @escaping @Sendable () -> String? = VoiceModelStore.bundledNotice,
        makeSession: @escaping (VoiceModelDownloadDelegate) -> URLSession = VoiceModelStore.systemSession
    ) {
        self.manifest = manifest
        self.root = root
        self.device = device
        self.network = network
        self.mirror = mirror
        self.freeSpace = freeSpace
        self.noticeText = noticeText
        self.makeSession = makeSession
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        delegate = VoiceModelDownloadDelegate(
            staging: { staging },
            expectedSizes: Dictionary(
                manifest.files.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first }))
        if let reason = VoiceDeviceSupport.unsupportedReason(for: device) {
            state = .unsupported(reason)
        } else {
            state = Self.installedState(manifest: manifest, root: root)
        }
        delegate.onProgress = { [weak self] path, written in
            Task { @MainActor [weak self] in self?.progress(path: path, written: written) }
        }
        delegate.onCompletion = { [weak self] path, completion in
            Task { @MainActor [weak self] in await self?.completed(path: path, completion) }
        }
        delegate.onBackgroundEventsFinished = {
            VoiceModelBackgroundEvents.complete(VoiceModelStore.backgroundIdentifier)
        }
    }

    var installedDirectory: URL? {
        state == .installed ? root.appendingPathComponent("model", isDirectory: true) : nil
    }

    var needsMeteredConfirmation: Bool {
        network.isMetered
    }

    var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }
    private var installDirectory: URL { root.appendingPathComponent("model", isDirectory: true) }
    private var downloadRequestURL: URL { root.appendingPathComponent("download-request.json") }

    func attach() async {
        guard VoiceDeviceSupport.unsupportedReason(for: device) == nil,
            let data = try? Data(contentsOf: downloadRequestURL),
            let request = try? JSONDecoder().decode(DownloadRequest.self, from: data), request.manifest == manifest,
            state != .installed
        else { return }
        await reattachBackgroundTasks()
        if !isDownloading { await startDownload(allowMetered: request.allowMetered) }
    }

    func refresh() async {
        guard !isDownloading else { return }
        if let reason = VoiceDeviceSupport.unsupportedReason(for: device) {
            state = .unsupported(reason)
        } else {
            let expectedOperation = operation
            let manifest = manifest
            let root = root
            let checked = await Task.detached {
                Self.installedState(manifest: manifest, root: root, verifyDigests: true)
            }.value
            if !isDownloading, expectedOperation == operation { state = checked }
        }
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    func startDownload(allowMetered: Bool) async {
        guard !retiringTasks else { return }
        switch state {
        case .notInstalled, .failed: break
        default: return
        }
        guard (try? manifest.validate()) != nil else {
            state = .failed(.manifestUnavailable)
            return
        }
        operation = UUID()
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            Self.excludeFromBackup(root)
        } catch {
            state = .failed(.storage("create_failed"))
            return
        }
        self.allowMetered = allowMetered
        let remaining = manifest.files.filter { !fileIsComplete($0) }.reduce(Int64(0)) { $0 + $1.bytes }
        guard let available = freeSpace(root) else {
            state = .failed(.storage("free_space_unknown"))
            return
        }
        if available < remaining + Self.spaceMarginBytes {
            state = .failed(
                .insufficientSpace(requiredBytes: remaining + Self.spaceMarginBytes, availableBytes: available))
            return
        }
        do {
            try JSONEncoder().encode(DownloadRequest(manifest: manifest, allowMetered: allowMetered))
                .write(to: downloadRequestURL, options: .atomic)
        } catch {
            state = .failed(.storage("consent_save_failed"))
            return
        }
        verified = []
        state = .downloading(
            VoiceModelDownloadProgress(
                completedBytes: completedBytes(), totalBytes: manifest.totalBytes, verifying: false))
        await reconcile()
    }

    func cancelDownload() async {
        guard isDownloading, !retiringTasks else { return }
        retiringTasks = true
        defer { retiringTasks = false }
        operation = UUID()
        state = .notInstalled
        activeIdentifier = nil
        try? FileManager.default.removeItem(at: downloadRequestURL)
        if let session {
            let tasks = await session.allTasks
            for task in tasks.compactMap({ $0 as? URLSessionDownloadTask }) {
                if let identifier = task.taskDescription, let path = VoiceModelDownloadDelegate.filePath(in: identifier)
                {
                    let data = await task.cancelByProducingResumeData()
                    if let data { saveResumeData(data, for: path) }
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
        state = .notInstalled
        if let session {
            for task in await session.allTasks { task.cancel() }
        }
        activePath = nil
        activeIdentifier = nil
        activeBytes = 0
        verified = []
        do {
            for directory in [installDirectory, stagingDirectory, downloadRequestURL]
            where FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            state = .failed(.storage("delete_failed"))
            return
        }
        if let reason = VoiceDeviceSupport.unsupportedReason(for: device) {
            state = .unsupported(reason)
        } else {
            state = .notInstalled
        }
    }

    nonisolated static func installedState(manifest: VoiceModelManifest, root: URL, verifyDigests: Bool = false)
        -> VoiceModelState
    {
        let directory = root.appendingPathComponent("model", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".installed.json")),
            let marker = try? JSONDecoder().decode(InstallMarker.self, from: data),
            marker.manifest == manifest
        else { return .notInstalled }
        for file in manifest.files {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(file.path).path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                (attributes?[.size] as? NSNumber)?.int64Value == file.bytes
            else { return .notInstalled }
            if verifyDigests,
                (try? VoiceModelDigest.sha256(of: directory.appendingPathComponent(file.path))) != file.sha256
            {
                return .notInstalled
            }
        }
        return .installed
    }

    private nonisolated struct InstallMarker: Codable, Sendable {
        let manifest: VoiceModelManifest
    }

    private nonisolated struct DownloadRequest: Codable, Sendable {
        let manifest: VoiceModelManifest
        let allowMetered: Bool
    }

    private func completedBytes() -> Int64 {
        manifest.files.filter { verified.contains($0.path) }.reduce(0) { $0 + $1.bytes } + activeBytes
    }

    private func fileIsComplete(_ file: VoiceModelManifest.File) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: stagingDirectory.appendingPathComponent(file.path).path)
        return (attributes?[.size] as? NSNumber)?.int64Value == file.bytes
    }

    private func resumeURL(_ path: String) -> URL {
        stagingDirectory.appendingPathComponent(path + ".resume")
    }

    private func saveResumeData(_ data: Data, for path: String) {
        let url = resumeURL(path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            state = .failed(.storage("resume_failed"))
        }
    }

    private func updateProgress() {
        guard isDownloading else { return }
        state = .downloading(
            VoiceModelDownloadProgress(
                completedBytes: completedBytes(), totalBytes: manifest.totalBytes, verifying: verifying))
    }

    private func progress(path: String, written: Int64) {
        guard isDownloading, path == activeIdentifier else { return }
        activeBytes = written
        updateProgress()
    }

    private func fail(_ failure: VoiceModelFailure) {
        activePath = nil
        activeIdentifier = nil
        activeBytes = 0
        verifying = false
        state = .failed(failure)
    }

    private func completed(path identifier: String, _ completion: VoiceModelDownloadDelegate.Completion) async {
        guard isDownloading, identifier == activeIdentifier, let path = activePath else { return }
        activePath = nil
        activeIdentifier = nil
        activeBytes = 0
        switch completion {
        case .arrived:
            try? FileManager.default.removeItem(at: resumeURL(path))
            await reconcile()
        case .cancelled(let data):
            if let data { saveResumeData(data, for: path) }
            if isDownloading { state = .notInstalled }
        case .failed(let failure, let data):
            if let data { saveResumeData(data, for: path) }
            if case .server = failure { try? FileManager.default.removeItem(at: resumeURL(path)) }
            fail(failure)
        }
    }

    private func ensureSession() -> URLSession {
        if let session { return session }
        let created = makeSession(delegate)
        session = created
        return created
    }

    private func reattachBackgroundTasks() async {
        let tasks = await ensureSession().allTasks.compactMap { $0 as? URLSessionDownloadTask }
        if let running = tasks.first(where: { $0.state == .running || $0.state == .suspended }),
            let identifier = running.taskDescription,
            let path = VoiceModelDownloadDelegate.filePath(in: identifier),
            manifest.files.contains(where: { $0.path == path }), !isDownloading
        {
            activePath = path
            activeIdentifier = identifier
            state = .downloading(
                VoiceModelDownloadProgress(
                    completedBytes: completedBytes(), totalBytes: manifest.totalBytes, verifying: false))
            running.resume()
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
            if rerun, isDownloading { Task { await reconcile() } }
        }
        repeat {
            rerun = false
            guard isDownloading, expectedOperation == operation else { return }
            let pending = manifest.files.sorted { $0.bytes < $1.bytes }.filter { !verified.contains($0.path) }
            for file in pending where fileIsComplete(file) && activePath != file.path {
                verifying = true
                updateProgress()
                let url = stagingDirectory.appendingPathComponent(file.path)
                let digest = await Task.detached { try? VoiceModelDigest.sha256(of: url) }.value
                verifying = false
                guard isDownloading, expectedOperation == operation else { return }
                if digest == file.sha256 {
                    verified.insert(file.path)
                    updateProgress()
                } else {
                    try? FileManager.default.removeItem(at: url)
                    fail(.checksumMismatch(path: file.path))
                    return
                }
            }
            for file in manifest.files {
                let url = stagingDirectory.appendingPathComponent(file.path)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                if let size = (attributes?[.size] as? NSNumber)?.int64Value, size != file.bytes,
                    activePath != file.path,
                    !verified.contains(file.path)
                {
                    try? FileManager.default.removeItem(at: url)
                    fail(.sizeMismatch(path: file.path))
                    return
                }
            }
            if let next = manifest.files.sorted(by: { $0.bytes < $1.bytes }).first(where: {
                !verified.contains($0.path)
            }) {
                if activePath == nil { startTask(for: next) }
                if isDownloading { updateProgress() }
                continue
            }
            install()
        } while rerun
    }

    private func startTask(for file: VoiceModelManifest.File) {
        guard let url = manifest.url(for: file, mirror: mirror()) else {
            fail(.storage("bad_mirror"))
            return
        }
        let session = ensureSession()
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeURL(file.path)) {
            task = session.downloadTask(withResumeData: resume)
        } else {
            var request = URLRequest(url: url)
            request.allowsExpensiveNetworkAccess = allowMetered
            request.allowsConstrainedNetworkAccess = allowMetered
            task = session.downloadTask(with: request)
        }
        let identifier = "\(operation.uuidString)|\(file.path)"
        task.taskDescription = identifier
        activePath = file.path
        activeIdentifier = identifier
        activeBytes = 0
        task.resume()
    }

    private func install() {
        do {
            try Self.writeMarker(manifest: manifest, into: stagingDirectory, notice: noticeText())
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: installDirectory.path) {
                _ = try fileManager.replaceItemAt(installDirectory, withItemAt: stagingDirectory)
            } else {
                try fileManager.moveItem(at: stagingDirectory, to: installDirectory)
            }
            Self.excludeFromBackup(root)
            try? FileManager.default.removeItem(at: downloadRequestURL)
            state = .installed
        } catch {
            fail(.storage("install_failed"))
        }
    }

    nonisolated private static func writeMarker(manifest: VoiceModelManifest, into directory: URL, notice: String?)
        throws
    {
        let marker = InstallMarker(manifest: manifest)
        try JSONEncoder().encode(marker).write(
            to: directory.appendingPathComponent(".installed.json"), options: .atomic)
        if let notice { try Data(notice.utf8).write(to: directory.appendingPathComponent("NOTICE"), options: .atomic) }
    }

    nonisolated static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    nonisolated static func defaultRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AstralDeep", isDirectory: true).appendingPathComponent(
            "VoiceModel", isDirectory: true)
    }

    nonisolated static func systemFreeSpace(_ url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func bundledNotice() -> String? {
        guard let url = Bundle.main.url(forResource: "voice-model-NOTICE", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
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
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

extension URLSession {
    fileprivate var allTasks: [URLSessionTask] {
        get async {
            await withCheckedContinuation { continuation in
                getAllTasks { continuation.resume(returning: $0) }
            }
        }
    }
}

extension URLSessionDownloadTask {
    fileprivate func cancelByProducingResumeData() async -> Data? {
        await withCheckedContinuation { continuation in
            cancel { continuation.resume(returning: $0) }
        }
    }
}
