// Server-authored placement hints for the initial workspace welcome and viewport-based layout bounds;
// WorkspaceWelcome/WorkspaceLayout drive AppModel and the watch/phone/desktop workspace views to match the
// web shell.

import Foundation

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

    public static func unscopedComponents(in frame: InboundFrame) -> [AstralComponent]? {
        guard ["ui_render", "ui_update"].contains(frame.name),
            let payload = frame.payload.objectValue,
            payload["target"] == nil || payload["target"] == .string("canvas"),
            let rawComponents = payload["components"]?.arrayValue,
            !rawComponents.isEmpty
        else { return nil }
        let scopeKeys = [
            "chat_id", "chatId", "connection_generation", "request_generation",
            "base_render_revision", "frame_sequence",
        ]
        guard scopeKeys.allSatisfy({ payload[$0] == nil }) else { return nil }
        let components = frame.renderComponents
        guard components.count == rawComponents.count,
            components.allSatisfy({ role(of: $0) != nil })
        else { return nil }
        return components
    }

    public static func components(_ components: [AstralComponent], for role: Role) -> [AstralComponent] {
        components.last(where: { Self.role(of: $0) == role }).map { [$0] } ?? []
    }

    public static func containsWork(_ components: [AstralComponent]) -> Bool {
        components.contains { role(of: $0) == nil }
    }

    public static func workComponents(_ components: [AstralComponent]) -> [AstralComponent] {
        components.filter { role(of: $0) == nil }
    }
}

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
