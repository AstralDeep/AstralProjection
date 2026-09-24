// Tests for AstralConfig's endpoint resolution ladder (override, then Info.plist, then build fallback):
// watch-without-companion and headless paths, malformed-override rejection, and OAuth client identities.

import XCTest

@testable import AstralCore

final class ConfigurationResolutionTests: XCTestCase {
    private let plistValue = "https://sandbox.ai.uky.edu"

    func testOverrideWinsOverInfoPlist() {
        XCTAssertEqual(
            AstralConfig.resolve(
                override: "https://staging.example.edu",
                infoValue: plistValue,
                fallback: AstralConfig.fallbackServerBaseURL),
            "https://staging.example.edu")
    }

    func testInfoPlistUsedWhenNoOverride() {
        XCTAssertEqual(
            AstralConfig.resolve(
                override: nil,
                infoValue: plistValue,
                fallback: AstralConfig.fallbackServerBaseURL),
            plistValue)
    }

    func testFallbackWhenNeitherOverrideNorInfoPlistResolves() {
        XCTAssertEqual(
            AstralConfig.resolve(
                override: nil, infoValue: nil,
                fallback: AstralConfig.fallbackServerBaseURL),
            AstralConfig.fallbackServerBaseURL)
    }

    func testBlankAndEmptyOverridesAreIgnored() {
        for bad in ["", "   ", "\n\t"] {
            XCTAssertEqual(
                AstralConfig.resolve(
                    override: bad, infoValue: plistValue,
                    fallback: AstralConfig.fallbackServerBaseURL),
                plistValue, "override \(bad.debugDescription) should be ignored")
        }
    }

    func testNonHTTPOverridesAreIgnored() {
        for bad in ["ftp://example.edu", "sandbox.ai.uky.edu", "/relative/path", "https://"] {
            XCTAssertEqual(
                AstralConfig.resolve(
                    override: bad, infoValue: plistValue,
                    fallback: AstralConfig.fallbackServerBaseURL),
                plistValue, "override \(bad.debugDescription) should be ignored")
        }
    }

    func testUnsubstitutedBuildSettingIsRejected() {
        XCTAssertEqual(
            AstralConfig.resolve(
                override: nil,
                infoValue: "$(ASTRAL_SERVER_BASE_URL)",
                fallback: AstralConfig.fallbackServerBaseURL),
            AstralConfig.fallbackServerBaseURL)
    }

    func testOverrideIsTrimmed() {
        XCTAssertEqual(
            AstralConfig.resolve(
                override: "  https://staging.example.edu  ",
                infoValue: plistValue,
                fallback: AstralConfig.fallbackServerBaseURL),
            "https://staging.example.edu")
    }

    func testLocalhostDebugEndpointIsUsable() {
        XCTAssertEqual(
            AstralConfig.usableEndpoint("http://localhost:8001"),
            "http://localhost:8001")
    }

    func testAuthorityFallsBackToTheProductionRealm() {
        XCTAssertEqual(
            AstralConfig.resolve(
                override: nil, infoValue: nil,
                fallback: AstralConfig.fallbackKeycloakAuthority),
            "https://iam.ai.uky.edu/realms/Astral")
    }

    func testOAuthClientIdsMatchTheBackendContract() {
        XCTAssertEqual(AstralConfig.iosClientId, "astral-mobile")
        XCTAssertEqual(AstralConfig.macosClientId, "astral-desktop")
        XCTAssertEqual(AstralConfig.watchClientId, "astral-watch")
        XCTAssertEqual(AstralConfig.redirectURI, "com.personalailabs.astraldeep:/oauth2redirect")
    }
}
