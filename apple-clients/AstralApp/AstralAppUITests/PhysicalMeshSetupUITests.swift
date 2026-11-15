// Drives the installed physical-device app to its normal personal-mesh setup without fixtures or account changes.
// Enrollment, passwords, biometrics, microphone access and model-download consent remain human actions.

#if os(iOS) && !targetEnvironment(simulator)
    import XCTest

    final class PhysicalMeshSetupUITests: XCTestCase {
        func testImportTheExistingMeshInvitationFromTheDevicePasteboard() throws {
            guard ProcessInfo.processInfo.environment["ASTRAL_PHYSICAL_MESH_IMPORT"] == "1" else {
                throw XCTSkip("Run explicitly after copying the owner-approved existing-mesh invitation.")
            }
            let app = XCUIApplication()
            app.activate()
            let join = app.buttons["mesh.join"]
            if join.waitForExistence(timeout: 3) { join.tap() }
            let paste = app.buttons["mesh.join.paste"]
            XCTAssertTrue(paste.waitForExistence(timeout: 5))
            XCTAssertTrue(paste.isEnabled)
            paste.tap()
            XCTAssertTrue(app.descendants(matching: .any)["mesh.join.waiting"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.descendants(matching: .any)["mesh.join.code"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["mesh.tab.chats"].waitForExistence(timeout: 240))
        }

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
