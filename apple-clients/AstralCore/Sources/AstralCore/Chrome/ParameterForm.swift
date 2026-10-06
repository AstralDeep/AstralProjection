// Resolves SDUI form defaults, option labels, visibility and submitted values for the Apple renderer.
// It preserves server action descriptors without replacing guidance's stricter authorization-bound validator.

import Foundation

public struct ParameterOption: Equatable, Sendable, Identifiable {
    public let value: String
    public let label: String
    public var id: String { value }
}

public struct ParameterAction: Equatable, Sendable {
    public let label: String
    public let action: String?
    public let variant: String
    public let payload: [String: JSONValue]
    public let available: Bool
}

public struct ParameterForm: Equatable, Sendable {
    public let component: AstralComponent
    public let fields: [JSONValue]

    public init?(component: AstralComponent) {
        guard component.type == "param_picker", let fields = component.raw["fields"]?.arrayValue else { return nil }
        self.component = component
        self.fields = fields
    }

    public var actions: [ParameterAction] {
        if let definitions = component.raw["actions"]?.arrayValue, !definitions.isEmpty {
            return definitions.map { definition in
                let action = Self.action(definition["action"])
                let label = definition["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return ParameterAction(
                    label: label.isEmpty ? "Unavailable action" : label, action: action,
                    variant: definition["variant"]?.stringValue ?? "secondary",
                    payload: definition["payload"]?.objectValue ?? [:], available: action != nil && !label.isEmpty)
            }
        }
        let action = Self.action(component.raw["submit_action"])
        let label =
            component.raw["submit_label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Submit"
        return [
            ParameterAction(
                label: label.isEmpty ? "Unavailable action" : label, action: action,
                variant: "primary", payload: component.raw["submit_payload"]?.objectValue ?? [:],
                available: !label.isEmpty
                    && (action != nil || component.raw["submit_message_template"]?.stringValue?.isEmpty == false))
        ]
    }

    private static func action(_ value: JSONValue?) -> String? {
        guard let action = value?.stringValue,
            action.range(of: "^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$", options: .regularExpression) != nil
        else { return nil }
        return action
    }

    public func options(_ field: JSONValue) -> [ParameterOption] {
        var result: [ParameterOption] = []
        for option in field["options"]?.arrayValue ?? [] {
            guard let value = option.stringValue ?? option["value"]?.stringValue,
                !result.contains(where: { $0.value == value })
            else { continue }
            result.append(ParameterOption(value: value, label: option["label"]?.stringValue ?? value))
        }
        let defaults: [String]
        switch Self.kind(field) {
        case "select": defaults = field["default"]?.stringValue.map { [$0] } ?? []
        case "checklist": defaults = field["default"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        default: defaults = []
        }
        for value in defaults where !value.isEmpty && !result.contains(where: { $0.value == value }) {
            result.append(ParameterOption(value: value, label: value))
        }
        return result
    }

    public func stringValue(_ field: JSONValue, values: [String: String]) -> String {
        let name = field["name"]?.stringValue ?? ""
        if let current = values[name] { return current }
        if Self.kind(field) == "password" { return "" }
        if let value = field["default"] { return value.displayText }
        if Self.kind(field) == "select" { return options(field).first?.value ?? "" }
        return ""
    }

    public func selected(_ field: JSONValue, option: String, flags: [String: Bool]) -> Bool {
        let name = field["name"]?.stringValue ?? ""
        return flags["\(name).\(option)"] ?? field["default"]?.arrayValue?.contains(.string(option)) ?? false
    }

    public func collected(values: [String: String], flags: [String: Bool]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for field in fields {
            guard let name = field["name"]?.stringValue, !name.isEmpty else { continue }
            switch Self.kind(field) {
            case "checklist":
                result[name] = .array(
                    options(field).filter { selected(field, option: $0.value, flags: flags) }.map {
                        .string($0.value)
                    })
            case "boolean", "checkbox": result[name] = .bool(flags[name] ?? field["default"]?.boolValue ?? false)
            case "number":
                let raw = stringValue(field, values: values).trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty {
                    result[name] = .null
                } else if let value = Double(raw), value.isFinite {
                    result[name] = .number(value)
                } else {
                    result[name] = .string(raw)
                }
            default: result[name] = .string(stringValue(field, values: values))
            }
        }
        return result
    }

    public func visible(_ field: JSONValue, values: [String: String], flags: [String: Bool]) -> Bool {
        guard let condition = field["visible_when"]?.objectValue else { return true }
        let current = collected(values: values, flags: flags)
        if let controller = condition["field"]?.stringValue, let expected = condition["equals"] {
            return current[controller] == expected
        }
        return !condition.isEmpty && condition.allSatisfy { current[$0.key] == $0.value }
    }

    public func validationMessage(values: [String: String], flags: [String: Bool]) -> String? {
        let submitted = collected(values: values, flags: flags)
        for field in fields where visible(field, values: values, flags: flags) {
            guard let name = field["name"]?.stringValue else { continue }
            let label = field["label"]?.stringValue ?? name
            if Self.kind(field) == "number", case .string = submitted[name] {
                return "\(label) must be a valid number."
            }
            if field["required"]?.boolValue == true {
                let value = submitted[name]
                if value == nil || value == .null || value == .bool(false) || value == .array([])
                    || value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
                {
                    return "\(label) is required."
                }
            }
        }
        return nil
    }

    private static func kind(_ field: JSONValue) -> String {
        field["kind"]?.stringValue ?? field["type"]?.stringValue ?? "text"
    }
}
