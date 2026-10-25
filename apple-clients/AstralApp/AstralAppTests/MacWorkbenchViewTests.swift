// Exercises the native workbench with the shared server fixtures and persistent generated charts.

#if os(macOS)
    import AppKit
    import AstralCore
    import Observation
    import SwiftUI
    import Vision
    import WebKit
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacWorkbenchViewTests: XCTestCase {
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
                if width == 1440 {
                    let chat = try XCTUnwrap(
                        accessibilityElements(view).first {
                            $0.accessibilityIdentifier() == "workbench-chat-earlier-chat"
                        })
                    XCTAssertEqual(chat.accessibilityValue() as? String, "Preview details, Yesterday")
                }
                let choice = try XCTUnwrap(
                    accessibilityElements(view).first { $0.accessibilityIdentifier() == "workbench-scenario-dice" })
                XCTAssertEqual(choice.accessibilityLabel(), "Load prompt: Roll dice")
                XCTAssertTrue(choice.accessibilityPerformPress())
                try await settle()
                XCTAssertEqual(model.composerDraft, "Roll six dice")
                XCTAssertFalse(sent.contains { $0["action"]?.stringValue == "chat_message" })
                try attach(view, name: "workbench-direct-choices-\(width)")
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
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                try await settle()
                let elements = accessibilityElements(view)
                for (id, speaker, content) in [
                    ("question", "You", "Short question"), ("answer", "AstralDeep", "Short answer"),
                ] {
                    let bubble = try XCTUnwrap(
                        elements.first { $0.accessibilityIdentifier() == "conversation-turn-\(id)" })
                    XCTAssertEqual(bubble.accessibilityLabel(), speaker)
                    XCTAssertTrue(
                        accessibilityElements(bubble).contains {
                            $0.accessibilityValue() as? String == content || $0.accessibilityLabel() == content
                        })
                    if id == "answer" {
                        XCTAssertTrue(
                            accessibilityElements(bubble).contains {
                                $0.accessibilityRole() == .button && $0.accessibilityLabel() == "View result"
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

        private func accessibilityElements(_ object: Any) -> [any NSAccessibilityProtocol] {
            guard let element = object as? any NSAccessibilityProtocol else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap(accessibilityElements)
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
        }
    }
#endif
