// Turns kernel chat views into the existing ChatTurn and AstralComponent shapes that ChatBubble and ComponentView render.
// Model-written text is escaped here so link, image, autolink and raw-HTML syntax never parses, and surfaces keep only handle-free properties.

import AstralCore
import Foundation

nonisolated enum MeshModelText {
    static let joiner: Character = "\u{2060}"

    static func neutralize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 16)
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            switch character {
            case "]", "<":
                out.append(character)
                out.append(joiner)
            case "@":
                out.append(joiner)
                out.append(character)
            case ":" where index + 2 < characters.count && characters[index + 1] == "/" && characters[index + 2] == "/":
                out.append(joiner)
                out.append(character)
            case "." where index >= 3 && String(characters[(index - 3)..<index]).lowercased() == "www":
                out.append(joiner)
                out.append(character)
            default:
                out.append(character)
            }
        }
        return out
    }
}

extension MeshModelText {
    static func plainPreview(_ text: String) -> String {
        String(text.prefix(280))
    }
}

nonisolated enum MeshChatTree {
    static func children(of parentId: String?, in messages: [MeshChatMessage]) -> [MeshChatMessage] {
        messages.filter { $0.parentId == parentId }.sorted { ($0.createdAt, $0.eventId) < ($1.createdAt, $1.eventId) }
    }

    static func leaf(descendingFrom eventId: String, in messages: [MeshChatMessage]) -> String {
        var cursor = eventId
        while let next = children(of: cursor, in: messages).last { cursor = next.eventId }
        return cursor
    }

    static func defaultHead(of messages: [MeshChatMessage]) -> String? {
        let parents = Set(messages.compactMap(\.parentId))
        return messages.filter { !parents.contains($0.eventId) }
            .max { ($0.createdAt, $0.eventId) < ($1.createdAt, $1.eventId) }?.eventId
    }

    static func path(to head: String?, in messages: [MeshChatMessage]) -> [MeshChatMessage] {
        let byId = Dictionary(messages.map { ($0.eventId, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [MeshChatMessage] = []
        var seen = Set<String>()
        var cursor = head ?? defaultHead(of: messages)
        while let id = cursor, let message = byId[id], seen.insert(id).inserted {
            out.append(message)
            cursor = message.parentId
        }
        return out.reversed()
    }

    static func siblings(of message: MeshChatMessage, in messages: [MeshChatMessage]) -> [MeshChatMessage] {
        children(of: message.parentId, in: messages)
    }
}

nonisolated enum MeshSurfaceMapper {
    private static let maximumDepth = 32
    private static let structural: Set<String> = ["type", "component_id", "children", "id", "capability"]
    private static let handleKeys: Set<String> = ["href", "src", "url"]

    static func components(for surface: MeshSurface) -> [AstralComponent] {
        guard let json = value(of: surface.root, in: surface, depth: 0, visited: []) else { return [] }
        return AstralComponent(json: json).map { [$0] } ?? []
    }

    private static func value(
        of id: String, in surface: MeshSurface, depth: Int, visited: Set<String>
    ) -> JSONValue? {
        guard depth < maximumDepth, !visited.contains(id), let node = surface.nodes[id] else { return nil }
        var object: [String: JSONValue] = [:]
        for (key, raw) in node.props where !structural.contains(key) && !handleKeys.contains(key) {
            if let clean = sanitize(raw) { object[key] = clean }
        }
        object["type"] = .string(node.type)
        object["component_id"] = .string(id)
        if let capability = capability(in: node.props) {
            object["capability"] = .string(capability)
            object["action"] = .string("mesh_act")
        }
        let nested = node.children.compactMap {
            value(of: $0, in: surface, depth: depth + 1, visited: visited.union([id]))
        }
        if !nested.isEmpty { object["children"] = .array(nested) }
        return .object(object)
    }

    private static func capability(in props: [String: JSONValue]) -> String? {
        props["action"]?.objectValue?["capability"]?.stringValue
    }

    private static func sanitize(_ raw: JSONValue) -> JSONValue? {
        switch raw {
        case .string(let text):
            return .string(MeshModelText.neutralize(text))
        case .array(let items):
            return .array(items.compactMap(sanitize))
        case .object(let fields):
            guard fields["$bind"] == nil, fields["$handle"] == nil else { return nil }
            var out: [String: JSONValue] = [:]
            for (key, value) in fields where !handleKeys.contains(key) {
                if let clean = sanitize(value) { out[key] = clean }
            }
            return .object(out)
        case .null, .bool, .number:
            return raw
        }
    }
}

@MainActor
enum MeshChatMapper {
    struct Row: Identifiable {
        let turn: AppModel.ChatTurn
        let message: MeshChatMessage?
        var id: String { turn.id }
    }

    static func rows(for view: MeshChatView, head: String?, streaming: String? = nil) -> [Row] {
        let surfaces = Dictionary(view.surfaces.map { ($0.surfaceId, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = MeshChatTree.path(to: head, in: view.messages).map { message in
            Row(
                turn: AppModel.ChatTurn(
                    id: message.eventId, role: role(for: message.author),
                    text: message.author == .owner ? message.text : MeshModelText.neutralize(message.text),
                    components: message.surfaceIds.compactMap { surfaces[$0] }.flatMap(MeshSurfaceMapper.components)),
                message: message)
        }
        if let streaming, !streaming.isEmpty {
            rows.append(
                Row(
                    turn: AppModel.ChatTurn(
                        id: "mesh-streaming", role: "assistant", text: MeshModelText.neutralize(streaming)),
                    message: nil))
        }
        return rows
    }

    static func turns(for view: MeshChatView, head: String?, streaming: String? = nil) -> [AppModel.ChatTurn] {
        rows(for: view, head: head, streaming: streaming).map(\.turn)
    }

    static func role(for author: MeshAuthor) -> String {
        switch author {
        case .owner: return "user"
        case .assistant: return "assistant"
        case .tool, .system: return "reasoning"
        }
    }
}
