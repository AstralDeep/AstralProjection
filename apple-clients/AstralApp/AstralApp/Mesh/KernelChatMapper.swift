// Folds a kernel chat view into the message tree, branches and surfaces the screens draw: each turn's messages chain after the tail of the turn it continues, and queued messages chain after their anchor.
// The kernel keeps turns and branches while the screens keep one parent per message, so this is the single place that translates between them.

import AstralCore
import AstralKernel
import Foundation

nonisolated enum KernelChatMapper {
    enum Continuation: Equatable {
        case root
        case turn(String)
    }

    struct Folded {
        let messages: [MeshChatMessage]
        let surfaces: [MeshSurface]
    }

    static func summary(_ summary: AstralKernel.ChatSummary, detail: AstralKernel.ChatDetail?) -> MeshChatSummary {
        let view = detail.map { map($0, unknown: [], queuedBases: [:]) }
        return MeshChatSummary(
            chatId: summary.chatId, title: summary.title ?? "Chat", updatedAt: KernelMapping.date(summary.lastActivity),
            preview: view?.messages.last.map { MeshModelText.plainPreview($0.text) } ?? "",
            branchCount: max(0, (view?.branches.count ?? 1) - 1),
            queuedCount: view?.messages.filter { $0.delivery == .queued }.count ?? 0)
    }

    static func map(_ detail: AstralKernel.ChatDetail, unknown: [UnknownOutcomeInfo], queuedBases: [String: String]) -> MeshChatView {
        let view = detail.view
        let folded = fold(view, queuedBases: queuedBases)
        let status: MeshChatStatus
        if let first = unknown.first(where: { $0.chatId == view.chatId }) {
            status = .outcomeUnknown(KernelMapping.unknownOutcome(first))
        } else if let running = view.turns.last(where: { $0.status == .running }) {
            status = .running(turnId: running.id)
        } else {
            status = .idle
        }
        let labels = Set(view.messages.map(\.labels.confidentiality)).subtracting(["public", "private"]).sorted()
        return MeshChatView(
            chatId: view.chatId, title: view.title ?? "Chat", messages: folded.messages,
            branches: branches(of: folded.messages), surfaces: folded.surfaces, labels: labels, status: status)
    }

    static func fold(_ view: AstralKernel.ChatView, queuedBases: [String: String]) -> Folded {
        let visible = view.messages.filter { $0.kind != "chat.spoken" && !($0.text ?? "").isEmpty }
        let turnsById = Dictionary(view.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byTurn: [String: [AstralKernel.ChatMessage]] = [:]
        var queued: [AstralKernel.ChatMessage] = []
        var loose: [AstralKernel.ChatMessage] = []
        for message in visible {
            if message.status == .queued {
                queued.append(message)
            } else if let turn = message.turn, turnsById[turn] != nil {
                byTurn[turn, default: []].append(message)
            } else {
                loose.append(message)
            }
        }
        var linked: [(AstralKernel.ChatMessage, String?)] = []
        var tails: [String: String] = [:]
        for turn in view.turns {
            var list = byTurn[turn.id] ?? []
            if let first = turn.message, let index = list.firstIndex(where: { $0.id == first }), index != 0 {
                list.insert(list.remove(at: index), at: 0)
            }
            let inherited = turn.continues.flatMap { tails[$0] }
            var parent = inherited
            for message in list {
                linked.append((message, parent))
                parent = message.id
            }
            tails[turn.id] = list.last?.id ?? inherited
        }
        var lastQueued: [String: String] = [:]
        for message in queued.sorted(by: { ($0.clock.ms, $0.clock.n, $0.feed, $0.seq) < ($1.clock.ms, $1.clock.n, $1.feed, $1.seq) }) {
            let anchor = anchorTurn(of: message, in: view, queuedBases: queuedBases)
            let key = anchor ?? ""
            linked.append((message, lastQueued[key] ?? anchor.flatMap { tails[$0] }))
            lastQueued[key] = message.id
        }
        var tail = linked.last?.0.id
        for message in loose.sorted(by: { ($0.clock.ms, $0.clock.n, $0.feed, $0.seq) < ($1.clock.ms, $1.clock.n, $1.feed, $1.seq) }) {
            linked.append((message, tail))
            tail = message.id
        }
        let surfaces = KernelSurfaceFold.fold(view.surfaces)
        let placed = place(surfaces, among: linked.map(\.0))
        let messages = linked.map { message, parent in
            MeshChatMessage(
                eventId: message.id, parentId: parent, author: author(message.role), authorDevice: message.author,
                text: message.text ?? "", createdAt: KernelMapping.date(message.clock),
                delivery: message.status == .queued ? .queued : .recorded, surfaceIds: placed[message.id] ?? [])
        }
        return Folded(messages: messages, surfaces: surfaces.map(\.surface))
    }

    static func continuation(for messageId: String, in view: AstralKernel.ChatView, queuedBases: [String: String])
        -> Continuation?
    {
        guard let message = view.messages.first(where: { $0.id == messageId }) else { return nil }
        if let turn = message.turn, view.turns.contains(where: { $0.id == turn }) { return .turn(turn) }
        guard message.status == .queued else { return nil }
        return anchorTurn(of: message, in: view, queuedBases: queuedBases).map { .turn($0) } ?? .root
    }

    static func anchorTurn(
        of message: AstralKernel.ChatMessage, in view: AstralKernel.ChatView, queuedBases: [String: String]
    ) -> String? {
        if let base = queuedBases[message.id], view.turns.contains(where: { $0.id == base }) { return base }
        guard let branch = message.branch else { return nil }
        return view.turns.last { $0.branch == branch }?.id
    }

    private static func author(_ role: AstralKernel.Role) -> MeshAuthor {
        switch role {
        case .user: return .owner
        case .assistant: return .assistant
        case .tool: return .tool
        }
    }

    private static func place(_ surfaces: [KernelSurfaceFold.Folded], among messages: [AstralKernel.ChatMessage])
        -> [String: [String]]
    {
        var placed: [String: [String]] = [:]
        let replies = messages.filter { $0.role != .user }
        for surface in surfaces {
            let key = { (message: AstralKernel.ChatMessage) in (message.clock.ms, message.clock.n) }
            let target =
                replies.filter { key($0) <= (surface.created.ms, surface.created.n) }.max { key($0) < key($1) }
                ?? replies.last
            if let target { placed[target.id, default: []].append(surface.surface.surfaceId) }
        }
        return placed
    }

    static func branches(of messages: [MeshChatMessage]) -> [MeshBranch] {
        let parents = Set(messages.compactMap(\.parentId))
        var counts: [String: Int] = [:]
        for message in messages { if let parent = message.parentId { counts[parent, default: 0] += 1 } }
        let byId = Dictionary(messages.map { ($0.eventId, $0) }, uniquingKeysWith: { first, _ in first })
        return messages.filter { !parents.contains($0.eventId) }.map { leaf in
            var path = [leaf]
            var cursor = leaf.parentId
            while let id = cursor, let next = byId[id], path.count <= messages.count {
                path.append(next)
                cursor = next.parentId
            }
            return MeshBranch(
                headId: leaf.eventId, forkId: path.dropFirst().first { counts[$0.eventId, default: 0] > 1 }?.eventId,
                messageCount: path.count, updatedAt: leaf.createdAt)
        }
    }
}

nonisolated enum KernelSurfaceFold {
    struct Folded {
        let surface: MeshSurface
        let created: ClockStamp
    }

    private struct Component {
        var id: String
        var type: String
        var props: [String: JSONValue]
        var children: [String]
        var prov: String
    }

    private struct Document {
        var root: String
        var components: [String: Component]
    }

    private static let maximumComponents = 512

    static func fold(_ events: [SurfaceEvent]) -> [Folded] {
        let ordered = events.filter { $0.bodyState == .present && $0.bodyJson != nil }.sorted {
            ($0.clock.ms, $0.clock.n, $0.feed, $0.seq) < ($1.clock.ms, $1.clock.n, $1.feed, $1.seq)
        }
        var documents: [String: Document] = [:]
        var created: [String: ClockStamp] = [:]
        var order: [String] = []
        for event in ordered {
            guard let body = body(of: event)?.objectValue else { continue }
            switch event.kind {
            case "ui.surface_put":
                guard let raw = body["document"]?.objectValue, let document = parse(raw),
                    let named = raw["surface"]?.stringValue
                else { continue }
                let id = named == "new" ? event.id : named
                if documents[id] == nil {
                    created[id] = event.clock
                    order.append(id)
                }
                documents[id] = document
            case "ui.patch":
                guard let id = body["surface"]?.stringValue, let current = documents[id],
                    let ops = body["ops"]?.arrayValue, let patched = apply(ops, to: current)
                else { continue }
                documents[id] = patched
            default:
                continue
            }
        }
        return order.compactMap { id in
            guard let document = documents[id], let stamp = created[id] else { return nil }
            let nodes = document.components.mapValues {
                MeshSurfaceNode(id: $0.id, type: $0.type, props: $0.props, children: $0.children, provenance: $0.prov)
            }
            return Folded(surface: MeshSurface(surfaceId: id, root: document.root, nodes: nodes), created: stamp)
        }
    }

    private static func body(of event: SurfaceEvent) -> JSONValue? {
        guard let text = event.bodyJson else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private static func parse(_ raw: [String: JSONValue]) -> Document? {
        guard raw["v"]?.numberValue == 1, let root = raw["root"]?.stringValue,
            let components = raw["components"]?.objectValue, components.count <= maximumComponents
        else { return nil }
        var parsed: [String: Component] = [:]
        for (key, value) in components {
            guard let component = component(from: value, key: key) else { return nil }
            parsed[key] = component
        }
        return valid(Document(root: root, components: parsed))
    }

    private static func component(from value: JSONValue, key: String) -> Component? {
        guard let object = value.objectValue, object["id"]?.stringValue == key,
            let type = object["type"]?.stringValue, let props = object["props"]?.objectValue,
            let rawChildren = object["children"]?.arrayValue, case let children = rawChildren.compactMap(\.stringValue),
            children.count == rawChildren.count, let prov = object["prov"]?.stringValue,
            ["model", "tool", "host"].contains(prov)
        else { return nil }
        return Component(id: key, type: type, props: props, children: children, prov: prov)
    }

    private static func valid(_ document: Document) -> Document? {
        guard document.components[document.root] != nil else { return nil }
        var parents: [String: String] = [:]
        for component in document.components.values {
            for child in component.children {
                guard document.components[child] != nil, parents[child] == nil, child != document.root else { return nil }
                parents[child] = component.id
            }
        }
        var seen: Set<String> = []
        var stack = [(document.root, 1)]
        while let (id, depth) = stack.popLast() {
            guard depth <= 32, seen.insert(id).inserted, let component = document.components[id] else { return nil }
            stack.append(contentsOf: component.children.map { ($0, depth + 1) })
        }
        return seen.count == document.components.count ? document : nil
    }

    private static func apply(_ ops: [JSONValue], to start: Document) -> Document? {
        var document = start
        for op in ops {
            guard let fields = op.objectValue, let kind = fields["op"]?.stringValue else { return nil }
            switch kind {
            case "set":
                guard let id = fields["id"]?.stringValue, let prop = fields["prop"]?.stringValue,
                    let value = fields["value"]
                else { return nil }
                document.components[id]?.props[prop] = value
            case "unset":
                guard let id = fields["id"]?.stringValue, let prop = fields["prop"]?.stringValue else { return nil }
                document.components[id]?.props[prop] = nil
            case "add":
                guard let parent = fields["parent"]?.stringValue, let raw = fields["component"]?.objectValue,
                    let id = raw["id"]?.stringValue, document.components[parent] != nil, document.components[id] == nil,
                    let added = component(from: .object(raw), key: id)
                else { continue }
                var children = document.components[parent]?.children ?? []
                let index = fields["index"]?.numberValue.map(Int.init) ?? children.count
                children.insert(id, at: min(max(index, 0), children.count))
                document.components[parent]?.children = children
                document.components[id] = added
            case "remove":
                guard let id = fields["id"]?.stringValue, id != document.root, document.components[id] != nil else {
                    continue
                }
                var doomed: Set<String> = []
                var stack = [id]
                while let next = stack.popLast() {
                    if doomed.insert(next).inserted { stack.append(contentsOf: document.components[next]?.children ?? []) }
                }
                for key in doomed { document.components[key] = nil }
                for key in Array(document.components.keys) {
                    document.components[key]?.children.removeAll { doomed.contains($0) }
                }
            default:
                return nil
            }
        }
        return valid(document)
    }
}
