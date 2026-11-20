// Shares the download machinery behind the voice pack: failure reasons, progress, network cost, streaming SHA-256 checks and the background-session delegate that stages files.
// VoicePackStore drives it, RumbleModelLoading re-checks digests with it, and the app delegate routes background session events through it.

import CryptoKit
import Foundation
import Network

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
            return "A downloaded file didn't match its expected checksum and was discarded."
        case .storage:
            return "The voice model couldn't be saved on this device."
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
        while true {
            let hasChunk = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !hasChunk { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum VoiceModelBackgroundEvents {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: () -> Void] = [:]

    static func store(_ handler: @escaping () -> Void, for identifier: String) {
        lock.withLock { handlers[identifier] = handler }
    }

    static let identifiers: Set<String> = [VoicePackStore.backgroundIdentifier]

    static func route(_ identifier: String, completionHandler: @escaping () -> Void) {
        if identifiers.contains(identifier) {
            store(completionHandler, for: identifier)
        } else {
            completionHandler()
        }
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
        return VoicePackManifest.isSafePath(path) ? path : nil
    }
}

nonisolated enum VoiceDownloadSupport {
    static let mirrorDefaultsKey = "astral.voice.model.mirrorBase"

    static func configuredMirror(defaults: UserDefaults = .standard) -> URL? {
        guard let text = defaults.string(forKey: mirrorDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty, let url = URL(string: text), url.host != nil
        else { return nil }
        return url
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    static func systemFreeSpace(_ url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
