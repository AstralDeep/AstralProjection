// Owns the owner-visible command-sandbox policy: modes, egress domain lists, placeholder secret bindings,
// destination classification, and the pure decisions the Mac launcher and its loopback egress proxy apply.
// ComputerSandboxProfile renders the Seatbelt text; the Mac host wires the live launcher and proxy around it.

import Foundation

public enum ComputerSandboxMode: String, Codable, Sendable, Equatable, CaseIterable {
    case shadow
    case enforce
}

public struct ComputerEgressDomain: Sendable, Equatable, Hashable, Codable {
    public static let maximumCount = 64
    public let value: String

    public init?(_ value: String) {
        let lowered = value.lowercased()
        guard Self.valid(lowered) else { return nil }
        self.value = lowered
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let lowered = raw.lowercased()
        guard Self.valid(lowered) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid egress domain"))
        }
        self.value = lowered
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public static func valid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253, value == value.lowercased() else { return false }
        var body = Substring(value)
        if body.hasPrefix("*.") { body = body.dropFirst(2) }
        guard !body.isEmpty else { return false }
        let labels = body.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count) else { return false }
            let scalars = Array(label.unicodeScalars)
            guard scalars.first.map({ Self.labelCharacter($0) }) == true,
                scalars.last.map({ Self.labelCharacter($0) }) == true
            else { return false }
            return scalars.allSatisfy { Self.labelCharacter($0) || $0 == "-" }
        }
    }

    private static func labelCharacter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
    }

    public func matches(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if value.hasPrefix("*.") {
            let suffix = String(value.dropFirst(1))
            return lowered.hasSuffix(suffix) && lowered.count > suffix.count
        }
        return lowered == value
    }
}

public struct ComputerEgressBinding: Sendable, Equatable, Hashable, Codable {
    public static let maximumCount = 16
    public let placeholder: String
    public let host: String
    public let secret: String

    public init?(placeholder: String, host: String, secret: String) {
        guard Self.validPlaceholder(placeholder), let domain = ComputerEgressDomain(host),
            !domain.value.hasPrefix("*."), Self.validSecret(secret)
        else { return nil }
        self.placeholder = placeholder
        self.host = domain.value
        self.secret = secret
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let placeholder = try values.decode(String.self, forKey: .placeholder)
        let host = try values.decode(String.self, forKey: .host)
        let secret = try values.decode(String.self, forKey: .secret)
        guard let binding = ComputerEgressBinding(placeholder: placeholder, host: host, secret: secret) else {
            throw DecodingError.dataCorruptedError(
                forKey: .placeholder, in: values, debugDescription: "invalid egress binding")
        }
        self = binding
    }

    private enum CodingKeys: String, CodingKey {
        case placeholder, host, secret
    }

    public static func validPlaceholder(_ value: String) -> Bool {
        guard (8...128).contains(value.count) else { return false }
        let scalars = Array(value.unicodeScalars)
        guard value.hasPrefix("ASTRAL_"), scalars.dropFirst(7).count >= 3 else { return false }
        return scalars.allSatisfy {
            $0 == "_" || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57)
        }
    }

    public static func validSecret(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            $0 == "." || $0 == "-" || $0 == "_"
                || ($0.value >= 97 && $0.value <= 122) || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 48 && $0.value <= 57)
        }
    }
}

public struct ComputerSandboxConfiguration: Sendable, Equatable, Codable {
    public let mode: ComputerSandboxMode
    public let domains: [ComputerEgressDomain]
    public let bindings: [ComputerEgressBinding]

    public static let fallback = ComputerSandboxConfiguration(mode: .shadow, domains: [], bindings: [])!

    public init?(mode: ComputerSandboxMode, domains: [ComputerEgressDomain], bindings: [ComputerEgressBinding]) {
        guard domains.count <= ComputerEgressDomain.maximumCount,
            bindings.count <= ComputerEgressBinding.maximumCount,
            Set(domains).count == domains.count,
            Set(bindings).count == bindings.count,
            Set(bindings.map(\.placeholder)).count == bindings.count
        else { return nil }
        self.mode = mode
        self.domains = domains
        self.bindings = bindings
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try values.decodeIfPresent(ComputerSandboxMode.self, forKey: .mode) ?? .shadow
        let domains = try values.decodeIfPresent([ComputerEgressDomain].self, forKey: .domains) ?? []
        let bindings = try values.decodeIfPresent([ComputerEgressBinding].self, forKey: .bindings) ?? []
        guard let configuration = ComputerSandboxConfiguration(mode: mode, domains: domains, bindings: bindings) else {
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: values, debugDescription: "invalid sandbox configuration")
        }
        self = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case mode, domains, bindings
    }

    public static func decoded(_ data: Data) -> ComputerSandboxConfiguration {
        (try? JSONDecoder().decode(ComputerSandboxConfiguration.self, from: data)) ?? fallback
    }

    public var placeholders: [String] { bindings.map(\.placeholder) }

    public func replacing(mode: ComputerSandboxMode) -> ComputerSandboxConfiguration? {
        ComputerSandboxConfiguration(mode: mode, domains: domains, bindings: bindings)
    }
}

public enum ComputerEgressAddressClass: String, Sendable, Equatable {
    case loopback, linkLocal, metadata, privateNetwork, multicast, unspecified, reserved, publicNetwork
}

public enum ComputerIPAddress: Sendable, Equatable, Hashable {
    case v4([UInt8])
    case v6([UInt8])

    public static func parse(_ text: String) -> ComputerIPAddress? {
        if let v4 = Self.parseIPv4(text) { return .v4(v4) }
        if let v6 = Self.parseIPv6(text) { return .v6(v6) }
        return nil
    }

    private static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, !text.isEmpty else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isNumber), let value = Int(part), value <= 255,
                part == String(value)
            else { return nil }
            octets.append(UInt8(value))
        }
        return octets
    }

    private static func parseIPv6(_ text: String) -> [UInt8]? {
        guard text.contains(":") else { return nil }
        var remainder = Substring(text)
        if remainder.hasPrefix("[") && remainder.hasSuffix("]") {
            remainder = remainder.dropFirst().dropLast()
        }
        var bytes = Array(repeating: 0, count: 16)
        if let range = remainder.range(of: "::") {
            let left = remainder[..<range.lowerBound]
            let right = remainder[range.upperBound...]
            guard remainder.range(of: "::", options: [], range: range.upperBound..<remainder.endIndex) == nil else {
                return nil
            }
            let head = Self.ipv6Groups(left)
            let tail = Self.ipv6Groups(right)
            guard let head, let tail, head.count + tail.count <= 7 else { return nil }
            for (index, group) in head.enumerated() {
                bytes[index * 2] = UInt8((group >> 8) & 0xFF)
                bytes[index * 2 + 1] = UInt8(group & 0xFF)
            }
            let offset = 8 - tail.count
            for (index, group) in tail.enumerated() {
                let position = offset + index
                bytes[position * 2] = UInt8((group >> 8) & 0xFF)
                bytes[position * 2 + 1] = UInt8(group & 0xFF)
            }
            return bytes
        }
        guard let groups = Self.ipv6Groups(remainder), groups.count == 8 else { return nil }
        for (index, group) in groups.enumerated() {
            bytes[index * 2] = UInt8((group >> 8) & 0xFF)
            bytes[index * 2 + 1] = UInt8(group & 0xFF)
        }
        return bytes
    }

    private static func ipv6Groups(_ text: Substring) -> [Int]? {
        guard !text.isEmpty else { return [] }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        var groups: [Int] = []
        for part in parts {
            if part.contains(".") {
                guard let v4 = Self.parseIPv4(String(part)) else { return nil }
                groups.append(Int(v4[0]) << 8 | Int(v4[1]))
                groups.append(Int(v4[2]) << 8 | Int(v4[3]))
                continue
            }
            guard (1...4).contains(part.count), let value = Int(part, radix: 16) else { return nil }
            groups.append(value)
        }
        return groups
    }

    public var isIPv4: Bool {
        if case .v4 = self { return true }
        return false
    }

    public var text: String {
        switch self {
        case .v4(let octets): return octets.map(String.init).joined(separator: ".")
        case .v6(let bytes):
            var groups: [String] = []
            for index in stride(from: 0, to: 16, by: 2) {
                groups.append(String(format: "%x", (Int(bytes[index]) << 8) | Int(bytes[index + 1])))
            }
            return groups.joined(separator: ":")
        }
    }

    public var addressClass: ComputerEgressAddressClass {
        switch self {
        case .v4(let o):
            switch o[0] {
            case 127: return .loopback
            case 169 where o[1] == 254:
                return o[2] == 169 && o[3] == 254 ? .metadata : .linkLocal
            case 10: return .privateNetwork
            case 172 where (16...31).contains(o[1]): return .privateNetwork
            case 192 where o[1] == 168: return .privateNetwork
            case 100 where (64...127).contains(o[1]): return .privateNetwork
            case 0: return .unspecified
            case 224...239: return .multicast
            case 240...255: return .reserved
            default: return .publicNetwork
            }
        case .v6(let b):
            let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
            if Array(b[0...11]) == mappedPrefix {
                return ComputerIPAddress.v4([b[12], b[13], b[14], b[15]]).addressClass
            }
            if b == [UInt8](repeating: 0, count: 16) { return .unspecified }
            if b[15] == 1 && b[0...14].allSatisfy({ $0 == 0 }) { return .loopback }
            switch b[0] {
            case 0xFF: return .multicast
            case 0xFE where (0x80...0xBF).contains(Int(b[1])): return .linkLocal
            case 0xFC, 0xFD: return .privateNetwork
            case 0x20...0x3F: return .publicNetwork
            default: return .reserved
            }
        }
    }
}

public struct ComputerEgressTarget: Sendable, Equatable {
    public static let maximumHostBytes = 253
    public let host: String
    public let port: Int

    public init?(host: String, port: Int) {
        let lowered = host.lowercased()
        guard !lowered.isEmpty, lowered.utf8.count <= Self.maximumHostBytes,
            !lowered.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 || $0.value > 126 }),
            (0...65535).contains(port)
        else { return nil }
        self.host = lowered
        self.port = port
    }

    public static func authority(_ text: String, defaultPort: Int) -> ComputerEgressTarget? {
        guard !text.isEmpty, text.utf8.count <= maximumHostBytes + 6 else { return nil }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && rest.dropFirst().allSatisfy(\.isNumber)) else { return nil }
            guard !rest.hasPrefix(":0") else { return nil }
            let port = rest.isEmpty ? defaultPort : Int(rest.dropFirst())
            return ComputerEgressTarget(host: host, port: port ?? 0)
        }
        if let colon = text.lastIndex(of: ":") {
            let digits = text[text.index(after: colon)...]
            if !digits.isEmpty, digits.allSatisfy(\.isNumber), !text[..<colon].contains(":") {
                guard digits != "0" else { return nil }
                return ComputerEgressTarget(host: String(text[..<colon]), port: Int(digits) ?? 0)
            }
            return nil
        }
        return ComputerEgressTarget(host: text, port: defaultPort)
    }

    public var label: String { "\(host):\(port)" }
}

public struct ComputerEgressRequest: Sendable, Equatable {
    public enum Form: String, Sendable, Equatable {
        case connect, absolute, other
    }

    public static let maximumHeadBytes = 16384
    public let form: Form
    public let method: String
    public let target: ComputerEgressTarget?
    public let path: String?
    public let version: String
    public let head: String

    public static func parse(_ head: String) -> ComputerEgressRequest? {
        guard !head.isEmpty, head.utf8.count <= maximumHeadBytes else { return nil }
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let requestLine = first.hasSuffix("\r") ? first.dropLast() : first
        let tokens = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count == 3, !tokens[0].isEmpty, tokens[2].hasPrefix("HTTP/") else { return nil }
        let method = tokens[0].uppercased()
        if method == "CONNECT" {
            guard let target = ComputerEgressTarget.authority(tokens[1], defaultPort: 443) else { return nil }
            return ComputerEgressRequest(
                form: .connect, method: method, target: target, path: nil, version: tokens[2], head: head)
        }
        if tokens[1].lowercased().hasPrefix("http://") {
            let rest = tokens[1].dropFirst(7)
            let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
            guard let target = ComputerEgressTarget.authority(String(rest[..<cut]), defaultPort: 80) else { return nil }
            let path = rest[cut...].isEmpty ? "/" : String(rest[cut...])
            return ComputerEgressRequest(
                form: .absolute, method: method, target: target, path: path, version: tokens[2], head: head)
        }
        return ComputerEgressRequest(
            form: .other, method: method, target: nil, path: nil, version: tokens[2], head: head)
    }

    public var originFormRequestLine: String? {
        guard form == .absolute, let path, let target else { return nil }
        let port = target.port == 80 ? "" : ":\(target.port)"
        return "\(method) \(path) HTTP/1.1\r\nHost: \(target.host)\(port)"
    }
}

public enum ComputerEgressRefusal: String, Sendable, Equatable, CaseIterable {
    case malformedRequest = "malformed_request"
    case unlistedHost = "unlisted_host"
    case unresolvableHost = "unresolvable_host"
    case loopbackDestination = "loopback_destination"
    case linkLocalDestination = "link_local_destination"
    case metadataDestination = "metadata_destination"
    case privateDestination = "private_destination"
    case reservedDestination = "reserved_destination"
    case placeholderUnbound = "placeholder_unbound"
    case secretUnavailable = "secret_unavailable"
}

public enum ComputerEgressVerdict: Sendable, Equatable {
    case allow(rule: String)
    case refuse(ComputerEgressRefusal)
}

public struct ComputerEgressEvaluation: Sendable, Equatable {
    public let verdict: ComputerEgressVerdict
    public let placeholders: [String]
}

public struct ComputerEgressDecision: Sendable, Equatable {
    public let target: ComputerEgressTarget
    public let verdict: ComputerEgressVerdict
    public let forwarded: Bool
    public let placeholders: [String]

    public init(target: ComputerEgressTarget, verdict: ComputerEgressVerdict, forwarded: Bool, placeholders: [String]) {
        self.target = target
        self.verdict = verdict
        self.forwarded = forwarded
        self.placeholders = placeholders
    }

    public var decision: String { forwarded ? "allow" : "refuse" }

    public var rule: String {
        switch verdict {
        case .allow(let value): return value
        case .refuse(let reason): return reason.rawValue
        }
    }

    public var json: [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "host": .string(target.host), "port": .number(Double(target.port)), "decision": .string(decision),
            "rule": .string(rule),
        ]
        if !placeholders.isEmpty {
            payload["placeholders"] = .array(placeholders.sorted().map(.string))
        }
        return payload
    }
}

public struct ComputerEgressPolicy: Sendable, Equatable {
    public let mode: ComputerSandboxMode
    public let domains: [ComputerEgressDomain]
    public let bindings: [ComputerEgressBinding]

    public init(mode: ComputerSandboxMode, domains: [ComputerEgressDomain], bindings: [ComputerEgressBinding]) {
        self.mode = mode
        self.domains = domains
        self.bindings = bindings
    }

    public init(configuration: ComputerSandboxConfiguration) {
        self.init(mode: configuration.mode, domains: configuration.domains, bindings: configuration.bindings)
    }

    public func matchingRule(for host: String) -> String? {
        domains.first { $0.matches(host) }?.value
    }

    public func bindings(for host: String) -> [ComputerEgressBinding] {
        bindings.filter { $0.host == host.lowercased() }
    }

    public func placeholders(in head: String) -> [String] {
        bindings.map(\.placeholder).filter { head.contains($0) }
    }

    public static func classify(_ address: ComputerIPAddress) -> ComputerEgressRefusal? {
        switch address.addressClass {
        case .publicNetwork: return nil
        case .loopback: return .loopbackDestination
        case .linkLocal: return .linkLocalDestination
        case .metadata: return .metadataDestination
        case .privateNetwork: return .privateDestination
        case .multicast: return .reservedDestination
        case .unspecified: return .reservedDestination
        case .reserved: return .reservedDestination
        }
    }

    public func evaluate(request: ComputerEgressRequest, resolved: [ComputerIPAddress]) -> ComputerEgressEvaluation {
        guard let target = request.target else {
            return ComputerEgressEvaluation(verdict: .refuse(.malformedRequest), placeholders: [])
        }
        let found = placeholders(in: request.head)
        guard let rule = matchingRule(for: target.host) else {
            return ComputerEgressEvaluation(verdict: .refuse(.unlistedHost), placeholders: found)
        }
        guard !resolved.isEmpty else {
            return ComputerEgressEvaluation(verdict: .refuse(.unresolvableHost), placeholders: found)
        }
        if let refusal = resolved.compactMap(Self.classify).first {
            return ComputerEgressEvaluation(verdict: .refuse(refusal), placeholders: found)
        }
        for placeholder in found where !bindings(for: target.host).contains(where: { $0.placeholder == placeholder }) {
            return ComputerEgressEvaluation(verdict: .refuse(.placeholderUnbound), placeholders: found)
        }
        return ComputerEgressEvaluation(verdict: .allow(rule: rule), placeholders: found)
    }

    public static func swapPlaceholders(
        in head: String, bindings: [ComputerEgressBinding], resolving: (String) -> String?
    ) -> (head: String, swapped: [String], missing: [String]) {
        var result = head
        var swapped: [String] = []
        var missing: [String] = []
        for binding in bindings.sorted(by: { $0.placeholder.count > $1.placeholder.count }) {
            guard result.contains(binding.placeholder) else { continue }
            guard let secret = resolving(binding.secret), !secret.isEmpty, !secret.contains("\r"),
                !secret.contains("\n")
            else {
                missing.append(binding.placeholder)
                continue
            }
            result = result.replacingOccurrences(of: binding.placeholder, with: secret)
            swapped.append(binding.placeholder)
        }
        return (result, swapped, missing)
    }

    public static func scrub(_ text: String, placeholders: [String]) -> String {
        var result = text
        for placeholder in placeholders.sorted(by: { $0.count > $1.count }) where !placeholder.isEmpty {
            result = result.replacingOccurrences(of: placeholder, with: "[astral:redacted]")
        }
        return result
    }

    public static func leakedEnvironmentVariable(
        _ environment: [String: String], placeholders: [String]
    ) -> String? {
        for (name, value) in environment.sorted(by: { $0.key < $1.key })
        where placeholders.contains(where: { !$0.isEmpty && value.contains($0) }) {
            return name
        }
        return nil
    }
}

public struct ComputerSandboxViolation: Sendable, Equatable {
    public let process: String
    public let pid: Int
    public let operation: String
    public let target: String

    public var key: String { "\(pid)|\(operation)|\(target)" }

    public static func parse(_ text: String) -> [ComputerSandboxViolation] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ raw: String) -> ComputerSandboxViolation? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard line.hasPrefix("Sandbox: ") else { return nil }
        let remainder = line.dropFirst("Sandbox: ".count)
        guard let open = remainder.firstIndex(of: "(") else { return nil }
        let process = String(remainder[..<open])
        guard !process.isEmpty, let deny = remainder[open...].range(of: ") deny(") else { return nil }
        let pidText = String(remainder[remainder.index(after: open)..<deny.lowerBound])
        guard let pid = Int(pidText), (1...4_194_303).contains(pid) else { return nil }
        let body = remainder[deny.upperBound...]
        guard let close = body.firstIndex(of: ")") else { return nil }
        let count = String(body[..<close])
        guard !count.isEmpty, count.allSatisfy(\.isNumber) else { return nil }
        let detail = body[body.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard !detail.isEmpty, let separator = detail.firstIndex(of: " ") else { return nil }
        let operation = String(detail[..<separator])
        let target = String(detail[detail.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !operation.isEmpty, !target.isEmpty else { return nil }
        return ComputerSandboxViolation(process: process, pid: pid, operation: operation, target: target)
    }
}
