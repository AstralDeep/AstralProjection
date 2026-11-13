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
    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let images = expression(#"!\[([^\]]*)\]\(\s*[^)\s]*(?:\s+"[^"]*")?\s*\)"#)
    private static let links = expression(#"\[([^\]]*)\]\(\s*<?([^)\s>]*)>?(?:\s+"[^"]*")?\s*\)"#)
    private static let references = expression(#"\[([^\]]+)\]\[[^\]]*\]"#)
    private static let definitions = expression(#"(?m)^\s*\[[^\]]+\]:\s*\S+.*$\n?"#)
    private static let autolinks = expression(#"<((?:https?|ftp)://[^>\s]+)>"#)
    private static let bare = expression(#"(?:https?|ftp)://[^\s)<>\]]+"#)

    static func hostOnly(_ raw: String) -> String? {
        let candidate = raw.contains("://") ? raw : "https://" + raw
        guard let host = URL(string: candidate)?.host, !host.isEmpty else { return nil }
        return host
    }

    private static func replace(
        _ expression: NSRegularExpression, in text: String, _ build: (_ groups: [String]) -> String
    ) -> String {
        let source = text as NSString
        var out = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            out += build(groups)
            cursor = match.range.location + match.range.length
        }
        return out + source.substring(from: cursor)
    }

    static func display(_ text: String) -> String {
        var current = replace(images, in: text) { $0[1] }
        current = replace(links, in: current) { groups in
            guard let host = hostOnly(groups[2]) else { return groups[1] }
            return groups[1].isEmpty ? host : groups[1] + " (" + host + ")"
        }
        current = replace(references, in: current) { $0[1] }
        current = replace(definitions, in: current) { _ in "" }
        current = replace(autolinks, in: current) { hostOnly($0[1]) ?? "" }
        current = replace(bare, in: current) { hostOnly($0[0]) ?? "" }
        return neutralize(current)
    }

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

nonisolated enum MeshComponentTypes {
    private static let aliases = ["metric_card": "metric", "stat_card": "metric", "metric_tile": "metric", "kpi": "metric"]

    static func canonical(_ type: String) -> String { aliases[type] ?? type }
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
        object["type"] = .string(MeshComponentTypes.canonical(node.type))
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

nonisolated enum MeshRenderedMapper {
    private static let maximumDepth = 32
    private static let structural: Set<String> = ["type", "component_id", "id", "capability", "provenance"]

    static func handles(in surface: MeshRenderedSurface) -> [String] {
        var found: [String] = []
        for node in surface.tree { collect(node, depth: 0, into: &found) }
        return found
    }

    static func components(for surface: MeshRenderedSurface, resolved: [String: MeshResolvedHandle]) -> [AstralComponent] {
        surface.tree.compactMap { node in
            clean(node, depth: 0, resolved: resolved).flatMap { AstralComponent(json: $0) }
        }
    }

    private static func collect(_ value: JSONValue, depth: Int, into found: inout [String]) {
        guard depth < maximumDepth else { return }
        switch value {
        case .object(let fields):
            if fields.count == 1, let handle = fields["$handle"]?.stringValue {
                found.append(handle)
                return
            }
            for (key, nested) in fields where key != "action" { collect(nested, depth: depth + 1, into: &found) }
        case .array(let items):
            for item in items { collect(item, depth: depth + 1, into: &found) }
        default:
            break
        }
    }

    private static func clean(_ value: JSONValue, depth: Int, resolved: [String: MeshResolvedHandle]) -> JSONValue? {
        guard depth < maximumDepth else { return nil }
        switch value {
        case .string(let text):
            return .string(MeshModelText.neutralize(text))
        case .array(let items):
            return .array(items.compactMap { clean($0, depth: depth + 1, resolved: resolved) })
        case .object(let fields):
            if fields.count == 1, let handle = fields["$handle"]?.stringValue { return resolution(handle, resolved) }
            return .object(object(fields, depth: depth, resolved: resolved))
        case .null, .bool, .number:
            return value
        }
    }

    private static func object(_ fields: [String: JSONValue], depth: Int, resolved: [String: MeshResolvedHandle])
        -> [String: JSONValue]
    {
        var out: [String: JSONValue] = [:]
        for (key, nested) in fields where !structural.contains(key) && key != "action" {
            if let value = clean(nested, depth: depth + 1, resolved: resolved) { out[key] = value }
        }
        if let type = fields["type"]?.stringValue { out["type"] = .string(MeshComponentTypes.canonical(type)) }
        if let id = fields["id"]?.stringValue { out["component_id"] = .string(id) }
        if let capability = fields["action"]?.objectValue?["handle"]?.stringValue {
            out["capability"] = .string(capability)
            out["action"] = .string("mesh_act")
        }
        if out["type"]?.stringValue == "image", let source = imageSource(out) {
            out["src"] = nil
            out["url"] = .string(source)
        }
        return out
    }

    private static func imageSource(_ fields: [String: JSONValue]) -> String? {
        for key in ["src", "url"] {
            if let text = fields[key]?.stringValue, text.hasPrefix("data:image/") { return text }
        }
        return nil
    }

    private static func resolution(_ handle: String, _ resolved: [String: MeshResolvedHandle]) -> JSONValue? {
        guard let value = resolved[handle] else { return nil }
        switch value.kind {
        case .image:
            guard let mime = value.mime else { return nil }
            return .string("data:" + mime + ";base64," + value.value)
        case .url:
            return .string(URL(string: value.value)?.host ?? value.value)
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

    static func rows(
        for view: MeshChatView, head: String?, streaming: String? = nil, resolved: [String: MeshResolvedHandle] = [:]
    ) -> [Row] {
        let surfaces = Dictionary(view.surfaces.map { ($0.surfaceId, $0) }, uniquingKeysWith: { first, _ in first })
        let rendered = Dictionary(view.rendered.map { ($0.surfaceId, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = MeshChatTree.path(to: head, in: view.messages).map { message in
            let components = message.surfaceIds.flatMap { id -> [AstralComponent] in
                if let tree = rendered[id] { return MeshRenderedMapper.components(for: tree, resolved: resolved) }
                return surfaces[id].map(MeshSurfaceMapper.components) ?? []
            }
            return Row(
                turn: AppModel.ChatTurn(
                    id: message.eventId, role: role(for: message.author),
                    text: message.author == .owner ? message.text : MeshModelText.display(message.text),
                    components: components),
                message: message)
        }
        if let streaming, !streaming.isEmpty {
            rows.append(
                Row(
                    turn: AppModel.ChatTurn(
                        id: "mesh-streaming", role: "assistant", text: MeshModelText.display(streaming)),
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
