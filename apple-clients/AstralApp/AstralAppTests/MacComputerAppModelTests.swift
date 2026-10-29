// Verifies that local computer consent never enters the server operation queue.
// This AppModel integration test runs in the native app test target.

#if os(macOS)
    import AppKit
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerAppModelTests: XCTestCase {
        func testProjectCapabilityIsAdvertisedWithoutActivatingBeforeServerSelection() throws {
            let model = AppModel(
                tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
            model.signedIn = true
            var sent: [JSONValue] = []
            model.outboundTap = { if let frame = try? JSONValue.parse(Data($0.utf8)) { sent.append(frame) } }
            model.reportDeviceCapabilities()
            let update = try XCTUnwrap(sent.first { $0["action"] == .string("update_device") })
            XCTAssertEqual(update["payload"]?["device"]?["project_workspaces_v1"], .bool(true))
            XCTAssertFalse(model.projects.enabled)
        }
        func testLocalConsentNeverEntersServerOperationQueue() {
            let model = AppModel(
                tokenStore: InMemoryTokenStore(),
                defaults: UserDefaults(suiteName: "local-consent-" + UUID().uuidString)!)
            var sent: [String] = []
            model.outboundTap = { sent.append($0) }
            model.emit("computer_host_consent", payload: ["enabled": .bool(true)])
            XCTAssertTrue(sent.isEmpty)
            XCTAssertFalse(model.macComputerHost.enabled)
        }
    }
#endif
