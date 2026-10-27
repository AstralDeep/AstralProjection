// Drives the server settings overlay with real key events in offscreen AppKit windows.
// Covers Esc and Close, focus moving in and back to the composer, the disabled background and the send guard.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class SettingsOverlayKeyboardTests: XCTestCase {
        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func fixture(_ name: String) throws -> JSONValue {
            let url = try XCTUnwrap(
                Bundle(for: SettingsOverlayKeyboardTests.self).url(forResource: name, withExtension: "json"), name)
            return try JSONValue.parse(Data(contentsOf: url))
        }

        private func presentation() throws -> ConsolePresentation {
            let row = try XCTUnwrap(
                fixture("rote-console")["cases"]?.arrayValue?.first {
                    $0["viewport"]?.arrayValue?.first?.numberValue == 1440
                })
            return try XCTUnwrap(ConsolePresentation(json: row["presentation"]))
        }

        private func model() throws -> AppModel {
            let suite = "SettingsOverlayKeyboardTests.\(UUID().uuidString)"
            suites.append(suite)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.signedIn = true
            model.connected = true
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(fixture("chrome-console")))
            model.consolePresentation = try presentation()
            model.screen = .chat
            return model
        }

        private func open(_ model: AppModel) {
            model.pendingSurfaceKey = "agents"
            model.pendingSurfaceParams = .object([:])
            model.pendingSurface = .init(surfaceKey: "agents", title: "Agents & permissions", components: [])
            model.screen = .surface
        }

        private final class Mount {
            let window: NSWindow
            let view: NSView

            init(_ root: some View, size: CGSize = CGSize(width: 1440, height: 900)) {
                window = NSWindow(
                    contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: .borderless,
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let hosting = NSHostingView(rootView: root)
                window.contentView = hosting
                window.orderBack(nil)
                view = hosting
                hosting.layoutSubtreeIfNeeded()
            }

            func settle(_ seconds: Double = 0.25) async throws {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(25))
                }
            }

            func until(_ condition: () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(5)
                while !condition(), Date() < deadline {
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(25))
                }
            }

            func escape() -> NSEvent {
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                    keyCode: 53)!
            }

            func fields() -> [NSTextField] {
                func collect(_ view: NSView) -> [NSTextField] {
                    ((view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + view.subviews.flatMap(collect)
                }
                return collect(view)
            }

            func focused(on field: NSTextField) -> Bool {
                var responder = window.firstResponder as? NSView
                while let current = responder {
                    if current === field { return true }
                    responder = current.superview
                }
                return false
            }

            func close() {
                window.contentView = nil
                window.close()
            }
        }

        private func overlay(_ model: AppModel) throws -> Mount {
            let theme = ThemeStore()
            let presentation = try presentation()
            return Mount(
                ConsoleSurfaceOverlay(
                    console: try XCTUnwrap(model.console), presentation: presentation,
                    size: CGSize(width: 1440, height: 900)
                )
                .frame(width: 1440, height: 900)
                .environment(\.astralViewportWidth, 1440)
                .environment(model).environment(theme))
        }

        private func shell(_ model: AppModel) throws -> Mount {
            Mount(
                ConsoleShell(console: try XCTUnwrap(model.console), presentation: try presentation())
                    .frame(width: 1440, height: 900)
                    .environment(\.astralViewportWidth, 1440)
                    .environment(model).environment(ThemeStore()))
        }

        func testEscapeClosesAnOrdinarySurfaceButNotAMandatoryOne() async throws {
            for mandatory in [false, true] {
                let model = try model()
                open(model)
                model.mandatorySurface = mandatory
                let mount = try overlay(model)
                defer { mount.close() }
                try await mount.settle()
                XCTAssertEqual(mount.window.performKeyEquivalent(with: mount.escape()), !mandatory)
                try await mount.settle(0.1)
                XCTAssertEqual(model.screen, mandatory ? .surface : .chat, "mandatory \(mandatory)")
            }
        }

        func testOverlayTakesFocusAndEscapeFromInsideClosesOnlyOrdinarySurfaces() async throws {
            for mandatory in [false, true] {
                let model = try model()
                open(model)
                model.mandatorySurface = mandatory
                let mount = try overlay(model)
                defer { mount.close() }
                try await mount.until { !(mount.window.firstResponder is NSWindow) }
                XCTAssertNotNil(mount.window.firstResponder as? NSView, "mandatory \(mandatory)")
                XCTAssertFalse(mount.window.firstResponder is NSWindow, "mandatory \(mandatory)")
                mount.window.sendEvent(mount.escape())
                try await mount.settle(0.1)
                XCTAssertEqual(model.screen, mandatory ? .surface : .chat, "mandatory \(mandatory)")
            }
        }

        func testCoveredBackgroundLeavesTheKeyLoopAndFocusReturnsToTheComposer() async throws {
            let model = try model()
            model.consoleDashboardVisible = false
            model.workspaceStarted = true
            let mount = try shell(model)
            defer { mount.close() }
            try await mount.settle()
            let composer = try XCTUnwrap(
                mount.fields().first { $0.accessibilityIdentifier() == "chat-composer-input" }
                    ?? mount.fields().min { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY })
            XCTAssertTrue(mount.window.makeFirstResponder(composer))
            try await mount.until { mount.focused(on: composer) }
            XCTAssertTrue(mount.focused(on: composer))
            XCTAssertTrue(mount.fields().allSatisfy(\.isEnabled))

            open(model)
            try await mount.until { !mount.focused(on: composer) && !(mount.window.firstResponder is NSWindow) }
            XCTAssertFalse(mount.focused(on: composer))
            let background = mount.fields()
            XCTAssertFalse(background.isEmpty)
            XCTAssertTrue(background.allSatisfy { !$0.isEnabled }, "background text fields stay in the key loop")

            model.closeSurface()
            try await mount.until { mount.focused(on: composer) }
            XCTAssertTrue(mount.focused(on: composer), "focus did not return to the composer")
            XCTAssertTrue(mount.fields().allSatisfy(\.isEnabled))
        }

        func testSendChatRefusesBehindAMandatorySurfaceAndKeepsTheDraft() throws {
            let model = try model()
            var sent: [String] = []
            model.outboundTap = { sent.append($0) }
            open(model)
            model.mandatorySurface = true
            model.composerDraft = ""
            model.sendChat("Unsent behind the provider setup")
            XCTAssertTrue(sent.isEmpty)
            XCTAssertTrue(model.turns.isEmpty)
            XCTAssertFalse(model.turnActive)
            XCTAssertEqual(model.composerDraft, "Unsent behind the provider setup")
            model.mandatorySurface = false
            model.closeSurface()
            model.sendChat("Sent once the surface is gone")
            XCTAssertTrue(sent.contains { $0.contains("Sent once the surface is gone") })
        }
    }
#endif
