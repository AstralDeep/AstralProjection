// Exercises the real consent presenter above a separate SwiftUI setup sheet without opening a Kernel or authenticating a person.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import LocalAuthentication
    import Observation
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    private nonisolated struct PresentationAuthenticator: ConsentAuthenticating {
        func authenticate(reason: String, requiresBiometry: Bool) async throws -> LAContext {
            throw ConsentDenial.denied
        }
    }

    @MainActor
    @Observable
    private final class SetupPresentation {
        var showing = false
    }

    @MainActor
    private struct SetupPresentationHost: View {
        let setup: SetupPresentation
        let consent: ConsentCoordinator
        let runtime: MeshRuntime
        let theme: ThemeStore

        var body: some View {
            VStack {
                Text("Synthetic mesh")
                    .sheet(isPresented: Binding(get: { setup.showing }, set: { setup.showing = $0 })) {
                        MeshAddDeviceSheet()
                            .environment(runtime).environment(theme).environment(consent)
                    }
            }
            .frame(width: 700, height: 700)
            .consentSheet(consent)
        }
    }

    @MainActor
    final class MeshConsentPresentationTests: XCTestCase {
        func testConsentIsVisibleWithoutAnotherSheet() async throws {
            try await checkPresentation(aboveSetup: false)
        }

        func testConsentRemainsVisibleAboveTheDeviceSetupSheet() async throws {
            try await checkPresentation(aboveSetup: true)
        }

        private func checkPresentation(aboveSetup: Bool) async throws {
            let setup = SetupPresentation()
            let consent = ConsentCoordinator(authenticator: PresentationAuthenticator())
            let harness = MeshRuntimeHarness()
            defer { harness.cleanUp() }
            await harness.runtime.open()
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: SetupPresentationHost(
                        setup: setup, consent: consent, runtime: harness.runtime, theme: ThemeStore())))
            window.title = "Synthetic consent \(UUID().uuidString)"
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            func visible(_ identifier: String) -> Bool {
                func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
                    var value: CFTypeRef?
                    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
                }
                func contains(_ element: AXUIElement, depth: Int) -> Bool {
                    if attribute(kAXIdentifierAttribute, of: element) as? String == identifier { return true }
                    guard depth < 64 else { return false }
                    return (attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [])
                        .contains { contains($0, depth: depth + 1) }
                }
                let app = AXUIElementCreateApplication(getpid())
                return (attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? [])
                    .contains { contains($0, depth: 0) }
            }
            if aboveSetup {
                setup.showing = true
                let setupVisible = await eventually { visible("mesh.invite.waiting") }
                XCTAssertTrue(setupVisible, "The setup sheet must be presented before the consent request")
            }
            let request = Task {
                await consent.requestConsent(
                    ConsentPrompt(
                        actionTitle: "Add synthetic device", effect: "roster.add", target: "Synthetic phone",
                        arguments: "Synthetic public device record", untrustedSource: nil, labels: [],
                        digest: "sha256:" + String(repeating: "ab", count: 32)))
            }
            let requested = await eventually { consent.current != nil }
            XCTAssertTrue(requested)
            let consentVisible = await eventually { visible("consent.sheet") }
            XCTAssertTrue(consentVisible, "The current consent prompt must be visible to the person")
            request.cancel()
            setup.showing = false
            guard case .denied = await request.value else { return XCTFail("The test never approves an action") }
            await harness.runtime.close()
            try await Task.sleep(for: .milliseconds(100))
        }
    }
#endif
