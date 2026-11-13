// Drives the installed physical-device app to its normal personal-mesh setup without fixtures or account changes.
// Enrollment, passwords, biometrics, microphone access and model-download consent remain human actions.

#if os(iOS) && !targetEnvironment(simulator)
    import XCTest

    final class PhysicalMeshSetupUITests: XCTestCase {
        func testOpenPersonalMeshSetupFromTheExistingServerSession() throws {
            guard ProcessInfo.processInfo.environment["ASTRAL_PHYSICAL_MESH_SETUP"] == "1" else {
                throw XCTSkip("Run explicitly against the connected owner-approved test device.")
            }
            let app = XCUIApplication()
            app.activate()
            let join = app.buttons["mesh.join"]
            if !join.waitForExistence(timeout: 3) {
                let settings = app.buttons["Settings"].firstMatch
                if !settings.isHittable {
                    let directory = app.buttons["Show the agent directory"]
                    XCTAssertTrue(directory.waitForExistence(timeout: 5))
                    directory.tap()
                }
                XCTAssertTrue(settings.waitForExistence(timeout: 5))
                settings.tap()
                let mode = app.buttons["settings.personal-mesh"]
                XCTAssertTrue(mode.waitForExistence(timeout: 5))
                XCTAssertTrue(mode.isEnabled)
                mode.tap()
            }
            XCTAssertTrue(join.waitForExistence(timeout: 20))
            XCTAssertTrue(app.buttons["mesh.create"].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "physical-personal-mesh-setup"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }
#endif
