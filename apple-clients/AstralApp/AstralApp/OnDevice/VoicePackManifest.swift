// Describes the downloadable voice pack: three recognition and chat model files plus the twelve files the on-device voice loads, each with its repository, pinned commit, size and SHA-256, read from the manifest embedded in the app.
// VoicePackStore downloads and verifies against it, and the install layout it defines is the folder the speech library loads from without fetching anything itself.

import Foundation

nonisolated struct VoicePackManifest: Codable, Equatable, Sendable {
    enum Part: String, Codable, Equatable, Sendable {
        case recognition
        case audioEncoder = "audio_encoder"
        case localText = "local_text"
        case voice
    }

    enum Unit: String, CaseIterable, Sendable {
        case model
        case voice

        var folder: String { rawValue }
    }

    struct File: Codable, Equatable, Sendable {
        let repository: String
        let revision: String
        let path: String
        let bytes: Int64
        let sha256: String
        let part: Part

        var unit: Unit { part == .voice ? .voice : .model }
        var stagedPath: String { unit.folder + "/" + path }
    }

    enum Invalid: Error, Equatable {
        case notJSON
        case unsupportedFormat
        case unexpectedOrigin
        case unexpectedRepository(String)
        case emptyFileList
        case unsafePath(String)
        case duplicatePath(String)
        case badDigest(String)
        case badSize(String)
        case badRevision(String)
        case inconsistentRevision(String)
        case misplacedPart(String)
        case totalMismatch
        case missingRequiredFile(String)
    }

    static let supportedFormat = "astral.voice-pack-manifest/v1"
    static let origin = "https://huggingface.co"
    static let rumbleRepository = "Kentucky-Open-Science/Rumble-2-Flash-Astral"
    static let voiceRepository = "FluidInference/pocket-tts-coreml"
    static let voiceSubdirectory = "phonon/phonon-31m-en"
    static let requiredModelFiles: [String: Part] = [
        "rumble/Rumble-2-Flash-AD-Q5_K_M.gguf": .recognition,
        "rumble/mmproj-Rumble-2-Flash-Q8_0.gguf": .audioEncoder,
        "chat-1.2b/LFM2.5-1.2B-Instruct-Q4_K_M.gguf": .localText,
    ]
    static let requiredVoiceFiles = [
        "arch.json", "pocket_state.json", "pocket_state.mlmodelc/coremldata.bin", "pocket_state.mlmodelc/model.mil",
        "pocket_state.mlmodelc/weights/weight.bin", "mimi_decoder.mlmodelc/coremldata.bin",
        "mimi_decoder.mlmodelc/model.mil", "mimi_decoder.mlmodelc/weights/weight.bin", "constants_bin/bos_emb.bin",
        "constants_bin/text_embed_table.bin", "constants_bin/tokenizer.model", "constants_bin/default.safetensors",
    ].map { voiceSubdirectory + "/" + $0 }

    let displayName: String
    let format: String
    let id: String
    let origin: String
    let totalBytes: Int64
    let files: [File]

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case format, id, origin
        case totalBytes = "total_bytes"
        case files
    }

    static func decode(_ data: Data) throws -> VoicePackManifest {
        let manifest: VoicePackManifest
        do {
            manifest = try JSONDecoder().decode(VoicePackManifest.self, from: data)
        } catch {
            throw Invalid.notJSON
        }
        try manifest.validate()
        return manifest
    }

    static func bundled(in bundle: Bundle = .main) throws -> VoicePackManifest {
        guard let url = bundle.url(forResource: "voice-pack-manifest", withExtension: "json") else {
            throw Invalid.notJSON
        }
        return try decode(Data(contentsOf: url))
    }

    func validate() throws {
        guard format == Self.supportedFormat else { throw Invalid.unsupportedFormat }
        guard origin == Self.origin else { throw Invalid.unexpectedOrigin }
        guard !files.isEmpty else { throw Invalid.emptyFileList }
        var seen = Set<String>()
        var revisions = [String: String]()
        var total: Int64 = 0
        for file in files {
            guard file.repository == Self.rumbleRepository || file.repository == Self.voiceRepository else {
                throw Invalid.unexpectedRepository(file.repository)
            }
            guard VoiceModelManifest.isSafePath(file.path) else { throw Invalid.unsafePath(file.path) }
            let folded = file.path.lowercased()
            guard seen.insert(folded).inserted,
                !seen.contains(where: { $0.hasPrefix(folded + "/") || folded.hasPrefix($0 + "/") })
            else { throw Invalid.duplicatePath(file.path) }
            guard Self.isCommit(file.revision) else { throw Invalid.badRevision(file.path) }
            guard revisions.updateValue(file.revision, forKey: file.repository) ?? file.revision == file.revision else {
                throw Invalid.inconsistentRevision(file.repository)
            }
            guard file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw Invalid.badDigest(file.path)
            }
            guard file.bytes > 0 else { throw Invalid.badSize(file.path) }
            let placed =
                file.part == .voice
                ? file.repository == Self.voiceRepository && Self.requiredVoiceFiles.contains(file.path)
                : file.repository == Self.rumbleRepository && Self.requiredModelFiles[file.path] == file.part
            guard placed else { throw Invalid.misplacedPart(file.path) }
            let (sum, overflow) = total.addingReportingOverflow(file.bytes)
            guard !overflow else { throw Invalid.totalMismatch }
            total = sum
        }
        guard total == totalBytes, totalBytes <= Int64.max - (200 << 20) else { throw Invalid.totalMismatch }
        let present = Set(files.map(\.path))
        for required in Self.requiredModelFiles.keys.sorted() + Self.requiredVoiceFiles
        where !present.contains(required) {
            throw Invalid.missingRequiredFile(required)
        }
    }

    static func isCommit(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    func files(in unit: Unit) -> [File] {
        files.filter { $0.unit == unit }
    }

    func bytes(in unit: Unit) -> Int64 {
        files(in: unit).reduce(0) { $0 + $1.bytes }
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    func url(for file: File, mirror: URL? = nil) -> URL? {
        let tail = ([file.repository, "resolve", file.revision] + file.path.split(separator: "/").map(String.init))
        if let mirror {
            guard mirror.host != nil, mirror.user == nil, mirror.password == nil, mirror.query == nil,
                mirror.fragment == nil, mirror.scheme == "https" || Self.isLoopback(mirror)
            else { return nil }
            return tail.flatMap { $0.split(separator: "/") }.reduce(mirror) {
                $0.appendingPathComponent(String($1))
            }
        }
        guard let origin = URL(string: origin), origin.scheme == "https" else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = origin.host
        components.percentEncodedPath =
            "/"
            + tail.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
        return components.url
    }

    private static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "")
    }
}
