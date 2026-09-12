import AstralCore
import SwiftUI
import WebKit
import XCTest

@testable import AstralDeep

@MainActor
final class OfflineChartTests: XCTestCase {
    private func component(_ json: String) throws -> AstralComponent {
        try XCTUnwrap(AstralComponent(json: JSONValue.parse(Data(json.utf8))))
    }

    func testBundledDocumentUsesDataOnlyEnvelopeAndBoundedGeometry() throws {
        let chart = try component(
            #"{"type":"plotly_chart","data":[{"type":"bar","x":["A"],"y":[-3]}],"layout":{"height":600}}"#)
        let html = try OfflineChartDocument.html(component: chart, viewportWidth: 1200)
        XCTAssertFalse(html.contains("__ASTRAL_PLOTLY_VENDOR__"))
        XCTAssertFalse(html.contains("__ASTRAL_CHART_PAYLOAD_BASE64__"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertEqual(OfflineChartDocument.height(component: chart, viewportWidth: 1200, slotWidth: 490), 260)
        XCTAssertEqual(OfflineChartDocument.height(component: chart, viewportWidth: 1200, slotWidth: 700), 600)
        let tall = try component(#"{"type":"plotly_chart","layout":{"height":99999}}"#)
        XCTAssertEqual(OfflineChartDocument.height(component: tall, viewportWidth: 1200, slotWidth: 700), 1200)
        XCTAssertThrowsError(
            try OfflineChartDocument.html(component: chart, viewportWidth: 1200, bundle: Bundle(for: Self.self)))
    }

    func testIsolatedWebKitRendersMixedTracesAndDeniesNetworkNavigation() async throws {
        let chart = try component(
            #"{"type":"plotly_chart","title":"Synthetic chart fixture","data":[{"type":"bar","x":["A","B"],"y":[-2,3]},{"type":"scatter","mode":"lines+markers","x":["A","B"],"y":[1,4]}],"layout":{"height":600}}"#
        )
        let coordinator = OfflineChartCoordinator()
        let view = OfflineChartCoordinator.webView()
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 600)
        defer { coordinator.dismantle(view) }
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        coordinator.update(view, component: chart, viewportWidth: 1200)
        let state = try await waitForState(view)
        XCTAssertEqual(state, "ready")
        let traceTypes = try await view.evaluateJavaScript(
            "document.getElementById('chart').data.map(t => t.type).join(',')")
        XCTAssertEqual(traceTypes as? String, "bar,scatter")
        let renderedHeight = try await view.evaluateJavaScript("document.getElementById('chart')._fullLayout.height")
        XCTAssertEqual(renderedHeight as? Int, 600)
        let fetch: Any = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(
                "try { await fetch('https://blocked.invalid/chart-test'); return false; } catch (_) { return true; }",
                arguments: [:], in: nil, in: .page
            ) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(fetch as? Bool, true)
        _ = try await view.evaluateJavaScript("window.location.href='https://blocked.invalid/navigation'")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.url?.absoluteString, "about:blank")
        coordinator.dismantle(view)
        XCTAssertNil(view.navigationDelegate)
        XCTAssertNil(view.uiDelegate)
        XCTAssertNil(coordinator.document)
    }

    func testMaliciousPlotlyTextIsInertAndEmptyDataVisible() async throws {
        let chart = try component(
            #"{"type":"plotly_chart","data":[{"type":"bar","x":["<script>window.compromised=true</script>A"],"y":[1]}],"layout":{"title":{"text":"<img src='https://blocked.invalid/a' onerror='window.compromised=true'>"},"images":[{"source":"https://blocked.invalid/image"}]}}"#
        )
        let coordinator = OfflineChartCoordinator()
        let view = OfflineChartCoordinator.webView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 260)
        defer { coordinator.dismantle(view) }
        coordinator.update(view, component: chart, viewportWidth: 400)
        let state = try await waitForState(view)
        XCTAssertEqual(state, "error")
        let inert = try await view.evaluateJavaScript("window.compromised === undefined")
        XCTAssertEqual(inert as? Bool, true)
        coordinator.update(view, component: try component(#"{"type":"bar_chart","datasets":[]}"#), viewportWidth: 400)
        let empty = try await waitForState(view, expected: "empty")
        XCTAssertEqual(empty, "empty")
    }

    func testNestedMarkerOptionsRetainOrdinaryObjectsAndInertPrototypeKeys() async throws {
        let chart = try component(
            ##"{"type":"plotly_chart","title":"Alpha vs Beta","data":[{"marker":{"color":"#6366F1","__proto__":{"chartPrototypeAttack":true},"constructor":{"prototype":{"chartPrototypeAttack":true}}},"type":"bar","x":["Alpha","Beta"],"y":[2.0,5.0]}],"layout":{"xaxis":{"categoryorder":"category ascending","tickangle":-45,"type":"category","automargin":true},"autosize":true,"height":260,"margin":{"l":44,"r":12,"t":32,"b":60},"yaxis":{"automargin":true}},"config":{}}"##
        )
        let coordinator = OfflineChartCoordinator()
        let view = OfflineChartCoordinator.webView()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 260)
        defer { coordinator.dismantle(view) }
        coordinator.update(view, component: chart, viewportWidth: 393)
        let state = try await waitForState(view)
        XCTAssertEqual(state, "ready")
        let values = try await view.evaluateJavaScript("document.getElementById('chart').data[0].y.join(',')")
        XCTAssertEqual(values as? String, "2,5")
        let safe = try await view.evaluateJavaScript(
            """
            (function () {
                const marker = document.getElementById('chart').data[0].marker;
                return Object.getPrototypeOf(marker) === Object.prototype &&
                    Object.prototype.hasOwnProperty.call(marker, '__proto__') &&
                    ({}).chartPrototypeAttack === undefined;
            })()
            """)
        XCTAssertEqual(safe as? Bool, true)
    }

    #if os(macOS)
        private let barChart =
            ##"{"type":"plotly_chart","title":"Alpha vs Beta","data":[{"marker":{"color":"#6366F1"},"type":"bar","x":["Alpha","Beta"],"y":[2,5]}],"layout":{"height":260}}"##

        private struct ChartTestHost: View {
            let component: AstralComponent
            @Environment(ThemeStore.self) private var theme

            var body: some View {
                ComponentView(component: component)
                    .padding(20).frame(width: 500, height: 430).background(theme.palette.bg)
            }
        }

        private func host(_ json: String, theme: ThemeStore, transcriptRole: String? = nil) throws -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: transcriptRole == nil ? 430 : 800),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let model = AppModel(tokenStore: InMemoryTokenStore())
            if let transcriptRole {
                model.turns = [
                    .init(id: "synthetic-chart", role: transcriptRole, text: "", components: [try component(json)])
                ]
                window.contentView = NSHostingView(
                    rootView: ChatShell().frame(width: 500, height: 800).background(theme.palette.bg)
                        .environment(theme).environment(model)
                        .environment(\.astralViewportWidth, 500))
            } else {
                window.contentView = NSHostingView(
                    rootView: ChartTestHost(component: try component(json))
                        .environment(theme).environment(model)
                        .environment(\.astralViewportWidth, 1200))
            }
            // Hidden windows exercise the real native hierarchy without taking
            // focus from a signed-in client or presenting an authentication UI.
            window.contentView?.layoutSubtreeIfNeeded()
            return window
        }

        private func chartView(in window: NSWindow) async throws -> WKWebView {
            func find(_ view: NSView) -> WKWebView? {
                if let chart = view as? WKWebView { return chart }
                return view.subviews.lazy.compactMap(find).first
            }
            for _ in 0..<100 {
                if let content = window.contentView, let view = find(content), view.bounds.width > 0 {
                    return view
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw XCTUnwrapError.missingChart
        }

        private enum XCTUnwrapError: Error { case missingChart }

        private func assertBackdrop(
            _ view: WKWebView, rgb expected: [Int], name: String,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            let snapshot = try await view.takeSnapshot(configuration: nil)
            let image = try XCTUnwrap(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil))
            var pixel = [UInt8](repeating: 0, count: 4)
            // Respect the snapshot's ICC profile. NSBitmapImageRep.colorAt
            // returns a calibrated NSColor even for an sRGB image, which would
            // incorrectly apply another color conversion to dark pixels.
            let context = try XCTUnwrap(
                CGContext(
                    data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: CGFloat(4 - image.width), y: -3)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            for (actual, channel) in zip(pixel.prefix(3), expected) {
                XCTAssertEqual(Double(actual), Double(channel), accuracy: 3, name, file: file, line: line)
            }
            XCTAssertEqual(pixel[3], 255, file: file, line: line)
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func testMacChartPixelsMatchDirectAndNestedSurfacesInBothThemes() async throws {
            for (preset, expected) in [
                ("midnight", [[20, 23, 39], [23, 26, 42], [24, 28, 44]]),
                ("daylight", [[251, 252, 253], [253, 253, 254], [254, 254, 254]]),
            ] {
                let theme = ThemeStore()
                theme.apply(preset: preset)
                let card = "{\"type\":\"card\",\"content\":[\(barChart)]}"
                let nested = """
                    {"type":"card","content":[{"type":"collapsible","default_open":true,"content":[\(barChart)]}]}
                    """
                for (index, json) in [barChart, card, nested].enumerated() {
                    let window = try host(json, theme: theme)
                    defer {
                        window.contentView = nil
                        window.close()
                    }
                    let view = try await chartView(in: window)
                    let state = try await waitForState(view, expected: "ready")
                    XCTAssertEqual(state, "ready")
                    let values = try await view.evaluateJavaScript(
                        "document.getElementById('chart').data[0].y.join(',')")
                    XCTAssertEqual(values as? String, "2,5")
                    try await assertBackdrop(view, rgb: expected[index], name: "mac-chart-\(preset)-nesting-\(index)")
                }
            }
        }

        func testMacChartRepaintsWhenTheHostThemeChanges() async throws {
            let theme = ThemeStore()
            let window = try host("{\"type\":\"card\",\"content\":[\(barChart)]}", theme: theme)
            defer {
                window.contentView = nil
                window.close()
            }
            let view = try await chartView(in: window)
            _ = try await waitForState(view, expected: "ready")
            try await assertBackdrop(view, rgb: [23, 26, 42], name: "mac-chart-before-theme-change")
            theme.apply(preset: "daylight")
            for _ in 0..<100 {
                let background = try? await view.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
                if background as? String == "rgb(253, 253, 254)" { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            _ = try await waitForState(view, expected: "ready")
            try await assertBackdrop(view, rgb: [253, 253, 254], name: "mac-chart-after-theme-change")
        }

        func testMacTranscriptChartsMatchOpaqueAssistantAndTintedUserBubbles() async throws {
            for (preset, expected) in [
                ("midnight", [[28, 33, 52], [29, 33, 62]]),
                ("daylight", [[246, 247, 250], [233, 232, 251]]),
            ] {
                let theme = ThemeStore()
                theme.apply(preset: preset)
                for (index, role) in ["assistant", "user"].enumerated() {
                    let window = try host(barChart, theme: theme, transcriptRole: role)
                    defer {
                        window.contentView = nil
                        window.close()
                    }
                    let view = try await chartView(in: window)
                    _ = try await waitForState(view, expected: "ready")
                    try await assertBackdrop(view, rgb: expected[index], name: "mac-chart-\(preset)-\(role)-bubble")
                }
            }
        }

        func testMacEmptyErrorAndTerminatedDocumentsKeepThemedLegibleSurfaces() async throws {
            for (appearance, background, muted, text) in [
                (
                    OfflineChartDocument.Appearance(background: 0x171A2A, text: 0xF3F4F6, muted: 0x9CA3AF),
                    [23, 26, 42], "rgb(156, 163, 175)", "rgb(243, 244, 246)"
                ),
                (
                    OfflineChartDocument.Appearance(background: 0xFDFDFE, text: 0x1E293B, muted: 0x64748B),
                    [253, 253, 254], "rgb(100, 116, 139)", "rgb(30, 41, 59)"
                ),
            ] {
                let coordinator = OfflineChartCoordinator()
                let view = OfflineChartCoordinator.webView()
                view.frame = NSRect(x: 0, y: 0, width: 400, height: 260)
                let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                defer {
                    coordinator.dismantle(view)
                    window.contentView = nil
                    window.close()
                }
                for (json, expected) in [
                    (#"{"type":"plotly_chart","data":[]}"#, "empty"),
                    (
                        #"{"type":"plotly_chart","data":[{"type":"bar","y":[1]}],"layout":{"images":[{"source":"https://blocked.invalid/image"}]}}"#,
                        "error"
                    ),
                ] {
                    coordinator.update(view, component: try component(json), viewportWidth: 400, appearance: appearance)
                    let state = try await waitForState(view, expected: expected)
                    XCTAssertEqual(state, expected)
                    let status = try await view.evaluateJavaScript(
                        "getComputedStyle(document.getElementById('status')).color")
                    XCTAssertEqual(status as? String, muted)
                    try await assertBackdrop(
                        view, rgb: background, name: "mac-chart-\(expected)-\(appearance.background)")
                }
                coordinator.webViewWebContentProcessDidTerminate(view)
                for _ in 0..<100 {
                    let loaded = try? await view.evaluateJavaScript("document.querySelector('p[role=alert]') !== null")
                    if loaded as? Bool == true { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let color = try await view.evaluateJavaScript(
                    "getComputedStyle(document.querySelector('p[role=alert]')).color")
                XCTAssertEqual(color as? String, text)
                try await assertBackdrop(
                    view, rgb: background, name: "mac-chart-process-failure-\(appearance.background)")
            }
        }
    #endif

    private func waitForState(_ view: WKWebView, expected: String? = nil) async throws -> String {
        for _ in 0..<200 {
            if let state = try? await view.evaluateJavaScript("document.documentElement.dataset.chartState") as? String,
                state != "loading", expected == nil || state == expected
            {
                return state
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Offline chart did not reach a terminal state")
        return "timeout"
    }
}
