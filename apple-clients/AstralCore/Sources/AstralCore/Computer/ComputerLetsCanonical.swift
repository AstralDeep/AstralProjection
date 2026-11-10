// Strict JSON parsing, LETS-CJ/1 canonical encoding and base64url for receipt bytes signed by the warden.
// The receipt verifier and the resolved-effect plan digest build on these exact encodings.

#if os(macOS)
    import Foundation

    public enum ComputerLetsValue: Sendable, Equatable {
        case null
        case bool(Bool)
        case integer(Int64)
        case string(String)
        case array([ComputerLetsValue])
        case object([String: ComputerLetsValue])
    }

    public enum ComputerLetsCanonicalError: Error, Equatable, Sendable {
        case malformed
        case duplicateKey
        case floatingPoint
        case integerRange
        case loneSurrogate
        case base64
    }

    public enum ComputerLetsCanonical {
        public static func parse(_ text: String) throws -> ComputerLetsValue {
            var parser = Parser(Array(text.unicodeScalars))
            let value = try parser.value()
            try parser.end()
            return value
        }

        public static func canonical(_ value: ComputerLetsValue) throws -> Data {
            var bytes: [UInt8] = []
            try encode(value, into: &bytes)
            return Data(bytes)
        }

        public static func canonicalString(_ value: ComputerLetsValue) throws -> String {
            let data = try canonical(value)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ComputerLetsCanonicalError.malformed
            }
            return text
        }

        public static func base64URLDecode(_ text: String) throws -> Data {
            guard !text.contains("="), text.allSatisfy({ $0.isASCII }) else {
                throw ComputerLetsCanonicalError.base64
            }
            var buffer = 0
            var bits = 0
            var bytes: [UInt8] = []
            for character in text.unicodeScalars {
                guard let value = Self.alphabet.firstIndex(of: Character(character)) else {
                    throw ComputerLetsCanonicalError.base64
                }
                buffer = (buffer << 6) | value
                bits += 6
                if bits >= 8 {
                    bits -= 8
                    bytes.append(UInt8((buffer >> bits) & 0xFF))
                }
            }
            guard bits < 6, base64URLEncode(Data(bytes)) == text else {
                throw ComputerLetsCanonicalError.base64
            }
            return Data(bytes)
        }

        public static func base64URLEncode(_ data: Data) -> String {
            let bytes = [UInt8](data)
            var text: [Character] = []
            for index in stride(from: 0, to: bytes.count, by: 3) {
                let second = index + 1 < bytes.count ? bytes[index + 1] : 0
                let third = index + 2 < bytes.count ? bytes[index + 2] : 0
                text.append(alphabet[Int(bytes[index] >> 2)])
                text.append(alphabet[Int(((bytes[index] & 0x03) << 4) | (second >> 4))])
                if index + 1 < bytes.count {
                    text.append(alphabet[Int(((second & 0x0F) << 2) | (third >> 6))])
                }
                if index + 2 < bytes.count { text.append(alphabet[Int(third & 0x3F)]) }
            }
            return String(text)
        }

        private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

        private static func encode(_ value: ComputerLetsValue, into bytes: inout [UInt8]) throws {
            switch value {
            case .null:
                bytes.append(contentsOf: Array("null".utf8))
            case .bool(let flag):
                bytes.append(contentsOf: Array((flag ? "true" : "false").utf8))
            case .integer(let number):
                bytes.append(contentsOf: Array(String(number).utf8))
            case .string(let text):
                try encodeString(text, into: &bytes)
            case .array(let items):
                bytes.append(UInt8(ascii: "["))
                for (index, item) in items.enumerated() {
                    if index > 0 { bytes.append(UInt8(ascii: ",")) }
                    try encode(item, into: &bytes)
                }
                bytes.append(UInt8(ascii: "]"))
            case .object(let items):
                bytes.append(UInt8(ascii: "{"))
                for (index, key) in items.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
                    .enumerated()
                {
                    if index > 0 { bytes.append(UInt8(ascii: ",")) }
                    try encodeString(key, into: &bytes)
                    bytes.append(UInt8(ascii: ":"))
                    guard let item = items[key] else { throw ComputerLetsCanonicalError.malformed }
                    try encode(item, into: &bytes)
                }
                bytes.append(UInt8(ascii: "}"))
            }
        }

        private static func encodeString(_ text: String, into bytes: inout [UInt8]) throws {
            bytes.append(UInt8(ascii: "\""))
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": bytes.append(contentsOf: Array("\\\"".utf8))
                case "\\": bytes.append(contentsOf: Array("\\\\".utf8))
                case "\n": bytes.append(contentsOf: Array("\\n".utf8))
                case "\r": bytes.append(contentsOf: Array("\\r".utf8))
                case "\t": bytes.append(contentsOf: Array("\\t".utf8))
                case "\u{08}": bytes.append(contentsOf: Array("\\b".utf8))
                case "\u{0C}": bytes.append(contentsOf: Array("\\f".utf8))
                default:
                    if scalar.value < 0x20 {
                        let hex = String(scalar.value, radix: 16)
                        let padded = String(repeating: "0", count: max(0, 2 - hex.count)) + hex
                        bytes.append(contentsOf: Array("\\u00\(padded)".utf8))
                    } else {
                        bytes.append(contentsOf: Array(String(scalar).utf8))
                    }
                }
            }
            bytes.append(UInt8(ascii: "\""))
        }

        private struct Parser {
            private let scalars: [Unicode.Scalar]
            private var index = 0

            init(_ scalars: [Unicode.Scalar]) {
                self.scalars = scalars
            }

            mutating func value() throws -> ComputerLetsValue {
                skipWhitespace()
                guard let scalar = peek() else { throw ComputerLetsCanonicalError.malformed }
                switch scalar {
                case "{":
                    return try object()
                case "[":
                    return try array()
                case "\"":
                    return .string(try string())
                case "t":
                    try literal("true")
                    return .bool(true)
                case "f":
                    try literal("false")
                    return .bool(false)
                case "n":
                    try literal("null")
                    return .null
                default:
                    return try number()
                }
            }

            mutating func end() throws {
                skipWhitespace()
                guard index == scalars.count else { throw ComputerLetsCanonicalError.malformed }
            }

            private func peek() -> Unicode.Scalar? {
                guard index < scalars.count else { return nil }
                return scalars[index]
            }

            private mutating func skipWhitespace() {
                while index < scalars.count, [" ", "\t", "\n", "\r"].contains(scalars[index]) { index += 1 }
            }

            private mutating func literal(_ word: String) throws {
                let characters = Array(word.unicodeScalars)
                guard index + characters.count <= scalars.count,
                    Array(scalars[index..<index + characters.count]) == characters
                else { throw ComputerLetsCanonicalError.malformed }
                index += characters.count
            }

            private mutating func object() throws -> ComputerLetsValue {
                index += 1
                var items: [String: ComputerLetsValue] = [:]
                skipWhitespace()
                if peek() == "}" {
                    index += 1
                    return .object(items)
                }
                while true {
                    skipWhitespace()
                    guard peek() == "\"" else { throw ComputerLetsCanonicalError.malformed }
                    let key = try string()
                    guard items[key] == nil else { throw ComputerLetsCanonicalError.duplicateKey }
                    skipWhitespace()
                    guard peek() == ":" else { throw ComputerLetsCanonicalError.malformed }
                    index += 1
                    items[key] = try value()
                    skipWhitespace()
                    if peek() == "," {
                        index += 1
                        continue
                    }
                    guard peek() == "}" else { throw ComputerLetsCanonicalError.malformed }
                    index += 1
                    return .object(items)
                }
            }

            private mutating func array() throws -> ComputerLetsValue {
                index += 1
                var items: [ComputerLetsValue] = []
                skipWhitespace()
                if peek() == "]" {
                    index += 1
                    return .array(items)
                }
                while true {
                    items.append(try value())
                    skipWhitespace()
                    if peek() == "," {
                        index += 1
                        continue
                    }
                    guard peek() == "]" else { throw ComputerLetsCanonicalError.malformed }
                    index += 1
                    return .array(items)
                }
            }

            private mutating func string() throws -> String {
                index += 1
                var output = String.UnicodeScalarView()
                while true {
                    guard let scalar = peek() else { throw ComputerLetsCanonicalError.malformed }
                    index += 1
                    if scalar == "\"" { return String(output) }
                    if scalar.value < 0x20 { throw ComputerLetsCanonicalError.malformed }
                    if scalar != "\\" {
                        output.append(scalar)
                        continue
                    }
                    guard let escape = peek() else { throw ComputerLetsCanonicalError.malformed }
                    index += 1
                    switch escape {
                    case "\"": output.append("\"")
                    case "\\": output.append("\\")
                    case "/": output.append("/")
                    case "b": output.append("\u{08}")
                    case "f": output.append("\u{0C}")
                    case "n": output.append("\n")
                    case "r": output.append("\r")
                    case "t": output.append("\t")
                    case "u":
                        let high = try hexUnit()
                        if (0xD800...0xDBFF).contains(high) {
                            guard peek() == "\\", index + 1 < scalars.count, scalars[index + 1] == "u" else {
                                throw ComputerLetsCanonicalError.loneSurrogate
                            }
                            index += 2
                            let low = try hexUnit()
                            guard (0xDC00...0xDFFF).contains(low) else {
                                throw ComputerLetsCanonicalError.loneSurrogate
                            }
                            guard let paired = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) else {
                                throw ComputerLetsCanonicalError.loneSurrogate
                            }
                            output.append(paired)
                        } else {
                            guard (0xDC00...0xDFFF).contains(high) == false,
                                let scalar = Unicode.Scalar(high)
                            else { throw ComputerLetsCanonicalError.loneSurrogate }
                            output.append(scalar)
                        }
                    default: throw ComputerLetsCanonicalError.malformed
                    }
                }
            }

            private mutating func hexUnit() throws -> Int {
                var value = 0
                for _ in 0..<4 {
                    guard let scalar = peek(), let digit = Self.hexDigit(scalar) else {
                        throw ComputerLetsCanonicalError.malformed
                    }
                    value = value << 4 | digit
                    index += 1
                }
                return value
            }

            private static func hexDigit(_ scalar: Unicode.Scalar) -> Int? {
                switch scalar {
                case "0"..."9": return Int(scalar.value - 48)
                case "a"..."f": return Int(scalar.value - 87)
                case "A"..."F": return Int(scalar.value - 55)
                default: return nil
                }
            }

            private mutating func number() throws -> ComputerLetsValue {
                let start = index
                if peek() == "-" { index += 1 }
                guard let first = peek(), Self.isDigit(first) else { throw ComputerLetsCanonicalError.malformed }
                if first == "0" {
                    index += 1
                } else {
                    while let next = peek(), Self.isDigit(next) { index += 1 }
                }
                if peek() == "." || peek() == "e" || peek() == "E" {
                    throw ComputerLetsCanonicalError.floatingPoint
                }
                guard index > start else { throw ComputerLetsCanonicalError.malformed }
                let text = String(String.UnicodeScalarView(scalars[start..<index]))
                guard let value = Int64(text) else { throw ComputerLetsCanonicalError.integerRange }
                return .integer(value)
            }

            private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
                scalar.value >= 48 && scalar.value <= 57
            }
        }
    }
#endif
