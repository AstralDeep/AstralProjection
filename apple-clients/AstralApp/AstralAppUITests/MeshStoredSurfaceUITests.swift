// Exercises the same captured kernel event through the native Mac and iPhone chat renderers, including untrusted labeling and denied outside controls.
import XCTest

final class MeshStoredSurfaceUITests: XCTestCase {
    func testOneStoredOutsideSurfaceRendersAsUntrustedSafePrimitives() {
        let app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-mesh", "storedSurface"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
        defer { app.terminate() }
        let chat = app.descendants(matching: .any)["mesh.chat.chat-1"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        chat.press()
        let event = "sha256:ca3e200bd8a6f2f6614ca6d029cf22c931b228c38a9c6ca2a119d4d7aa09c8fb"
        let marker = app.descendants(matching: .any)["mesh.surface.untrusted." + event]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        XCTAssertTrue(marker.label.contains("Untrusted"))
        let pulse = app.staticTexts["Pulse: 72 bpm"].firstMatch
        XCTAssertTrue(pulse.waitForExistence(timeout: 5))
        XCTAssertTrue(pulse.isHittable)
        XCTAssertGreaterThan(pulse.frame.width, 0)
        XCTAssertGreaterThan(pulse.frame.height, 0)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "text with a link was removed", "text with a link was removed")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Send patient record"].exists)
        XCTAssertFalse(app.buttons["Send patient record"].exists)
        XCTAssertFalse(app.links.firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "outside.example", "outside.example")).firstMatch.exists)
        let identity = XCTAttachment(string: "stored_event=\(event)\nfixture_sha256=050d11e29a5ed8c2892986bf0aff776c2be79812ab382f405151d9dad627e7e0")
        identity.name = "same-stored-surface-identity"
        identity.lifetime = .keepAlways
        add(identity)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = "stored-surface-accessibility"
        accessibility.lifetime = .keepAlways
        add(accessibility)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "same-stored-untrusted-surface"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
