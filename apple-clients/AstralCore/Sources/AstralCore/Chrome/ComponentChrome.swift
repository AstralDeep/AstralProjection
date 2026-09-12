import Foundation

/// A closed presentation vocabulary, never an event name or authorization grant.
public enum ComponentActionKind: String, CaseIterable, Sendable {
    case refine, history, csv, share

    public var requiresLiveCanvas: Bool { self == .refine || self == .history }
    var context: String { requiresLiveCanvas ? "live_canvas" : "owned_chat" }
}

public struct ComponentActionDescriptor: Equatable, Identifiable, Sendable {
    public let kind: ComponentActionKind
    public let label: String
    public let icon: String
    public let title: String
    public var id: String { kind.rawValue }
}

/// Only archived-version display metadata survives. Archived bodies and arbitrary
/// attributes never enter the sheet or determine which event is dispatched.
public struct ComponentVersion: Equatable, Identifiable, Sendable {
    public let number: UInt64
    public let reason: String
    public let createdAt: String
    public let title: String
    public var id: UInt64 { number }

    public var displayTitle: String {
        let date = String(createdAt.replacingOccurrences(of: "T", with: " ").unicodeScalars.prefix(16))
        return "v\(number)" + (title.isEmpty ? "" : " · \(title)") + (date.isEmpty ? "" : " · \(date)")
    }

    public var restoreHint: String {
        "Restore this version" + (reason.isEmpty ? "" : " (archived on \(reason))")
    }
}

/// Defensive native interpretation of the shared server-owned component chrome.
public enum ComponentChromeModel {
    public static let emptyHistory = "No earlier versions yet — refine the component to create one."

    public static func actions(from value: JSONValue?) -> [ComponentActionDescriptor] {
        guard let object = value?.objectValue, Set(object.keys) == ["version", "actions"],
            object["version"]?.numberValue == 1,
            let rows = object["actions"]?.arrayValue, rows.count <= 16
        else { return [] }
        var seen = Set<ComponentActionKind>()
        var duplicates = Set<ComponentActionKind>()
        var accepted: [ComponentActionKind: ComponentActionDescriptor] = [:]
        for value in rows {
            guard let row = value.objectValue, let raw = row["kind"]?.stringValue,
                let kind = ComponentActionKind(rawValue: raw)
            else { continue }
            if !seen.insert(kind).inserted { duplicates.insert(kind) }
            guard Set(row.keys) == ["kind", "label", "icon", "title", "context"],
                row["context"]?.stringValue == kind.context,
                let label = bounded(row["label"], maximum: 96),
                let icon = bounded(row["icon"], maximum: 8),
                let title = bounded(row["title"], maximum: 160)
            else { continue }
            accepted[kind] = ComponentActionDescriptor(kind: kind, label: label, icon: icon, title: title)
        }
        return ComponentActionKind.allCases.compactMap { duplicates.contains($0) ? nil : accepted[$0] }
    }

    public static func versions(from value: JSONValue?) -> [ComponentVersion] {
        guard let rows = value?.arrayValue else { return [] }
        var seen = Set<UInt64>()
        var duplicates = Set<UInt64>()
        var accepted: [ComponentVersion] = []
        for value in rows.prefix(5) {
            guard let row = value.objectValue, let number = row["version_no"]?.numberValue,
                number.isFinite, number >= 1, number <= 9_007_199_254_740_991, number.rounded(.towardZero) == number
            else { continue }
            let identity = UInt64(number)
            if !seen.insert(identity).inserted { duplicates.insert(identity) }
            guard let reason = plain(row["reason"], maximum: 32),
                let createdAt = plain(row["created_at"], maximum: 64),
                let title = plain(row["title"], maximum: 120)
            else { continue }
            accepted.append(ComponentVersion(number: identity, reason: reason, createdAt: createdAt, title: title))
        }
        return accepted.filter { !duplicates.contains($0.number) }
    }

    /// `id` alone is a layout alias, not the durable component endpoint identity.
    public static func canonicalIdentity(of component: AstralComponent) -> String? {
        guard let value = component.raw["component_id"]?.stringValue, !value.isEmpty,
            !["dg_", "ly_", "wel_"].contains(where: value.hasPrefix),
            !["divider", "skeleton"].contains(component.type.lowercased())
        else { return nil }
        return value
    }

    private static func bounded(_ value: JSONValue?, maximum: Int) -> String? {
        guard let string = value?.stringValue, !string.isEmpty, string.unicodeScalars.count <= maximum else {
            return nil
        }
        return string
    }

    private static func plain(_ value: JSONValue?, maximum: Int) -> String? {
        guard let value, value != .null else { return "" }
        guard let string = value.stringValue else { return nil }
        return String(string.unicodeScalars.prefix(maximum))
    }
}
