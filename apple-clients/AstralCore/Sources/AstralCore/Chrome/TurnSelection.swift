// Validates exact guidance revision selections for the current conversation.
// Outbound chat messages carry nonempty selections unchanged for server-side authorization.

import Foundation

public struct TurnSelection: Equatable, Sendable {
    public struct Agent: Equatable, Sendable {
        public let agentId: String
        public let revisionId: String
    }

    public struct Reference: Equatable, Sendable, Identifiable {
        public let id: String
        public let revision: UInt64
    }

    public let version: Int
    public let agent: Agent?
    public let skills: [Reference]
    public let notes: [Reference]
    public let json: JSONValue
    public var isEmpty: Bool { agent == nil && skills.isEmpty && notes.isEmpty }
    var isGuidanceSelection: Bool { agent == nil || continuityUUID4(agent?.agentId) != nil }

    public static let empty = TurnSelection(
        json: .object([
            "version": .number(1), "agent": .null, "skills": .array([]), "notes": .array([]),
        ]))!

    public init?(json: JSONValue?) {
        guard let json, let object = json.objectValue,
            Set(object.keys) == ["version", "agent", "skills", "notes"],
            object["version"]?.numberValue == 1,
            let rawAgent = object["agent"],
            let skills = Self.references(object["skills"], identityKey: "skill_id", maximum: 20),
            let notes = Self.references(object["notes"], identityKey: "note_id", maximum: 8)
        else { return nil }
        if rawAgent == .null {
            agent = nil
        } else {
            guard let fields = rawAgent.objectValue, Set(fields.keys) == ["agent_id", "revision_id"],
                let agentId = ConsoleDecoding.text(fields["agent_id"], maximum: 255),
                agentId == agentId.trimmingCharacters(in: .whitespacesAndNewlines),
                let revisionId = continuityUUID4(fields["revision_id"]?.stringValue)
            else { return nil }
            agent = Agent(agentId: agentId, revisionId: revisionId)
        }
        version = 1
        self.skills = skills
        self.notes = notes
        self.json = json
    }

    private static func references(_ json: JSONValue?, identityKey: String, maximum: Int) -> [Reference]? {
        guard let rows = ConsoleDecoding.rows(json, maximum: maximum) else { return nil }
        var result: [Reference] = []
        var identities: Set<String> = []
        for row in rows {
            guard let fields = row.objectValue, Set(fields.keys) == [identityKey, "revision"],
                let id = continuityUUID4(fields[identityKey]?.stringValue),
                let revision = ConsoleDecoding.number(fields["revision"], range: 1...9_007_199_254_740_991),
                revision.rounded() == revision, identities.insert(id).inserted
            else { return nil }
            result.append(Reference(id: id, revision: UInt64(revision)))
        }
        return result
    }
}
