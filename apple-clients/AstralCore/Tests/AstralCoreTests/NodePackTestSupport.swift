// Builds a small real node pack archive with a matching descriptor and manifest, and supplies the fakes the node host tests share.
// NodePackInstallerTests, NodeHostControllerTests and NodeSupervisorTests use it so they exercise the real tar extraction and digest checks.

#if os(macOS)
    import CryptoKit
    import XCTest

    @testable import AstralCore

    struct BuiltPack {
        let directory: URL
        let descriptorURL: URL
        let descriptor: NodePackDescriptor
        let manifest: NodePackManifest
        let tree: URL
    }

    enum NodePackTestSupport {
        static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

        static func temporaryDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("nodepack-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        static func tar(_ directory: URL, to archive: URL, names: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-czf", archive.path, "-C", directory.path] + names
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        static func build(
            version: String = "3.11.18-test", files: [(String, String, Bool)] = defaultFiles, platform: String = "macos-arm64",
            mutate: (URL) throws -> Void = { _ in }
        ) throws -> BuiltPack {
            let directory = try temporaryDirectory()
            let tree = directory.appendingPathComponent("tree")
            var entries: [NodePackManifest.Entry] = []
            for (path, body, executable) in files {
                let url = tree.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(body.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
                entries.append(
                    .init(path: path, sha256: sha(Data(body.utf8)), size: Int64(body.utf8.count), executable: executable))
            }
            let link = tree.appendingPathComponent("python/bin/python")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "python3.11")
            entries.append(.init(path: "python/bin/python", link: "python3.11"))
            let manifest = NodePackManifest(
                format: "astral.nodepack-manifest/v1", version: version, platform: platform,
                installedBytes: entries.reduce(0) { $0 + ($1.size ?? 0) }, files: entries.sorted { $0.path < $1.path })
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: tree.appendingPathComponent("manifest.json"))
            try mutate(tree)
            let archive = directory.appendingPathComponent("pack.tar.gz")
            try tar(tree, to: archive, names: ["."])
            let archiveData = try Data(contentsOf: archive)
            let descriptor = NodePackDescriptor(
                version: version, platform: platform,
                archive: .init(file: "pack.tar.gz", size: Int64(archiveData.count), sha256: sha(archiveData)),
                installedBytes: max(manifest.installedBytes, 1), manifestSha256: sha(manifestData))
            let descriptorURL = directory.appendingPathComponent("node-pack.json")
            try JSONEncoder().encode(descriptor).write(to: descriptorURL)
            return BuiltPack(
                directory: directory, descriptorURL: descriptorURL, descriptor: descriptor, manifest: manifest, tree: tree)
        }

        static let defaultFiles: [(String, String, Bool)] = [
            ("python/bin/python3.11", "#!/bin/sh\nexit 0\n", true),
            ("launcher/astral_node_launch.py", "print('x')\n", false),
            ("app/scripts/node/install-personal-node.sh", "#!/bin/sh\n", true),
            ("app/backend/orchestrator/orchestrator.py", "x = 1\n", false),
        ]
    }

    struct FileTransport: NodePackTransport {
        var corruptDownload = false
        var failDownload = false

        func data(from url: URL, maxBytes: Int) async throws -> Data {
            guard NodePackURLPolicy.permits(url) else { throw NodePackError.unsupportedURL(url.absoluteString) }
            let data = try Data(contentsOf: url)
            guard data.count <= maxBytes else { throw NodePackError.downloadFailed("too large") }
            return data
        }

        func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            if failDownload { throw NodePackError.downloadFailed("offline") }
            var data = try Data(contentsOf: url)
            progress(Int64(data.count / 2), Int64(data.count))
            if corruptDownload { data[data.count / 2] ^= 0xFF }
            try data.write(to: destination)
            progress(Int64(data.count), Int64(data.count))
        }
    }

    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [NodePackInstallProgress] = []
        func add(_ item: NodePackInstallProgress) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }
        var values: [NodePackInstallProgress] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }
#endif
