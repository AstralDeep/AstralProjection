import Foundation

/// Placement hints authored by the server for the initial workspace. Only
/// top-level ephemeral welcome components qualify; nested or identified result
/// content is never extracted, even if it contains a similarly named marker.
public enum WorkspaceWelcome {
    public enum Role: String, CaseIterable, Sendable {
        case intro
        case permission
        case examples
        case more
    }

    public static func role(of component: AstralComponent) -> Role? {
        guard hasWelcomeIdentity(component) else { return nil }
        return component.raw["data-welcome"]?.stringValue.flatMap(Role.init(rawValue:))
    }

    public static func isExample(_ component: AstralComponent) -> Bool {
        hasWelcomeIdentity(component) && component.raw["data-welcome"]?.stringValue == "example"
    }

    /// The watch can run ordinary welcome prompts through its existing chat
    /// dispatcher. Other actions retain the explicit phone/desktop handoff.
    public static func chatMessage(of component: AstralComponent) -> String? {
        guard component.type == "button",
            component.raw["data-welcome"]?.stringValue == "example",
            hasWelcomeIdentity(component),
            component.raw["action"]?.stringValue == "chat_message",
            component.raw["disabled"]?.boolValue != true,
            component.raw["enabled"]?.boolValue != false,
            let message = component.raw["payload"]?["message"]?.stringValue,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return message
    }

    private static func hasWelcomeIdentity(_ component: AstralComponent) -> Bool {
        for key in ["component_id", "id"] {
            if let raw = component.raw[key] {
                guard let identity = raw.stringValue, identity.hasPrefix("wel_") else { return false }
            }
        }
        return true
    }

    public static func components(_ components: [AstralComponent], for role: Role) -> [AstralComponent] {
        // Mirrors the web placement host: the newest component owns each slot.
        components.last(where: { Self.role(of: $0) == role }).map { [$0] } ?? []
    }

    public static func containsWork(_ components: [AstralComponent]) -> Bool {
        components.contains { role(of: $0) == nil }
    }

    public static func workComponents(_ components: [AstralComponent]) -> [AstralComponent] {
        components.filter { role(of: $0) == nil }
    }
}

/// Widths and rail preference match the server's web shell. Preference never
/// overrules the minimum width needed for a usable multiline composer.
public enum WorkspaceLayout: Equatable, Sendable {
    case stacked
    case collapsed
    case split

    public static func forWidth(_ width: Double, preference: String) -> Self {
        if width < 700 { return .stacked }
        if preference == "closed" || width < 1024 { return .collapsed }
        return .split
    }
}
