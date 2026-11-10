// Consumes every published LETS-CJ/1 canonicalization vector from the digest-pinned fixture and exercises the
// strict parser, canonical encoder and base64url codec the receipt verifier and plan digests depend on.

#if os(macOS)
    import CryptoKit
    import Foundation
    import XCTest

    @testable import AstralCore

    final class ComputerLetsCanonicalTests: XCTestCase {
        private static func data(fromHex hex: String) throws -> Data {
            guard hex.count % 2 == 0 else { throw ComputerLetsCanonicalError.malformed }
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) else {
                    throw ComputerLetsCanonicalError.malformed
                }
                guard let byte = UInt8(hex[index..<next], radix: 16) else {
                    throw ComputerLetsCanonicalError.malformed
                }
                bytes.append(byte)
                index = next
            }
            return Data(bytes)
        }

        private struct Vectors {
            let version: String
            let valid: [(name: String, input: ComputerLetsValue, canonical: String, digest: String)]
            let invalidJSON: [String]
            let base64URL: [(bytes: Data, encoded: String)]
            let invalidBase64URL: [String]

            init() throws {
                guard let url = Bundle.module.url(forResource: "canonicalization-vectors", withExtension: "json")
                else {
                    throw NSError(
                        domain: "ComputerLetsCanonicalTests", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "bundled LETS vector fixture is missing"])
                }
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == "d9ad1f5849bd3bb1a4ef73ef430ab14fc4077f5aa2e7d566bebf82f0e6b261f5" else {
                    throw NSError(
                        domain: "ComputerLetsCanonicalTests", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "bundled LETS vector fixture digest differs"])
                }
                guard case .object(let root) = try ComputerLetsCanonical.parse(
                    String(decoding: data, as: UTF8.self)),
                    case .string(let version) = root["version"],
                    case .array(let validEntries) = root["valid"],
                    case .array(let invalidEntries) = root["invalid_json"],
                    case .array(let encodedEntries) = root["base64url"],
                    case .array(let invalidEncodedEntries) = root["invalid_base64url"]
                else {
                    throw NSError(
                        domain: "ComputerLetsCanonicalTests", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "LETS vector fixture shape changed"])
                }
                self.version = version
                var parsed: [(name: String, input: ComputerLetsValue, canonical: String, digest: String)] = []
                for entry in validEntries {
                    guard case .object(let item) = entry,
                        case .string(let name) = item["name"],
                        let input = item["input"],
                        case .string(let canonical) = item["canonical"],
                        case .string(let digest) = item["sha256"]
                    else {
                        throw NSError(
                            domain: "ComputerLetsCanonicalTests", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "LETS valid vector is malformed"])
                    }
                    parsed.append((name, input, canonical, digest))
                }
                valid = parsed
                invalidJSON = invalidEntries.compactMap {
                    guard case .string(let text) = $0 else { return nil }
                    return text
                }
                var encoded: [(bytes: Data, encoded: String)] = []
                for entry in encodedEntries {
                    guard case .object(let item) = entry,
                        case .string(let hex) = item["bytes_hex"],
                        case .string(let text) = item["encoded"]
                    else {
                        throw NSError(
                            domain: "ComputerLetsCanonicalTests", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "LETS base64url vector is malformed"])
                    }
                    encoded.append((try ComputerLetsCanonicalTests.data(fromHex: hex), text))
                }
                base64URL = encoded
                invalidBase64URL = invalidEncodedEntries.compactMap {
                    guard case .string(let text) = $0 else { return nil }
                    return text
                }
            }
        }

        private var vectors: Vectors?

        private func load() throws -> Vectors {
            if let vectors { return vectors }
            let parsed = try Vectors()
            vectors = parsed
            return parsed
        }

        func testVectorSetIsLoadedFromThePublishedFixture() throws {
            let vectors = try load()
            XCTAssertEqual(vectors.version, "LETS-CJ/1")
            XCTAssertGreaterThanOrEqual(vectors.valid.count, 4)
            XCTAssertGreaterThanOrEqual(vectors.invalidJSON.count, 6)
            XCTAssertGreaterThanOrEqual(vectors.base64URL.count, 1)
            XCTAssertGreaterThanOrEqual(vectors.invalidBase64URL.count, 4)
        }

        func testEveryValidVectorCanonicalizesToThePublishedBytes() throws {
            for vector in try load().valid {
                let canonical = try ComputerLetsCanonical.canonicalString(vector.input)
                XCTAssertEqual(canonical, vector.canonical, vector.name)
                let bytes = try ComputerLetsCanonical.canonical(vector.input)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, vector.digest, vector.name)
                let reparsed = try ComputerLetsCanonical.parse(canonical)
                let again = try ComputerLetsCanonical.canonicalString(reparsed)
                XCTAssertEqual(again, vector.canonical, vector.name)
            }
        }

        func testEveryPublishedInvalidJSONDocumentIsRefused() throws {
            for text in try load().invalidJSON {
                XCTAssertThrowsError(try ComputerLetsCanonical.parse(text), text)
            }
        }

        func testStrictParserRefusesAdditionalMalformedDocuments() {
            for text in [
                "", "   ", "{", "}", "[1,]", "{\"a\":}", "{\"a\" 1}", "01", "\"\u{0}\"", "{\"a\":1,}",
                "{\"a\":true,\"a\":false}", "[1 2]", "tru", "{\"a\":1} trailing", "nul",
            ] {
                XCTAssertThrowsError(try ComputerLetsCanonical.parse(text), text)
            }
        }

        func testBase64URLCodecMatchesThePublishedVectors() throws {
            for vector in try load().base64URL {
                XCTAssertEqual(ComputerLetsCanonical.base64URLEncode(vector.bytes), vector.encoded)
                XCTAssertEqual(try ComputerLetsCanonical.base64URLDecode(vector.encoded), vector.bytes)
            }
            for text in try load().invalidBase64URL {
                XCTAssertThrowsError(try ComputerLetsCanonical.base64URLDecode(text), text)
            }
            XCTAssertEqual(try ComputerLetsCanonical.base64URLDecode(""), Data())
            XCTAssertEqual(ComputerLetsCanonical.base64URLEncode(Data()), "")
            let bytes = Data([0xFB, 0xFF, 0xBF, 0x03])
            let encoded = ComputerLetsCanonical.base64URLEncode(bytes)
            XCTAssertFalse(encoded.contains("="))
            XCTAssertEqual(try ComputerLetsCanonical.base64URLDecode(encoded), bytes)
        }

        func testCanonicalFormEscapesControlsAndKeepsUnicodeRaw() throws {
            let value = ComputerLetsValue.object([
                "line": .string("a\nb"), "tab": .string("c\td"), "quote": .string("e\"f"),
                "back": .string("g\\h"), "del": .string("\u{7F}"), "unit": .string("\u{1}"),
                "emoji": .string("w:\u{1F600}"),
            ])
            XCTAssertEqual(
                try ComputerLetsCanonical.canonicalString(value),
                "{\"back\":\"g\\\\h\",\"del\":\"\u{7F}\",\"emoji\":\"w:\u{1F600}\",\"line\":\"a\\nb\","
                    + "\"quote\":\"e\\\"f\",\"tab\":\"c\\td\",\"unit\":\"\\u0001\"}")
        }

        func testCanonicalFormSortsKeysByUTF8Bytes() throws {
            let value = ComputerLetsValue.object([
                "\u{00E9}": .integer(1), "\u{1F600}": .integer(2), "\u{E000}": .integer(3), "z": .integer(4),
                "Z": .integer(5),
            ])
            XCTAssertEqual(
                try ComputerLetsCanonical.canonicalString(value),
                "{\"Z\":5,\"z\":4,\"\u{00E9}\":1,\"\u{E000}\":3,\"\u{1F600}\":2}")
        }

        func testParserRejectsFloatsAndOutOfRangeIntegers() {
            XCTAssertThrowsError(try ComputerLetsCanonical.parse("{\"a\":1.0}"))
            XCTAssertThrowsError(try ComputerLetsCanonical.parse("{\"a\":1e3}"))
            XCTAssertThrowsError(try ComputerLetsCanonical.parse("{\"a\":-1.5}"))
            XCTAssertThrowsError(try ComputerLetsCanonical.parse("{\"a\":9223372036854775808}"))
            XCTAssertThrowsError(try ComputerLetsCanonical.parse("{\"a\":-9223372036854775809}"))
            XCTAssertEqual(
                try ComputerLetsCanonical.parse("{\"a\":9223372036854775807}"),
                ComputerLetsValue.object(["a": .integer(Int64.max)]))
            XCTAssertEqual(
                try ComputerLetsCanonical.parse("{\"a\":-9223372036854775808}"),
                ComputerLetsValue.object(["a": .integer(Int64.min)]))
        }

        func testParserRejectsLoneSurrogatesButAcceptsPairedOnes() {
            XCTAssertThrowsError(try ComputerLetsCanonical.parse("{\"a\":\"\\ud800\"}"))
            XCTAssertThrowsError(try ComputerLetsCanonical.parse("{\"a\":\"\\udc00\"}"))
            XCTAssertThrowsError(try ComputerLetsCanonical.parse("{\"a\":\"\\ud800x\"}"))
            XCTAssertEqual(
                try ComputerLetsCanonical.parse("{\"a\":\"\\ud83d\\ude00\"}"),
                ComputerLetsValue.object(["a": .string("\u{1F600}")]))
        }
    }
#endif
