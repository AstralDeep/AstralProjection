// Describes the downloadable node pack: the descriptor a host serves, the manifest inside the archive and the failures the installer reports.
// NodePackInstaller reads these, and the app shows the descriptor's sizes before anything is downloaded.

#if os(macOS)
    import Foundation

    public struct NodePackDescriptor: Codable, Equatable, Sendable {
        public struct Archive: Codable, Equatable, Sendable {
            public let file: String
            public let size: Int64
            public let sha256: String

            public init(file: String, size: Int64, sha256: String) {
                self.file = file
                self.size = size
                self.sha256 = sha256
            }
        }

        public static let formatName = "astral.nodepack-descriptor/v1"
        public static let platformName = "macos-arm64"

        public let format: String
        public let version: String
        public let platform: String
        public let archive: Archive
        public let installedBytes: Int64
        public let manifestSha256: String

        public init(
            format: String = NodePackDescriptor.formatName, version: String,
            platform: String = NodePackDescriptor.platformName, archive: Archive, installedBytes: Int64,
            manifestSha256: String
        ) {
            self.format = format
            self.version = version
            self.platform = platform
            self.archive = archive
            self.installedBytes = installedBytes
            self.manifestSha256 = manifestSha256
        }

        enum CodingKeys: String, CodingKey {
            case format, version, platform, archive
            case installedBytes = "installed_bytes"
            case manifestSha256 = "manifest_sha256"
        }
    }

    public struct NodePackManifest: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public let path: String
            public let sha256: String?
            public let size: Int64?
            public let executable: Bool?
            public let link: String?

            public init(
                path: String, sha256: String? = nil, size: Int64? = nil, executable: Bool? = nil, link: String? = nil
            ) {
                self.path = path
                self.sha256 = sha256
                self.size = size
                self.executable = executable
                self.link = link
            }
        }

        public let format: String
        public let version: String
        public let platform: String
        public let installedBytes: Int64
        public let files: [Entry]

        public init(format: String, version: String, platform: String, installedBytes: Int64, files: [Entry]) {
            self.format = format
            self.version = version
            self.platform = platform
            self.installedBytes = installedBytes
            self.files = files
        }

        enum CodingKeys: String, CodingKey {
            case format, version, platform, files
            case installedBytes = "installed_bytes"
        }
    }

    public struct NodePackOffer: Equatable, Sendable {
        public let descriptor: NodePackDescriptor
        public let archiveURL: URL
        public let descriptorSha256: String

        public var downloadBytes: Int64 { descriptor.archive.size }
        public var installedBytes: Int64 { descriptor.installedBytes }

        public var sizeDescription: String {
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            return "\(format(downloadBytes)) to download, \(format(installedBytes)) on disk"
        }
    }

    public struct InstalledNodePack: Codable, Equatable, Sendable {
        public let version: String
        public let manifestSha256: String
        public let root: URL
        public let installedAt: Date
    }

    public enum NodePackError: Error, Equatable, Sendable {
        case unsupportedURL(String)
        case descriptorInvalid(String)
        case descriptorPinMismatch
        case platformMismatch(String)
        case insufficientSpace(needed: Int64, available: Int64)
        case downloadFailed(String)
        case sizeMismatch(expected: Int64, actual: Int64)
        case digestMismatch(String)
        case extractionFailed(String)
        case treeMismatch([String])
        case notInstalled
    }
#endif
