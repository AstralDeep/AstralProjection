// Parses the small JSON Schema subset the on-device model is asked to follow and checks generated JSON against it.
// OnDeviceModelAdapter uses it so constrained output is verified in code and never trusted as produced.

import Foundation

nonisolated struct OnDeviceSchemaProperty: Equatable, Sendable {
    let name: String
    let schema: OnDeviceJSONSchema
    let required: Bool
}

nonisolated enum OnDeviceSchemaError: Error, Equatable {
    case invalidJSON
    case unsupported(String)
}

nonisolated indirect enum OnDeviceJSONSchema: Equatable, Sendable {
    case object([OnDeviceSchemaProperty])
    case string(allowed: [String]?)
    case integer(minimum: Int?, maximum: Int?)
    case number
    case boolean
    case array(items: OnDeviceJSONSchema, minItems: Int?, maxItems: Int?)

    init(json: String) throws {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw OnDeviceSchemaError.invalidJSON }
        self = try Self.parse(root)
    }

    private static func parse(_ node: [String: Any]) throws -> OnDeviceJSONSchema {
        guard let type = node["type"] as? String else {
            throw OnDeviceSchemaError.unsupported("type")
        }
        switch type {
        case "object":
            let properties = node["properties"] as? [String: Any] ?? [:]
            let required = Set(node["required"] as? [String] ?? [])
            let parsed = try properties.keys.sorted().map { name -> OnDeviceSchemaProperty in
                guard let child = properties[name] as? [String: Any] else {
                    throw OnDeviceSchemaError.unsupported("property \(name)")
                }
                return OnDeviceSchemaProperty(
                    name: name, schema: try parse(child), required: required.contains(name))
            }
            return .object(parsed)
        case "string":
            if let allowed = node["enum"] {
                guard let values = allowed as? [String], !values.isEmpty else {
                    throw OnDeviceSchemaError.unsupported("enum")
                }
                return .string(allowed: values)
            }
            return .string(allowed: nil)
        case "integer":
            return .integer(
                minimum: (node["minimum"] as? NSNumber)?.intValue,
                maximum: (node["maximum"] as? NSNumber)?.intValue)
        case "number":
            return .number
        case "boolean":
            return .boolean
        case "array":
            guard let items = node["items"] as? [String: Any] else {
                throw OnDeviceSchemaError.unsupported("items")
            }
            return .array(
                items: try parse(items),
                minItems: (node["minItems"] as? NSNumber)?.intValue,
                maxItems: (node["maxItems"] as? NSNumber)?.intValue)
        default:
            throw OnDeviceSchemaError.unsupported(type)
        }
    }

    func accepts(_ jsonText: String) -> Bool {
        guard let data = jsonText.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return false }
        return accepts(value: value)
    }

    private func accepts(value: Any) -> Bool {
        switch self {
        case .object(let properties):
            guard let dictionary = value as? [String: Any] else { return false }
            let known = Set(properties.map(\.name))
            if !Set(dictionary.keys).isSubset(of: known) { return false }
            for property in properties {
                guard let child = dictionary[property.name] else {
                    if property.required { return false }
                    continue
                }
                if !property.schema.accepts(value: child) { return false }
            }
            return true
        case .string(let allowed):
            guard let text = value as? String else { return false }
            return allowed?.contains(text) ?? true
        case .integer(let minimum, let maximum):
            guard let number = value as? NSNumber, !Self.isBoolean(number),
                number.doubleValue.rounded() == number.doubleValue
            else { return false }
            let integer = number.intValue
            return integer >= (minimum ?? Int.min) && integer <= (maximum ?? Int.max)
        case .number:
            guard let number = value as? NSNumber else { return false }
            return !Self.isBoolean(number)
        case .boolean:
            guard let number = value as? NSNumber else { return false }
            return Self.isBoolean(number)
        case .array(let items, let minItems, let maxItems):
            guard let elements = value as? [Any] else { return false }
            if elements.count < (minItems ?? 0) || elements.count > (maxItems ?? Int.max) {
                return false
            }
            return elements.allSatisfy { items.accepts(value: $0) }
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
