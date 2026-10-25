// Adapts native workbench panes and searches authorized server menu entries without changing their actions.

import Foundation

public enum MacWorkbenchPane: Equatable, Sendable {
    case conversation
    case canvas
}

public struct ConsoleWorkbenchPane: Equatable, Sendable {
    public let split: Bool
    public let conversationWidth: Double
    public let compactToolbar: Bool

    init?(json: JSONValue?) {
        guard let split = json?["split"]?.boolValue,
            let width = ConsoleDecoding.number(json?["conversation_width"], range: 0...16384),
            let compact = json?["compact_toolbar"]?.boolValue
        else { return nil }
        self.split = split
        conversationWidth = width
        compactToolbar = compact
    }
}

public struct ConsoleWorkbenchPresentation: Equatable, Sendable {
    public let withSidebar: ConsoleWorkbenchPane
    public let withoutSidebar: ConsoleWorkbenchPane
    public let composerMaxWidth: Double
    public let transcriptMaxWidth: Double

    init?(json: JSONValue?) {
        guard json?["version"]?.numberValue == 1,
            let withSidebar = ConsoleWorkbenchPane(json: json?["with_sidebar"]),
            let withoutSidebar = ConsoleWorkbenchPane(json: json?["without_sidebar"]),
            let composerMaxWidth = ConsoleDecoding.number(json?["composer_max_width"], range: 1...16384),
            let transcriptMaxWidth = ConsoleDecoding.number(json?["transcript_max_width"], range: 1...16384)
        else { return nil }
        self.withSidebar = withSidebar
        self.withoutSidebar = withoutSidebar
        self.composerMaxWidth = composerMaxWidth
        self.transcriptMaxWidth = transcriptMaxWidth
    }
}

public struct MacWorkbenchLayout: Equatable, Sendable {
    public let conversationVisible: Bool
    public let canvasVisible: Bool
    public let conversationWidth: Double
    public let canvasWidth: Double

    public static func resolve(
        width: Double, pane: ConsoleWorkbenchPane, hasCanvas: Bool, selectedPane: MacWorkbenchPane, expandedCanvas: Bool
    ) -> MacWorkbenchLayout {
        let available = width.isFinite ? max(0, width) : 0
        let split = hasCanvas && !expandedCanvas && pane.split
        let conversation = !hasCanvas || (!expandedCanvas && (split || selectedPane == .conversation))
        let canvas = hasCanvas && (expandedCanvas || split || selectedPane == .canvas)
        let conversationWidth = split ? min(available, pane.conversationWidth) : conversation ? available : 0
        return MacWorkbenchLayout(
            conversationVisible: conversation, canvasVisible: canvas,
            conversationWidth: conversationWidth, canvasWidth: canvas ? available - conversationWidth : 0)
    }
}

public struct MacWorkbenchCommand: Equatable, Sendable, Identifiable {
    public let groupKey: String
    public let groupLabel: String
    public let item: ChromeMenuItem
    public var id: String { "\(groupKey)/\(item.key)" }

    public static func search(menu: ChromeMenuModel?, query: String) -> [MacWorkbenchCommand] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        return (menu?.menu ?? []).flatMap { group in
            group.items.compactMap { item in
                let text = normalized("\(group.label) \(item.label)")
                guard words.allSatisfy({ text.contains($0) }) else { return nil }
                return MacWorkbenchCommand(groupKey: group.key, groupLabel: group.label, item: item)
            }
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
