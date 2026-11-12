// Describes the downloadable voice model: its repository, revision, license and every file with its exact size and SHA-256, read from the manifest embedded in the app.
// VoiceModelStore downloads and verifies against it and refuses any file whose size or digest differs, and the mic flow reads the total size from it before asking to download.

import Foundation

nonisolated struct VoiceModelManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    enum Invalid: Error, Equatable {
        case notJSON
        case unsupportedFormat
        case unexpectedModel
        case emptyFileList
        case unsafePath(String)
        case duplicatePath(String)
        case badDigest(String)
        case badSize(String)
        case totalMismatch
        case missingRequiredFile(String)
    }

    static let supportedFormat = "astral.voice-model-manifest/v1"
    static let requiredFiles = [
        "config.json", "model.safetensors", "tokenizer.json", "audio_tokenizer/config.json",
        "audio_tokenizer/model.safetensors", "LICENSE",
    ]
    static let mirrorDefaultsKey = "astral.voice.model.mirrorBase"

    let displayName: String
    let format: String
    let id: String
    let license: String
    let repository: String
    let revision: String
    let runtime: String
    let source: String
    let totalBytes: Int64
    let files: [File]

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case format, id, license, repository, revision, runtime, source
        case totalBytes = "total_bytes"
        case files
    }

    static func decode(_ data: Data) throws -> VoiceModelManifest {
        let manifest: VoiceModelManifest
        do {
            manifest = try JSONDecoder().decode(VoiceModelManifest.self, from: data)
        } catch {
            throw Invalid.notJSON
        }
        try manifest.validate()
        return manifest
    }

    static func bundled(in bundle: Bundle = .main) throws -> VoiceModelManifest {
        guard let url = bundle.url(forResource: "voice-model-manifest", withExtension: "json") else {
            throw Invalid.notJSON
        }
        return try decode(Data(contentsOf: url))
    }

    func validate() throws {
        guard format == Self.supportedFormat, runtime == "mlx" else { throw Invalid.unsupportedFormat }
        guard id == "lfm3-audio-2b-3bit-mlx", repository == "Kentucky-Open-Science/LFM3-Audio-2B-MLX-3bit",
            revision == "main" || (revision.count == 40 && revision.allSatisfy({ $0.isHexDigit && !$0.isUppercase }))
        else { throw Invalid.unexpectedModel }
        guard !files.isEmpty else { throw Invalid.emptyFileList }
        var seen = Set<String>()
        var total: Int64 = 0
        for file in files {
            guard Self.isSafePath(file.path) else { throw Invalid.unsafePath(file.path) }
            guard seen.insert(file.path).inserted else { throw Invalid.duplicatePath(file.path) }
            guard file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw Invalid.badDigest(file.path)
            }
            guard file.bytes > 0 else { throw Invalid.badSize(file.path) }
            let (sum, overflow) = total.addingReportingOverflow(file.bytes)
            guard !overflow else { throw Invalid.totalMismatch }
            total = sum
        }
        guard total == totalBytes, totalBytes <= Int64.max - (200 << 20) else { throw Invalid.totalMismatch }
        for required in Self.requiredFiles where !seen.contains(required) {
            throw Invalid.missingRequiredFile(required)
        }
    }

    static func isSafePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/")
            && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && path.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.")
                    .contains($0)
            })
            && ![".installed.json", "NOTICE"].contains(path) && !path.hasSuffix(".resume")
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    func url(for file: File, mirror: URL? = nil) -> URL? {
        if let mirror {
            guard mirror.host != nil, mirror.user == nil, mirror.password == nil,
                mirror.query == nil, mirror.fragment == nil,
                mirror.scheme == "https" || Self.isLoopback(mirror)
            else { return nil }
            return file.path.split(separator: "/").reduce(mirror) { $0.appendingPathComponent(String($1)) }
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.percentEncodedPath =
            "/"
            + ([repository, "resolve", revision] + file.path.split(separator: "/").map(String.init))
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
        return components.url
    }

    static func configuredMirror(defaults: UserDefaults = .standard) -> URL? {
        guard let text = defaults.string(forKey: mirrorDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty, let url = URL(string: text), url.host != nil
        else { return nil }
        return url
    }

    private static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "")
    }
}
