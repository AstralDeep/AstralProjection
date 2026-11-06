// Decodes agent permissions and trusted server connection notices. Screens and the console directory render these models.

import Foundation

public struct ConnectionSecurityNotice: Equatable, Sendable {
    public let title: String
    public let message: String

    public init?(json: JSONValue?) {
        guard ["standard_mcp", "standard_a2a"].contains(json?["kind"]?.stringValue ?? ""),
            let title = Self.text(json?["title"], maximum: 120),
            let message = Self.text(json?["message"], maximum: 2000)
        else { return nil }
        self.title = title
        self.message = message
    }

    private static func text(_ json: JSONValue?, maximum: Int) -> String? {
        guard let value = json?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= maximum,
            value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }
}

public struct Agent: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let isPublic: Bool
    public let scopes: [String: Bool]
    public let tools: [String]
    public let toolDescriptions: [String: String]
    public var permissions: [String: Bool]
    public let toolScopeMap: [String: String]
    public let connectionSecurity: ConnectionSecurityNotice?

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        self.connectionSecurity = ConnectionSecurityNotice(json: json["connection_security"])
        self.name = json["name"]?.stringValue ?? id
        self.description = json["description"]?.stringValue ?? ""
        self.isPublic = json["is_public"]?.boolValue ?? false
        self.scopes = Agent.boolMap(json["scopes"])
        let permissions = Agent.boolMap(json["permissions"])
        self.permissions = permissions
        let toolObjs = (json["tools"]?.arrayValue ?? []).filter { $0.objectValue != nil }
        if !toolObjs.isEmpty {
            self.tools = toolObjs.compactMap { $0["name"]?.stringValue }
            var descs: [String: String] = [:]
            for t in toolObjs {
                if let name = t["name"]?.stringValue { descs[name] = t["description"]?.stringValue ?? "" }
            }
            self.toolDescriptions = descs
        } else {
            let strTools = (json["tools"]?.arrayValue ?? []).compactMap { $0.stringValue }
            self.tools = strTools.isEmpty ? Array(permissions.keys) : strTools
            self.toolDescriptions = Agent.strMap(json["tool_descriptions"])
        }
        self.toolScopeMap = Agent.strMap(json["tool_scope_map"])
    }

    public init(
        id: String, name: String, description: String, isPublic: Bool,
        scopes: [String: Bool], tools: [String], toolDescriptions: [String: String],
        permissions: [String: Bool], toolScopeMap: [String: String],
        connectionSecurity: ConnectionSecurityNotice? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isPublic = isPublic
        self.scopes = scopes
        self.tools = tools
        self.toolDescriptions = toolDescriptions
        self.permissions = permissions
        self.toolScopeMap = toolScopeMap
        self.connectionSecurity = connectionSecurity
    }

    public var enabledCount: Int { permissions.values.filter { $0 }.count }
    public var anyEnabled: Bool { permissions.values.contains(true) }

    public static func list(from json: JSONValue?) -> [Agent] {
        (json?.arrayValue ?? []).compactMap { Agent(json: $0) }
    }

    static func boolMap(_ v: JSONValue?) -> [String: Bool] {
        guard let o = v?.objectValue else { return [:] }
        var out: [String: Bool] = [:]
        for (k, value) in o { out[k] = value.boolValue ?? false }
        return out
    }

    static func strMap(_ v: JSONValue?) -> [String: String] {
        guard let o = v?.objectValue else { return [:] }
        var out: [String: String] = [:]
        for (k, value) in o { out[k] = value.stringValue ?? "" }
        return out
    }
}


