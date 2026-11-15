// Renders mesh screens from in-memory fixtures into window bitmaps and checks the visible chat status.
// The windows stay behind other apps, and status text is read from an opaque image without accessibility focus.

#if os(macOS)
    @testable import AstralDeep
    import AppKit
    import SwiftUI
    import Vision
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

        private func activityWindow(_ runtime: MeshRuntime) -> (NSWindow, NSView) {
            let theme = ThemeStore()
            let hosting = NSHostingView(
                rootView: MeshTurnActivityView().environment(runtime).environment(theme)
                    .preferredColorScheme(theme.colorScheme).frame(width: 700, height: 180).background(theme.palette.bg)
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 180), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            window.orderBack(nil)
            return (window, hosting)
        }

        private func statusText(in view: NSView) throws -> String {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let source = try XCTUnwrap(bitmap.cgImage)
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(bounds)
            context.draw(source, in: bounds)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: try XCTUnwrap(context.makeImage())).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }

        func testAnUnfinishedLogTurnRendersAwaitingAnswer() async throws {
            let h = MeshRuntimeHarness()
            defer { h.cleanUp() }
            await h.runtime.open()
            let chat = h.kernel.seedChat(
                title: "Offline", messages: [MeshRuntimeHarness.message("q", parent: nil, at: 1)])
            h.kernel.setChatStatus(chatId: chat, .running(turnId: "unfinished"))
            await h.runtime.openChat(chat)
            let (window, view) = activityWindow(h.runtime)
            defer { window.close() }
            var text = ""
            let visible = await eventually {
                text = (try? self.statusText(in: view)) ?? ""
                return text.contains("Awaiting answer")
            }
            XCTAssertTrue(visible, text)
            XCTAssertFalse(text.contains("Working"), text)
        }

        func testANetworkWaitNoticeRendersInsteadOfGenericWorking() async throws {
            let h = MeshRuntimeHarness()
            defer { h.cleanUp() }
            await h.runtime.open()
            _ = await h.runtime.newChat()
            h.kernel.turnScript = [.started, .notice("The network is unreachable. Waiting to reconnect.")]
            _ = await h.runtime.send("hello")
            await h.runtime.settle()
            let (window, view) = activityWindow(h.runtime)
            defer { window.close() }
            var text = ""
            let visible = await eventually {
                text = (try? self.statusText(in: view)) ?? ""
                return text.contains("Waiting to reconnect")
            }
            XCTAssertTrue(visible, text)
            XCTAssertFalse(text.contains("Working"), text)
        }

        func testAnAcceptedStopRendersStoppingUntilNativeOutcomeArrives() async throws {
            let h = MeshRuntimeHarness()
            defer { h.cleanUp() }
            await h.runtime.open()
            _ = await h.runtime.newChat()
            h.kernel.turnScript = [.started]
            _ = await h.runtime.send("Long answer")
            await h.runtime.settle()
            await h.runtime.interrupt()
            let (window, view) = activityWindow(h.runtime)
            defer { window.close() }
            var text = ""
            let visible = await eventually {
                text = (try? self.statusText(in: view)) ?? ""
                return text.contains("Stopping")
            }
            XCTAssertTrue(visible, text)
            XCTAssertFalse(text.contains("Stopped"), text)
        }

        func testAnIncompleteAnswerKeepsItsWarningAfterTheTurnFinishes() async throws {
            let h = MeshRuntimeHarness()
            defer { h.cleanUp() }
            await h.runtime.open()
            _ = await h.runtime.newChat()
            let ending = KernelMapping.turn(.ended(chatId: "c", turnId: "t", reason: "incomplete", code: nil))
                .compactMap {
                    if case .turnProgress(let progress) = $0 { return progress.event }
                    return nil
                }
            h.kernel.turnScript =
                [.started, .notice("Waiting to reconnect"), .assistantDelta("Partial answer")] + ending
            _ = await h.runtime.send("hello")
            await h.runtime.settle()
            XCTAssertEqual(h.runtime.currentTurn?.running, false)
            let (window, view) = activityWindow(h.runtime)
            defer { window.close() }
            var text = ""
            let visible = await eventually {
                text = (try? self.statusText(in: view)) ?? ""
                return text.contains("The answer may be incomplete")
            }
            XCTAssertTrue(visible, text)
            XCTAssertFalse(text.contains("Waiting to reconnect"), text)
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

        func testProviderSharingScreens() async throws {
            let rig = Rig(.shell)
            await rig.runtime.open()
            _ = await rig.runtime.saveProvider(
                baseURL: "https://provider.example.test/v1", model: "Example model", key: "fixture-key")
            let provider = try XCTUnwrap(rig.runtime.providers.first)
            await capture(
                "mac-provider-all", rig.host(NavigationStack { MeshModelProviderView() }, width: 1000, height: 1000),
                width: 1000, height: 1000)
            var selected = provider
            selected.recipients = rig.runtime.members.map(\.memberId).sorted()
            await capture(
                "mac-provider-selected",
                rig.host(NavigationStack { MeshProviderSharingView(provider: selected) }, width: 1000, height: 820),
                width: 1000, height: 820)
            await rig.runtime.close()
        }

        func testProviderAudienceRendersItsFutureDeviceScopeAndExplicitSelections() async throws {
            let model = AppModel()
            let member = MeshMember(
                memberId: "mac", label: "My Mac", kind: .desktop, isThisDevice: true, attested: true, lastSeen: nil,
                path: .none)
            for recipients: [String]? in [nil, [member.memberId, "removed-device"]] {
                let mount = SurfaceMount(
                    VStack(alignment: .leading) {
                        MeshProviderRecipientsPicker(recipients: .constant(recipients), members: [member])
                    }.padding(24),
                    model: model, size: CGSize(width: 700, height: 240))
                defer { mount.window.close() }
                var text = ""
                let visible = await eventually {
                    text = (try? mount.text()) ?? ""
                    if recipients == nil { return text.contains("Includes devices you add later") }
                    return text.contains("My Mac") && text.contains("Unavailable device")
                }
                XCTAssertTrue(visible, text)
                if recipients != nil { XCTAssertFalse(text.contains("Includes devices you add later"), text) }
            }
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
