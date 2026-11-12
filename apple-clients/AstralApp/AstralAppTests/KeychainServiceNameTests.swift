// Verifies that every Keychain service the app uses derives from the bundle identifier, keeping production names unchanged.

@testable import AstralDeep
import AstralCore
import XCTest

final class KeychainServiceNameTests: XCTestCase {
    private let suffixes = ["tokens", "mesh", "server-session", "push", "unsent-message", "mesh-device"]

    func testProductionBundleKeepsTodaysNames() {
        for suffix in suffixes {
            XCTAssertEqual(
                KeychainServices.name(suffix, bundleIdentifier: "com.personalailabs.astraldeep"),
                "com.personalailabs.astraldeep." + suffix)
        }
    }

    func testLocalTestBundleGetsItsOwnNames() {
        for suffix in suffixes {
            let name = KeychainServices.name(suffix, bundleIdentifier: "com.personalailabs.astraldeep.localtest")
            XCTAssertEqual(name, "com.personalailabs.astraldeep.localtest." + suffix)
            XCTAssertNotEqual(name, KeychainServices.name(suffix, bundleIdentifier: "com.personalailabs.astraldeep"))
        }
    }

    func testMissingOrEmptyBundleIdentifierFallsBackToProduction() {
        XCTAssertEqual(KeychainServices.name("tokens", bundleIdentifier: nil), "com.personalailabs.astraldeep.tokens")
        XCTAssertEqual(KeychainServices.name("tokens", bundleIdentifier: ""), "com.personalailabs.astraldeep.tokens")
    }

    func testEveryDefaultStoreUsesTheBundleDerivedService() {
        XCTAssertEqual(KeychainTokenStore().service, KeychainServices.name("tokens"))
        XCTAssertEqual(KeychainMeshKeyStorage().service, KeychainServices.name("mesh"))
        XCTAssertEqual(KeychainUnsentMessageStore().service, KeychainServices.name("unsent-message"))
        XCTAssertEqual(MeshKeychainStore.defaultService, KeychainServices.name("mesh-device"))
    }

    func testRunningBundleMatchesDerivation() {
        let bundle = Bundle.main.bundleIdentifier ?? KeychainServices.productionBundleIdentifier
        XCTAssertEqual(KeychainServices.name("tokens"), bundle + ".tokens")
    }
}
