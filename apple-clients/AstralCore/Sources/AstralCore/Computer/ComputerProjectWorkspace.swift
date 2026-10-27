// Bounded project manifests and immutable origin contexts bind Mac grants to server-authorized conversations.
// Both host admission and native execution consume these exact ordered, revisioned values.

import CryptoKit
import Foundation

public struct ComputerProjectWorkspace: Sendable, Equatable {
    public let projectId: String
    public let grantRevision: UInt64
    public let roots: [ComputerHostWorkspaceRoot]
    public init(projectId: String, grantRevision: UInt64, roots: [ComputerHostWorkspaceRoot]) throws {
        guard ProjectIdentity.valid(projectId), (1...9_007_199_254_740_991).contains(grantRevision),
            roots.count <= 16, Set(roots.map(\.path)).count == roots.count,
            roots.allSatisfy({ root in
                ProjectIdentity.name(root.name) && root.path.hasPrefix("/") && root.path != "/"
                    && root.path.unicodeScalars.count <= 1024 && !root.path.hasSuffix("/")
                    && !root.path.contains("//") && !root.path.split(separator: "/").contains(".")
                    && !root.path.split(separator: "/").contains("..")
                    && !root.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            })
        else { throw ComputerHostError("invalid_project_manifest", "The project folder grant is invalid.") }
        self.projectId = projectId
        self.grantRevision = grantRevision
        self.roots = roots
    }
    public init(json: JSONValue) throws {
        guard let object = json.objectValue, Set(object.keys) == ["project_id", "grant_revision", "roots"],
            let id = object["project_id"]?.stringValue,
            let revision = ProjectIdentity.integer(object["grant_revision"], positive: true),
            let values = object["roots"]?.arrayValue
        else {
            throw ComputerHostError("invalid_project_manifest", "The project folder grant is invalid.")
        }
        let roots = try values.map { value -> ComputerHostWorkspaceRoot in
            guard let root = value.objectValue, Set(root.keys) == ["name", "path"],
                let name = root["name"]?.stringValue, let path = root["path"]?.stringValue
            else {
                throw ComputerHostError("invalid_project_manifest", "The project folder is invalid.")
            }
            return ComputerHostWorkspaceRoot(name: name, path: path)
        }
        try self.init(projectId: id, grantRevision: revision, roots: roots)
    }
    public var json: JSONValue {
        .object([
            "project_id": .string(projectId), "grant_revision": .number(Double(grantRevision)),
            "roots": .array(roots.map(\.json)),
        ])
    }
}

public struct ComputerProjectManifest: Sendable, Equatable {
    public static let maximumProjects = 64
    public static let maximumRoots = 256
    public static let maximumBytes = 262144
    public let generation: UInt64
    public let projects: [ComputerProjectWorkspace]
    public let digest: String
    public init(generation: UInt64, projects: [ComputerProjectWorkspace]) throws {
        guard (1...9_007_199_254_740_991).contains(generation), projects.count <= Self.maximumProjects,
            Set(projects.map(\.projectId)).count == projects.count,
            projects.reduce(0, { $0 + $1.roots.count }) <= Self.maximumRoots
        else {
            throw ComputerHostError("invalid_project_manifest", "The project manifest exceeds its bounds.")
        }
        self.generation = generation
        self.projects = projects
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Self.value(generation, projects))
        guard bytes.count <= Self.maximumBytes else {
            throw ComputerHostError("invalid_project_manifest", "The project manifest exceeds its byte limit.")
        }
        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public init(json: JSONValue) throws {
        guard let object = json.objectValue, Set(object.keys) == ["generation", "projects"],
            let generation = ProjectIdentity.integer(object["generation"], positive: true),
            let items = object["projects"]?.arrayValue, items.count <= Self.maximumProjects
        else {
            throw ComputerHostError("invalid_project_manifest", "The project manifest is invalid.")
        }
        try self.init(generation: generation, projects: items.map(ComputerProjectWorkspace.init(json:)))
    }
    public var json: JSONValue { Self.value(generation, projects) }
    private static func value(_ generation: UInt64, _ projects: [ComputerProjectWorkspace]) -> JSONValue {
        .object(["generation": .number(Double(generation)), "projects": .array(projects.map(\.json))])
    }
}

public struct ComputerProjectContext: Sendable, Equatable {
    public let chatId: String
    public let projectId: String
    public let grantRevision: UInt64?
    public let manifestGeneration: UInt64
    public init(chatId: String, projectId: String, grantRevision: UInt64?, manifestGeneration: UInt64) throws {
        guard !chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, chatId.unicodeScalars.count <= 512,
            ProjectIdentity.valid(projectId), (1...9_007_199_254_740_991).contains(manifestGeneration),
            grantRevision.map({ (1...9_007_199_254_740_991).contains($0) }) ?? true
        else {
            throw ComputerHostError("invalid_project_context", "The origin project binding is invalid.")
        }
        self.chatId = chatId
        self.projectId = projectId
        self.grantRevision = grantRevision
        self.manifestGeneration = manifestGeneration
    }
    public init(json: JSONValue) throws {
        guard let object = json.objectValue,
            Set(object.keys) == ["chat_id", "project_id", "grant_revision", "manifest_generation"],
            let chat = object["chat_id"]?.stringValue, let project = object["project_id"]?.stringValue,
            let generation = ProjectIdentity.integer(object["manifest_generation"], positive: true),
            object["grant_revision"] == .null
                || ProjectIdentity.integer(object["grant_revision"], positive: true) != nil
        else { throw ComputerHostError("invalid_project_context", "The origin project binding is invalid.") }
        try self.init(
            chatId: chat, projectId: project,
            grantRevision: ProjectIdentity.integer(object["grant_revision"], positive: true),
            manifestGeneration: generation)
    }
    public var json: JSONValue {
        .object([
            "chat_id": .string(chatId), "project_id": .string(projectId),
            "grant_revision": grantRevision.map { .number(Double($0)) } ?? .null,
            "manifest_generation": .number(Double(manifestGeneration)),
        ])
    }
}
