// Exercises the native workbench with the shared server fixtures and persistent generated charts.
// Accessibility checks read only the test process's named windows through the public AX interface.

#if os(macOS)
    import AppKit
    import ApplicationServices
    import AstralCore
    import Observation
    import SwiftUI
    import Vision
    import WebKit
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacWorkbenchViewTests: XCTestCase {
        func testSurfaceAccessibilityRejectsMissingOwnedWindow() {
            XCTAssertThrowsError(
                try SurfaceAccessibility.elements(windowTitle: "Absent surface \(UUID().uuidString)")
            ) { error in
                XCTAssertEqual(error as? SurfaceAccessibility.Failure, .missingWindow)
            }
        }

        func testSurfaceAccessibilityRejectsAmbiguousOwnedWindows() async throws {
            let (model, suite) = try SurfaceFixtures.model()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let first = SurfaceMount(Text("First sentinel"), model: model, size: CGSize(width: 240, height: 120))
            let second = SurfaceMount(Text("Second sentinel"), model: model, size: CGSize(width: 240, height: 120))
            defer {
                first.close()
                second.close()
            }
            second.window.title = first.window.title
            try await first.settle()
            try await second.settle()
            let application = AXUIElementCreateApplication(getpid())
            var rawWindows: CFTypeRef?
            XCTAssertEqual(
                AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows), .success)
            let windows = try XCTUnwrap(rawWindows as? [AXUIElement])
            let duplicates = windows.filter { window in
                var title: CFTypeRef?
                return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success
                    && title as? String == first.window.title
            }
            XCTAssertEqual(duplicates.count, 2)
            for window in duplicates {
                var pid: pid_t = 0
                XCTAssertEqual(AXUIElementGetPid(window, &pid), .success)
                XCTAssertEqual(pid, getpid())
            }
            XCTAssertThrowsError(try SurfaceAccessibility.elements(windowTitle: first.window.title)) { error in
                XCTAssertEqual(error as? SurfaceAccessibility.Failure, .ambiguousWindow)
            }
        }

        func testSlashInAnEmptyComposerOpensThePaletteAndRunsTheChosenAction() async throws {
            let (model, suite) = try panelModel()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            let (_, window) = try mountWorkbench(model, width: 1440, activity: false)
            defer { window.close() }
            try await settle()
            func sheet() async throws -> NSWindow {
                try await settle()
                return try XCTUnwrap(window.attachedSheet, "The palette sheet did not open")
            }
            func type(_ text: String, in sheet: NSWindow) {
                (sheet.firstResponder as? NSTextView)?.insertText(
                    text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            model.composerDraft = "/"
            var palette = try await sheet()
            XCTAssertEqual(model.composerDraft, "")
            type("back", in: palette)
            try await settle()
            palette.sendEvent(try SurfaceKey.returnKey.event(windowNumber: palette.windowNumber))
            try await settle()
            XCTAssertNil(window.attachedSheet)
            XCTAssertTrue(model.runInBackground)
            XCTAssertFalse(sent.contains { $0["action"]?.stringValue == "chat_message" })

            model.composerDraft = ""
            try await settle()
            model.composerDraft = "/"
            palette = try await sheet()
            type("he", in: palette)
            try await settle()
            XCTAssertTrue(
                palette.performKeyEquivalent(with: try SurfaceKey.escape.event(windowNumber: palette.windowNumber)))
            try await settle()
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(model.composerDraft, "/he")

            model.composerDraft = ""
            try await settle()
            model.composerDraft = "/"
            palette = try await sheet()
            palette.sendEvent(try SurfaceKey.delete.event(windowNumber: palette.windowNumber))
            try await settle()
            type("llm", in: palette)
            try await settle()
            palette.sendEvent(try SurfaceKey.returnKey.event(windowNumber: palette.windowNumber))
            try await settle()
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(sent.last?["action"], .string("chrome_open"))
            XCTAssertEqual(sent.last?["payload"]?["surface"], .string("llm"))

            model.screen = .chat
            model.mandatorySurface = true
            model.composerDraft = ""
            try await settle()
            model.composerDraft = "/"
            try await settle()
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(model.composerDraft, "/")
        }

        func testPaletteRenamesPinsAndArchivesTheCurrentChat() async throws {
            let (model, suite) = try panelModel()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            model.activeChatId = "c1"
            model.history = [
                try XCTUnwrap(
                    ChatSummary(json: .object(["id": .string("c1"), "title": .string("Roll notes")])))
            ]
            let (_, window) = try mountWorkbench(model, width: 1440, activity: false)
            defer { window.close() }
            try await settle()
            func choose(_ query: String) async throws {
                model.composerDraft = ""
                try await settle()
                model.composerDraft = "/"
                try await settle()
                let palette = try XCTUnwrap(window.attachedSheet, "The palette sheet did not open")
                palette.sendEvent(try SurfaceKey.delete.event(windowNumber: palette.windowNumber))
                try await settle()
                (palette.firstResponder as? NSTextView)?.insertText(
                    query, replacementRange: NSRange(location: NSNotFound, length: 0))
                try await settle()
                palette.sendEvent(try SurfaceKey.returnKey.event(windowNumber: palette.windowNumber))
                try await settle()
            }
            try await choose("pin chat")
            XCTAssertEqual(sent.last?["action"], .string("chat_pin"))
            XCTAssertEqual(sent.last?["payload"]?["chat_id"], .string("c1"))
            model.history = [
                try XCTUnwrap(
                    ChatSummary(
                        json: .object([
                            "id": .string("c1"), "title": .string("Roll notes"), "pinned": .bool(true),
                            "archived": .bool(true),
                        ])))
            ]
            try await choose("unpin")
            XCTAssertEqual(sent.last?["action"], .string("chat_unpin"))
            try await choose("unarchive")
            XCTAssertEqual(sent.last?["action"], .string("chat_unarchive"))
            try await choose("rename")
            let rename = try XCTUnwrap(window.attachedSheet, "The rename sheet did not open")
            (rename.firstResponder as? NSTextView)?.insertText(
                "Dice log", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await settle()
            rename.sendEvent(try SurfaceKey.returnKey.event(windowNumber: rename.windowNumber))
            try await settle()
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(sent.last?["action"], .string("chat_rename"))
            XCTAssertEqual(sent.last?["payload"]?["title"], .string("Dice log"))
            model.activeChatId = nil
            let count = sent.count
            try await choose("archive chat")
            XCTAssertEqual(sent.count, count)
        }

        func testAgentDirectoryFocusesSearchAndMarksOfflineAgentsByShapeAndText() async throws {
            let (model, suite) = try SurfaceFixtures.model(menu: Self.twoAgentMenu())
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            let console = try XCTUnwrap(model.console)
            for preset in SurfaceFixtures.presets {
                for size in [DynamicTypeSize.large, .accessibility3] {
                    let mount = SurfaceMount(
                        MacWorkbenchAgents(console: console).environment(\.dynamicTypeSize, size), model: model,
                        size: CGSize(width: 360, height: 360), preset: preset)
                    defer { mount.close() }
                    try await mount.settle()
                    XCTAssertEqual(mount.focusedPrompt(), "Search agents", "\(preset) \(size)")
                    let text = try mount.text()
                    for kept in ["Agent Directory", "Dice Roller", "Clinical Notes", "Offline"] {
                        XCTAssertTrue(text.contains(kept), "\(preset) \(size) missing \(kept): \(text)")
                    }
                    XCTAssertFalse(text.contains("Rolls dice"), preset)
                    XCTAssertFalse(text.contains("Available"), preset)
                    try mount.snapshot(self, name: "agent_directory-\(preset)-\(size == .large ? "large" : "ax3")")
                }
            }
            let mount = SurfaceMount(
                MacWorkbenchAgents(console: console), model: model, size: CGSize(width: 360, height: 360))
            defer { mount.close() }
            try await mount.settle()
            try mount.click(text: "Dice Roller")
            try await mount.settle()
            XCTAssertEqual(sent.last?["action"], .string("chrome_open"))
            XCTAssertEqual(sent.last?["payload"]?["surface"], .string("agent_intro"))
            XCTAssertEqual(sent.last?["payload"]?["params"]?["agent_id"], .string("dice"))
            model.mandatorySurface = true
            sent = []
            try mount.click(text: "Clinical Notes")
            try await mount.settle()
            XCTAssertTrue(sent.isEmpty, "\(sent)")
        }

        func testAgentDirectoryRowsExposeNamesStatusDescriptionAndOrder() async throws {
            let (model, suite) = try SurfaceFixtures.model(menu: Self.twoAgentMenu())
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let mount = SurfaceMount(
                MacWorkbenchAgents(console: try XCTUnwrap(model.console)), model: model,
                size: CGSize(width: 360, height: 360))
            defer { mount.close() }
            try await mount.settle()
            let tree = try mount.accessibility
            let dice = try XCTUnwrap(tree.first { $0.identifier == "workbench-agent-dice" })
            XCTAssertEqual(dice.label, "Dice Roller")
            XCTAssertEqual(dice.value, "Available")
            XCTAssertEqual(dice.help, "Rolls dice")
            XCTAssertEqual(tree.first { $0.identifier == "workbench-agent-notes" }?.value, "Offline")
            XCTAssertEqual(tree.first { $0.identifier == "workbench-agent-search" }?.label, "Search agents")
            XCTAssertEqual(
                tree.compactMap(\.identifier).filter { $0.hasPrefix("workbench-agent-") },
                ["workbench-agent-search", "workbench-agent-dice", "workbench-agent-notes"])
            XCTAssertFalse(
                tree.contains { $0.label == "magnifyingglass" || $0.label == "Search" && $0.role == "AXImage" })
        }

        func testAgentDirectoryShowsNoMatchAndEmptyStatesAndOpensTheFirstMatchOnReturn() async throws {
            let (model, suite) = try SurfaceFixtures.model()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            for preset in SurfaceFixtures.presets {
                let mount = SurfaceMount(
                    MacWorkbenchAgents(console: try XCTUnwrap(model.console)), model: model,
                    size: CGSize(width: 360, height: 220), preset: preset)
                defer { mount.close() }
                try await mount.settle()
                mount.type("zzz")
                try await mount.settle()
                let text = try mount.text()
                XCTAssertTrue(text.contains("No matching agents"), "\(preset): \(text)")
                XCTAssertFalse(text.contains("Dice Roller"), preset)
                try mount.snapshot(self, name: "agent_directory_no_match-\(preset)")
            }
            let mount = SurfaceMount(
                MacWorkbenchAgents(console: try XCTUnwrap(model.console)), model: model,
                size: CGSize(width: 360, height: 220))
            defer { mount.close() }
            try await mount.settle()
            mount.type("dice")
            try mount.key(.returnKey)
            try await mount.settle()
            XCTAssertEqual(sent.last?["payload"]?["params"]?["agent_id"], .string("dice"))
            let (empty, emptySuite) = try SurfaceFixtures.model(menu: SurfaceFixtures.menu(agents: []))
            defer { UserDefaults.standard.removePersistentDomain(forName: emptySuite) }
            for preset in SurfaceFixtures.presets {
                let mount = SurfaceMount(
                    MacWorkbenchAgents(console: try XCTUnwrap(empty.console)), model: empty,
                    size: CGSize(width: 360, height: 220), preset: preset)
                defer { mount.close() }
                try await mount.settle()
                XCTAssertTrue(try mount.text().contains("No agents available"), preset)
                try mount.snapshot(self, name: "agent_directory_empty-\(preset)")
            }
        }

        func testAgentDirectoryPopoverPointsAtTheWorkspaceActionsControl() async throws {
            let (model, suite) = try panelModel()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            model.outboundTap = { _ in }
            let state = try MountState(model: model, fixture: fixture("mac-workbench"))
            state.width = 1440
            let console = try XCTUnwrap(model.console)
            let presentation = try XCTUnwrap(model.consolePresentation)
            let view = NSHostingView(
                rootView: MacWorkbenchView(
                    console: console, presentation: presentation, workbench: try XCTUnwrap(presentation.workbench),
                    agentsPresented: true
                )
                .environment(model).environment(model.themeStore)
                .font(ConsoleTypography.body).tint(model.themeStore.palette.primary))
            let window = host(view, model: model, width: 900)
            window.setFrameOrigin(.zero)
            defer { window.close() }
            try await settle()
            func buttons(_ view: NSView) -> [NSView] {
                (view is NSButton ? [view] : []) + view.subviews.flatMap(buttons)
            }
            let menus = buttons(view).filter {
                $0 is NSPopUpButton || String(describing: type(of: $0)).contains("Menu")
            }
            let anchors = menus.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
                .filter { $0.minY >= window.frame.maxY - 120 && $0.midX > window.frame.midX }
            let anchor = try XCTUnwrap(anchors.first, "\(menus)")
            let popover = try XCTUnwrap(
                NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") },
                "No popover window")
            defer { popover.close() }
            XCTAssertLessThanOrEqual(popover.frame.maxY, anchor.minY + 2, "\(popover.frame) vs \(anchor)")
            XCTAssertTrue(
                (anchor.minX - 24...anchor.maxX + 24).contains(popover.frame.midX), "\(popover.frame) vs \(anchor)")
            XCTAssertLessThanOrEqual(popover.frame.height, 560 + 40)
            XCTAssertGreaterThanOrEqual(popover.frame.width, 320)
        }

        private static func twoAgentMenu() throws -> JSONValue {
            try SurfaceFixtures.menu(agents: [
                SurfaceFixtures.agent("dice", name: "Dice Roller", description: "Rolls dice", state: "ready"),
                SurfaceFixtures.agent("notes", name: "Clinical Notes", description: "Drafts notes", state: "offline"),
            ])
        }

        func testWelcomeUsesDirectChoicesAndRetainsAccessiblePromptLoading() async throws {
            for width in [390, 1440] {
                let suite = "MacWorkbenchViewTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
                let model = AppModel(
                    conversationResumeStore: ConversationResumeStore(defaults: defaults),
                    tokenStore: InMemoryTokenStore(), defaults: defaults)
                model.signedIn = true
                model.connected = true
                model.bindConversationAccount(
                    try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "workbench-owner")))
                model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(fixture("chrome-console")))
                model.history = [
                    try XCTUnwrap(
                        ChatSummary(
                            json: .object([
                                "id": .string("earlier-chat"), "title": .string("Earlier work"),
                                "preview": .string("Preview details"), "time": .string("Yesterday"),
                            ])))
                ]
                var sent: [JSONValue] = []
                model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
                let state = try MountState(model: model, fixture: fixture("mac-workbench"))
                state.width = width
                let view = NSHostingView(rootView: MountView(state: state))
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "Workbench choices \(UUID().uuidString)"
                window.appearance = NSAppearance(named: model.themeStore.colorScheme == .dark ? .darkAqua : .aqua)
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                try await settle()
                let text = try recognizedText(view)
                XCTAssertTrue(text.contains("Roll dice"))
                for redundant in [
                    "AstralDeep Console", "Multi-agent", "Six rolls", "Preview details", "Yesterday", "Member",
                ] {
                    XCTAssertFalse(text.contains(redundant), "Unexpected secondary copy: \(redundant)")
                }
                let snapshot = WorkbenchAccessibility.snapshot(windowTitle: window.title)
                let elements = try XCTUnwrap(snapshot, "Missing test window in the accessibility tree").elements
                if width == 1440 {
                    let chat = try XCTUnwrap(
                        elements.first { $0.identifier == "workbench-chat-earlier-chat" })
                    XCTAssertEqual(chat.value, "Preview details, Yesterday")
                }
                let choice = try XCTUnwrap(
                    elements.first { $0.identifier == "workbench-scenario-dice" })
                XCTAssertEqual(choice.label, "Load prompt: Roll dice")
                try attach(view, name: "workbench-direct-choices-\(width)")
                let pressed = WorkbenchAccessibility.press(
                    identifier: "workbench-scenario-dice", windowTitle: window.title)
                XCTAssertTrue(pressed)
                try await settle()
                XCTAssertEqual(model.composerDraft, "Roll six dice")
                XCTAssertFalse(sent.contains { $0["action"]?.stringValue == "chat_message" })
            }
        }

        func testCanvasKeepsItsDocumentAndDraftAcrossExpansionAndCompactResize() async throws {
            let suite = "MacWorkbenchViewTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.signedIn = true
            model.connected = true
            model.bindConversationAccount(
                try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "workbench-owner")))
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(fixture("chrome-console")))
            model.activeChatId = "workbench-chat"
            model.workspaceStarted = true
            model.consoleDashboardVisible = false
            model.turns = [.init(id: "u", role: "user", text: "Show three values")]
            model.composerDraft = "Keep my unfinished question"
            model.canvas = [
                try XCTUnwrap(
                    AstralComponent(
                        json: JSONValue.parse(
                            Data(
                                #"{"type":"bar_chart","component_id":"stable-result","title":"Values","labels":["A","B","C"],"datasets":[{"label":"Value","data":[2,5,3]}]}"#
                                    .utf8))))
            ]
            let state = try MountState(model: model, fixture: fixture("mac-workbench"))
            let view = NSHostingView(rootView: MountView(state: state))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: model.themeStore.colorScheme == .dark ? .darkAqua : .aqua)
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            let chart = try await readyChart(view)
            try attach(view, name: "workbench-wide")
            _ = try await chart.evaluateJavaScript("Plotly.relayout('chart', {'yaxis.range': [1, 4]}); true")
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            for width in [1440, 390, 1024, 1440] {
                state.width = width
                window.setContentSize(NSSize(width: width, height: 900))
                model.consoleFullscreen = true
                try await settle()
                try attach(view, name: "workbench-expanded-\(width)")
                let current = charts(view)
                XCTAssertEqual(current.count, 1)
                XCTAssertTrue(current.first === chart)
                let range = try await chart.evaluateJavaScript("document.getElementById('chart').layout.yaxis.range")
                XCTAssertEqual(range as? [Double], [1, 4])
                model.consoleFullscreen = false
                try await settle()
                try attach(view, name: "workbench-conversation-\(width)")
                XCTAssertTrue(charts(view).first === chart)
                XCTAssertEqual(model.composerDraft, "Keep my unfinished question")
                XCTAssertEqual(model.workspaceCanvas.map(\.componentId), ["stable-result"])
            }
            XCTAssertFalse(
                sent.contains { ["chat_message", "component_action"].contains($0["action"]?.stringValue ?? "") })
            let updates = sent.filter { $0["action"]?.stringValue == "update_device" }
            XCTAssertFalse(updates.isEmpty)
            XCTAssertTrue(updates.allSatisfy { $0["payload"]?["device"]?["mac_workbench_v1"] == .bool(true) })
        }

        func testReadingPositionIsPreservedWhenMoreConversationArrives() async throws {
            let suite = "MacWorkbenchViewTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.activeChatId = "reading-chat"
            model.turns = (0..<40).map {
                .init(
                    id: "turn-\($0)", role: "assistant",
                    text: "Message \($0). " + String(repeating: "A readable conversation keeps its place. ", count: 8))
            }
            let view = NSHostingView(
                rootView: MacWorkbenchTranscript(
                    maximumWidth: 720, contentPadding: EdgeInsets(top: 28, leading: 28, bottom: 28, trailing: 28)
                ).environment(model).environment(model.themeStore))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: model.themeStore.colorScheme == .dark ? .darkAqua : .aqua)
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            try await settle()
            let scroll = try XCTUnwrap(scrollViews(view).first { ($0.documentView?.frame.height ?? 0) > 1_000 })
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            try await settle()
            let position = scroll.contentView.bounds.origin.y
            model.turns.append(.init(id: "incoming", role: "assistant", text: "The next message has arrived."))
            try await settle()
            XCTAssertEqual(scroll.contentView.bounds.origin.y, position, accuracy: 1)
        }

        func testTranscriptShowsDistinctRoleAlignedBubblesAtCompactAndWideWidths() async throws {
            let suite = "MacWorkbenchViewTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.activeChatId = "bubble-chat"
            model.turns = [
                .init(id: "question", role: "user", text: "Short question"),
                .init(
                    id: "answer", role: "assistant", text: "Short answer",
                    components: [
                        try XCTUnwrap(
                            AstralComponent(
                                json: .object([
                                    "type": .string("text"), "content": .string("Attached detail"),
                                ]))),
                        try XCTUnwrap(
                            AstralComponent(
                                json: .object([
                                    "type": .string("button"), "label": .string("View result"),
                                    "variant": .string("secondary"),
                                    "action": .string("chrome_open"),
                                    "payload": .object(["surface": .string("guide"), "params": .object([:])]),
                                ]))),
                    ]),
            ]
            let theme = model.themeStore
            theme.apply(
                spec: .object([
                    "colors": .object([
                        "bg": .string("#FFFFFF"), "primary": .string("#FF0000"),
                        "surface": .string("#00FF00"), "text": .string("#000000"),
                        "muted": .string("#000000"),
                    ])
                ]))
            for width in [390, 900] {
                let view = NSHostingView(
                    rootView: MacWorkbenchTranscript(
                        maximumWidth: 720, contentPadding: EdgeInsets(top: 28, leading: 28, bottom: 28, trailing: 28)
                    ).background(theme.palette.bg).environment(model).environment(theme))
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "Workbench bubbles \(UUID().uuidString)"
                window.appearance = NSAppearance(named: model.themeStore.colorScheme == .dark ? .darkAqua : .aqua)
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                try await settle()
                let snapshot = WorkbenchAccessibility.snapshot(windowTitle: window.title)
                let elements = try XCTUnwrap(snapshot, "Missing test window in the accessibility tree").elements
                for (id, speaker, content) in [
                    ("question", "You", "Short question"), ("answer", "AstralDeep", "Short answer"),
                ] {
                    let bubble = try XCTUnwrap(
                        elements.first { $0.identifier == "conversation-turn-\(id)" })
                    XCTAssertEqual(bubble.label, speaker)
                    XCTAssertTrue(
                        bubble.elements.contains {
                            $0.value == content || $0.label == content
                        })
                    if id == "answer" {
                        XCTAssertTrue(
                            bubble.elements.contains {
                                $0.role == kAXButtonRole && $0.label == "View result"
                            })
                    }
                }
                let text = try recognizedText(view)
                XCTAssertFalse(text.contains("You"))
                XCTAssertFalse(text.contains("AstralDeep"))
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let question = try XCTUnwrap(bubbleBounds(bitmap, user: true), "Missing user bubble fill")
                let answer = try XCTUnwrap(bubbleBounds(bitmap, user: false), "Missing assistant bubble fill")
                let midpoint = CGFloat(bitmap.pixelsWide) / 2
                XCTAssertGreaterThan(question.midX, midpoint)
                XCTAssertLessThan(answer.midX, midpoint)
                XCTAssertFalse(question.intersects(answer))
                XCTAssertGreaterThan(question.width, 80)
                XCTAssertGreaterThan(answer.width, 80)
                XCTAssertGreaterThan(question.minX, 0)
                XCTAssertLessThan(question.maxX, CGFloat(bitmap.pixelsWide))
                XCTAssertGreaterThan(answer.minX, 0)
                XCTAssertLessThan(answer.maxX, CGFloat(bitmap.pixelsWide))
                try attach(view, name: "transcript-bubbles-\(width)")
            }
        }

        func testLocalComputerControlsWorkWithoutServerChromeAndRemainDistributionGated() async throws {
            for available in [true, false] {
                let suite = "MacWorkbenchViewTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
                let host = MacComputerHost(
                    available: available, defaults: defaults,
                    permissionProvider: {
                        MacComputerPermissions(accessibility: false, screen: false, monitoring: false)
                    })
                let view = NSHostingView(rootView: MacComputerAccessButton(host: host).environment(ThemeStore()))
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                try await settle()
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type, location: CGPoint(x: 240, y: 22), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                try await settle()
                XCTAssertEqual(host.controlsPresented, available)
                XCTAssertFalse(host.enabled)
            }
        }

        func testActivityPanelShowsToolRowsBesideTheConversationWithoutASheet() async throws {
            let (model, suite) = try activityModel()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let entries = MacTranscriptEntry.build(turns: model.visibleTurns, activity: model.activity)
            XCTAssertEqual(entries.map(\.id), ["u", "tool-steps-1", "a"])
            let (view, window) = try mountWorkbench(model, width: 1440, activity: true)
            defer { window.close() }
            try await settle()
            XCTAssertNil(window.attachedSheet)
            let lines = try recognizedLines(view)
            let text = lines.joined(separator: "\n")
            for expected in ["Activity", "Approval waiting", "Exit 0", "Open TextEdit and type", "Finished typing"] {
                XCTAssertTrue(text.contains(expected), "Missing \(expected) in \(lines)")
            }
            XCTAssertGreaterThanOrEqual(lines.filter { $0.contains("notes.txt") }.count, 2, "\(lines)")
            XCTAssertFalse(text.contains("No activity"))
            try attach(view, name: "workbench-activity-panel")
            let (compact, compactWindow) = try mountWorkbench(model, width: 390, activity: true)
            defer { compactWindow.close() }
            try await settle()
            XCTAssertTrue(try recognizedText(compact).contains("notes.txt"))
            try attach(compact, name: "workbench-activity-panel-overlay")
        }

        func testActivityRowsAndToggleKeepAccessibleLabelsAndValues() async throws {
            let (model, suite) = try activityModel()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let (_, window, _) = try mount(model, width: 1440)
            defer { window.close() }
            try await settle()
            let initial = try XCTUnwrap(
                WorkbenchAccessibility.snapshot(windowTitle: window.title),
                "Missing test window in the accessibility tree")
            let toggle = try XCTUnwrap(initial.elements.first { $0.identifier == "workbench-activity-toggle" })
            XCTAssertEqual(toggle.label, "Activity")
            XCTAssertEqual(toggle.value, "Hidden")
            XCTAssertNil(initial.elements.first { $0.identifier == "workbench-activity-panel" })
            let inline = try XCTUnwrap(initial.elements.first { $0.identifier == "conversation-tool-step-command" })
            XCTAssertEqual(inline.label, "run command, wc -l notes.txt")
            XCTAssertEqual(inline.value, "Done, Exit 0")
            XCTAssertTrue(
                WorkbenchAccessibility.press(identifier: "workbench-activity-toggle", windowTitle: window.title))
            try await settle()
            let elements = try XCTUnwrap(WorkbenchAccessibility.snapshot(windowTitle: window.title)).elements
            XCTAssertNotNil(elements.first { $0.identifier == "workbench-activity-panel" })
            XCTAssertNotNil(elements.first { $0.identifier == "chat-composer-input" })
            let click = try XCTUnwrap(elements.first { $0.identifier == "activity-row-step-click" })
            XCTAssertEqual(click.label, "click, at 10, 20")
            XCTAssertEqual(click.value, "Approval waiting, Running")
            XCTAssertEqual(elements.first { $0.identifier == "workbench-activity-close" }?.label, "Hide activity")
            XCTAssertTrue(
                WorkbenchAccessibility.press(identifier: "workbench-activity-close", windowTitle: window.title))
            try await settle()
            XCTAssertNil(
                WorkbenchAccessibility.snapshot(windowTitle: window.title)?.elements.first {
                    $0.identifier == "workbench-activity-panel"
                })
        }

        func testCutCopyStaysOffTheWorkbenchAndTheCanvasHeaderShowsTheResultTitle() async throws {
            let (model, suite) = try panelModel()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            model.outboundTap = { _ in }
            model.history = []
            model.historyLoaded = true
            model.activeChatId = "copy-chat"
            model.workspaceStarted = true
            model.consoleDashboardVisible = false
            model.turns = [.init(id: "u", role: "user", text: "Summarize the rolls")]
            model.canvas = [
                try XCTUnwrap(
                    AstralComponent(
                        json: .object([
                            "type": .string("card"), "component_id": .string("copy-result"),
                            "title": .string("Roll Summary"), "source_agent": .string("dice"),
                            "content": .array([.object(["type": .string("text"), "content": .string("Total 18")])]),
                        ])))
            ]
            XCTAssertEqual(model.consoleResultTitle, "Roll Summary")
            XCTAssertEqual(model.consoleResultAgent, "Dice Roller")
            XCTAssertEqual(model.consoleResultAccessibilityLabel, "Roll Summary, Dice Roller")
            let (view, window) = try mountWorkbench(model, width: 1440, activity: true)
            defer { window.close() }
            try await settle()
            let lines = try recognizedLines(view)
            let text = lines.joined(separator: "\n")
            XCTAssertGreaterThanOrEqual(lines.filter { $0.contains("Roll Summary") }.count, 2, "\(lines)")
            for cut in [
                "AstralDeep", "No chats", "No activity", "Interface", "Specialist", "Click to interact",
                "Multi-agent orchestrator and server-driven UI workspace", "Ask anything", "How can I help?",
                "More examples", "Your generated interface appears here",
            ] {
                XCTAssertFalse(text.contains(cut), "Unexpected cut copy: \(cut)")
            }
            try attach(view, name: "workbench-cut-copy")
            model.canvas = [
                AstralComponent(
                    type: "text", raw: .object(["content": .string("Untitled"), "source_agent": .string("dice")]))
            ]
            XCTAssertEqual(model.consoleResultTitle, "Dice Roller")
            XCTAssertEqual(model.consoleResultAccessibilityLabel, "Dice Roller")
            model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Untitled")]))]
            XCTAssertEqual(model.consoleResultTitle, "")
            XCTAssertEqual(model.consoleResultAccessibilityLabel, "Canvas")
        }

        func testStopAppearsOnlyDuringAComputerTaskAndCancelsTheTurnWithTheSession() async throws {
            let computer = try MacComputerLifecycleFixture()
            defer { computer.close() }
            let suite = "MacWorkbenchViewTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults, computerHost: computer.host)
            model.signedIn = true
            model.connected = true
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(fixture("chrome-console")))
            model.activeChatId = "stop-chat"
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            try computer.enable()
            let (view, window) = try mountWorkbench(model, width: 1440, activity: false)
            defer { window.close() }
            try await settle()
            XCTAssertNil(try stopControl(view))
            computer.host.consume(try computer.session())
            XCTAssertEqual(computer.host.session?.state, "active")
            model.turnActive = true
            try await settle()
            let stop = try XCTUnwrap(try stopControl(view))
            try attach(view, name: "workbench-stop")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(
                    try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type, location: stop, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            try await settle()
            XCTAssertNil(computer.host.session)
            XCTAssertEqual(sent.filter { $0["action"] == .string("cancel_task") }.count, 1)
            XCTAssertNil(try stopControl(view))
        }

        func testEscapeCancelsOnlyOutsideTextEditingSheetsAndBlockedSurfaces() throws {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            let container = NSView(frame: window.contentLayoutRect)
            container.addSubview(field)
            window.contentView = container
            window.orderBack(nil)
            defer { window.close() }
            func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) throws
                -> NSEvent
            {
                try XCTUnwrap(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: (target ?? window).windowNumber, context: nil, characters: "\u{1b}",
                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: code))
            }
            var cancels = 0
            let cancel: () -> Bool = {
                cancels += 1
                return true
            }
            let escape = try key(53)
            XCTAssertNil(MacWorkbenchEscapeMonitor.consume(escape, in: window, blocked: false, cancel: cancel))
            XCTAssertEqual(cancels, 1)
            XCTAssertNotNil(MacWorkbenchEscapeMonitor.consume(escape, in: window, blocked: true, cancel: cancel))
            XCTAssertNotNil(MacWorkbenchEscapeMonitor.consume(escape, in: nil, blocked: false, cancel: cancel))
            XCTAssertNotNil(
                MacWorkbenchEscapeMonitor.consume(try key(53, .shift), in: window, blocked: false, cancel: cancel))
            XCTAssertNotNil(MacWorkbenchEscapeMonitor.consume(try key(36), in: window, blocked: false, cancel: cancel))
            XCTAssertNotNil(MacWorkbenchEscapeMonitor.consume(escape, in: window, blocked: false) { false })
            XCTAssertEqual(cancels, 1)
            XCTAssertTrue(window.makeFirstResponder(field))
            XCTAssertNil(MacWorkbenchEscapeMonitor.consume(escape, in: window, blocked: false, cancel: cancel))
            XCTAssertEqual(cancels, 2)
            field.string = "Unsent draft"
            XCTAssertNotNil(MacWorkbenchEscapeMonitor.consume(escape, in: window, blocked: false, cancel: cancel))
            field.string = ""
            field.setMarkedText(
                "か", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: 0, length: 0))
            XCTAssertTrue(field.hasMarkedText())
            XCTAssertNotNil(MacWorkbenchEscapeMonitor.consume(escape, in: window, blocked: false, cancel: cancel))
            field.unmarkText()
            let other = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
                defer: false)
            other.isReleasedWhenClosed = false
            other.orderBack(nil)
            defer { other.close() }
            XCTAssertNotNil(
                MacWorkbenchEscapeMonitor.consume(try key(53, in: other), in: window, blocked: false, cancel: cancel))
            XCTAssertEqual(cancels, 2)
        }

        func testBrowserPaneTakesTheCanvasSlotWhenPresentedAndSignOutUnbindsIt() async throws {
            let (model, suite) = try panelModel()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            model.outboundTap = { _ in }
            model.activeChatId = "browser-chat"
            model.workspaceStarted = true
            model.consoleDashboardVisible = false
            model.turns = [.init(id: "u", role: "user", text: "Open the fixture page")]
            model.canvas = [
                AstralComponent(
                    type: "card",
                    raw: .object([
                        "type": .string("card"), "component_id": .string("browser-result"), "title": .string("Notes"),
                        "content": .array([.object(["type": .string("text"), "content": .string("Kept result")])]),
                    ]))
            ]
            XCTAssertFalse(model.macBrowser.isEnabled)
            model.macBrowser.setPaneEnabled(true)
            XCTAssertFalse(model.macBrowser.isEnabled)
            model.macBrowser.bind(owner: "browser-owner")
            model.macBrowser.setPaneEnabled(true)
            XCTAssertTrue(model.macBrowser.isEnabled)
            let (view, window) = try mountWorkbench(model, width: 1440, activity: false)
            defer { window.close() }
            try await settle()
            let webView = model.macBrowser.pane.webView
            XCTAssertNil(webView.window)
            XCTAssertTrue(try recognizedText(view).contains("Kept result"))
            model.macBrowser.isPresented = true
            try await settle()
            XCTAssertTrue(webView.window === window)
            XCTAssertFalse(try recognizedText(view).contains("Kept result"))
            try attach(view, name: "workbench-browser-slot")
            model.macBrowser.isPresented = false
            try await settle()
            XCTAssertNil(webView.window)
            XCTAssertTrue(try recognizedText(view).contains("Kept result"))
            model.macBrowser.isPresented = true
            window.close()
            await model.signOut(revokeRemote: false)
            XCTAssertFalse(model.macBrowser.accountBound)
            XCTAssertFalse(model.macBrowser.isEnabled)
            XCTAssertFalse(model.macBrowser.isPresented)
            XCTAssertTrue(model.activityLog.isEmpty)
        }

        private func activityModel() throws -> (AppModel, String) {
            let (model, suite) = try panelModel()
            model.outboundTap = { _ in }
            model.activeChatId = "activity-chat"
            model.workspaceStarted = true
            model.consoleDashboardVisible = false
            model.turns = [.init(id: "u", role: "user", text: "Open TextEdit and type")]
            for frame in [
                ActivityFrames.step(
                    "step-click", chat: "activity-chat", status: "in_progress",
                    arguments: #"{"x":10,"y":20,"hwnd":5}"#),
                ActivityFrames.step(
                    "step-click", chat: "activity-chat", status: "completed",
                    result: #"{"_data":{"status":"confirmation_required"}}"#),
                ActivityFrames.step(
                    "step-command", chat: "activity-chat", name: "run_command", status: "in_progress",
                    arguments: #"{"command":"wc -l notes.txt"}"#),
                ActivityFrames.step(
                    "step-command", chat: "activity-chat", name: "run_command", status: "completed",
                    result: #"{"exit_code":0,"stdout":"3 notes.txt"}"#),
            ] {
                model.handleFrame(frame)
            }
            model.turns.append(.init(id: "a", role: "assistant", text: "Finished typing"))
            return (model, suite)
        }

        private func mount(_ model: AppModel, width: Int) throws -> (NSHostingView<MountView>, NSWindow, MountState) {
            let state = try MountState(model: model, fixture: fixture("mac-workbench"))
            state.width = width
            let view = NSHostingView(rootView: MountView(state: state))
            return (view, host(view, model: model, width: width), state)
        }

        private func mountWorkbench(_ model: AppModel, width: Int, activity: Bool) throws -> (
            NSHostingView<AnyView>, NSWindow
        ) {
            let state = try MountState(model: model, fixture: fixture("mac-workbench"))
            state.width = width
            let console = try XCTUnwrap(model.console)
            let presentation = try XCTUnwrap(model.consolePresentation)
            let view = NSHostingView(
                rootView: AnyView(
                    MacWorkbenchView(
                        console: console, presentation: presentation, workbench: try XCTUnwrap(presentation.workbench),
                        activityPresented: activity
                    )
                    .environment(model).environment(model.themeStore)
                    .font(ConsoleTypography.body).tint(model.themeStore.palette.primary)
                    .preferredColorScheme(model.themeStore.colorScheme)))
            return (view, host(view, model: model, width: width))
        }

        private func host(_ view: NSView, model: AppModel, width: Int) -> NSWindow {
            let window = WorkbenchMountWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Workbench mount \(UUID().uuidString)"
            window.appearance = NSAppearance(named: model.themeStore.colorScheme == .dark ? .darkAqua : .aqua)
            window.contentView = view
            window.orderBack(nil)
            return window
        }

        private func recognizedLines(_ view: NSView) throws -> [String] {
            try recognizedText(view).components(separatedBy: "\n")
        }

        private func stopControl(_ view: NSView) throws -> CGPoint? {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            var found: CGRect?
            for y in 0..<Int(56 * scale) {
                for x in stride(from: bitmap.pixelsWide / 2, to: bitmap.pixelsWide, by: 1) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.redComponent > color.greenComponent + 0.25,
                        color.redComponent > color.blueComponent + 0.2
                    else { continue }
                    let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                    found = found.map { $0.union(pixel) } ?? pixel
                }
            }
            return found.map { CGPoint(x: $0.midX / scale, y: view.bounds.height - $0.midY / scale) }
        }

        private func bubbleBounds(_ bitmap: NSBitmapImageRep, user: Bool) -> CGRect? {
            var result: CGRect?
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let matches =
                        user
                        ? color.redComponent > color.greenComponent + 0.08
                            && color.redComponent > color.blueComponent + 0.08
                        : color.greenComponent > color.redComponent + 0.08
                            && color.greenComponent > color.blueComponent + 0.08
                    if matches {
                        let pixel = CGRect(x: x, y: y, width: 2, height: 2)
                        result = result.map { $0.union(pixel) } ?? pixel
                    }
                }
            }
            return result
        }

        private func panelModel() throws -> (AppModel, String) {
            let suite = "MacWorkbenchViewTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.signedIn = true
            model.connected = true
            model.bindConversationAccount(
                try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "workbench-owner")))
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(fixture("chrome-console")))
            return (model, suite)
        }

        private func panel<Content: View>(_ content: Content, model: AppModel, width: CGFloat) -> (
            NSHostingView<AnyView>, NSWindow
        ) {
            let view = NSHostingView(
                rootView: AnyView(
                    content.environment(model).environment(model.themeStore)
                        .font(ConsoleTypography.body).tint(model.themeStore.palette.primary)
                        .preferredColorScheme(model.themeStore.colorScheme)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Workbench panel \(UUID().uuidString)"
            window.appearance = NSAppearance(named: model.themeStore.colorScheme == .dark ? .darkAqua : .aqua)
            window.contentView = view
            window.orderBack(nil)
            return (view, window)
        }

        private func recognizedText(_ view: NSView) throws -> String {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }

        private func fixture(_ name: String) throws -> JSONValue {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
            return try JSONValue.parse(Data(contentsOf: url))
        }

        private func settle() async throws {
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(50)) }
        }

        private func charts(_ view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(charts)
        }

        private func attach(_ view: NSView, name: String) throws {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        private func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }

        private func readyChart(_ view: NSView) async throws -> WKWebView {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if let chart = charts(view).first,
                    (try? await chart.evaluateJavaScript(
                        "typeof Plotly !== 'undefined' && !!document.getElementById('chart').layout"))
                        as? Bool == true
                {
                    return chart
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "MacWorkbenchViewTests", code: 1)
        }
    }

    private final class WorkbenchMountWindow: NSWindow {
        // Ordering a window on screen clamps it to the display, and hosted runners have a 1024-point display.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    @MainActor
    private enum WorkbenchAccessibility {
        struct Element: Sendable {
            let identifier: String?
            let label: String?
            let value: String?
            let help: String?
            let role: String?
            let children: [Element]
            nonisolated var elements: [Element] { [self] + children.flatMap(\.elements) }
        }

        static func snapshot(windowTitle: String) -> Element? {
            guard let window = window(title: windowTitle) else { return nil }
            return snapshot(window, depth: 0)
        }

        static func press(identifier: String, windowTitle: String) -> Bool {
            guard let window = window(title: windowTitle),
                let element = find(identifier, in: window, depth: 0)
            else { return false }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }

        private static func window(title: String) -> AXUIElement? {
            let application = AXUIElementCreateApplication(getpid())
            let windows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] ?? []
            return windows.first { attribute(kAXTitleAttribute, of: $0) as? String == title }
        }

        private static func snapshot(_ element: AXUIElement, depth: Int) -> Element {
            Element(
                identifier: attribute(kAXIdentifierAttribute, of: element) as? String,
                label: attribute(kAXDescriptionAttribute, of: element) as? String
                    ?? attribute(kAXTitleAttribute, of: element) as? String,
                value: attribute(kAXValueAttribute, of: element) as? String,
                help: attribute(kAXHelpAttribute, of: element) as? String,
                role: attribute(kAXRoleAttribute, of: element) as? String,
                children: depth < 64 ? children(of: element).map { snapshot($0, depth: depth + 1) } : [])
        }

        private static func find(_ identifier: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
            if attribute(kAXIdentifierAttribute, of: element) as? String == identifier { return element }
            guard depth < 64 else { return nil }
            return children(of: element).lazy.compactMap { find(identifier, in: $0, depth: depth + 1) }.first
        }

        private static func children(of element: AXUIElement) -> [AXUIElement] {
            attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
        }

        private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
    }

    @MainActor @Observable
    private final class MountState {
        let model: AppModel
        let presentations: [Int: JSONValue]
        var width = 1440 {
            didSet { applyPresentation() }
        }

        init(model: AppModel, fixture: JSONValue) throws {
            self.model = model
            presentations = Dictionary(
                uniqueKeysWithValues: try (fixture["cases"]?.arrayValue ?? []).map { row in
                    (
                        Int(try XCTUnwrap(row["viewport"]?.arrayValue?.first?.numberValue)),
                        try XCTUnwrap(row["presentation"])
                    )
                })
            applyPresentation()
        }

        private func applyPresentation() {
            let value: JSONValue = .object([
                "type": .string("rote_config"),
                "device_profile": .object(["console": presentations[width]!]),
            ])
            model.handleFrame(InboundFrame.parse(String(data: try! value.encoded(), encoding: .utf8)!)!)
        }
    }

    private struct MountView: View {
        let state: MountState
        var body: some View {
            RootView()
                .environment(state.model).environment(state.model.themeStore)
                .font(ConsoleTypography.body).tint(state.model.themeStore.palette.primary)
                .preferredColorScheme(state.model.themeStore.colorScheme)
        }
    }
#endif
