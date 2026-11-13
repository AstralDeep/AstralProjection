// Fetches the node pack's descriptor, downloads its archive, checks every digest, unpacks it into staging and moves it into Application Support only when the whole tree matches its manifest.
// NodeHostController drives it, and a failed or tampered download leaves the previous installation untouched.

#if os(macOS)
    import CryptoKit
    import Foundation

    public protocol NodePackTransport: Sendable {
        func data(from url: URL, maxBytes: Int) async throws -> Data
        func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void)
            async throws
    }

    public enum NodePackURLPolicy {
        private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost", "[::1]"]

        public static func permits(_ url: URL) -> Bool {
            switch url.scheme?.lowercased() {
            case "https": return url.host?.isEmpty == false
            case "http": return url.host.map { loopbackHosts.contains($0.lowercased()) } ?? false
            case "file": return url.isFileURL
            default: return false
            }
        }
    }

    public struct NodePackTree {
        public static func sha256(of url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        static func linkEscapes(path: String, target: String) -> Bool {
            if target.hasPrefix("/") { return true }
            var parts: [Substring] = path.split(separator: "/").dropLast()
            for piece in target.split(separator: "/") {
                switch piece {
                case ".": continue
                case "..":
                    if parts.isEmpty { return true }
                    parts.removeLast()
                default: parts.append(piece)
                }
            }
            return false
        }

        public static func problems(in root: URL, manifest: NodePackManifest) -> [String] {
            let fileManager = FileManager.default
            var found: [String: FileAttributeType] = [:]
            func walk(_ relative: String) {
                let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
                for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                    let child = relative.isEmpty ? name : relative + "/" + name
                    let type = (try? fileManager.attributesOfItem(atPath: root.appendingPathComponent(child).path))?[.type]
                        as? FileAttributeType
                    if type == .typeDirectory {
                        walk(child)
                    } else {
                        found[child] = type ?? .typeUnknown
                    }
                }
            }
            walk("")
            found.removeValue(forKey: "manifest.json")
            var problems: [String] = []
            let expected = Dictionary(manifest.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            for path in found.keys.sorted() where expected[path] == nil { problems.append("unexpected file \(path)") }
            for entry in manifest.files.sorted(by: { $0.path < $1.path }) {
                guard let type = found[entry.path] else {
                    problems.append("missing file \(entry.path)")
                    continue
                }
                let url = root.appendingPathComponent(entry.path)
                if let link = entry.link {
                    if type != .typeSymbolicLink || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != link {
                        problems.append("link changed \(entry.path)")
                    } else if linkEscapes(path: entry.path, target: link) {
                        problems.append("link leaves the pack \(entry.path)")
                    }
                } else if type != .typeRegular {
                    problems.append("not a regular file \(entry.path)")
                } else {
                    let size = ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
                    let mode = ((try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?
                        .intValue ?? 0
                    if size != entry.size || (try? sha256(of: url)) != entry.sha256 {
                        problems.append("content changed \(entry.path)")
                    } else if (entry.executable ?? false) != (mode & 0o100 != 0) {
                        problems.append("mode changed \(entry.path)")
                    }
                }
            }
            return problems
        }
    }

    public actor NodePackInstaller {
        public static let maximumDescriptorBytes = 64 * 1024
        public static let maximumManifestBytes = 32 * 1024 * 1024
        static let spaceMargin: Int64 = 256 * 1024 * 1024

        private let root: URL
        private let transport: NodePackTransport
        private let pinnedDescriptorSha256: String?
        private let availableSpace: @Sendable (URL) -> Int64
        private let fileManager = FileManager.default

        public init(
            root: URL, transport: NodePackTransport, pinnedDescriptorSha256: String? = nil,
            availableSpace: @escaping @Sendable (URL) -> Int64 = NodePackInstaller.volumeAvailableBytes
        ) {
            self.root = root
            self.transport = transport
            self.pinnedDescriptorSha256 = pinnedDescriptorSha256?.lowercased()
            self.availableSpace = availableSpace
        }

        public static func volumeAvailableBytes(at url: URL) -> Int64 {
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage ?? 0
        }

        public func fetchOffer(from descriptorURL: URL) async throws -> NodePackOffer {
            guard NodePackURLPolicy.permits(descriptorURL) else {
                throw NodePackError.unsupportedURL(descriptorURL.absoluteString)
            }
            let raw = try await transport.data(from: descriptorURL, maxBytes: Self.maximumDescriptorBytes)
            let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
            if let pinnedDescriptorSha256, pinnedDescriptorSha256 != digest { throw NodePackError.descriptorPinMismatch }
            guard let descriptor = try? JSONDecoder().decode(NodePackDescriptor.self, from: raw),
                descriptor.format == NodePackDescriptor.formatName
            else { throw NodePackError.descriptorInvalid("unrecognized format") }
            guard descriptor.platform == NodePackDescriptor.platformName else {
                throw NodePackError.platformMismatch(descriptor.platform)
            }
            let file = descriptor.archive.file
            guard !file.isEmpty, !file.contains("/"), file != "..", file != ".", descriptor.archive.size > 0,
                descriptor.installedBytes > 0, Self.isDigest(descriptor.archive.sha256),
                Self.isDigest(descriptor.manifestSha256), Self.isVersion(descriptor.version)
            else { throw NodePackError.descriptorInvalid("fields are out of range") }
            let archiveURL = descriptorURL.deletingLastPathComponent().appendingPathComponent(file)
            guard NodePackURLPolicy.permits(archiveURL) else {
                throw NodePackError.unsupportedURL(archiveURL.absoluteString)
            }
            return NodePackOffer(descriptor: descriptor, archiveURL: archiveURL, descriptorSha256: digest)
        }

        public func install(
            _ offer: NodePackOffer, progress: @escaping @Sendable (NodePackInstallProgress) -> Void
        ) async throws -> InstalledNodePack {
            try fileManager.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let needed = offer.downloadBytes + offer.installedBytes + Self.spaceMargin
            let available = availableSpace(root)
            guard available >= needed else {
                throw NodePackError.insufficientSpace(needed: needed, available: available)
            }
            let work = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: work) }

            let archive = work.appendingPathComponent("pack.tar.gz")
            progress(.downloading(received: 0, expected: offer.downloadBytes))
            do {
                try await transport.download(from: offer.archiveURL, to: archive) { received, expected in
                    progress(.downloading(received: received, expected: expected > 0 ? expected : offer.downloadBytes))
                }
            } catch let error as NodePackError {
                throw error
            } catch {
                throw NodePackError.downloadFailed(String(describing: error))
            }

            progress(.verifying)
            let actualSize = ((try? fileManager.attributesOfItem(atPath: archive.path))?[.size] as? NSNumber)?.int64Value ?? -1
            guard actualSize == offer.descriptor.archive.size else {
                throw NodePackError.sizeMismatch(expected: offer.descriptor.archive.size, actual: actualSize)
            }
            guard try NodePackTree.sha256(of: archive) == offer.descriptor.archive.sha256 else {
                throw NodePackError.digestMismatch("archive")
            }

            progress(.unpacking)
            let unpacked = work.appendingPathComponent("tree", isDirectory: true)
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await Self.extract(archive, into: unpacked)
            let manifestURL = unpacked.appendingPathComponent("manifest.json")
            guard (try? NodePackTree.sha256(of: manifestURL)) == offer.descriptor.manifestSha256 else {
                throw NodePackError.digestMismatch("manifest")
            }
            let manifestData = try Data(contentsOf: manifestURL)
            guard manifestData.count <= Self.maximumManifestBytes,
                let manifest = try? JSONDecoder().decode(NodePackManifest.self, from: manifestData),
                manifest.version == offer.descriptor.version, manifest.platform == offer.descriptor.platform
            else { throw NodePackError.descriptorInvalid("manifest does not match the descriptor") }
            progress(.checking)
            let problems = NodePackTree.problems(in: unpacked, manifest: manifest)
            guard problems.isEmpty else { throw NodePackError.treeMismatch(Array(problems.prefix(20))) }

            let packs = root.appendingPathComponent("packs", isDirectory: true)
            try fileManager.createDirectory(at: packs, withIntermediateDirectories: true)
            let destination = packs.appendingPathComponent(offer.descriptor.version, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: unpacked, to: destination)
            let installed = InstalledNodePack(
                version: offer.descriptor.version, manifestSha256: offer.descriptor.manifestSha256, root: destination,
                installedAt: Date())
            try record(installed)
            prune(keeping: installed.version)
            progress(.done)
            return installed
        }

        public func installed() -> InstalledNodePack? {
            guard let data = try? Data(contentsOf: recordURL),
                let installed = try? Self.decoder.decode(InstalledNodePack.self, from: data),
                fileManager.isExecutableFile(atPath: installed.root.appendingPathComponent("python/bin/python3.11").path)
            else { return nil }
            return installed
        }

        public func verify(_ installed: InstalledNodePack) throws {
            let manifestURL = installed.root.appendingPathComponent("manifest.json")
            guard try NodePackTree.sha256(of: manifestURL) == installed.manifestSha256 else {
                throw NodePackError.digestMismatch("manifest")
            }
            let manifest = try JSONDecoder().decode(NodePackManifest.self, from: Data(contentsOf: manifestURL))
            let problems = NodePackTree.problems(in: installed.root, manifest: manifest)
            guard problems.isEmpty else { throw NodePackError.treeMismatch(Array(problems.prefix(20))) }
        }

        public func remove() throws {
            try? fileManager.removeItem(at: recordURL)
            try? fileManager.removeItem(at: root.appendingPathComponent("packs", isDirectory: true))
        }

        private var recordURL: URL { root.appendingPathComponent("installed.json") }

        private static var decoder: JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }

        private func record(_ installed: InstalledNodePack) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(installed).write(to: recordURL, options: .atomic)
        }

        private func prune(keeping version: String) {
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            for name in (try? fileManager.contentsOfDirectory(atPath: packs.path)) ?? [] where name != version {
                try? fileManager.removeItem(at: packs.appendingPathComponent(name))
            }
        }

        private static func isDigest(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }

        private static func isVersion(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 64
                && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" || $0 == "+" }
        }

        private static func extract(_ archive: URL, into directory: URL) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = ["-xzf", archive.path, "-C", directory.path]
                process.environment = ["PATH": "/usr/bin:/bin"]
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                process.terminationHandler = { finished in
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    if finished.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: NodePackError.extractionFailed(String(message.prefix(400))))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: NodePackError.extractionFailed("\(error)")) }
            }
        }
    }

    public enum NodePackInstallProgress: Equatable, Sendable {
        case downloading(received: Int64, expected: Int64)
        case verifying
        case unpacking
        case checking
        case done
    }

    public final class URLSessionNodePackTransport: NSObject, NodePackTransport, URLSessionTaskDelegate,
        URLSessionDownloadDelegate, @unchecked Sendable
    {
        private let lock = NSLock()
        private var progressHandlers: [Int: @Sendable (Int64, Int64) -> Void] = [:]
        private var destinations: [Int: URL] = [:]
        private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
        private var failures: [Int: Error] = [:]
        private lazy var session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.waitsForConnectivity = false
            return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }()

        public func data(from url: URL, maxBytes: Int) async throws -> Data {
            guard NodePackURLPolicy.permits(url) else { throw NodePackError.unsupportedURL(url.absoluteString) }
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NodePackError.downloadFailed("http \(http.statusCode)")
            }
            guard data.count <= maxBytes else { throw NodePackError.downloadFailed("response is larger than \(maxBytes) bytes") }
            return data
        }

        public func download(
            from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws {
            guard NodePackURLPolicy.permits(url) else { throw NodePackError.unsupportedURL(url.absoluteString) }
            let task = session.downloadTask(with: url)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    progressHandlers[task.taskIdentifier] = progress
                    destinations[task.taskIdentifier] = destination
                    continuations[task.taskIdentifier] = continuation
                    lock.unlock()
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        public func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            lock.lock()
            let handler = progressHandlers[downloadTask.taskIdentifier]
            lock.unlock()
            handler?(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
        }

        public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            lock.lock()
            let destination = destinations[downloadTask.taskIdentifier]
            lock.unlock()
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                record(failure: NodePackError.downloadFailed("http \(http.statusCode)"), for: downloadTask.taskIdentifier)
                return
            }
            guard let destination else { return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                record(failure: NodePackError.downloadFailed("\(error)"), for: downloadTask.taskIdentifier)
            }
        }

        public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let continuation = continuations.removeValue(forKey: task.taskIdentifier)
            let recorded = failures.removeValue(forKey: task.taskIdentifier)
            progressHandlers.removeValue(forKey: task.taskIdentifier)
            destinations.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            if let failure = recorded ?? error {
                continuation?.resume(throwing: failure)
            } else {
                continuation?.resume()
            }
        }

        public func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(request.url.map(NodePackURLPolicy.permits) == true ? request : nil)
        }

        private func record(failure: Error, for identifier: Int) {
            lock.lock()
            failures[identifier] = failure
            lock.unlock()
        }
    }
#endif
