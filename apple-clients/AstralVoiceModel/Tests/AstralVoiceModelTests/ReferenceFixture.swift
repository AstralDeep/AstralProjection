// Loads the reference fixtures written by Tests/Parity/make_fixtures.py and locates the real model directory for the parity tests.
// Tests that need the weights call requireModel() so they skip with a clear message when ASTRAL_LFM3_MODEL_DIR and the default Desktop path are both absent.

import Foundation
import XCTest

@testable import AstralVoiceModel

struct ReferenceFixture {
    let json: [String: Any]

    static func load() throws -> ReferenceFixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reference", withExtension: "json", subdirectory: "Fixtures"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return ReferenceFixture(json: try XCTUnwrap(object as? [String: Any]))
    }

    static func wavSamples() throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "asr_input", withExtension: "wav", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        var offset = 12
        var body = Data()
        while offset + 8 <= data.count {
            let name = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(data[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            if name == "data" {
                body = data.subdata(in: (offset + 8)..<min(data.count, offset + 8 + size))
                break
            }
            offset += 8 + size
        }
        return body.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }

    func value<T>(_ path: String...) -> T {
        var current: Any = json
        for key in path { current = (current as! [String: Any])[key]! }
        return current as! T
    }

    func floats(_ path: String...) -> [Float] {
        var current: Any = json
        for key in path { current = (current as! [String: Any])[key]! }
        return (current as! [NSNumber]).map(\.floatValue)
    }

    func ints(_ path: String...) -> [Int] {
        var current: Any = json
        for key in path { current = (current as! [String: Any])[key]! }
        return (current as! [NSNumber]).map(\.intValue)
    }
}

enum RealModel {
    static var directory: URL {
        let path =
            ProcessInfo.processInfo.environment["ASTRAL_LFM3_MODEL_DIR"]
            ?? "/Users/sam/Desktop/LFM3-Audio-Edge-Test/models/LFM3-Audio-2B-3bit"
        return URL(fileURLWithPath: path)
    }

    static func require() throws -> URL {
        let missing = LFM3AudioEngine.requiredFiles.filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        try XCTSkipUnless(
            missing.isEmpty,
            "LFM3 model files not found in \(directory.path). Set ASTRAL_LFM3_MODEL_DIR to run the parity tests.")
        return directory
    }

    private static let sharedEngine = Task { try LFM3AudioEngine(directory: directory) }

    static func engine() async throws -> LFM3AudioEngine {
        _ = try require()
        return try await sharedEngine.value
    }
}
