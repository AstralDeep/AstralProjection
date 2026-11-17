// Verifies the stored app mode: a value from an older server build opens mesh onboarding and stays byte for byte.
// Choosing the mesh persists it, and nothing here writes or removes a server session store.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshModeTransitionTests: XCTestCase {
    private static let key = "astral.app-mode.v2"

    private func makeDefaults() throws -> UserDefaults {
        let suite = "MeshModeTransitionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testStoredNodeModeReadsAsNoChoiceAndKeepsItsBytes() throws {
        let defaults = try makeDefaults()
        defaults.set("node", forKey: Self.key)
        defaults.set("https://node.example", forKey: "serverBase")
        let store = AppModeStore(defaults: defaults)
        XCTAssertNil(store.mode)
        XCTAssertEqual(defaults.string(forKey: Self.key), "node")
        XCTAssertEqual(defaults.string(forKey: "serverBase"), "https://node.example")
    }

    func testStoredMeshModeOpensAsMesh() throws {
        let defaults = try makeDefaults()
        defaults.set("mesh", forKey: Self.key)
        XCTAssertEqual(AppModeStore(defaults: defaults).mode, .mesh)
    }

    func testChoosingTheMeshPersistsIt() throws {
        let defaults = try makeDefaults()
        let store = AppModeStore(defaults: defaults)
        XCTAssertNil(store.mode)
        store.choose(.mesh)
        XCTAssertEqual(AppModeStore(defaults: defaults).mode, .mesh)
        XCTAssertEqual(defaults.string(forKey: Self.key), "mesh")
    }

    func testNoSourceNamesTheServerSessionKeychainService() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AstralApp", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for forbidden in ["\"server-session\"", "ServerSession", "signIn()", "oauth2redirect", "Keycloak"]
            where text.contains(forbidden) {
                offenders.append(url.lastPathComponent + ": " + forbidden)
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
