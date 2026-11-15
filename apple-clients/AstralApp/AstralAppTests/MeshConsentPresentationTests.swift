// Exercises the real consent presenter above a separate SwiftUI setup sheet without opening a Kernel or authenticating a person.

#if os(macOS)
    import AppKit
    import LocalAuthentication
    import Observation
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    private nonisolated final class PresentationAuthenticator: ConsentAuthenticating, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }

        func authenticate(reason: String, requiresBiometry: Bool) async throws -> LAContext {
            lock.withLock { count += 1 }
            throw ConsentDenial.denied
        }
    }

    private enum ConsentEnding {
        case requestCancelled
        case escapeKey
        case parentClosed
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
            try await checkPresentation(aboveSetup: false, ending: .requestCancelled)
        }

        func testConsentRemainsVisibleAboveTheDeviceSetupSheet() async throws {
            try await checkPresentation(aboveSetup: true, ending: .requestCancelled)
        }

        func testEscapeAboveTheDeviceSetupSheetDeniesWithoutAuthenticating() async throws {
            try await checkPresentation(aboveSetup: true, ending: .escapeKey)
        }

        func testClosingTheDeviceSetupSheetCancelsTheConsentItHosts() async throws {
            try await checkPresentation(aboveSetup: true, ending: .parentClosed)
        }

        private func checkPresentation(aboveSetup: Bool, ending: ConsentEnding) async throws {
            let setup = SetupPresentation()
            let authenticator = PresentationAuthenticator()
            let consent = ConsentCoordinator(authenticator: authenticator)
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
            func sheets() -> [NSWindow] {
                var chain: [NSWindow] = []
                var parent = window
                while let attached = parent.attachedSheet, attached.isVisible {
                    chain.append(attached)
                    parent = attached
                }
                return chain
            }
            let consentDepth = aboveSetup ? 2 : 1
            if aboveSetup {
                setup.showing = true
                let setupVisible = await eventually {
                    guard case .waiting = harness.runtime.invite else { return false }
                    return sheets().count == 1
                }
                XCTAssertTrue(setupVisible, "The setup sheet must be presented before the consent request")
            }
            let setupSheet = sheets().first
            XCTAssertEqual(sheets().count, aboveSetup ? 1 : 0, "No consent prompt may show before a request")
            let request = Task {
                await consent.requestConsent(
                    ConsentPrompt(
                        actionTitle: "Add synthetic device", effect: "roster.add", target: "Synthetic phone",
                        arguments: "Synthetic public device record", untrustedSource: nil, labels: [],
                        digest: "sha256:" + String(repeating: "ab", count: 32)))
            }
            let requested = await eventually { consent.current != nil }
            XCTAssertTrue(requested)
            let consentVisible = await eventually { sheets().count == consentDepth }
            XCTAssertTrue(consentVisible, "The current consent prompt must be visible to the person")
            if aboveSetup { XCTAssertTrue(sheets().first === setupSheet, "Consent must attach above the setup sheet") }
            switch ending {
            case .requestCancelled:
                request.cancel()
                guard case .denied(.cancelled) = await request.value else {
                    return XCTFail("A cancelled request must end as a cancellation")
                }
            case .escapeKey:
                let sheet = try XCTUnwrap(sheets().last, "The consent prompt must be an attached sheet")
                sheet.makeKey()
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let escape = try XCTUnwrap(
                        NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                    NSApp.sendEvent(escape)
                }
                guard case .denied(.denied) = await request.value else {
                    return XCTFail("Escape must deny the displayed request")
                }
            case .parentClosed:
                setup.showing = false
                let closed = await eventually { sheets().isEmpty }
                XCTAssertTrue(closed, "Closing the setup sheet must also remove the consent prompt above it")
                let ended = await eventually { consent.current == nil }
                XCTAssertTrue(ended, "Closing the hosting sheet must end its request")
                if !ended { request.cancel() }
                guard case .denied(.cancelled) = await request.value else {
                    return XCTFail("Closing the hosting sheet must cancel its request")
                }
            }
            let consentGone = await eventually { sheets().count == (aboveSetup && ending != .parentClosed ? 1 : 0) }
            XCTAssertTrue(consentGone, "No consent prompt may remain after the request ends")
            if aboveSetup && ending != .parentClosed {
                XCTAssertTrue(sheets().first === setupSheet, "Ending consent must leave the setup sheet open")
            }
            XCTAssertNil(consent.current)
            XCTAssertEqual(authenticator.calls, 0, "Nothing in this test may start authentication")
            setup.showing = false
            await harness.runtime.close()
            try await Task.sleep(for: .milliseconds(100))
        }
    }
#endif
