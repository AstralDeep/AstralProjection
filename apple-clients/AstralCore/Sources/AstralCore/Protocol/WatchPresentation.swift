import Foundation

/// Owner-scoped history chrome, intercepted before conversation continuity or speech.
public enum WatchHistoryUpdate: Equatable, Sendable {
    case loading
    case content(title: String, chats: [ChatSummary])

    public init?(frame: InboundFrame) {
        guard frame.name == "ui_render", frame.renderTarget == "history" else { return nil }
        let scopeKeys = [
            "chat_id", "chatId", "connection_generation", "request_generation",
            "base_render_revision", "frame_sequence",
        ]
        guard !scopeKeys.contains(where: { frame.payload[$0] != nil }) else { return nil }
        if let list = frame.renderComponents.first(where: { $0.type == "chat_history" }),
            let items = list.raw["items"]?.arrayValue
        {
            let title = list.raw["title"]?.stringValue ?? ""
            self = .content(
                title: title.isEmpty ? "Recent chats" : title,
                chats: items.compactMap(ChatSummary.init(historyItem:)))
        } else if frame.renderComponents.contains(where: { $0.type == "skeleton" }) {
            self = .loading
        } else {
            return nil
        }
    }
}

/// Passive text already present in watch-adapted primitives; never action metadata.
public enum WatchComponentText {
    public struct KeyValueRow: Equatable, Sendable {
        public let label: String
        public let value: String
        public let hint: String
    }

    public static func keyValueRows(in component: AstralComponent) -> [KeyValueRow] {
        let entries = component.raw["items"]?.arrayValue ?? component.raw["pairs"]?.arrayValue ?? []
        return entries.compactMap { item in
            guard let object = item.objectValue else { return nil }
            return KeyValueRow(
                label: object["label"]?.displayText ?? object["key"]?.displayText ?? "",
                value: object["value"]?.displayText ?? "",
                hint: object["hint"]?.displayText ?? "")
        }
    }

    public static func listItems(in component: AstralComponent) -> [String] {
        guard component.variant == "detailed" else { return component.listItems }
        return component.raw["items"]?.arrayValue?.map { item in
            guard item.objectValue != nil else { return item.displayText }
            let title = item["title"]?.stringValue ?? item["text"]?.stringValue ?? item["label"]?.stringValue ?? ""
            return [title, item["subtitle"]?.stringValue ?? "", item["description"]?.stringValue ?? ""]
                .filter { !$0.isEmpty }.joined(separator: "\n")
        } ?? []
    }
}
