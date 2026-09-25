// Admits bounded server-rendered watch console surfaces and their exact offered actions.
// WatchModel binds each admitted response to the current owner, connection, and request.

import AstralCore
import Foundation

struct WatchConsoleSurface: Equatable {
    let key: String
    let title: String
    let generation: String
    let components: [AstralComponent]

    init?(frame: InboundFrame) {
        guard frame.name == "chrome_surface", let p = frame.payload.objectValue,
            Set(p.keys) == [
                "type", "surface_key", "region", "title", "admin_only", "components", "mode", "request_generation",
            ],
            p["type"]?.stringValue == "chrome_surface", p["surface_key"]?.stringValue == "agent_intro",
            p["region"]?.stringValue == "modal", p["mode"]?.stringValue == "replace",
            p["admin_only"]?.boolValue == false,
            let title = p["title"]?.stringValue, title.utf8.count <= 4096,
            let generation = p["request_generation"]?.stringValue,
            UUID(uuidString: generation)?.uuidString.lowercased() == generation,
            let rows = p["components"]?.arrayValue,
            let encoded = try? frame.payload.encoded(), encoded.count <= 1024 * 1024
        else { return nil }
        var count = 0
        guard rows.allSatisfy({ Self.valid($0, count: &count) }) else { return nil }
        self.key = "agent_intro"
        self.title = title
        self.generation = generation
        components = rows.compactMap(AstralComponent.init(json:))
    }

    func permits(_ component: AstralComponent) -> Bool {
        func contains(_ current: AstralComponent) -> Bool {
            current == component || current.children.contains(where: contains)
        }
        return components.contains(where: contains) && Self.button(component.raw)
    }

    private static func valid(_ value: JSONValue, count: inout Int, depth: Int = 0) -> Bool {
        count += 1
        guard count <= 256, depth <= 8, let p = value.objectValue, let type = p["type"]?.stringValue,
            ["text", "alert", "badge", "card", "container", "list", "keyvalue", "button"].contains(type)
        else { return false }
        if type == "button" { return button(value) }
        for key in ["children", "content"] {
            if let children = p[key]?.arrayValue,
                !children.allSatisfy({ valid($0, count: &count, depth: depth + 1) })
            {
                return false
            }
        }
        return true
    }

    private static func button(_ value: JSONValue) -> Bool {
        guard value["type"]?.stringValue == "button", value["disabled"]?.boolValue == false,
            value["local"]?.boolValue == false, let payload = value["payload"]?.objectValue,
            let action = value["action"]?.stringValue
        else { return false }
        if ["chat_message", "compose_prompt"].contains(action) {
            guard Set(payload.keys) == ["message"], let text = payload["message"]?.stringValue else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 32_000
                && !text.contains("\0")
        }
        return action == "chrome_open" && Set(payload.keys) == ["surface", "params"]
            && payload["surface"]?.stringValue == "agents" && payload["params"]?.objectValue != nil
    }
}
