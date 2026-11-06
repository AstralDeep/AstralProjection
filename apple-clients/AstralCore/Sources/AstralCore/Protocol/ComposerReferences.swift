// Decoders and transports for the composer_references_v1 presentation contract: the rote_config
// capability acknowledgment, the project instructions report with per-file hashes, and the
// per-project ingestion toggle. AppModel consumes these to gate the Mac composer reference UI
// and the instructions indicator on the server advertisement.

import Foundation

public struct ComposerReferencesAcknowledgement: Sendable, Equatable {
    public let instructionsReporting: Bool
    public let ingestionControl: Bool

    public static func fromRoteConfig(_ payload: JSONValue) -> ComposerReferencesAcknowledgement? {
        ComposerReferencesAcknowledgement(json: payload["device_profile"]?["console"]?["composer_references"])
    }
}

extension ComposerReferencesAcknowledgement {
    public init?(json: JSONValue?) {
        guard let object = json?.objectValue,
            Set(object.keys) == ["version", "instructions_reporting", "ingestion_control"],
            object["version"] == .number(1),
            let instructionsReporting = object["instructions_reporting"]?.boolValue,
            let ingestionControl = object["ingestion_control"]?.boolValue
        else { return nil }
        self.instructionsReporting = instructionsReporting
        self.ingestionControl = ingestionControl
    }
}

public struct ProjectInstructionsFile: Sendable, Equatable {
    public static let maximumPathScalars = 1024
    public static let maximumFiles = 32

    public let path: String
    public let sha256: String
    public let bytes: Int

    public init?(json: JSONValue) {
        guard let object = json.objectValue, Set(object.keys) == ["path", "sha256", "bytes"],
            let path = object["path"]?.stringValue, !path.hasPrefix("/"), !path.hasSuffix("/"),
            path.unicodeScalars.count <= Self.maximumPathScalars,
            !path.split(separator: "/").contains(".."),
            let sha256 = object["sha256"]?.stringValue, sha256.count == 64,
            sha256.allSatisfy({ $0.isHexDigit && $0.isLowercase }),
            let bytes = object["bytes"]?.numberValue, bytes.isFinite, bytes.rounded() == bytes,
            bytes >= 0, bytes <= 4_000_000
        else { return nil }
        self.path = path
        self.sha256 = sha256
        self.bytes = Int(bytes)
    }
}

public struct ProjectInstructionsReport: Sendable, Equatable {
    public let projectId: String
    public let enabled: Bool
    public let revision: UInt64
    public let files: [ProjectInstructionsFile]

    public init?(json: JSONValue) {
        guard let object = json.objectValue,
            Set(object.keys) == ["project_id", "enabled", "revision", "files"],
            let projectId = object["project_id"]?.stringValue, ProjectIdentity.valid(projectId),
            let enabled = object["enabled"]?.boolValue,
            let revision = ProjectIdentity.integer(object["revision"], positive: true),
            let items = object["files"]?.arrayValue, items.count <= ProjectInstructionsFile.maximumFiles
        else { return nil }
        let decoded = try? items.map { item -> ProjectInstructionsFile in
            guard let file = ProjectInstructionsFile(json: item) else { throw ProjectAPIError.invalidResponse }
            return file
        }
        guard let files = decoded, Set(files.map(\.path)).count == files.count else { return nil }
        self.projectId = projectId
        self.enabled = enabled
        self.revision = revision
        self.files = files
    }
}

extension RestClient {
    public func projectInstructions(id: String) async throws -> ProjectInstructionsReport {
        try requireProject(id)
        return try ProjectInstructionsReport(json: await projectRequest("GET", "api/projects/\(id)/instructions"))
    }

    public func setProjectInstructions(id: String, enabled: Bool, revision: UInt64) async throws
        -> ProjectInstructionsReport
    {
        try requireProject(id, revision)
        return try ProjectInstructionsReport(
            json: await projectRequest(
                "PUT", "api/projects/\(id)/instructions",
                body: .object([
                    "enabled": .bool(enabled), "revision": .number(Double(revision)),
                ])))
    }
}
