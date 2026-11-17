// Verifies the connection callback matches only the registered https host and path and that the OS gate refuses below 17.4 and 14.4.
// Each hostile URL shape from a redirect a browser could return is listed explicitly.

import XCTest

@testable import AstralCore

final class ConnectionCallbackTests: XCTestCase {
    func testMatchesOnlyTheRegisteredHostAndPath() throws {
        let good = [
            "https://astraldeep.github.io/oauth/callback?code=c&state=s",
            "https://ASTRALDEEP.github.io/oauth/callback",
            "https://astraldeep.github.io/oauth/callback?error=access_denied",
        ]
        for text in good { XCTAssertTrue(ConnectionCallback.matches(try XCTUnwrap(URL(string: text))), text) }
        let bad = [
            "http://astraldeep.github.io/oauth/callback",
            "https://astraldeep.github.io/oauth/callback/",
            "https://astraldeep.github.io/oauth/callback/extra",
            "https://astraldeep.github.io/oauth",
            "https://astraldeep.github.io/other",
            "https://astraldeep.github.io.evil.example/oauth/callback",
            "https://evil.example/oauth/callback",
            "https://astraldeep.github.io:8443/oauth/callback",
            "https://user@astraldeep.github.io/oauth/callback",
            "https://evil.example@astraldeep.github.io/oauth/callback",
            "https://astraldeep.github.io@evil.example/oauth/callback",
            "astraldeep://astraldeep.github.io/oauth/callback",
        ]
        for text in bad { XCTAssertFalse(ConnectionCallback.matches(try XCTUnwrap(URL(string: text))), text) }
    }

    func testRedirectURLMatchesItself() throws {
        XCTAssertTrue(ConnectionCallback.matches(try XCTUnwrap(URL(string: ConnectionCallback.redirectURL))))
    }

    func testIOSNeedsSeventeenFour() {
        XCTAssertEqual(check(.iOS, 17, 3), .unavailable(code: "connection.os_too_old"))
        XCTAssertEqual(check(.iOS, 16, 9), .unavailable(code: "connection.os_too_old"))
        XCTAssertEqual(check(.iOS, 17, 4), .available)
        XCTAssertEqual(check(.iOS, 18, 0), .available)
        XCTAssertEqual(check(.iOS, 26, 0), .available)
    }

    func testMacOSNeedsFourteenFour() {
        XCTAssertEqual(check(.macOS, 14, 3), .unavailable(code: "connection.os_too_old"))
        XCTAssertEqual(check(.macOS, 13, 9), .unavailable(code: "connection.os_too_old"))
        XCTAssertEqual(check(.macOS, 14, 4), .available)
        XCTAssertEqual(check(.macOS, 15, 0), .available)
    }

    func testOtherPlatformsAreRefused() {
        XCTAssertEqual(check(.other, 99, 0), .unavailable(code: "connection.os_too_old"))
    }

    private func check(_ platform: ConnectionCallback.Platform, _ major: Int, _ minor: Int)
        -> ConnectionCallback.Availability
    {
        let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
        return ConnectionCallback.availability(platform: platform, version: version)
    }
}
