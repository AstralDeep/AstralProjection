import AstralCore
import SwiftUI
import WebKit

/// One data-only document with the approved, hash-pinned Plotly bytes. This
/// web view has no identity, action bridge, persistent store, or navigation.
private struct AstralViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1024
}
extension EnvironmentValues {
    var astralViewportWidth: CGFloat {
        get { self[AstralViewportWidthKey.self] }
        set { self[AstralViewportWidthKey.self] = newValue }
    }
}

enum OfflineChartDocument {
    /// Host colors are numeric, never authored CSS or executable chart data.
    struct Appearance: Equatable {
        let background: UInt32
        let text: UInt32
        let muted: UInt32

        var style: String {
            func css(_ color: UInt32) -> String { String(format: "#%06X", color & 0xFFFFFF) }
            return
                "<style>html,body{background:\(css(background));color:\(css(text))}#status{color:\(css(muted))}</style>"
        }
    }

    static func height(component: AstralComponent, viewportWidth: Double, slotWidth: Double) -> Double {
        if slotWidth < 500 { return 260 }
        let raw = component.type == "plotly_chart" ? component.raw["layout"]?["height"] : nil
        let authored = raw?.numberValue ?? raw?.stringValue.flatMap(Double.init)
        let preferred = authored ?? (viewportWidth < 640 ? 240 : 320)
        let height = preferred.isFinite && preferred != 0 ? preferred : 320
        return min(1200, max(160, height))
    }

    static func html(
        component: AstralComponent, viewportWidth: Double, bundle: Bundle = .main, appearance: Appearance? = nil
    ) throws -> String {
        guard let templateURL = bundle.url(forResource: "chart", withExtension: "html"),
            let vendorURL = bundle.url(forResource: "plotly.min", withExtension: "js")
        else { throw CocoaError(.fileNoSuchFile) }
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let vendor = try String(contentsOf: vendorURL, encoding: .utf8)
        var raw = component.raw.objectValue ?? [:]
        raw["type"] = .string(component.type)
        let envelope = JSONValue.object([
            "component": .object(raw), "viewport_width": .number(viewportWidth),
        ])
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= 8 * 1024 * 1024,
            template.contains("__ASTRAL_PLOTLY_VENDOR__"),
            template.contains("__ASTRAL_CHART_PAYLOAD_BASE64__"),
            template.contains("</head>"),
            !vendor.lowercased().contains("</script")
        else { throw CocoaError(.fileReadCorruptFile) }
        return template.replacingOccurrences(of: "</head>", with: (appearance?.style ?? "") + "</head>")
            .replacingOccurrences(of: "__ASTRAL_PLOTLY_VENDOR__", with: vendor)
            .replacingOccurrences(of: "__ASTRAL_CHART_PAYLOAD_BASE64__", with: data.base64EncodedString())
    }

    static func failure(isolationUnavailable: Bool = false, appearance: Appearance?) -> String {
        let message =
            isolationUnavailable
            ? "Chart isolation is unavailable."
            : "This chart could not be displayed. Open it in the web client."
        return """
            <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <style>p{font:14px system-ui;padding:12px}</style>
            \(appearance?.style ?? "")</head><body><p role="alert">\(message)</p></body></html>
            """
    }
}

@MainActor
final class OfflineChartCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var document: String?
    private var mayLoadDocument = false
    private var generation = UUID()
    private var hasShownFailure = false
    private var appearance: OfflineChartDocument.Appearance?

    static func webView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        #if os(iOS)
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.isScrollEnabled = false
        #endif
        return view
    }

    func update(
        _ webView: WKWebView, component: AstralComponent, viewportWidth: Double,
        appearance: OfflineChartDocument.Appearance? = nil
    ) {
        self.appearance = appearance
        #if os(macOS)
            webView.underPageBackgroundColor = appearance.map { NSColor(Color(hex: $0.background)) } ?? .clear
        #endif
        let next: String
        do {
            next = try OfflineChartDocument.html(
                component: component, viewportWidth: viewportWidth, appearance: appearance)
        } catch {
            next = OfflineChartDocument.failure(appearance: appearance)
        }
        guard document != next else { return }
        document = next
        hasShownFailure = false
        let current = UUID()
        generation = current
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // The CSP already blocks fetch, frames, remote images, fonts, and
        // workers. WebKit's content blocker adds a second network boundary.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "astral-offline-chart-network-deny-v1",
            encodedContentRuleList:
                #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]"#
        ) { [weak self, weak webView] rules, error in
            guard let self, let webView, self.generation == current else { return }
            guard error == nil, let rules else {
                self.mayLoadDocument = true
                webView.loadHTMLString(
                    OfflineChartDocument.failure(isolationUnavailable: true, appearance: appearance), baseURL: nil)
                return
            }
            webView.configuration.userContentController.removeAllContentRuleLists()
            webView.configuration.userContentController.add(rules)
            self.mayLoadDocument = true
            webView.loadHTMLString(next, baseURL: nil)
        }
    }

    func dismantle(_ webView: WKWebView) {
        generation = UUID()
        document = nil
        appearance = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func showFailure(_ webView: WKWebView) {
        guard !hasShownFailure else { return }
        hasShownFailure = true
        mayLoadDocument = true
        webView.loadHTMLString(
            OfflineChartDocument.failure(appearance: appearance), baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showFailure(webView) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showFailure(webView) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showFailure(webView) }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let initial =
            mayLoadDocument && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url?.absoluteString == "about:blank"
        if initial { mayLoadDocument = false }
        decisionHandler(initial ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

#if os(iOS)
    struct OfflineChartView: UIViewRepresentable {
        let component: AstralComponent
        let viewportWidth: CGFloat
        func makeCoordinator() -> OfflineChartCoordinator { OfflineChartCoordinator() }
        func makeUIView(context: Context) -> WKWebView { OfflineChartCoordinator.webView() }
        static func dismantleUIView(_ view: WKWebView, coordinator: OfflineChartCoordinator) {
            coordinator.dismantle(view)
        }
        func updateUIView(_ view: WKWebView, context: Context) {
            context.coordinator.update(view, component: component, viewportWidth: viewportWidth)
        }
    }
#else
    struct OfflineChartView: NSViewRepresentable {
        let component: AstralComponent
        let viewportWidth: CGFloat
        @Environment(ThemeStore.self) private var theme
        @Environment(\.astralChartBackdrop) private var backdrop
        func makeCoordinator() -> OfflineChartCoordinator { OfflineChartCoordinator() }
        func makeNSView(context: Context) -> WKWebView { OfflineChartCoordinator.webView() }
        static func dismantleNSView(_ view: WKWebView, coordinator: OfflineChartCoordinator) {
            coordinator.dismantle(view)
        }
        func updateNSView(_ view: WKWebView, context: Context) {
            context.coordinator.update(
                view, component: component, viewportWidth: viewportWidth,
                appearance: .init(
                    background: (backdrop ?? AstralChartBackdrop(theme.palette.bg)).hex,
                    text: AstralChartBackdrop(theme.palette.text).hex,
                    muted: AstralChartBackdrop(theme.palette.muted).hex))
        }
    }
#endif
