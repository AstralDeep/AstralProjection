// Decodes the server-owned console catalog, copy, identity, and composer actions for the native shell.
// Invalid console payloads are rejected independently of the existing settings menu.

import Foundation

public struct ChromeAvailability: Equatable, Sendable {
    public enum Mode: String, Sendable { case native, handoff }
    public let mode: Mode
    public let message: String?

    public init?(json: JSONValue?) {
        guard let object = json?.objectValue, let raw = object["mode"]?.stringValue,
            let mode = Mode(rawValue: raw)
        else { return nil }
        if mode == .native {
            guard Set(object.keys) == ["mode"] else { return nil }
            message = nil
        } else {
            guard Set(object.keys) == ["mode", "message"],
                let value = ConsoleDecoding.text(object["message"], maximum: 500)
            else { return nil }
            message = value
        }
        self.mode = mode
    }
}

public struct ConsoleIdentity: Equatable, Sendable {
    public let name: String
    public let role: String
    public let initials: String
}

public struct ConsoleScenario: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let prompt: String
    public let category: String
}

public struct ConsoleAgent: Equatable, Sendable, Identifiable {
    public enum State: String, Sendable {
        case ready, offline
    }

    public let id: String
    public let name: String
    public let description: String
    public let state: State
    public let owned: Bool
    public let availability: ChromeAvailability?
}

public struct ConsoleCatalog: Equatable, Sendable {
    public let categories: [String]
    public let scenarios: [ConsoleScenario]
    public let agents: [ConsoleAgent]

    init?(json: JSONValue?) {
        guard let categoriesJSON = ConsoleDecoding.rows(json?["categories"], maximum: 16),
            let scenarioRows = ConsoleDecoding.rows(json?["scenarios"], maximum: 64),
            let agentRows = ConsoleDecoding.rows(json?["agents"], maximum: 60)
        else { return nil }
        let categories = categoriesJSON.compactMap { ConsoleDecoding.text($0, maximum: 80) }
        guard categories.count == categoriesJSON.count, Set(categories).count == categories.count else { return nil }
        var scenarios: [ConsoleScenario] = []
        for row in scenarioRows {
            guard let id = ConsoleDecoding.text(row["id"], maximum: 200),
                let title = ConsoleDecoding.text(row["title"], maximum: 200),
                let description = ConsoleDecoding.text(row["description"], maximum: 2000, empty: true),
                let prompt = ConsoleDecoding.text(row["prompt"], maximum: 8000),
                let category = ConsoleDecoding.text(row["category"], maximum: 80),
                categories.contains(category)
            else { return nil }
            scenarios.append(
                ConsoleScenario(id: id, title: title, description: description, prompt: prompt, category: category))
        }
        var agents: [ConsoleAgent] = []
        for row in agentRows {
            guard let id = ConsoleDecoding.text(row["id"], maximum: 200),
                let name = ConsoleDecoding.text(row["name"], maximum: 200),
                let description = ConsoleDecoding.text(row["description"], maximum: 2000, empty: true),
                let rawState = row["state"]?.stringValue, let state = ConsoleAgent.State(rawValue: rawState),
                let owned = row["owned"]?.boolValue,
                row["availability"] == nil || ChromeAvailability(json: row["availability"]) != nil
            else { return nil }
            agents.append(
                ConsoleAgent(
                    id: id, name: name, description: description, state: state, owned: owned,
                    availability: ChromeAvailability(json: row["availability"])))
        }
        guard Set(scenarios.map(\.id)).count == scenarios.count,
            Set(agents.map(\.id)).count == agents.count
        else { return nil }
        self.categories = categories
        self.scenarios = scenarios
        self.agents = agents
    }
}

public struct ConsoleComposerAction: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case toggle, action
    }

    public let key: String
    public let kind: Kind
    public let label: String
    public let icon: String
    public let action: SurfaceRef?
    public let availability: ChromeAvailability?
    public var id: String { key }

    init?(json: JSONValue) {
        guard let key = ConsoleDecoding.text(json["key"], maximum: 80),
            let rawKind = json["kind"]?.stringValue, let kind = Kind(rawValue: rawKind),
            let label = ConsoleDecoding.text(json["label"], maximum: 200),
            let icon = ConsoleDecoding.text(json["icon"], maximum: 80),
            json["availability"] == nil || ChromeAvailability(json: json["availability"]) != nil
        else { return nil }
        if kind == .toggle {
            guard key == "background", json["action"] == nil else { return nil }
            action = nil
        } else {
            guard let reference = json["action"],
                let surface = ConsoleDecoding.text(reference["surface"], maximum: 80),
                surface.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil,
                let params = reference["params"], params.objectValue != nil,
                let encoded = try? params.encoded(), encoded.count <= 16_384
            else { return nil }
            action = SurfaceRef(surface: surface, params: params)
        }
        self.key = key
        self.kind = kind
        self.label = label
        self.icon = icon
        availability = ChromeAvailability(json: json["availability"])
    }
}

public struct ConsoleModel: Equatable, Sendable {
    public static let contract = "console/v2"
    public let version: Int
    public let labels: [String: String]
    public let identity: ConsoleIdentity
    public let catalog: ConsoleCatalog
    public let composerActions: [ConsoleComposerAction]
    public let showVoiceAvailabilityBanner: Bool

    public init?(json: JSONValue?) {
        guard json?["version"]?.numberValue == 2,
            let rawLabels = json?["labels"]?.objectValue, rawLabels.count <= 64,
            Self.requiredLabels.isSubset(of: Set(rawLabels.keys)),
            let name = ConsoleDecoding.text(json?["identity"]?["name"], maximum: 120),
            let role = ConsoleDecoding.text(json?["identity"]?["role"], maximum: 40),
            let initials = ConsoleDecoding.text(json?["identity"]?["initials"], maximum: 40),
            let catalog = ConsoleCatalog(json: json?["catalog"]),
            let actions = ConsoleDecoding.rows(json?["composer_actions"], maximum: 16),
            let showVoiceAvailabilityBanner = json?["show_voice_availability_banner"]?.boolValue
        else { return nil }
        var labels: [String: String] = [:]
        for (key, raw) in rawLabels {
            guard ConsoleDecoding.text(.string(key), maximum: 80) != nil,
                let label = ConsoleDecoding.text(raw, maximum: 500)
            else { return nil }
            labels[key] = label
        }
        let composerActions = actions.compactMap(ConsoleComposerAction.init(json:))
        guard composerActions.count == actions.count,
            Set(composerActions.map(\.key)).count == composerActions.count
        else { return nil }
        version = 2
        self.labels = labels
        identity = ConsoleIdentity(name: name, role: role, initials: initials)
        self.catalog = catalog
        self.composerActions = composerActions
        self.showVoiceAvailabilityBanner = showVoiceAvailabilityBanner
    }

    public func selectionSummary(_ selection: TurnSelection) -> String? {
        guard !selection.isEmpty, let template = labels["selection_summary"] else { return nil }
        var parts: [String] = []
        for (kind, count) in [
            ("agent", selection.agent == nil ? 0 : 1),
            ("skill", selection.skills.count), ("note", selection.notes.count),
        ] where count > 0 {
            let key = "selection_\(kind)_\(count == 1 ? "singular" : "plural")"
            guard let label = labels[key] else { return nil }
            parts.append(label.replacingOccurrences(of: "{count}", with: String(count)))
        }
        return template.replacingOccurrences(of: "{selection}", with: parts.joined(separator: ", "))
    }

    private static let requiredLabels: Set<String> = [
        "brand", "title", "subtitle", "start_here", "history", "agent_directory", "search_agents",
        "dashboard", "dashboard_suffix", "new_chat", "all_categories", "example", "run", "load_prompt",
        "empty_title", "empty_subtitle", "message_placeholder", "attach", "more", "send", "background",
        "advanced", "fullscreen", "exit_fullscreen", "collapse", "expand", "clear_selection",
    ]
}

enum ConsoleDecoding {
    static func text(_ value: JSONValue?, maximum: Int, empty: Bool = false) -> String? {
        guard let value = value?.stringValue, value.unicodeScalars.count <= maximum,
            !value.unicodeScalars.contains(where: { $0.value == 0 }),
            empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    static func rows(_ value: JSONValue?, maximum: Int) -> [JSONValue]? {
        guard let value = value?.arrayValue, value.count <= maximum else { return nil }
        return value
    }

    static func number(_ value: JSONValue?, range: ClosedRange<Double>) -> Double? {
        guard let value = value?.numberValue, value.isFinite, range.contains(value) else { return nil }
        return value
    }
}
