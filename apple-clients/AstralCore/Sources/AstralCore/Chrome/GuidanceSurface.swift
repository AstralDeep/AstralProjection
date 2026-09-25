// Client model and reducer for server-owned notes and selection surfaces: request/form decode, per-connection
// correlation, and atomic acceptance of surface updates. Read by AppModel and rendered by Screens and
// WatchGuidanceSurfaceView.

import Foundation

public struct GuidanceRequest: Equatable, Sendable {
    public let action: String
    public let payload: JSONValue
    public static let noteActions: Set<String> = [
        "chrome_note_search", "chrome_note_save", "chrome_note_toggle", "chrome_note_forget",
    ]
    public static let categories = ["Profession", "Goal", "Preference", "Workflow tag", "Context"]

    public init?(action: String, payload: JSONValue) {
        guard let p = payload.objectValue else { return nil }
        switch action {
        case "chrome_open":
            guard Set(p.keys) == ["surface", "params"], p["surface"]?.stringValue == "guidance",
                let params = p["params"]?.objectValue
            else { return nil }
            if params == ["view": .string("selection")] { break }
            guard let mode = params["mode"]?.stringValue else { return nil }
            switch mode {
            case "list":
                guard Set(params.keys).isSubset(of: ["mode", "search", "after_id"]),
                    params["search"] == nil || Self.text(params["search"], max: 256),
                    params["after_id"] == nil || continuityUUID4(params["after_id"]?.stringValue) != nil
                else { return nil }
            case "new": guard Set(params.keys) == ["mode"] else { return nil }
            case "edit", "forget":
                guard Set(params.keys) == ["mode", "note_id", "expected_revision"], Self.identity(params) else {
                    return nil
                }
            default: return nil
            }
        case "chrome_close": guard p == ["surface": .string("guidance")] else { return nil }
        case "chrome_turn_selection_set":
            guard TurnSelection(json: payload)?.isGuidanceSelection == true else { return nil }
        case "chrome_note_search":
            guard Set(p.keys) == ["fields"], let fields = p["fields"]?.objectValue,
                Set(fields.keys) == ["search"], Self.text(fields["search"], max: 256)
            else { return nil }
        case "chrome_note_save":
            guard Set(p.keys) == ["note_id", "expected_revision", "fields"], Self.identity(p, create: true),
                let fields = p["fields"]?.objectValue,
                Set(fields.keys).isSuperset(of: ["category", "value", "enabled", "expiry"]),
                Set(fields.keys).isSubset(of: ["category", "value", "enabled", "expiry", "expiry_date"]),
                let category = fields["category"]?.stringValue, Self.categories.contains(category),
                Self.text(fields["value"], max: 4096),
                fields["value"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                fields["enabled"]?.boolValue != nil, let expiry = fields["expiry"]?.stringValue,
                ["No expiry", "Set a date", "Keep current expiry"].contains(expiry),
                expiry != "Keep current expiry" || (p["expected_revision"]?.numberValue ?? 0) > 0,
                fields["expiry_date"] == nil || Self.text(fields["expiry_date"], max: 32)
            else { return nil }
            if expiry == "Set a date" {
                guard let value = fields["expiry_date"]?.stringValue,
                    value.range(
                        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$"#, options: .regularExpression)
                        != nil
                else { return nil }
            }
        case "chrome_note_toggle":
            guard Set(p.keys) == ["note_id", "expected_revision", "enabled"], Self.identity(p),
                p["enabled"]?.boolValue != nil
            else { return nil }
        case "chrome_note_forget":
            guard Set(p.keys) == ["note_id", "expected_revision"], Self.identity(p) else { return nil }
        default: return nil
        }
        self.action = action
        self.payload = payload
    }

    static func text(_ value: JSONValue?, max: Int) -> Bool {
        guard let text = value?.stringValue else { return false }
        return text.utf8.count <= max && !text.unicodeScalars.contains { $0.value == 0 }
    }

    static func identity(_ p: [String: JSONValue], create: Bool = false) -> Bool {
        guard continuityUUID4(p["note_id"]?.stringValue) != nil, let revision = p["expected_revision"]?.numberValue
        else { return false }
        return revision.isFinite && revision.rounded() == revision && revision >= (create ? 0 : 1)
            && revision <= 9_007_199_254_740_990
    }

    public static var list: GuidanceRequest {
        GuidanceRequest(
            action: "chrome_open",
            payload: .object(["surface": .string("guidance"), "params": .object(["mode": .string("list")])]))!
    }

    public static var selection: GuidanceRequest {
        GuidanceRequest(
            action: "chrome_open",
            payload: .object(["surface": .string("guidance"), "params": .object(["view": .string("selection")])]))!
    }

    public init?(component: AstralComponent) {
        guard component.type == "button", component.raw["disabled"]?.boolValue == false,
            component.raw["local"]?.boolValue == false, let action = component.raw["action"]?.stringValue,
            let payload = component.raw["payload"]
        else { return nil }
        self.init(action: action, payload: payload)
    }

    public func frameText(requestGeneration: String) -> String {
        Outbound.uiEvent(action: action, sessionId: nil, payload: payload, requestGeneration: requestGeneration)
    }

    public init?(frameText: String) {
        guard let replay = QueuedOperationReplay(frameText: frameText), let frame = InboundFrame.parse(frameText),
            frame.payload["session_id"] == .null,
            Set(frame.payload.objectValue?.keys.map { $0 } ?? []) == [
                "type", "action", "session_id", "submission_id", "request_generation", "payload",
            ],
            var payload = frame.payload["payload"]?.objectValue
        else { return nil }
        payload.removeValue(forKey: "submission_id")
        payload.removeValue(forKey: "request_generation")
        self.init(action: replay.action, payload: .object(payload))
    }

    public static func claimsCurrentConnectionSemantics(frameText: String) -> Bool {
        guard let frame = InboundFrame.parse(frameText), frame.name == "ui_event",
            let action = frame.payload["action"]?.stringValue
        else { return false }
        return action.hasPrefix("chrome_note_")
            || action == "chrome_turn_selection_set"
            || (["chrome_open", "chrome_close"].contains(action)
                && frame.payload["payload"]?["surface"]?.stringValue == "guidance")
    }

    public static func controls(in model: ChromeMenuModel?) -> [TopBarControl] {
        (model?.topbarActions ?? []).filter {
            $0.kind == "action" && $0.action?.surface == "guidance" && $0.label?.isEmpty == false
                && GuidanceRequest(action: "chrome_open", payload: .object($0.chromeOpenPayload)) != nil
        }
    }
}

public struct GuidanceForm: Equatable, Sendable {
    public let component: AstralComponent
    public let fields: [JSONValue]
    public let action: String
    public let payload: JSONValue
    public init?(component: AstralComponent) {
        guard component.type == "param_picker", let p = component.raw.objectValue,
            Set(p.keys) == [
                "type", "title", "description", "fields", "submit_label", "submit_action", "submit_payload",
            ],
            ["title", "description", "submit_label"].allSatisfy({ GuidanceRequest.text(p[$0], max: 8192) }),
            let action = p["submit_action"]?.stringValue, ["chrome_note_search", "chrome_note_save"].contains(action),
            let payload = p["submit_payload"], let fields = p["fields"]?.arrayValue
        else { return nil }
        let names = fields.compactMap { $0["name"]?.stringValue }
        guard
            names
                == (action == "chrome_note_search"
                    ? ["search"] : ["category", "value", "enabled", "expiry", "expiry_date"])
        else { return nil }
        if action == "chrome_note_search" {
            guard payload == .object([:]) else { return nil }
        } else {
            guard let identity = payload.objectValue, Set(identity.keys) == ["note_id", "expected_revision"],
                GuidanceRequest.identity(identity, create: true)
            else { return nil }
        }
        for field in fields {
            guard let f = field.objectValue, let name = f["name"]?.stringValue,
                Set(f.keys).isSuperset(of: ["name", "label", "kind", "default"]),
                Set(f.keys).isSubset(of: ["name", "label", "kind", "default", "options", "help", "visible_when"]),
                GuidanceRequest.text(f["label"], max: 8192),
                f["help"] == nil || GuidanceRequest.text(f["help"], max: 8192)
            else { return nil }
            let kind =
                name == "enabled"
                ? "boolean" : name == "value" ? "textarea" : ["category", "expiry"].contains(name) ? "select" : "text"
            guard f["kind"]?.stringValue == kind else { return nil }
            if kind == "boolean" {
                guard f["default"]?.boolValue != nil else { return nil }
            } else {
                guard GuidanceRequest.text(f["default"], max: name == "value" ? 4096 : name == "search" ? 256 : 32)
                else { return nil }
            }
            if kind == "select" {
                let options =
                    name == "category"
                    ? GuidanceRequest.categories
                    : (payload["expected_revision"]?.numberValue == 0
                        ? ["No expiry", "Set a date"] : ["Keep current expiry", "No expiry", "Set a date"])
                guard f["options"] == .array(options.map(JSONValue.string)), let value = f["default"]?.stringValue,
                    options.contains(value)
                else { return nil }
            } else if f["options"] != nil {
                return nil
            }
            if name == "expiry_date" {
                guard f["visible_when"] == .object(["expiry": .string("Set a date")]) else { return nil }
            } else if f["visible_when"] != nil {
                return nil
            }
        }
        self.component = component
        self.fields = fields
        self.action = action
        self.payload = payload
    }

    public var defaults: [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0["name"]!.stringValue!, $0["default"]!) })
    }

    public func visible(_ field: JSONValue, values: [String: JSONValue]) -> Bool {
        guard let condition = field["visible_when"]?.objectValue else { return true }
        return condition.allSatisfy { (values[$0.key] ?? defaults[$0.key]) == $0.value }
    }

    public func request(values: [String: JSONValue]) -> GuidanceRequest? {
        guard Set(values.keys).isSubset(of: Set(defaults.keys)) else { return nil }
        let values = defaults.merging(values) { _, supplied in supplied }
        guard
            fields.allSatisfy({ field in
                let name = field["name"]!.stringValue!
                if field["kind"]?.stringValue == "select" {
                    return field["options"]!.arrayValue!.contains(values[name]!)
                }
                return true
            })
        else { return nil }
        var body = payload.objectValue!
        body["fields"] = .object(values)
        return GuidanceRequest(action: action, payload: .object(body))
    }
}

public struct GuidanceSurfaceUpdate: Equatable, Sendable {
    public let generation: String
    public let title: String
    public let components: [AstralComponent]
    public let selection: TurnSelection?
    public init?(frame: InboundFrame) {
        guard frame.name == "chrome_surface", let p = frame.payload.objectValue,
            Set(p.keys).subtracting(["selection"]) == [
                "type", "surface_key", "region", "title", "admin_only", "components", "mode", "request_generation",
            ],
            p["type"]?.stringValue == "chrome_surface", p["surface_key"]?.stringValue == "guidance",
            p["region"]?.stringValue == "modal", p["mode"]?.stringValue == "replace",
            p["admin_only"]?.boolValue == false,
            let generation = continuityUUID4(p["request_generation"]?.stringValue),
            GuidanceRequest.text(p["title"], max: 4096),
            let raw = p["components"]?.arrayValue, let bytes = try? frame.payload.encoded(), bytes.count <= 1024 * 1024
        else { return nil }
        if let rawSelection = p["selection"] {
            guard let selection = TurnSelection(json: rawSelection), selection.isGuidanceSelection else { return nil }
            self.selection = selection
        } else {
            selection = nil
        }
        var count = 0
        guard raw.allSatisfy({ Self.valid($0, count: &count) }) else { return nil }
        let components = raw.compactMap(AstralComponent.init(json:))
        guard components.count == raw.count else { return nil }
        self.generation = generation
        self.title = p["title"]!.stringValue!
        self.components = components
    }

    public func permits(_ request: GuidanceRequest) -> Bool {
        func contains(_ c: AstralComponent) -> Bool {
            if GuidanceRequest(component: c) == request { return true }
            if let form = GuidanceForm(component: c), form.action == request.action,
                let fields = request.payload["fields"]?.objectValue, form.request(values: fields) == request
            {
                return true
            }
            return c.children.contains(where: contains)
        }
        return components.contains(where: contains)
    }

    private static func valid(_ value: JSONValue, count: inout Int, depth: Int = 0) -> Bool {
        count += 1
        guard count <= 1024, depth <= 8, let p = value.objectValue, let type = p["type"]?.stringValue else {
            return false
        }
        let shape: (Set<String>, Set<String>)
        switch type {
        case "text": shape = (["type", "content", "variant"], [])
        case "alert": shape = (["type", "message", "variant"], ["title"])
        case "badge": shape = (["type", "label", "variant"], [])
        case "card": shape = (["type", "title", "content", "variant"], [])
        case "button": shape = (["type", "label", "action", "payload", "variant", "disabled", "local"], [])
        case "param_picker": return AstralComponent(json: value).flatMap(GuidanceForm.init(component:)) != nil
        default: return false
        }
        guard shape.0.isSubset(of: Set(p.keys)), Set(p.keys).isSubset(of: shape.0.union(shape.1)),
            ["title", "message", "label", "variant"].allSatisfy({
                p[$0] == nil || GuidanceRequest.text(p[$0], max: 8192)
            })
        else { return false }
        switch type {
        case "text": return GuidanceRequest.text(p["content"], max: 8192)
        case "card": return p["content"]?.arrayValue?.allSatisfy { valid($0, count: &count, depth: depth + 1) } == true
        case "button":
            guard p["local"]?.boolValue == false, p["disabled"]?.boolValue != nil,
                let action = p["action"]?.stringValue,
                ["chrome_open", "chrome_note_toggle", "chrome_note_forget", "chrome_turn_selection_set"].contains(
                    action),
                let payload = p["payload"]
            else { return false }
            return GuidanceRequest(action: action, payload: payload) != nil
        default: return true
        }
    }
}

public struct GuidanceRequestState: Equatable, Sendable {
    public private(set) var generation: String?
    public private(set) var action: String?
    public private(set) var submissionId: String?
    public init() {}
    public mutating func begin(_ request: GuidanceRequest, generation: String) -> Bool {
        guard continuityUUID4(generation) != nil else { return false }
        self.generation = generation
        action = request.action
        submissionId = nil
        return true
    }
    public mutating func bindSubmission(_ text: String) -> Bool {
        guard let request = GuidanceRequest(frameText: text), request.action == action,
            let frame = InboundFrame.parse(text),
            frame.payload["request_generation"]?.stringValue == generation,
            let submission = continuityUUID4(frame.payload["submission_id"]?.stringValue)
        else { return false }
        submissionId = submission
        return true
    }
    public mutating func invalidate() {
        generation = nil
        action = nil
        submissionId = nil
    }
    public func accepts(_ update: GuidanceSurfaceUpdate) -> Bool {
        generation != nil && generation == update.generation
            && (update.selection == nil || action == "chrome_turn_selection_set")
    }
    public func matchesFailure(_ frame: InboundFrame, connectionGeneration: String?) -> Bool {
        guard generation != nil else { return false }
        if let refusal = AdmissionRefusal(frame: frame) {
            return submissionId != nil && refusal.submissionId == submissionId
        }
        guard let status = OperationStatus(frame: frame) else { return false }
        return status.action == action && status.surface == "guidance" && status.chatId == nil
            && status.requestGeneration == generation && status.connectionGeneration == connectionGeneration
            && status.terminal && status.state != "completed"
    }
}
