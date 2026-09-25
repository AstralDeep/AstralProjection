// Qualifies server-fixture console layouts and result continuity in isolated native test hosts.
// Captured views exercise the same ConsoleShell and live chart renderer used by the signed-in app.

import AstralCore
import Observation
import SwiftUI
import Vision
import WebKit
import XCTest

@testable import AstralDeep

@MainActor
final class ConsoleShellPresentationTests: XCTestCase {
    private var suites: [String] = []

    private func fixture(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(
            Bundle(for: ConsoleShellPresentationTests.self).url(forResource: name, withExtension: "json"))
        return try JSONValue.parse(Data(contentsOf: url))
    }

    private func presentation(width: Int) throws -> (ConsolePresentation, CGSize) {
        let row = try XCTUnwrap(
            try fixture("rote-console")["cases"]?.arrayValue?.first {
                $0["viewport"]?.arrayValue?.first?.numberValue == Double(width)
            })
        let height = try XCTUnwrap(row["viewport"]?.arrayValue?.last?.numberValue)
        return (
            try XCTUnwrap(ConsolePresentation(json: row["presentation"])), CGSize(width: width, height: Int(height))
        )
    }

    private func model(tokenStore: InMemoryTokenStore = InMemoryTokenStore(), server: URL? = nil) throws -> AppModel {
        let suite = "ConsoleShellPresentationTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        if let server { defaults.set(server.absoluteString, forKey: "serverBase") }
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults),
            tokenStore: tokenStore, defaults: defaults)
        model.signedIn = true
        model.connected = true
        model.bindConversationAccount(
            ConversationAccount(issuer: "https://iam.example.test", subject: "console-owner")!)
        model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(fixture("chrome-console")))
        model.screen = .chat
        model.composerDraft = "Keep this unfinished prompt"
        return model
    }

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    private func startConversation(_ model: AppModel, chart: Bool = false) throws {
        model.activeChatId = "console-reference-chat"
        model.turns = [
            .init(id: "user-turn", role: "user", text: "Roll six dice"),
            .init(id: "assistant-turn", role: "assistant", text: "The six rolls total 16."),
        ]
        let raw =
            chart
            ? #"{"type":"bar_chart","component_id":"stable-result","title":"Six rolls","labels":["1","2","3"],"datasets":[{"label":"Roll","data":[2,5,3]}]}"#
            : #"{"type":"card","component_id":"stable-result","title":"Dice roll results","content":[{"type":"metric","title":"Total","value":16},{"type":"text","content":"Synthetic reference result"}]}"#
        model.canvas = [try XCTUnwrap(AstralComponent(json: JSONValue.parse(Data(raw.utf8))))]
        model.workspaceStarted = true
        model.consoleDashboardVisible = false
    }

    func testServerLayoutsRenderDashboardConversationCollapseAndFullscreenAtReferenceWidths() async throws {
        for width in [320, 390, 768, 1440] {
            let model = try model()
            let (presentation, size) = try presentation(width: width)
            let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
            defer { host.close() }
            try await host.settle()
            let landing = try attach(host, name: "console-landing-\(width)")
            try startConversation(model)
            let canvas = model.canvas
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            try await host.settle()
            let conversation = try attach(host, name: "console-result-\(width)")
            XCTAssertNotEqual(landing, conversation)
            model.consoleResultCollapsed = true
            try await host.settle()
            let collapsed = try attach(host, name: "console-collapsed-\(width)")
            XCTAssertNotEqual(conversation, collapsed)
            model.consoleFullscreen = true
            try await host.settle()
            let fullscreen = try attach(host, name: "console-fullscreen-\(width)")
            XCTAssertNotEqual(collapsed, fullscreen)
            model.consoleFullscreen = false
            model.consoleResultCollapsed = false
            model.showConsoleDashboard()
            try await host.settle()
            _ = try attach(host, name: "console-returned-dashboard-\(width)")
            XCTAssertEqual(model.activeChatId, "console-reference-chat")
            XCTAssertEqual(model.composerDraft, "Keep this unfinished prompt")
            XCTAssertEqual(model.canvas, canvas)
            XCTAssertEqual(model.workspaceCanvas.map(\.componentId), ["stable-result"])
            XCTAssertFalse(
                sent.contains { ["chat_message", "component_action"].contains($0["action"]?.stringValue ?? "") })
        }
    }

    func testEnlargedTextAndDrawerRenderAtPhoneAndTabletWidths() async throws {
        for width in [320, 390, 768] {
            let model = try model()
            let (presentation, size) = try presentation(width: width)
            let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
            defer { host.close() }
            host.state.textSize = .accessibility3
            try await host.settle()
            let dashboard = try attach(host, name: "console-large-text-\(width)")
            model.consoleDrawerOpen = true
            try await host.settle()
            let drawer = try attach(host, name: "console-drawer-large-text-\(width)")
            XCTAssertNotEqual(dashboard, drawer)
            model.consoleDrawerOpen = false
            try startConversation(model)
            model.consoleFullscreen = true
            try await host.settle()
            _ = try attach(host, name: "console-fullscreen-large-text-\(width)")
            XCTAssertEqual(model.workspaceCanvas.map(\.componentId), ["stable-result"])
        }
    }

    func testOneLiveChartKeepsIdentityDocumentAndZoomAcrossPresentationTransitions() async throws {
        let model = try model()
        try startConversation(model, chart: true)
        let (presentation, size) = try presentation(width: 390)
        let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
        defer { host.close() }
        let chart = try await host.readyChart()
        let initialOrigin = try await chart.evaluateJavaScript("performance.timeOrigin")
        let origin = try XCTUnwrap(initialOrigin as? Double)
        _ = try await chart.evaluateJavaScript("Plotly.relayout('chart', {'yaxis.range': [1, 4]}); true")
        for state in ["collapsed", "fullscreen", "preview", "dashboard", "returned", "resized"] {
            switch state {
            case "collapsed": model.consoleResultCollapsed = true
            case "fullscreen": model.consoleFullscreen = true
            case "preview":
                model.consoleFullscreen = false
                model.consoleResultCollapsed = false
            case "dashboard": model.showConsoleDashboard()
            case "returned": model.consoleDashboardVisible = false
            default:
                let (widePresentation, wideSize) = try self.presentation(width: 1440)
                host.resize(presentation: widePresentation, size: wideSize)
            }
            try await host.settle()
            let current = host.charts()
            XCTAssertEqual(current.count, 1, state)
            XCTAssertTrue(current.first === chart, state)
            let nextOrigin = try await chart.evaluateJavaScript("performance.timeOrigin") as? Double
            XCTAssertEqual(nextOrigin, origin, state)
            let range =
                try await chart.evaluateJavaScript("document.getElementById('chart').layout.yaxis.range") as? [Double]
            XCTAssertEqual(range, [1, 4], state)
            XCTAssertEqual(model.workspaceCanvas.map(\.componentId), ["stable-result"], state)
        }
    }

    #if os(macOS)
        func testConsoleShareControlsHandleSuccessRefusalAndLateOwnerChange() async throws {
            let peer = try WorkspaceActionLoopback(
                replies: [
                    .share: [
                        .init(status: 201), .init(status: 403, error: "phi_blocked"),
                        .init(status: 503, error: "unavailable"), .init(status: 201, held: true),
                    ]
                ], supportsWebSocket: true)
            peer.start()
            defer { peer.stop() }
            await fulfillment(of: [peer.ready], timeout: 5)
            let store = InMemoryTokenStore()
            store.save(
                StoredTokens(
                    from: TokenSet(accessToken: WorkspaceActionLoopback.token, refreshToken: nil, expiresIn: 3600)))
            let server = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(peer.port))"))
            let model = try model(tokenStore: store, server: server)
            await model.bootstrap()
            for _ in 0..<100 where peer.registrations == 0 { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(peer.registrations, 1)
            var menu = try XCTUnwrap(try fixture("chrome-console").objectValue)
            menu["topbar"] = .array(
                (menu["topbar"]?.arrayValue ?? []) + [
                    .object([
                        "key": .string("share"), "kind": .string("workspace_action"),
                        "label": .string("Share page"), "icon": .string("share"),
                        "operation": .string("share_canvas"), "context": .string("live_canvas"),
                    ])
                ])
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(.object(menu)))
            try startConversation(model)
            model.activeChatId = WorkspaceActionLoopback.chat
            let (presentation, size) = try presentation(width: 1440)
            let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
            defer { host.close() }
            try await host.settle()
            XCTAssertNotNil(model.workspaceActionContext(for: .shareCanvas))
            _ = try attach(host, name: "Console workspace share controls")
            for expected in [
                "Share link copied to clipboard.", "Sharing refused: the content matched the PHI gate.",
                "Couldn't create the share link.",
            ] {
                model.errorBanner = nil
                let title = try XCTUnwrap(host.recognizedText().first { $0.text == model.consoleResultTitle })
                host.click(CGPoint(x: size.width - 76, y: title.bounds.midY * size.height))
                for _ in 0..<50 where model.errorBanner == nil { try await Task.sleep(for: .milliseconds(50)) }
                XCTAssertEqual(model.errorBanner, expected)
            }
            model.errorBanner = nil
            let title = try XCTUnwrap(host.recognizedText().first { $0.text == model.consoleResultTitle })
            host.click(CGPoint(x: size.width - 76, y: title.bounds.midY * size.height))
            for _ in 0..<50 where peer.requests.count < 4 { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(peer.requests.count, 4)
            XCTAssertTrue(model.workspaceActionInFlight(.shareCanvas))
            model.bindConversationAccount(
                ConversationAccount(issuer: "https://iam.example.test", subject: "replacement-owner")!)
            try await host.settle()
            peer.releaseHeldReplies()
            try await host.settle()
            XCTAssertNil(model.errorBanner)
            XCTAssertFalse(model.workspaceActionInFlight(.shareCanvas))
            XCTAssertTrue(peer.unexpectedRequests.isEmpty)
        }

        func testComposerControlsStayCenteredAndAdjacentAcrossWindowWidths() async throws {
            for width in [320, 390, 768, 1440] {
                let model = try model()
                let (presentation, size) = try presentation(width: width)
                let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
                defer { host.close() }
                try await host.settle()
                let labels = ["Attach files", "Start voice conversation", "More options", "Send message"]
                for (index, label) in labels.enumerated() {
                    let cell = CGRect(
                        x: size.width - presentation.composerPadding.right - 194 + Double(index * 50),
                        y: size.height - presentation.composerPadding.bottom - 44, width: 44, height: 44)
                    let glyph = try XCTUnwrap(host.foregroundBounds(in: cell), "\(width): \(label)")
                    XCTAssertGreaterThan(glyph.width, 8, label)
                    XCTAssertLessThanOrEqual(glyph.width, 25, label)
                    XCTAssertLessThanOrEqual(glyph.height, 26, label)
                    XCTAssertEqual(glyph.midX, cell.midX, accuracy: 3, "\(width): \(label)")
                    XCTAssertEqual(glyph.midY, cell.midY, accuracy: 3, "\(width): \(label)")
                }
                _ = try attach(host, name: "console-composer-alignment-\(width)")
            }
        }

        func testSelectionDialogHasNoSettingsRailAndNotesRetainsSignout() async throws {
            for width in [320, 390, 768] {
                let model = try model()
                let (presentation, size) = try presentation(width: width)
                model.screen = .surface
                model.pendingSurfaceKey = "guidance"
                model.pendingSurfaceParams = .object(["view": .string("selection")])
                model.pendingSurface = .init(surfaceKey: "guidance", title: "Select guidance", components: [])
                let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
                defer { host.close() }
                try await host.settle()
                XCTAssertFalse(try host.recognizedText().contains { $0.text.contains("Sign out") })
                _ = try attach(host, name: "console-selection-dialog-\(width)")
                model.pendingSurfaceParams = .object(["mode": .string("list")])
                model.pendingSurface = .init(surfaceKey: "guidance", title: "Notes", components: [])
                try await host.settle()
                if presentation.settingsNavigationAxis == .horizontal {
                    XCTAssertTrue(host.scrollHorizontalNavigationToEnd())
                    try await host.settle()
                }
                XCTAssertTrue(try host.recognizedText().contains { $0.text.contains("Sign out") })
                _ = try attach(host, name: "console-notes-navigation-\(width)")
            }
        }

        func testSelectionSummaryClearUsesTheVisibleControlWithoutDispatch() async throws {
            let model = try model()
            let selection = try JSONValue.parse(
                Data(
                    #"{"version":1,"agent":null,"skills":[],"notes":[{"note_id":"33333333-3333-4333-8333-333333333333","revision":2}]}"#
                        .utf8))
            model.turnSelection = try XCTUnwrap(TurnSelection(json: selection))
            let (presentation, size) = try presentation(width: 390)
            let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
            defer { host.close() }
            try await host.settle()
            _ = try attach(host, name: "console-selection-summary-390")
            let summary = try XCTUnwrap(host.recognizedText().first { $0.text == "Using 1 note for this chat" })
            var sent: [String] = []
            model.outboundTap = { sent.append($0) }
            host.click(CGPoint(x: size.width - 30, y: summary.bounds.midY * size.height))
            try await host.settle()
            XCTAssertNil(model.turnSelection)
            XCTAssertFalse(try host.recognizedText().contains { $0.text.contains("Using 1 note") })
            XCTAssertTrue(sent.isEmpty)
        }
    #endif

    @discardableResult
    private func openIntro(_ model: AppModel) throws -> JSONValue {
        let intro = try fixture("agent-intro")
        model.screen = .surface
        model.pendingSurfaceKey = "agent_intro"
        model.pendingSurface = .init(
            surfaceKey: "agent_intro", title: intro["title"]!.stringValue!,
            components: AstralComponent.list(from: intro["components"]))
        return intro
    }

    func testAgentIntroductionUsesReferenceRowsAndReachableActionsAtEverySize() async throws {
        for width in [320, 390, 768, 1440] {
            let model = try model()
            try openIntro(model)
            let (presentation, size) = try presentation(width: width)
            let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
            defer { host.close() }
            try await host.settle()
            _ = try attach(host, name: "console-agent-intro-\(width)")
            XCTAssertEqual(model.pendingSurface?.subtitle, "What it does, and what to ask it")
            #if os(macOS)
                let rows = try host.recognizedText()
                XCTAssertTrue(rows.contains { $0.text.contains("What it does") })
                XCTAssertTrue(rows.contains { $0.text.contains("Permissions for this agent") })
                let title = try XCTUnwrap(rows.first { $0.text == "Six dice" })
                let run = try XCTUnwrap(rows.filter { $0.text == "Run" }.max { $0.bounds.midY < $1.bounds.midY })
                if presentation.settingsPresentation == .sheet {
                    XCTAssertLessThan(run.bounds.midY, title.bounds.midY)
                } else {
                    XCTAssertGreaterThan(run.bounds.minX, title.bounds.maxX)
                    XCTAssertLessThan(abs(run.bounds.midY - title.bounds.midY) * size.height, 45)
                }
            #endif
        }
    }

    func testAgentIntroductionHandlesLargeTextUnavailableStatusAndServerErrors() async throws {
        let model = try model()
        let (presentation, size) = try presentation(width: 390)
        try openIntro(model)
        let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
        defer { host.close() }
        host.state.textSize = .accessibility3
        try await host.settle()
        _ = try attach(host, name: "console-agent-intro-large-text")
        let error = try JSONValue.parse(
            Data(
                #"[{"type":"badge","label":"Turned off for this account","variant":"default"},{"type":"alert","message":"That agent isn't available to your account.","variant":"error"},{"type":"button","label":"Unavailable","disabled":true}]"#
                    .utf8))
        model.pendingSurface = .init(
            surfaceKey: "agent_intro", title: "Unavailable", components: AstralComponent.list(from: error))
        try await host.settle()
        XCTAssertNil(model.pendingSurface?.subtitle)
        _ = try attach(host, name: "console-agent-intro-unavailable")
    }

    #if os(macOS)
        func testAgentIntroVisibleLoadAndRunPreserveNormalComposerSemantics() async throws {
            let model = try model()
            try startConversation(model)
            let canvas = model.canvas
            let (presentation, size) = try presentation(width: 1440)
            let host = try ConsoleTestMount(model: model, presentation: presentation, size: size)
            defer { host.close() }
            var frames: [JSONValue] = []
            model.outboundTap = { frames.append(try! JSONValue.parse(Data($0.utf8))) }
            for label in ["Load", "Run"] {
                try openIntro(model)
                try await host.settle()
                let button = try XCTUnwrap(
                    host.recognizedText().filter { $0.text == label }
                        .max { $0.bounds.midY < $1.bounds.midY })
                host.click(CGPoint(x: button.bounds.midX * size.width, y: button.bounds.midY * size.height))
                try await host.settle()
                XCTAssertEqual(model.screen, .chat)
                if label == "Load" {
                    XCTAssertEqual(
                        model.composerDraft, "Roll exactly six six-sided dice and show the normalized results.")
                    XCTAssertEqual(model.canvas, canvas)
                    XCTAssertFalse(frames.contains { $0["action"]?.stringValue == "chat_message" })
                } else {
                    XCTAssertTrue(
                        frames.contains {
                            $0["action"]?.stringValue == "chat_message"
                                && $0["payload"]?["message"]?.stringValue
                                    == "Roll exactly six six-sided dice and show the normalized results."
                        })
                }
            }
        }
    #endif

    @discardableResult
    private func attach(_ host: ConsoleTestMount, name: String) throws -> Data {
        let image = try host.snapshot()
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        #if os(macOS)
            XCTAssertEqual(image.size, host.state.size)
            return try XCTUnwrap(image.tiffRepresentation)
        #else
            XCTAssertEqual(image.size, host.state.size)
            return try XCTUnwrap(image.pngData())
        #endif
    }
}

@MainActor
@Observable
private final class ConsoleTestState {
    var presentation: ConsolePresentation
    var size: CGSize
    var textSize = DynamicTypeSize.large

    init(presentation: ConsolePresentation, size: CGSize) {
        self.presentation = presentation
        self.size = size
    }
}

@MainActor
private struct ConsoleTestRoot: View {
    let state: ConsoleTestState
    let model: AppModel
    let theme: ThemeStore
    let console: ConsoleModel

    var body: some View {
        RootView()
            .environment(model).environment(theme)
            .environment(\.astralViewportWidth, state.size.width)
            .environment(\.dynamicTypeSize, state.textSize)
            .frame(width: state.size.width, height: state.size.height)
    }
}

@MainActor
private final class ConsoleTestMount {
    let state: ConsoleTestState
    let model: AppModel
    #if os(macOS)
        let window: NSWindow
        let view: NSHostingView<ConsoleTestRoot>
    #else
        let window: UIWindow
        let controller: UIHostingController<ConsoleTestRoot>
        var view: UIView { controller.view }
    #endif

    init(model: AppModel, presentation: ConsolePresentation, size: CGSize) throws {
        state = ConsoleTestState(presentation: presentation, size: size)
        self.model = model
        model.consolePresentation = presentation
        let root = ConsoleTestRoot(
            state: state, model: model, theme: ThemeStore(), console: try XCTUnwrap(model.console))
        #if os(macOS)
            window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            view = NSHostingView(rootView: root)
            window.contentView = view
            window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
            window.orderBack(nil)
        #else
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
            controller = UIHostingController(rootView: root)
            controller.safeAreaRegions = []
            window.rootViewController = controller
            window.isHidden = false
        #endif
        layout()
    }

    func resize(presentation: ConsolePresentation, size: CGSize) {
        state.presentation = presentation
        model.consolePresentation = presentation
        state.size = size
        #if os(macOS)
            window.setContentSize(size)
        #else
            window.frame.size = size
        #endif
        layout()
    }

    func layout() {
        #if os(macOS)
            view.layoutSubtreeIfNeeded()
        #else
            window.layoutIfNeeded()
            view.layoutIfNeeded()
        #endif
    }

    func settle() async throws {
        for _ in 0..<4 {
            layout()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func close() {
        #if os(macOS)
            window.contentView = nil
            window.close()
        #else
            window.isHidden = true
            window.rootViewController = nil
        #endif
    }

    func charts() -> [WKWebView] {
        #if os(macOS)
            func collect(_ view: NSView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(collect)
            }
        #else
            func collect(_ view: UIView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(collect)
            }
        #endif
        return collect(view)
    }

    #if os(macOS)
        func foregroundBounds(in cell: CGRect) throws -> CGRect? {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(snapshot().tiffRepresentation)))
            let scale = Double(bitmap.pixelsWide) / state.size.width
            var bounds = CGRect.null
            for y in Int(cell.minY * scale)..<Int(cell.maxY * scale) {
                for x in Int(cell.minX * scale)..<Int(cell.maxX * scale) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    let high = channels.max()!
                    let low = channels.min()!
                    if low > 0.27, high - low < 0.18 {
                        bounds = bounds.union(
                            CGRect(x: Double(x) / scale, y: Double(y) / scale, width: 1 / scale, height: 1 / scale))
                    }
                }
            }
            return bounds.isNull ? nil : bounds
        }

        func recognizedText() throws -> [(text: String, bounds: CGRect)] {
            let image = try XCTUnwrap(snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { result in
                result.topCandidates(1).first.map { (text: $0.string, bounds: result.boundingBox) }
            }
        }

        func scrollHorizontalNavigationToEnd() -> Bool {
            func collect(_ current: NSView) -> [NSScrollView] {
                (current as? NSScrollView).map { [$0] } ?? current.subviews.flatMap(collect)
            }
            guard
                let scroll = collect(view).first(where: {
                    $0.frame.height < 120 && ($0.documentView?.frame.width ?? 0) > $0.contentSize.width
                }), let document = scroll.documentView
            else { return false }
            scroll.contentView.scroll(to: CGPoint(x: document.frame.width - scroll.contentSize.width, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            return true
        }

        func click(_ location: CGPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                {
                    window.sendEvent(event)
                }
            }
        }
    #endif

    func readyChart() async throws -> WKWebView {
        for _ in 0..<100 {
            layout()
            if let chart = charts().first,
                (try? await chart.evaluateJavaScript("document.documentElement.dataset.chartState") as? String)
                    == "ready"
            {
                XCTAssertEqual(charts().count, 1)
                return chart
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(
            domain: "ConsoleShellPresentationTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Live result chart never mounted and became ready"])
    }

    #if os(macOS)
        func snapshot() throws -> NSImage {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: state.size)
            image.addRepresentation(bitmap)
            return image
        }
    #else
        func snapshot() throws -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: state.size, format: format).image { _ in
                XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
            }
        }
    #endif
}
