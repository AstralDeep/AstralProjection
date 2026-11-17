// Strict JSON tree, parser and canonical writer for execution policies: no duplicate keys, no floats, 64-bit integers, valid UTF-8 and byte-wise string comparison.
// ExecPolicy and the Seatbelt conformance tests use it because Foundation's parser and Swift String equality would blur cases the policy contract keeps distinct.

import Foundation

public indirect enum ExecJSON: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([ExecJSON])
    case object([(key: String, value: ExecJSON)])
}

public struct ExecJSONError: Error, Equatable, Sendable {
    public let detail: String
}

extension ExecJSON: Equatable {
    public static func == (lhs: ExecJSON, rhs: ExecJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.string(let a), .string(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            return zip(a.sorted(by: Self.keyOrder), b.sorted(by: Self.keyOrder)).allSatisfy {
                $0.key.utf8.elementsEqual($1.key.utf8) && $0.value == $1.value
            }
        default: return false
        }
    }

    static func keyOrder(_ a: (key: String, value: ExecJSON), _ b: (key: String, value: ExecJSON)) -> Bool {
        a.key.utf8.lexicographicallyPrecedes(b.key.utf8)
    }
}

extension ExecJSON {
    public subscript(key: String) -> ExecJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var arrayValue: [ExecJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public static func parse(_ data: Data) throws -> ExecJSON {
        var parser = ExecJSONParser(data: data)
        return try parser.document()
    }

    public func canonicalData() throws -> Data {
        var out = [UInt8]()
        try write(into: &out)
        return Data(out)
    }

    private func write(into out: inout [UInt8]) throws {
        switch self {
        case .null: out += Array("null".utf8)
        case .bool(let value): out += Array((value ? "true" : "false").utf8)
        case .int(let value): out += Array(String(value).utf8)
        case .string(let value): Self.writeString(value, into: &out)
        case .array(let items):
            out.append(0x5B)
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(0x2C) }
                try item.write(into: &out)
            }
            out.append(0x5D)
        case .object(let members):
            let sorted = members.sorted(by: Self.keyOrder)
            for pair in zip(sorted, sorted.dropFirst()) where pair.0.key.utf8.elementsEqual(pair.1.key.utf8) {
                throw ExecJSONError(detail: "duplicate key")
            }
            out.append(0x7B)
            for (index, member) in sorted.enumerated() {
                if index > 0 { out.append(0x2C) }
                Self.writeString(member.key, into: &out)
                out.append(0x3A)
                try member.value.write(into: &out)
            }
            out.append(0x7D)
        }
    }

    private static func writeString(_ value: String, into out: inout [UInt8]) {
        out.append(0x22)
        for byte in value.utf8 {
            switch byte {
            case 0x22: out += [0x5C, 0x22]
            case 0x5C: out += [0x5C, 0x5C]
            case 0x0A: out += [0x5C, 0x6E]
            case 0x0D: out += [0x5C, 0x72]
            case 0x09: out += [0x5C, 0x74]
            case 0x08: out += [0x5C, 0x62]
            case 0x0C: out += [0x5C, 0x66]
            case 0..<0x20: out += Array(String(format: "\\u%04x", byte).utf8)
            default: out.append(byte)
            }
        }
        out.append(0x22)
    }
}

private struct ExecJSONParser {
    static let maxDepth = 900

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var depth = 0

    init(data: Data) {
        var decoded = [Unicode.Scalar]()
        decoded.reserveCapacity(data.count)
        var iterator = data.makeIterator()
        var decoder = UTF8()
        var valid = true
        decode: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): decoded.append(scalar)
            case .emptyInput: break decode
            case .error:
                valid = false
                break decode
            }
        }
        scalars = valid ? decoded : []
        invalidUTF8 = !valid
    }

    private let invalidUTF8: Bool

    mutating func document() throws -> ExecJSON {
        if invalidUTF8 { throw ExecJSONError(detail: "not UTF-8") }
        if scalars.first?.value == 0xFEFF { throw ExecJSONError(detail: "byte order mark") }
        skipSpace()
        let value = try parseValue()
        skipSpace()
        guard index == scalars.count else { throw ExecJSONError(detail: "trailing data") }
        return value
    }

    private mutating func skipSpace() {
        while index < scalars.count, [0x20, 0x09, 0x0A, 0x0D].contains(scalars[index].value) { index += 1 }
    }

    private func peek() -> UInt32? { index < scalars.count ? scalars[index].value : nil }

    private mutating func expect(_ literal: String) throws {
        for scalar in literal.unicodeScalars {
            guard index < scalars.count, scalars[index] == scalar else { throw ExecJSONError(detail: "bad literal") }
            index += 1
        }
    }

    private mutating func parseValue() throws -> ExecJSON {
        guard let next = peek() else { throw ExecJSONError(detail: "unexpected end") }
        switch next {
        case 0x7B: return try parseObject()
        case 0x5B: return try parseArray()
        case 0x22: return .string(try parseString())
        case 0x74:
            try expect("true")
            return .bool(true)
        case 0x66:
            try expect("false")
            return .bool(false)
        case 0x6E:
            try expect("null")
            return .null
        case 0x2D, 0x30...0x39: return try parseNumber()
        default: throw ExecJSONError(detail: "unexpected character")
        }
    }

    private mutating func enter() throws {
        depth += 1
        if depth > Self.maxDepth { throw ExecJSONError(detail: "nesting too deep") }
    }

    private mutating func parseObject() throws -> ExecJSON {
        try enter()
        defer { depth -= 1 }
        index += 1
        var members = [(key: String, value: ExecJSON)]()
        var seen = Set<[UInt8]>()
        skipSpace()
        if peek() == 0x7D {
            index += 1
            return .object(members)
        }
        while true {
            skipSpace()
            guard peek() == 0x22 else { throw ExecJSONError(detail: "object key expected") }
            let key = try parseString()
            guard seen.insert(Array(key.utf8)).inserted else { throw ExecJSONError(detail: "duplicate key") }
            skipSpace()
            guard peek() == 0x3A else { throw ExecJSONError(detail: "colon expected") }
            index += 1
            skipSpace()
            members.append((key, try parseValue()))
            skipSpace()
            switch peek() {
            case 0x2C: index += 1
            case 0x7D:
                index += 1
                return .object(members)
            default: throw ExecJSONError(detail: "comma or brace expected")
            }
        }
    }

    private mutating func parseArray() throws -> ExecJSON {
        try enter()
        defer { depth -= 1 }
        index += 1
        var items = [ExecJSON]()
        skipSpace()
        if peek() == 0x5D {
            index += 1
            return .array(items)
        }
        while true {
            skipSpace()
            items.append(try parseValue())
            skipSpace()
            switch peek() {
            case 0x2C: index += 1
            case 0x5D:
                index += 1
                return .array(items)
            default: throw ExecJSONError(detail: "comma or bracket expected")
            }
        }
    }

    private mutating func hexQuad() throws -> UInt32 {
        guard index + 4 <= scalars.count else { throw ExecJSONError(detail: "short escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt32
            switch scalars[index].value {
            case 0x30...0x39: digit = scalars[index].value - 0x30
            case 0x41...0x46: digit = scalars[index].value - 0x41 + 10
            case 0x61...0x66: digit = scalars[index].value - 0x61 + 10
            default: throw ExecJSONError(detail: "bad escape")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func parseString() throws -> String {
        index += 1
        var out = String.UnicodeScalarView()
        while true {
            guard index < scalars.count else { throw ExecJSONError(detail: "unterminated string") }
            let scalar = scalars[index]
            index += 1
            switch scalar.value {
            case 0x22: return String(out)
            case 0..<0x20: throw ExecJSONError(detail: "control character in string")
            case 0x5C:
                guard index < scalars.count else { throw ExecJSONError(detail: "unterminated escape") }
                let escape = scalars[index].value
                index += 1
                switch escape {
                case 0x22: out.append("\"")
                case 0x5C: out.append("\\")
                case 0x2F: out.append("/")
                case 0x62: out.append("\u{08}")
                case 0x66: out.append("\u{0C}")
                case 0x6E: out.append("\n")
                case 0x72: out.append("\r")
                case 0x74: out.append("\t")
                case 0x75:
                    var code = try hexQuad()
                    if (0xD800...0xDBFF).contains(code) {
                        guard peek() == 0x5C, index + 1 < scalars.count, scalars[index + 1].value == 0x75 else {
                            throw ExecJSONError(detail: "lone surrogate")
                        }
                        index += 2
                        let low = try hexQuad()
                        guard (0xDC00...0xDFFF).contains(low) else { throw ExecJSONError(detail: "lone surrogate") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(code) {
                        throw ExecJSONError(detail: "lone surrogate")
                    }
                    guard let decoded = Unicode.Scalar(code) else { throw ExecJSONError(detail: "bad escape") }
                    out.append(decoded)
                default: throw ExecJSONError(detail: "bad escape")
                }
            default: out.append(scalar)
            }
        }
    }

    private mutating func parseNumber() throws -> ExecJSON {
        var text = ""
        if peek() == 0x2D {
            text.append("-")
            index += 1
        }
        guard let first = peek(), (0x30...0x39).contains(first) else { throw ExecJSONError(detail: "bad number") }
        if first == 0x30 {
            text.append("0")
            index += 1
        } else {
            while let digit = peek(), (0x30...0x39).contains(digit) {
                text.unicodeScalars.append(scalars[index])
                index += 1
            }
        }
        if let next = peek(), next == 0x2E || next == 0x65 || next == 0x45 {
            throw ExecJSONError(detail: "float")
        }
        guard let value = Int64(text) else { throw ExecJSONError(detail: "integer outside signed 64 bits") }
        return .int(value)
    }
}
