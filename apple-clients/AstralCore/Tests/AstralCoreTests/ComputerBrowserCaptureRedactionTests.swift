// Checks the browser pane's captured-URL redaction and emulated viewport letterboxing that ComputerBrowserPolicy
// and ComputerBrowserViewport provide to the Mac browser pane's console, network and resize verbs.

import XCTest

@testable import AstralCore

final class ComputerBrowserCaptureRedactionTests: XCTestCase {
    func testAuthLikeQueryAndFragmentValuesAreRedacted() {
        let redacted = ComputerBrowserPolicy.redacted
        XCTAssertEqual(
            ComputerBrowserPolicy.redactedURL(
                "https://user:pass@h.example/p?token=abc&q=1&API_KEY=z&next=%2F#access_token=t&state=s"),
            "https://h.example/p?token=\(redacted)&q=1&API_KEY=\(redacted)&next=%2F#access_token=\(redacted)&state=s")
        XCTAssertEqual(
            ComputerBrowserPolicy.redactedURL("http://h.example/cb?code=123&session%5Fid=9&password&Auth=x"),
            "http://h.example/cb?code=\(redacted)&session%5Fid=\(redacted)&password&Auth=\(redacted)")
        XCTAssertEqual(
            ComputerBrowserPolicy.redactedURL("https://h.example/a?b=c#section"), "https://h.example/a?b=c#section")
        XCTAssertEqual(ComputerBrowserPolicy.redactedURL("https://h.example/a@b"), "https://h.example/a@b")
        XCTAssertEqual(ComputerBrowserPolicy.redactedURL(""), "")
        XCTAssertEqual(ComputerBrowserPolicy.redactedURL(String(repeating: "a", count: 5000)).count, 2000)
        XCTAssertEqual(ComputerBrowserPolicy.redactedURL("https://h.example/?secret=s", limit: 10), "https://h.")
    }

    func testViewportPresetsBoundsAndLetterbox() {
        XCTAssertEqual(ComputerBrowserViewport.presets["mobile"], ComputerBrowserViewport(width: 375, height: 812))
        XCTAssertEqual(ComputerBrowserViewport.presets["tablet"], ComputerBrowserViewport(width: 768, height: 1024))
        XCTAssertNil(ComputerBrowserViewport.presets["desktop"])
        XCTAssertNil(ComputerBrowserViewport(validWidth: 320, height: 319))
        XCTAssertEqual(
            ComputerBrowserViewport(validWidth: 320, height: 320), ComputerBrowserViewport(width: 320, height: 320))
        let tablet = ComputerBrowserViewport(width: 768, height: 1024)
        let fitted = tablet.letterbox(in: CGSize(width: 800, height: 512))
        XCTAssertEqual(fitted.scale, 0.5)
        XCTAssertEqual(fitted.frame, CGRect(x: 208, y: 0, width: 384, height: 512))
        let exact = tablet.letterbox(in: CGSize(width: 768, height: 1024))
        XCTAssertEqual(exact.frame, CGRect(x: 0, y: 0, width: 768, height: 1024))
        XCTAssertEqual(exact.scale, 1)
    }
}
