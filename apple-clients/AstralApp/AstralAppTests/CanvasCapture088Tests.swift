import AstralCore
import SwiftUI
import WebKit
import XCTest

@testable import AstralDeep

@MainActor
final class CanvasCapture088Tests: XCTestCase {
    private let png = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNITvv4HwAFpAK6buOwBAAAAABJRU5ErkJggg==")!

    private func component(_ text: String) throws -> AstralComponent {
        try XCTUnwrap(AstralComponent(json: JSONValue.parse(Data(text.utf8))))
    }

    private func registry() -> CanvasCaptureRegistry {
        let registry = CanvasCaptureRegistry()
        let scope = CanvasCaptureScope(
            owner: .init(account: nil, generation: 7, signedIn: true),
            server: URL(string: "https://fixture.test")!, chat: "synthetic")
        registry.currentScope = { scope }
        registry.setWindow(CGSize(width: 320, height: 900))
        registry.setCanvas(CGSize(width: 296, height: 600), palette: .midnight)
        return registry
    }

    func testRawPathsSelectedPaneAndClosedChildrenArePreservedWithoutPrivateMetadata() async throws {
        let registry = registry()
        let root = try component(
            #"{"type":"tabs","id":"tabs","_source_params":{"api_key":"PRIVATE"},"tabs":[{"label":"Hidden","content":[{"type":"image","url":"https://unloaded.invalid"}]},{"label":"Selected","_source_params":{"api_key":"PRIVATE"},"action":"PRIVATE","children":[{"type":"collapsible","id":"closed","children":[{"type":"image","url":"https://unloaded.invalid/2"}]},{"type":"image","id":"loaded","url":"https://private.invalid/token"},{"type":"table","headers":["Metadata"],"rows":[["Visible literal _source",{"_source":"PRIVATE"}]],"unrecognized_secret":"PRIVATE"}]}]}"#
        )
        let tabs = try XCTUnwrap(registry.node(path: "/components/0", component: root))
        registry.record(tabs, state: .array([.number(1)]))
        let selected = root.raw["tabs"]!.arrayValue![1]["children"]!.arrayValue!
        registry.record(
            registry.node(path: "/components/0/tabs/1/children/0", component: AstralComponent(json: selected[0])!),
            state: .bool(false))
        registry.retain(
            png,
            for: registry.node(path: "/components/0/tabs/1/children/1", component: AstralComponent(json: selected[1])!)!
        )
        let bytes = try await registry.capture([root], isCurrent: { true })
        let capture = try JSONValue.parse(bytes)
        let tree = capture["components"]!.arrayValue![0]
        XCTAssertEqual(tree["tabs"]!.arrayValue![0]["content"], .array([]))
        XCTAssertEqual(tree["tabs"]!.arrayValue![1]["children"]!.arrayValue![0]["children"], .array([]))
        XCTAssertEqual(capture["images"]!.arrayValue!.first?["path"]?.stringValue, "/components/0/tabs/1/children/1")
        XCTAssertEqual(capture["viewport"]?["width"], .number(296))
        XCTAssertEqual(capture["viewport"]?["window_width"], .number(320))
        XCTAssertEqual(capture["theme"]?.objectValue?.count, 13)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertFalse(text.contains("private.invalid"))
        XCTAssertTrue(text.contains("Visible literal"))
    }

    func testUnusedFieldsAndStructuredCellsNeverLeaveTheClient() async throws {
        let registry = registry()
        let source = try component(
            #"{"type":"container","children":[{"type":"text","content":"Visible literal _source_params","title":"PRIVATE","variant":"PRIVATE","attributes":["PRIVATE"],"headers":{"Authorization":"PRIVATE"},"data":{"secret":"PRIVATE"}},{"type":"list","items":["Visible item",{"token":"PRIVATE"}]},{"type":"table","headers":["Visible column"],"rows":[["Visible cell",{"Authorization":"PRIVATE"}]]},{"type":"keyvalue","items":[{"label":"Visible key","value":"Visible value","hint":"PRIVATE","headers":{"Authorization":"PRIVATE"}}]},{"type":"timeline","items":[{"title":"Visible event","description":"Visible detail","_source_params":{"key":"PRIVATE"}}]}]}"#
        )
        let bytes = try await registry.capture([source], isCurrent: { true })
        let text = String(decoding: bytes, as: UTF8.self)
        for expected in [
            "Visible literal _source_params", "Visible item", "Visible cell", "Visible key", "Visible value",
            "Visible event", "Visible detail",
        ] { XCTAssertTrue(text.contains(expected), expected) }
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertFalse(text.contains("Authorization"))
    }

    func testAuthoredStyleAndAmbiguousChildAliasesRefuseBeforePosting() async throws {
        for raw in [
            #"{"type":"text","content":"Visible","css":{"color":"red","hidden":"PRIVATE"}}"#,
            #"{"type":"container","content":[],"children":[{"type":"text","content":"Not displayed"}]}"#,
        ] {
            do {
                _ = try await registry().capture([component(raw)], isCurrent: { true })
                XCTFail("Unsupported presentation captured")
            } catch { XCTAssertTrue(error is CanvasCaptureError) }
        }
    }

    func testAggregateCaptureDeadlineStopsLaterProviders() async throws {
        let registry = registry()
        let first = try component(#"{"type":"bar_chart","id":"first"}"#)
        let second = try component(#"{"type":"bar_chart","id":"second"}"#)
        registry.register(registry.node(path: "/components/0", component: first)!, lease: UUID()) {
            try await Task.sleep(for: .milliseconds(20))
            return self.png
        }
        var laterCalls = 0
        registry.register(registry.node(path: "/components/1", component: second)!, lease: UUID()) {
            laterCalls += 1
            return self.png
        }
        do {
            _ = try await registry.capture([first, second], timeout: .milliseconds(5), isCurrent: { true })
            XCTFail("Expired capture returned")
        } catch { XCTAssertTrue(error is CanvasCaptureError) }
        XCTAssertEqual(laterCalls, 0)
    }

    func testImageUsesMeasuredBoxAndActualCaptionWhileDroppingAuthoredSize() async throws {
        let registry = registry()
        let image = try component(
            #"{"type":"image","caption":"Visible caption","alt":"Accessible image","width":9999,"height":8888,"title":"PRIVATE","url":"https://private.invalid"}"#
        )
        registry.retain(
            png, for: registry.node(path: "/components/0", component: image)!,
            imageSize: CGSize(width: 120.5, height: 80))
        let capture = try JSONValue.parse(await registry.capture([image], isCurrent: { true }))
        let display = try XCTUnwrap(capture["components"]?.arrayValue?.first)
        XCTAssertEqual(display["width"], .number(120.5))
        XCTAssertEqual(display["height"], .number(80))
        XCTAssertEqual(display["caption"], .string("Visible caption"))
        XCTAssertNil(display["title"])
    }

    func testUnseenImageAndStaleRawNodeCannotBorrowRetainedPixels() async throws {
        let registry = registry()
        let old = try component(#"{"type":"image","id":"same","url":"https://old.invalid"}"#)
        let next = try component(#"{"type":"image","id":"same","url":"https://new.invalid"}"#)
        registry.retain(png, for: registry.node(path: "/components/0", component: old)!)
        do {
            _ = try await registry.capture([next], isCurrent: { true })
            XCTFail("Borrowed stale pixels")
        } catch { XCTAssertTrue(error is CanvasCaptureError) }
        let misplaced = registry.node(path: "/components/1", component: old)!
        registry.retain(png, for: misplaced)
        registry.clear()
        do {
            _ = try await registry.capture([old], isCurrent: { true })
            XCTFail("Retained after clear")
        } catch { XCTAssertTrue(error is CanvasCaptureError) }
    }

    func testEffectiveGridColumnsAndCurrentPixelsReplaceRawChartSpec() async throws {
        let registry = registry()
        let root = try component(
            #"{"type":"grid","columns":4,"children":[{"type":"bar_chart","id":"c","datasets":[{"hidden_secret":"PRIVATE"}],"title":"Current plot"}]}"#
        )
        do {
            _ = try await registry.capture([root], isCurrent: { true })
            XCTFail("Unmeasured layout captured")
        } catch { XCTAssertTrue(error is CanvasCaptureError) }
        registry.record(registry.node(path: "/components/0", component: root), columns: 1)
        let chart = AstralComponent(json: root.raw["children"]!.arrayValue![0])!
        registry.retain(png, for: registry.node(path: "/components/0/children/0", component: chart)!)
        let capture = try JSONValue.parse(await registry.capture([root], isCurrent: { true }))
        let rendered = capture["components"]!.arrayValue![0]
        XCTAssertEqual(rendered["columns"], .number(1))
        XCTAssertNil(rendered["children"]!.arrayValue![0]["datasets"])
        XCTAssertEqual(capture["images"]?.arrayValue?.count, 1)
    }

    func testOwnerStateAndCancellationChangesDiscardPendingPixels() async throws {
        for change in 0..<3 {
            let registry = registry()
            let chart = try component(#"{"type":"bar_chart","id":"c"}"#)
            let node = registry.node(path: "/components/0", component: chart)!
            var continuation: CheckedContinuation<Data, Never>?
            registry.register(node, lease: UUID()) {
                await withCheckedContinuation { continuation = $0 }
            }
            let task = Task { try await registry.capture([chart], isCurrent: { true }) }
            while continuation == nil { await Task.yield() }
            if change == 0 {
                registry.currentScope = { nil }
            } else if change == 1 {
                registry.setWindow(CGSize(width: 400, height: 900))
            } else {
                task.cancel()
            }
            continuation?.resume(returning: png)
            do {
                _ = try await task.value
                XCTFail("Mixed or stale capture")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testOldUnmountLeaseCannotOverwriteReplacementPixels() async throws {
        let registry = registry()
        let chart = try component(#"{"type":"bar_chart","id":"c"}"#)
        let node = registry.node(path: "/components/0", component: chart)!
        let old = UUID()
        let next = UUID()
        registry.register(node, lease: old) { self.png }
        registry.register(node, lease: next) { self.png }
        registry.unmount(node, lease: next, pixels: png)
        registry.unmount(node, lease: old, pixels: nil)
        let retained = try JSONValue.parse(await registry.capture([chart], isCurrent: { true }))
        XCTAssertEqual(retained["images"]?.arrayValue?.count, 1)
        registry.retain(Data(repeating: 0, count: CanvasCaptureRegistry.maximumPixelBytes + 1), for: node, lease: next)
        do {
            _ = try await registry.capture([chart], isCurrent: { true })
            XCTFail("Oversized retained pixels")
        } catch { XCTAssertTrue(error is CanvasCaptureError) }
    }

    func testRemovedOffscreenPixelsAreReclaimedWithoutLosingHiddenStateOrAcceptingLateCallbacks() async throws {
        let registry = registry()
        let tabs = try component(
            #"{"type":"tabs","id":"tabs","tabs":[{"label":"Hidden","children":[{"type":"image","id":"hidden"}]},{"label":"Selected","children":[]}]}"#
        )
        let old = try component(#"{"type":"image","id":"old"}"#)
        let next = try component(#"{"type":"image","id":"next"}"#)
        var tree = [tabs, old]
        registry.currentComponents = { tree }
        let tabNode = registry.node(path: "/components/0", component: tabs)!
        let hidden = AstralComponent(json: tabs.raw["tabs"]!.arrayValue![0]["children"]!.arrayValue![0])!
        registry.record(tabNode, state: .array([.number(1)]))
        registry.retain(
            Data(repeating: 1, count: 1024 * 1024),
            for: registry.node(path: "/components/0/tabs/0/children/0", component: hidden)!)
        let oldNode = registry.node(path: "/components/1", component: old)!
        registry.retain(Data(repeating: 2, count: 4 * 1024 * 1024), for: oldNode)
        tree = [tabs, try component(#"{"type":"text","content":"Replacement"}"#), next]
        registry.retain(
            Data(repeating: 3, count: 2 * 1024 * 1024), for: registry.node(path: "/components/2", component: next)!)
        let first = try JSONValue.parse(await registry.capture(tree, isCurrent: { true }))
        XCTAssertEqual(first["images"]?.arrayValue?.count, 1)
        XCTAssertEqual(registry.state(for: tabNode), .array([.number(1)]))
        // A late completion from the removed image must not refill the budget.
        registry.retain(Data(repeating: 4, count: 4 * 1024 * 1024), for: oldNode)
        XCTAssertFalse(registry.accepts(oldNode))
        registry.record(tabNode, state: .array([.number(0)]))
        let restored = try JSONValue.parse(await registry.capture(tree, isCurrent: { true }))
        XCTAssertEqual(restored["images"]?.arrayValue?.count, 2)
        XCTAssertEqual(restored["images"]?.arrayValue?.last?["path"], .string("/components/2"))
    }

    func testChildListUsesTheDisplayedChildrenAndStatePath() async throws {
        let registry = registry()
        let list = try component(
            #"{"type":"list","children":[{"type":"collapsible","title":"Current details","children":[]}] }"#)
        registry.record(
            registry.node(path: "/components/0/children/0", component: list.children[0]), state: .bool(false))
        let capture = try JSONValue.parse(await registry.capture([list], isCurrent: { true }))
        XCTAssertEqual(capture["components"]?.arrayValue?.first?["type"], .string("container"))
        XCTAssertEqual(capture["display_state"]?.arrayValue?.first?["path"], .string("/components/0/children/0"))
    }

    func testMountedTabsGridDisclosureAndImagePublishActualCaptureState() async throws {
        URLProtocol.registerClass(CanvasCaptureImageProtocol.self)
        defer { URLProtocol.unregisterClass(CanvasCaptureImageProtocol.self) }
        let model = model()
        model.screen = .chat
        let source = try component(
            #"{"type":"tabs","id":"tabs","tabs":[{"label":"First","children":[{"type":"grid","id":"grid","columns":4,"children":[{"type":"image","id":"loaded","url":"https://canvas-capture-fixture.invalid/loaded.png","caption":"Loaded caption"},{"type":"collapsible","title":"Collapsed details","children":[]}]},{"type":"container","direction":"row","children":[{"type":"text","content":"Measured row"}]}]},{"label":"Second","content":[]}]}"#
        )
        model.canvas = [source]
        model.canvasCapture.setWindow(CGSize(width: 320, height: 900))
        model.canvasCapture.setCanvas(CGSize(width: 296, height: 600), palette: .midnight)
        let content = ComponentView(component: source)
            .environment(model).environment(ThemeStore())
            .environment(\.canvasCapturePath, "/components/0")
            .environment(\.astralViewportWidth, 320).frame(width: 296, height: 600)
        #if os(macOS)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 296, height: 600), styleMask: .borderless, backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: content)
            window.contentView?.layoutSubtreeIfNeeded()
            defer {
                window.contentView = nil
                window.close()
            }
        #else
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 296, height: 600))
            window.rootViewController = UIHostingController(rootView: content)
            window.isHidden = false
            window.layoutIfNeeded()
            window.rootViewController?.view.layoutIfNeeded()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
        #endif
        var captured: Data?
        for _ in 0..<100 {
            captured = try? await model.canvasCapture.capture([source], isCurrent: { true })
            if captured != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let envelope = try JSONValue.parse(XCTUnwrap(captured))
        XCTAssertEqual(envelope["display_state"]?.arrayValue?.count, 2)
        XCTAssertEqual(envelope["images"]?.arrayValue?.count, 1)
        let grid = envelope["components"]?.arrayValue?.first?["tabs"]?.arrayValue?.first?["children"]?.arrayValue?
            .first
        XCTAssertEqual(grid?["columns"], .number(1))
        let image = grid?["children"]?.arrayValue?.first
        XCTAssertGreaterThan(try XCTUnwrap(image?["width"]?.numberValue), 0)
        XCTAssertEqual(image?["caption"], .string("Loaded caption"))
    }

    #if os(macOS)
        func testAlreadyLoadedSwiftUIImageProducesBoundedPixelsWithoutRefetchingURL() async throws {
            let registry = registry()
            let component = try component(
                #"{"type":"image","id":"loaded","url":"https://never-fetch.invalid/private"}"#)
            let node = registry.node(path: "/components/0", component: component)!
            let loaded = Image(nsImage: try XCTUnwrap(NSImage(data: png)))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 120, height: 80), styleMask: .borderless, backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: CanvasLoadedImage(image: loaded, node: node, registry: registry).frame(width: 120, height: 80)
            )
            window.contentView?.layoutSubtreeIfNeeded()
            defer {
                window.contentView = nil
                window.close()
            }
            var captured: Data?
            for _ in 0..<40 {
                captured = try? await registry.capture([component], isCurrent: { true })
                if captured != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let envelope = try JSONValue.parse(XCTUnwrap(captured))
            let url = try XCTUnwrap(envelope["images"]?.arrayValue?.first?["data_url"]?.stringValue)
            let bytes = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst(22))))
            let image = try XCTUnwrap(NSBitmapImageRep(data: bytes))
            XCTAssertEqual(image.pixelsWide, 160)
            XCTAssertEqual(image.pixelsHigh, 160)
            XCTAssertFalse(String(decoding: captured!, as: UTF8.self).contains("never-fetch.invalid"))
        }
    #endif

    private func model() -> AppModel {
        let defaults = UserDefaults(suiteName: "CanvasCapture088.\(UUID().uuidString)")!
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults), tokenStore: InMemoryTokenStore(),
            defaults: defaults)
        model.signedIn = true
        model.activeChatId = "synthetic"
        model.workspaceStarted = true
        model.canvas = [try! component(#"{"type":"text","content":"Visible"}"#)]
        model.chromeMenu = ChromeMenuModel.fromJSON(
            try! JSONValue.parse(
                Data(
                    #"{"version":2,"topbar":[{"key":"export","kind":"workspace_action","label":"Export page","icon":"download","operation":"export_canvas","context":"live_canvas"}]}"#
                        .utf8)))
        return model
    }

    func testExportPipelineRemovesAuthorizationHTMLBeforeCaptureAndKeepsFrozenViewAcrossResize() async throws {
        let model = model()
        let context = try XCTUnwrap(model.workspaceActionContext(for: .exportCanvas))
        let authorization = try CanvasCaptureFile.write(Data("Canonical authorization only".utf8))
        var stages: [String] = []
        let file = try await model.exportWorkspacePresentation(
            context,
            authorize: {
                stages.append("authorize")
                return authorization
            },
            capture: {
                stages.append("capture")
                XCTAssertFalse(FileManager.default.fileExists(atPath: authorization.path))
                return Data("Frozen visible state".utf8)
            },
            present: { bytes in
                stages.append("present")
                XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "Frozen visible state")
                model.canvasCapture.setWindow(CGSize(width: 999, height: 700))
                model.canvas = [try self.component(#"{"type":"text","content":"Later transient"}"#)]
                return bytes
            },
            render: { bytes in
                stages.append("render")
                return bytes
            })
        defer { RestClient.removeTemporaryDownload(file) }
        XCTAssertEqual(stages, ["authorize", "capture", "present", "render"])
        XCTAssertEqual(try Data(contentsOf: file), Data("Frozen visible state".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions]
                as? Int, 0o700)
    }

    func testDeniedAuthorizationAndOwnerChangeCannotCaptureOrPresentAndNeverRetry() async throws {
        for denied in [true, false] {
            let model = model()
            let context = model.workspaceActionContext(for: .exportCanvas)!
            var calls = 0
            var temporary: URL?
            do {
                _ = try await model.exportWorkspacePresentation(
                    context,
                    authorize: {
                        calls += 1
                        if denied { throw URLError(.userAuthenticationRequired) }
                        temporary = try CanvasCaptureFile.write(Data("Auth".utf8))
                        model.activeChatId = "other"
                        return temporary!
                    },
                    capture: {
                        XCTFail("Stale/denied capture")
                        return Data()
                    },
                    present: { _ in
                        XCTFail("Stale/denied POST")
                        return Data()
                    },
                    render: { _ in
                        XCTFail("Stale/denied render")
                        return Data()
                    })
                XCTFail("Unexpected file")
            } catch { XCTAssertEqual(calls, 1) }
            if let temporary { XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path)) }
        }
    }

    func testActualWKCapturesCurrentZoomThenRetainsPixelsWhenUnmounted() async throws {
        let registry = registry()
        let component = try component(
            #"{"type":"plotly_chart","id":"c","data":[{"type":"bar","x":["Alpha","Beta"],"y":[2,5]}],"layout":{"height":260}}"#
        )
        let node = registry.node(path: "/components/0", component: component)!
        let coordinator = OfflineChartCoordinator()
        let webView = OfflineChartCoordinator.webView()
        webView.frame = CGRect(x: 0, y: 0, width: 296, height: 260)
        coordinator.update(
            webView, component: component, viewportWidth: 320, captureRegistry: registry, captureNode: node)
        for _ in 0..<100 {
            if coordinator.readyForCapture,
                (try? await webView.evaluateJavaScript("document.documentElement.dataset.chartState")) as? String
                    == "ready"
            {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Each successful call freezes this chart at that moment, like the web
        // finalizer. Later interaction changes only the next captured image.
        let before = try await coordinator.capturePixels(webView)
        let _: Any? = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                "await Plotly.relayout(document.getElementById('chart'), {'yaxis.range':[0,20]}); return true;",
                arguments: [:], in: nil, in: .page
            ) { continuation.resume(with: $0.map { Optional($0) }) }
        }
        let after = try await coordinator.capturePixels(webView)
        XCTAssertNotEqual(before, after)
        coordinator.dismantle(webView)
        for _ in 0..<120 where coordinator.document != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(coordinator.document)
        let capture = try JSONValue.parse(await registry.capture([component], isCurrent: { true }))
        let pixels = try XCTUnwrap(capture["images"]?.arrayValue?.first?["data_url"]?.stringValue)
        XCTAssertTrue(pixels.hasPrefix("data:image/png;base64,"))
        XCTAssertGreaterThan(pixels.count, 100)
    }
}

private final class CanvasCaptureImageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "canvas-capture-fixture.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let bytes = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNITvv4HwAFpAK6buOwBAAAAABJRU5ErkJggg==")!
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
