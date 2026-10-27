// Owner project records and paginated requests use the existing Bearer-only REST transport.
// Local filesystem grants remain separate from the synchronized catalog and chat membership.

import Foundation

public enum ProjectAPIError: Error, LocalizedError, Sendable, Equatable {
    case invalidResponse
    case refused(status: Int, code: String, message: String)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The project response is invalid. Refresh and try again."
        case .refused(_, _, let message): return message
        }
    }
}

public enum ProjectIdentity {
    public static func valid(_ text: String) -> Bool {
        UUID(uuidString: text)?.uuidString.lowercased() == text
    }
    public static func integer(_ value: JSONValue?, positive: Bool = false) -> UInt64? {
        guard let number = value?.numberValue, number.isFinite, number.rounded() == number,
            number >= (positive ? 1 : 0), number <= 9_007_199_254_740_991
        else { return nil }
        return UInt64(number)
    }
    public static func name(_ text: String, maximum: Int = 128) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= maximum
            && !text.unicodeScalars.contains(where: { $0.value < 32 || (maximum == 128 && $0.value == 127) })
    }
}

public struct ProjectRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let position: UInt64
    public let revision: UInt64
    public let createdAt: UInt64
    public let updatedAt: UInt64
    public init(json: JSONValue) throws {
        guard let id = json["project_id"]?.stringValue, ProjectIdentity.valid(id),
            let name = json["name"]?.stringValue,
            ProjectIdentity.name(name, maximum: 200) && name == name.trimmingCharacters(in: .whitespacesAndNewlines),
            let position = ProjectIdentity.integer(json["position"]),
            let revision = ProjectIdentity.integer(json["revision"], positive: true),
            let createdAt = ProjectIdentity.integer(json["created_at"]),
            let updatedAt = ProjectIdentity.integer(json["updated_at"])
        else { throw ProjectAPIError.invalidResponse }
        self.id = id
        self.name = name
        self.position = position
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProjectPage: Sendable, Equatable {
    public let projects: [ProjectRecord]
    public let nextCursor: String?
    public init(json: JSONValue) throws {
        guard let items = json["projects"]?.arrayValue, items.count <= 200 else {
            throw ProjectAPIError.invalidResponse
        }
        projects = try items.map(ProjectRecord.init(json:))
        guard Set(projects.map(\.id)).count == projects.count else { throw ProjectAPIError.invalidResponse }
        nextCursor = try projectCursor(json)
    }
}

public struct ProjectChatPage: Sendable, Equatable {
    public let projectId: String
    public let chats: [ChatSummary]
    public let nextCursor: String?
    public init(json: JSONValue) throws {
        guard let id = json["project_id"]?.stringValue, ProjectIdentity.valid(id),
            let items = json["chats"]?.arrayValue, items.count <= 200
        else { throw ProjectAPIError.invalidResponse }
        projectId = id
        chats = try items.map {
            guard let chat = ChatSummary(json: $0), chat.projectId == id else { throw ProjectAPIError.invalidResponse }
            return chat
        }
        guard Set(chats.map(\.id)).count == chats.count else { throw ProjectAPIError.invalidResponse }
        nextCursor = try projectCursor(json)
    }
}

private func projectCursor(_ json: JSONValue) throws -> String? {
    if json["next_cursor"] == .null { return nil }
    guard let cursor = json["next_cursor"]?.stringValue, !cursor.isEmpty, cursor.utf8.count <= 4096,
        cursor.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 })
    else {
        throw ProjectAPIError.invalidResponse
    }
    return cursor
}

extension RestClient {
    public func projects(limit: Int = 50, cursor: String? = nil) async throws -> ProjectPage {
        let json = try await projectRequest("GET", "api/projects", queryItems: try projectQuery(limit, cursor))
        return try ProjectPage(json: json)
    }
    public func project(id: String) async throws -> ProjectRecord {
        try requireProject(id)
        return try ProjectRecord(json: await projectRequest("GET", "api/projects/\(id)"))
    }
    public func createProject(id: String, name: String, position: UInt64 = 0) async throws -> ProjectRecord {
        try requireProject(id)
        guard ProjectIdentity.name(name, maximum: 200) && name == name.trimmingCharacters(in: .whitespacesAndNewlines),
            position <= 9_007_199_254_740_991
        else { throw ProjectAPIError.invalidResponse }
        return try ProjectRecord(
            json: await projectRequest(
                "POST", "api/projects",
                body: .object([
                    "project_id": .string(id), "name": .string(name), "position": .number(Double(position)),
                ])))
    }
    public func renameProject(id: String, name: String, revision: UInt64) async throws -> ProjectRecord {
        try requireProject(id, revision)
        guard ProjectIdentity.name(name, maximum: 200) && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw ProjectAPIError.invalidResponse }
        return try ProjectRecord(
            json: await projectRequest(
                "PATCH", "api/projects/\(id)",
                body: .object([
                    "name": .string(name), "revision": .number(Double(revision)),
                ])))
    }
    public func deleteProject(id: String, revision: UInt64) async throws {
        try requireProject(id, revision)
        _ = try await projectRequest(
            "DELETE", "api/projects/\(id)",
            queryItems: [
                URLQueryItem(name: "revision", value: String(revision))
            ])
    }
    public func projectChats(id: String, limit: Int = 50, cursor: String? = nil) async throws -> ProjectChatPage {
        try requireProject(id)
        let page = try ProjectChatPage(
            json: await projectRequest(
                "GET", "api/projects/\(id)/chats",
                queryItems: try projectQuery(limit, cursor)))
        guard page.projectId == id else { throw ProjectAPIError.invalidResponse }
        return page
    }
    public func createProjectChat(id: String, projectId: String, agentId: String? = nil) async throws -> String {
        try requireProject(projectId)
        try requireProject(id)
        var body: [String: JSONValue] = ["chat_id": .string(id), "project_id": .string(projectId)]
        if let agentId { body["agent_id"] = .string(agentId) }
        let json = try await projectRequest("POST", "api/chats", body: .object(body))
        guard json["chat_id"] == .string(id), json["project_id"] == .string(projectId) else {
            throw ProjectAPIError.invalidResponse
        }
        return id
    }
    private func requireProject(_ id: String, _ revision: UInt64 = 1) throws {
        guard ProjectIdentity.valid(id), (1...9_007_199_254_740_991).contains(revision) else {
            throw ProjectAPIError.invalidResponse
        }
    }
    private func projectQuery(_ limit: Int, _ cursor: String?) throws -> [URLQueryItem] {
        guard (1...200).contains(limit), cursor.map({ !$0.isEmpty && $0.utf8.count <= 4096 }) ?? true else {
            throw ProjectAPIError.invalidResponse
        }
        var result = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { result.append(URLQueryItem(name: "cursor", value: cursor)) }
        return result
    }
    private func projectRequest(
        _ method: String, _ path: String, body: JSONValue? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> JSONValue {
        let (status, json) = try await request(method, path, body: body, queryItems: queryItems)
        guard (200...299).contains(status) else {
            throw ProjectAPIError.refused(
                status: status,
                code: json["detail"]?["code"]?.stringValue ?? "project_request_failed",
                message: json["detail"]?["message"]?.stringValue ?? "The project request failed. Try again.")
        }
        return json
    }
}
