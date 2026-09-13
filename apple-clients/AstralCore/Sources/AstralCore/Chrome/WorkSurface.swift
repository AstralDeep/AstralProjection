import Foundation

/// Closed navigation in the server-owned Work read surface. Never an effect.
public struct WorkReadRequest: Equatable, Sendable {
    public let params: JSONValue

    public init?(payload: JSONValue) {
        guard let object = payload.objectValue, Set(object.keys) == ["surface", "params"],
            object["surface"]?.stringValue == "work", let params = object["params"],
            let fields = params.objectValue, let mode = fields["mode"]?.stringValue
        else { return nil }
        if mode == "list" {
            guard Set(fields.keys) == ["mode"] || Set(fields.keys) == ["mode", "after_id"] else { return nil }
            if let after = fields["after_id"], continuityUUID4(after.stringValue) == nil { return nil }
        } else {
            guard ["detail", "result"].contains(mode), Set(fields.keys) == ["mode", "operation_id"],
                continuityUUID4(fields["operation_id"]?.stringValue) != nil
            else { return nil }
        }
        self.params = params
    }

    public init?(component: AstralComponent) {
        guard component.type == "button", component.raw["action"]?.stringValue == "chrome_open",
            component.raw["disabled"]?.boolValue == false, component.raw["local"]?.boolValue == false,
            let payload = component.raw["payload"]
        else { return nil }
        self.init(payload: payload)
    }

    public init?(frameText: String) {
        guard let replay = QueuedOperationReplay(frameText: frameText), replay.action == "chrome_open",
            let frame = InboundFrame.parse(frameText), frame.payload["session_id"] == .null,
            Set(frame.payload.objectValue?.keys.map { $0 } ?? []) == [
                "type", "action", "session_id", "submission_id", "request_generation", "payload",
            ],
            var payload = frame.payload["payload"]?.objectValue
        else { return nil }
        payload.removeValue(forKey: "submission_id")
        payload.removeValue(forKey: "request_generation")
        self.init(payload: .object(payload))
    }

    public var payload: JSONValue { .object(["surface": .string("work"), "params": params]) }

    public func frameText(requestGeneration: String) -> String {
        Outbound.uiEvent(
            action: "chrome_open", sessionId: nil, payload: payload,
            requestGeneration: requestGeneration)
    }

    /// The generic reconnect queue must reject even malformed attempts at this surface.
    public static func claimsCurrentConnectionSemantics(frameText: String) -> Bool {
        guard let frame = InboundFrame.parse(frameText), frame.name == "ui_event",
            let action = frame.payload["action"]?.stringValue,
            ["chrome_open", "chrome_close"].contains(action)
        else { return false }
        return frame.payload["payload"]?["surface"]?.stringValue == "work"
    }

    public static func isCurrentConnectionEvent(_ text: String) -> Bool {
        if WorkReadRequest(frameText: text) != nil { return true }
        guard let replay = QueuedOperationReplay(frameText: text), replay.action == "chrome_close",
            let frame = InboundFrame.parse(text), frame.payload["session_id"] == .null,
            Set(frame.payload.objectValue?.keys.map { $0 } ?? []) == [
                "type", "action", "session_id", "submission_id", "request_generation", "payload",
            ],
            var payload = frame.payload["payload"]?.objectValue
        else { return false }
        payload.removeValue(forKey: "submission_id")
        payload.removeValue(forKey: "request_generation")
        return payload == ["surface": .string("work")]
    }

    /// Thin consumers retain canonical labels/icons; only the supported surface is selected.
    public static func watchControls(in model: ChromeMenuModel?) -> [TopBarControl] {
        let controls =
            model?.topbarActions.filter { control in
                control.kind == "action" && control.action?.surface == "work"
                    && control.label?.isEmpty == false
                    && WorkReadRequest(payload: .object(control.chromeOpenPayload)) != nil
            } ?? []
        return controls.count == 1 ? controls : []
    }

    public static func watchControls(frame: InboundFrame) -> [TopBarControl] {
        guard frame.name == "chrome_menu", let model = frame.payload["model"],
            model["version"]?.numberValue == 2, let topbar = model["topbar"]?.arrayValue,
            topbar.count <= 32
        else { return [] }
        return watchControls(in: ChromeMenuModel.fromJSON(model))
    }
}

/// Entire Work surface acceptance is atomic. No malformed row is silently dropped.
public struct WorkSurfaceUpdate: Equatable, Sendable {
    public let requestGeneration: String
    public let title: String
    public let components: [AstralComponent]

    public init?(frame: InboundFrame) {
        guard frame.name == "chrome_surface", let fields = frame.payload.objectValue,
            Set(fields.keys) == [
                "type", "surface_key", "region", "title", "admin_only", "components", "mode", "request_generation",
            ],
            fields["type"]?.stringValue == "chrome_surface", fields["surface_key"]?.stringValue == "work",
            fields["mode"]?.stringValue == "replace", fields["admin_only"]?.boolValue == false,
            fields["region"]?.stringValue == "modal",
            let generation = continuityUUID4(frame.payload["request_generation"]?.stringValue),
            let title = frame.payload["title"]?.stringValue, title.utf8.count <= 4096,
            let raw = frame.payload["components"]?.arrayValue,
            let bytes = try? frame.payload.encoded(), bytes.count <= 1024 * 1024,
            ["chat_id", "chatId", "connection_generation", "frame_sequence", "speech"].allSatisfy({
                frame.payload[$0] == nil
            })
        else { return nil }
        var count = 0
        guard raw.allSatisfy({ Self.valid($0, count: &count) }) else { return nil }
        let components = raw.compactMap(AstralComponent.init(json:))
        guard components.count == raw.count else { return nil }
        self.requestGeneration = generation
        self.title = title
        self.components = components
    }

    public func permits(_ request: WorkReadRequest) -> Bool {
        func contains(_ component: AstralComponent) -> Bool {
            WorkReadRequest(component: component) == request || component.children.contains(where: contains)
        }
        return components.contains(where: contains)
    }

    private static func valid(_ value: JSONValue, count: inout Int, depth: Int = 0) -> Bool {
        count += 1
        guard count <= 1024, depth <= 8, let fields = value.objectValue,
            let type = fields["type"]?.stringValue
        else { return false }
        let shape: (Set<String>, Set<String>)
        switch type {
        case "text": shape = (["type", "content", "variant"], [])
        case "alert": shape = (["type", "message", "variant"], ["title"])
        case "badge": shape = (["type", "label", "variant"], [])
        case "card": shape = (["type", "title", "content", "variant"], [])
        case "keyvalue": shape = (["type", "items"], ["title"])
        case "button": shape = (["type", "label", "action", "payload", "variant", "disabled", "local"], [])
        default: return false
        }
        let keys = Set(fields.keys)
        guard shape.0.isSubset(of: keys), keys.isSubset(of: shape.0.union(shape.1)) else { return false }
        for key in ["title", "message", "label", "variant"] where fields[key] != nil {
            guard let text = fields[key]?.stringValue, text.utf8.count <= 8192 else { return false }
        }
        switch type {
        case "text":
            guard let text = fields["content"]?.stringValue else { return false }
            return text.utf8.count <= 8192
        case "card":
            guard let children = fields["content"]?.arrayValue else { return false }
            return children.allSatisfy { valid($0, count: &count, depth: depth + 1) }
        case "keyvalue":
            guard let items = fields["items"]?.arrayValue, items.count <= 100 else { return false }
            return items.allSatisfy { item in
                guard let row = item.objectValue, Set(row.keys) == ["label", "value"] else { return false }
                return ["label", "value"].allSatisfy { key in
                    guard let text = row[key]?.stringValue else { return false }
                    return text.utf8.count <= 8192
                }
            }
        case "button":
            guard fields["action"]?.stringValue == "chrome_open", fields["local"]?.boolValue == false,
                fields["disabled"]?.boolValue != nil, let payload = fields["payload"]
            else { return false }
            return WorkReadRequest(payload: payload) != nil
        default: return true
        }
    }
}

/// Ephemeral request correlation; the owning model also binds owner and socket.
public struct WorkReadState: Equatable, Sendable {
    public private(set) var request: WorkReadRequest?
    public private(set) var generation: String?
    public private(set) var submissionId: String?
    public init() {}

    @discardableResult
    public mutating func begin(_ request: WorkReadRequest, generation: String) -> Bool {
        guard continuityUUID4(generation) != nil else { return false }
        self.request = request
        self.generation = generation
        submissionId = nil
        return true
    }

    public mutating func invalidate() {
        request = nil
        generation = nil
        submissionId = nil
    }

    /// Bind the exact nonqueued wire attempt so an unrelated refusal cannot retire it.
    @discardableResult
    public mutating func bindSubmission(frameText: String) -> Bool {
        guard let frame = InboundFrame.parse(frameText),
            WorkReadRequest(frameText: frameText) == request,
            frame.payload["request_generation"]?.stringValue == generation,
            let submission = continuityUUID4(frame.payload["submission_id"]?.stringValue)
        else { return false }
        submissionId = submission
        return true
    }

    public func matchesFailure(_ frame: InboundFrame, connectionGeneration: String?) -> Bool {
        guard generation != nil else { return false }
        if let refusal = AdmissionRefusal(frame: frame) {
            return submissionId != nil && refusal.submissionId == submissionId
        }
        guard let status = OperationStatus(frame: frame) else { return false }
        return status.action == "chrome_open" && status.surface == "work" && status.chatId == nil
            && status.requestGeneration == generation && status.connectionGeneration == connectionGeneration
            && status.terminal && status.state != "completed"
    }

    public func accepts(_ update: WorkSurfaceUpdate) -> Bool {
        request != nil && update.requestGeneration == generation
    }
}
