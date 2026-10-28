// Decides which URLs the Mac browser pane may load, the origin each belongs to, which fields are secret and
// which controls are consequential. MacBrowserDriver applies it at action time, and browser_snapshot.js
// receives scriptRules so snapshot redaction follows the same rules inside the page.

import Foundation

public struct ComputerBrowserElement: Sendable, Equatable {
    public let tag: String
    public let type: String
    public let role: String
    public let nameAttribute: String
    public let idAttribute: String
    public let autocomplete: String
    public let label: String
    public let text: String
    public let inForm: Bool
    public let formHasSecret: Bool
    public let editable: Bool

    public init(
        tag: String, type: String = "", role: String = "", nameAttribute: String = "", idAttribute: String = "",
        autocomplete: String = "", label: String = "", text: String = "", inForm: Bool = false,
        formHasSecret: Bool = false, editable: Bool = false
    ) {
        func bounded(_ value: String) -> String { String(value.prefix(1000)) }
        self.tag = bounded(tag).lowercased()
        self.type = bounded(type).lowercased()
        self.role = bounded(role).lowercased()
        self.nameAttribute = bounded(nameAttribute)
        self.idAttribute = bounded(idAttribute)
        self.autocomplete = bounded(autocomplete).lowercased()
        self.label = bounded(label)
        self.text = bounded(text)
        self.inForm = inForm
        self.formHasSecret = formHasSecret
        self.editable = editable
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue, let tag = object["tag"]?.stringValue, !tag.isEmpty else { return nil }
        func string(_ key: String) -> String { object[key]?.stringValue ?? "" }
        self.init(
            tag: tag, type: string("type"), role: string("role"), nameAttribute: string("name_attr"),
            idAttribute: string("id_attr"), autocomplete: string("autocomplete"), label: string("label"),
            text: string("text"), inForm: object["in_form"]?.boolValue ?? false,
            formHasSecret: object["form_has_secret"]?.boolValue ?? false,
            editable: object["editable"]?.boolValue ?? false)
    }
}

public enum ComputerBrowserPolicy {
    public static let redacted = "<redacted>"
    public static let maximumURLLength = 4096
    static let secretTypes: Set<String> = ["password"]
    static let secretAutocomplete: Set<String> = ["one-time-code", "cc-number", "cc-csc"]
    static let secretAutocompletePrefixes = ["cc-exp"]
    static let secretAutocompleteSuffixes = ["-password"]
    static let nonFieldTypes: Set<String> = [
        "button", "submit", "reset", "image", "checkbox", "radio", "file", "hidden", "range", "color",
    ]
    static let identifierPattern = "passw(?:or)?d|(?:^|[^a-z0-9])(?:otp|cvv|cvc|card)"
    static let consequentialPattern =
        "(?:^|[^a-z0-9])(?:buy|pay|purchase|order|checkout|delete|remove|send|transfer|confirm\\s+payment)"
        + "(?=$|[^a-z0-9])"
    static let camelPattern = "([a-z0-9])([A-Z])"

    public static func navigableURL(_ text: String) throws -> URL {
        let rejected = ComputerHostError(
            "url_rejected", "The browser pane opens only plain http or https addresses without sign-in details.")
        guard !text.isEmpty, text.utf8.count <= maximumURLLength,
            text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value != 127 && $0 != "\\" }),
            !text.unicodeScalars.contains(where: bidiOrFormat), let separator = text.range(of: "://")
        else { throw rejected }
        let scheme = text[..<separator.lowerBound].lowercased()
        let authority = text[separator.upperBound...].prefix { !["/", "?", "#"].contains($0) }
        guard ["http", "https"].contains(scheme), !authority.isEmpty, !authority.contains("@"),
            !authority.contains("%"), let components = URLComponents(string: text), components.user == nil,
            components.password == nil, components.scheme?.lowercased() == scheme,
            let host = components.percentEncodedHost, !host.isEmpty, !host.contains("%"),
            let url = URL(string: text), origin(of: url) != nil
        else { throw rejected }
        return url
    }

    public static func isNavigable(_ url: URL) -> Bool {
        (try? navigableURL(url.absoluteString)) != nil
    }

    public static func origin(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return origin(scheme: components.scheme, host: components.host, port: components.port)
    }

    public static func origin(of text: String) -> String? {
        guard let url = try? navigableURL(text) else { return nil }
        return origin(of: url)
    }

    public static func origin(scheme: String?, host: String?, port: Int?) -> String? {
        guard let scheme = scheme?.lowercased(), ["http", "https"].contains(scheme),
            var host = host?.lowercased(), !host.isEmpty,
            host.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value != 127 }),
            !host.contains("@"), !host.contains("/"), !host.contains("\\")
        else { return nil }
        if host.contains(":") && !host.hasPrefix("[") { host = "[" + host + "]" }
        if let port {
            guard (1...65535).contains(port) else { return nil }
            if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
                return scheme + "://" + host
            }
            return scheme + "://" + host + ":" + String(port)
        }
        return scheme + "://" + host
    }

    public static func isField(_ element: ComputerBrowserElement) -> Bool {
        switch element.tag {
        case "textarea", "select": return true
        case "input": return element.type == "password" || !nonFieldTypes.contains(element.type)
        default: return element.editable
        }
    }

    public static func isSecret(_ element: ComputerBrowserElement) -> Bool {
        guard isField(element) else { return false }
        if element.tag == "input" && secretTypes.contains(element.type) { return true }
        let tokens = element.autocomplete.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.contains(where: { token in
            secretAutocomplete.contains(token) || secretAutocompletePrefixes.contains(where: token.hasPrefix)
                || secretAutocompleteSuffixes.contains(where: token.hasSuffix)
        }) {
            return true
        }
        return [element.nameAttribute, element.idAttribute].contains { matches(identifierPattern, identifier($0)) }
    }

    public static func isSubmit(_ element: ComputerBrowserElement) -> Bool {
        switch element.tag {
        case "button": return element.type.isEmpty || element.type == "submit"
        case "input": return element.type == "submit" || element.type == "image"
        default: return false
        }
    }

    public static func isConsequential(_ element: ComputerBrowserElement) -> Bool {
        if isSubmit(element) && element.inForm && element.formHasSecret { return true }
        if element.autocomplete.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix("cc-") }) {
            return true
        }
        return [element.label, element.text].contains { matches(consequentialPattern, $0.lowercased()) }
    }

    public static func displayValue(_ value: String, for element: ComputerBrowserElement) -> String {
        isSecret(element) ? redacted : value
    }

    public static func identifier(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        let regex = try? NSRegularExpression(pattern: camelPattern)
        let split = regex?.stringByReplacingMatches(in: raw, range: range, withTemplate: "$1 $2") ?? raw
        return split.lowercased()
    }

    public static var scriptRules: JSONValue {
        func list(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
        return .object([
            "secret_types": list(secretTypes.sorted()),
            "secret_autocomplete": list(secretAutocomplete.sorted()),
            "secret_autocomplete_prefixes": list(secretAutocompletePrefixes),
            "secret_autocomplete_suffixes": list(secretAutocompleteSuffixes),
            "non_field_types": list(nonFieldTypes.sorted()),
            "identifier_pattern": .string(identifierPattern),
            "consequential_pattern": .string(consequentialPattern),
            "camel_pattern": .string(camelPattern),
            "redacted": .string(redacted),
        ])
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func bidiOrFormat(_ scalar: Unicode.Scalar) -> Bool {
        [0x200E, 0x200F].contains(scalar.value) || (0x202A...0x202E).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value) || scalar.properties.generalCategory == .format
    }
}
