// Renders the mesh screens on macOS from the in-memory fixture into window bitmaps and attaches them to the test result.
// It never shows a window, so it needs no screen control and can run beside other apps.

#if os(macOS)
    @testable import AstralDeep
    import AppKit
    import SwiftUI
    import XCTest

    @MainActor
    final class MeshMacScreenshotTests: XCTestCase {
        private struct Rig {
            let consent = ConsentCoordinator()
            let model = AppModel()
            let mode: AppModeStore
            let runtime: MeshRuntime

            init(_ scenario: MeshUITestFixture.Scenario) {
                let fixture = MeshUITestFixture.install(scenario, consent: consent)
                mode = fixture.mode
                runtime = fixture.runtime
            }

            func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> some View {
                view.environment(model).environment(mode).environment(consent).environment(runtime)
                    .environment(MacNodeHostStore())
                    .font(ConsoleTypography.body)
                    .environment(model.themeStore)
                    .tint(model.themeStore.palette.primary)
                    .preferredColorScheme(model.themeStore.colorScheme)
                    .background(model.themeStore.palette.bg)
                    .frame(width: width, height: height)
            }
        }

        private func capture<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat, settle: Double = 1.0) async {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: view)
            window.contentView = hosting
            window.appearance = NSAppearance(named: .darkAqua)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window.orderBack(nil)
            try? await Task.sleep(for: .seconds(settle))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                return XCTFail("no bitmap for " + name)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("no png") }
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.orderOut(nil)
        }

        private func shell(_ name: String, _ destination: (MeshRuntime) -> MeshDestination) async {
            let rig = Rig(.shell)
            await rig.runtime.open()
            await rig.runtime.settle()
            let start = destination(rig.runtime)
            await capture("mac-" + name, rig.host(MeshRootView(start: start), width: 1280, height: 820), width: 1280, height: 820)
            await rig.runtime.close()
        }

        func testShellScreens() async {
            await shell("devices") { _ in .devices }
            await shell("runs") { _ in .runs }
            await shell("settings") { _ in .settings }
            await shell("chat") { .chat($0.chats.first?.chatId ?? "") }
        }

        func testAttachmentOnlyChatScreen() async {
            let rig = Rig(.attachments)
            await rig.runtime.open()
            await capture(
                "mac-file-attachment",
                rig.host(MeshRootView(start: .chat(rig.runtime.chats.first?.chatId ?? "")), width: 1280, height: 820),
                width: 1280, height: 820)
            await rig.runtime.close()
        }

        func testPairingAndSheetScreens() async {
            let rig = Rig(.shell)
            await rig.runtime.open()
            await rig.runtime.startInvitation()
            await capture(
                "mac-add-device-invitation",
                rig.host(NavigationStack { MeshInviteView {} }, width: 520, height: 700), width: 520, height: 700)
            try? await Task.sleep(for: .seconds(6))
            await capture(
                "mac-add-device-compare",
                rig.host(NavigationStack { MeshInviteView {} }, width: 520, height: 700), width: 520, height: 700)
            await rig.runtime.close()
        }

        func testOnboardingAndPermissionScreens() async {
            let rig = Rig(.onboarding)
            await rig.runtime.open()
            await capture("mac-onboarding", rig.host(MeshRootView(), width: 760, height: 640), width: 760, height: 640)
            await capture(
                "mac-join",
                rig.host(
                    MeshJoinStartView(onShowCode: {}, onBack: {}).padding(24).frame(maxWidth: 480), width: 760, height: 640),
                width: 760, height: 640)
            await capture(
                "mac-recovery",
                rig.host(MeshRecoveryView(words: (1...24).map { "word\($0)" }), width: 760, height: 700), width: 760, height: 700)
            await capture(
                "mac-restore",
                rig.host(MeshRestoreView(onCancel: {}).padding(24), width: 760, height: 640), width: 760, height: 640)
            await rig.runtime.close()
            await capture(
                "mac-outcome-unknown",
                rig.host(
                    MeshUnknownOutcomeCard(
                        outcome: MeshUnknownOutcome(stepId: "s1", tool: "mail.send", summary: "Send the weekly plan to the lab"))
                        .padding(20).frame(maxWidth: 520),
                    width: 560, height: 260),
                width: 560, height: 260)
            let shell = Rig(.shell)
            await shell.runtime.open()
            await shell.runtime.refreshTools()
            await capture(
                "mac-permissions",
                shell.host(NavigationStack { MeshPermissionsView() }, width: 1000, height: 640), width: 1000, height: 640)
            if let pending = shell.runtime.pendingConsents.first, let prompt = shell.runtime.prompt(for: pending) {
                await capture(
                    "mac-consent",
                    shell.host(
                        ConsentSheet(prompt: prompt, isAuthenticating: false, message: nil, onApprove: {}, onDeny: {}),
                        width: 480, height: 460),
                    width: 480, height: 460)
            }
            await shell.runtime.close()
        }
    }
#endif
