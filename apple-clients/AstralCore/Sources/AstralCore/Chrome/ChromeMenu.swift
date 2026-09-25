// Client model of the server-owned top-bar and settings chrome, decoded from the chrome_menu frame and
// tolerant of unknown fields; a 1:1 port of Android's ChromeMenu.kt. Rendered by RootView and read by
// AppModel.

import Foundation

public struct SurfaceRef: Equatable, Sendable {
    public let surface: String
    public let params: JSONValue
    public init(surface: String, params: JSONValue = .object([:])) {
        self.surface = surface
        self.params = params
    }
}

public enum WorkspaceAction: String, Equatable, Sendable {
    case exportCanvas = "export_canvas"
    case shareCanvas = "share_canvas"
}

public struct TopBarControl: Equatable, Sendable, Identifiable {
    public let key: String
    public let kind: String
    public let label: String?
    public let icon: String?
    public let action: SurfaceRef?
    public let workspaceAction: WorkspaceAction?
    public var id: String { key }
}

public struct ChromeMenuItem: Equatable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let surface: String
    public let params: JSONValue
    public let adminOnly: Bool
    public var id: String { key }
}

public struct ChromeMenuGroup: Equatable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let adminOnly: Bool
    public let items: [ChromeMenuItem]
    public var id: String { key }
}

public struct SignOutItem: Equatable, Sendable {
    public let key: String
    public let label: String
    public let style: String
    public let action: String
    public init(
        key: String = "signout", label: String = "Sign out",
        style: String = "danger", action: String = "logout"
    ) {
        self.key = key
        self.label = label
        self.style = style
        self.action = action
    }
}

public struct ChromeMenuModel: Equatable, Sendable {
    public let version: Int
    public let topbar: [TopBarControl]
    public let menu: [ChromeMenuGroup]
    public let signout: SignOutItem
    public let console: ConsoleModel?

    public var topbarActions: [TopBarControl] {
        topbar.filter { $0.kind == "action" || $0.workspaceAction != nil }
    }
    public var settingsControl: TopBarControl? { topbar.first { $0.kind == "menu" } }
    public var allItems: [ChromeMenuItem] { menu.flatMap(\.items) }

    public static func fromJSON(_ root: JSONValue?) -> ChromeMenuModel? {
        guard let root else { return nil }
        let topbar: [TopBarControl] = (root["topbar"]?.arrayValue ?? []).compactMap { el in
            guard let key = el["key"]?.stringValue else { return nil }
            var action: SurfaceRef?
            if let a = el["action"], a.objectValue != nil {
                action = SurfaceRef(
                    surface: a["surface"]?.stringValue ?? "",
                    params: a["params"] ?? .object([:]))
            }
            let kind = el["kind"]?.stringValue ?? "action"
            var workspaceAction: WorkspaceAction?
            if kind == "workspace_action" {
                guard let fields = el.objectValue,
                    Set(fields.keys) == ["key", "kind", "label", "icon", "operation", "context"],
                    el["context"]?.stringValue == "live_canvas",
                    let operation = el["operation"]?.stringValue,
                    let known = WorkspaceAction(rawValue: operation)
                else { return nil }
                let expected =
                    known == .exportCanvas
                    ? ("export", "Export page", "download") : ("share", "Share page", "share")
                guard key == expected.0, el["label"]?.stringValue == expected.1,
                    el["icon"]?.stringValue == expected.2
                else { return nil }
                workspaceAction = known
            }
            return TopBarControl(
                key: key, kind: kind,
                label: el["label"]?.stringValue, icon: el["icon"]?.stringValue,
                action: action, workspaceAction: workspaceAction)
        }
        let menu: [ChromeMenuGroup] = (root["menu"]?.arrayValue ?? []).compactMap { g in
            guard let key = g["key"]?.stringValue else { return nil }
            let items: [ChromeMenuItem] = (g["items"]?.arrayValue ?? []).compactMap { i in
                guard let ik = i["key"]?.stringValue, let surface = i["surface"]?.stringValue else { return nil }
                return ChromeMenuItem(
                    key: ik, label: i["label"]?.stringValue ?? "",
                    surface: surface, params: i["params"] ?? .object([:]),
                    adminOnly: i["admin_only"]?.boolValue ?? false)
            }
            return ChromeMenuGroup(
                key: key, label: g["label"]?.stringValue ?? "",
                adminOnly: g["admin_only"]?.boolValue ?? false, items: items)
        }
        let so = root["signout"]
        let signout = SignOutItem(
            key: so?["key"]?.stringValue ?? "signout",
            label: so?["label"]?.stringValue ?? "Sign out",
            style: so?["style"]?.stringValue ?? "danger",
            action: so?["action"]?.stringValue ?? "logout")
        return ChromeMenuModel(
            version: Int(root["version"]?.numberValue ?? 1),
            topbar: topbar, menu: menu, signout: signout,
            console: ConsoleModel(json: root["console"]))
    }
}

extension ChromeMenuItem {
    public var chromeOpenPayload: [String: JSONValue] {
        ["surface": .string(surface), "params": params]
    }
}

extension TopBarControl {
    public var chromeOpenPayload: [String: JSONValue] {
        ["surface": .string(action?.surface ?? ""), "params": action?.params ?? .object([:])]
    }
}
