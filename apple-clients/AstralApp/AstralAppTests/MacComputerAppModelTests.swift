// Verifies that local computer consent never enters the server operation queue.
// This AppModel integration test runs in the native app test target.

#if os(macOS)
    import AppKit
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacComputerAppModelTests: XCTestCase {
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
