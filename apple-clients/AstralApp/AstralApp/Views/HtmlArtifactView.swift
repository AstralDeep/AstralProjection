// Shows a server-validated `html_artifact` page inside a sandboxed iframe in a non-persistent WKWebView whose
// content rules block every network host but the CDN allowlist and whose delegate cancels every navigation after
// the first load. ComponentView and ChatView's CanvasArea host it; NativeDownloadSaveLease saves its export.

#if os(macOS)
    import AppKit
    import AstralCore
    import CryptoKit
    import SwiftUI
    import WebKit

    struct HtmlArtifactDocument: Equatable {
        static let allowedHosts = [
            "cdnjs.cloudflare.com", "cdn.jsdelivr.net", "unpkg.com", "esm.sh", "fonts.googleapis.com",
            "fonts.gstatic.com",
        ]
        static let kinds: Set<String> = ["page", "app", "visualization"]
        static let maximumBytes = 2 * 1024 * 1024

        let id: String
        let title: String
        let kind: String?
        let version: Int?
        let html: String
        let createdAt: String

        init?(component: AstralComponent) {
            let raw = component.raw
            guard component.type == "html_artifact", let html = raw["html"]?.stringValue, !html.isEmpty,
                html.utf8.count <= Self.maximumBytes
            else { return nil }
            let id = ArtifactDocument.text(raw["id"], 120)
            self.id = id.isEmpty ? ArtifactDocument.text(raw["component_id"], 120) : id
            title = ArtifactDocument.text(raw["title"], 120)
            let kind = ArtifactDocument.text(raw["kind"], 40).lowercased()
            self.kind = Self.kinds.contains(kind) ? kind : nil
            version = ArtifactDocument.version(raw["version"])
            self.html = html
            createdAt = ArtifactDocument.text(raw["created_at"], 64)
        }

        var filename: String {
            String(ArtifactView.filename(title).dropLast(5)) + (version.map { "-v\($0)" } ?? "") + ".html"
        }

        static func escapeAttribute(_ text: String) -> String {
            var escaped = ""
            escaped.reserveCapacity(text.utf8.count)
            for character in text {
                switch character {
                case "&": escaped += "&amp;"
                case "\"": escaped += "&quot;"
                case "<": escaped += "&lt;"
                case ">": escaped += "&gt;"
                case "'": escaped += "&#39;"
                default: escaped.append(character)
                }
            }
            return escaped
        }

        static let hostPolicy = "connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

        static func hostPage(html: String, title: String, background: String) -> String {
            """
            <!doctype html><html><head><meta charset="utf-8">\
            <meta http-equiv="Content-Security-Policy" content="\(hostPolicy)">\
            <meta name="color-scheme" content="light dark">\
            <style>html,body{margin:0;height:100%;overflow:hidden;background:\(background)}\
            iframe{display:block}</style></head><body>\
            <iframe sandbox="allow-scripts" title="\(escapeAttribute(title))" \
            style="border:0;width:100%;height:100%" srcdoc="\(escapeAttribute(html))"></iframe>\
            </body></html>
            """
        }

        static func contentRules(allowing origins: [String]) -> String {
            var rules: [JSONValue] = ["^https?:", "^wss?:", "^ftp:", "^file:"].map { pattern in
                .object([
                    "trigger": .object(["url-filter": .string(pattern)]),
                    "action": .object(["type": .string("block")]),
                ])
            }
            for origin in origins {
                let escaped = origin.map { "\\.*+?^$[](){}|".contains($0) ? "\\\($0)" : String($0) }.joined()
                rules.append(
                    .object([
                        "trigger": .object(["url-filter": .string("^" + escaped + "/")]),
                        "action": .object(["type": .string("ignore-previous-rules")]),
                    ]))
            }
            let data = (try? JSONValue.array(rules).encoded()) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        static var productionRules: String { contentRules(allowing: allowedHosts.map { "https://" + $0 }) }
    }

    enum HtmlArtifactNavigationPolicy {
        struct Pending: Equatable {
            var mainFrame = false
            var sourceDocument = false
        }

        static func decide(url: URL?, mainFrame: Bool?, pending: inout Pending) -> WKNavigationActionPolicy {
            let address = url?.absoluteString ?? ""
            if mainFrame == true, pending.mainFrame, address == "about:blank" {
                pending.mainFrame = false
                return .allow
            }
            if mainFrame == false, pending.sourceDocument, address == "about:srcdoc" {
                pending.sourceDocument = false
                return .allow
            }
            return .cancel
        }
    }

    @MainActor
    final class HtmlArtifactRuleStore {
        static let shared = HtmlArtifactRuleStore()
        private var compiled: [String: WKContentRuleList] = [:]
        private var waiting: [String: [(Result<WKContentRuleList, Error>) -> Void]] = [:]

        func rules(_ encoded: String, completion: @escaping (Result<WKContentRuleList, Error>) -> Void) {
            let digest = SHA256.hash(data: Data(encoded.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            let identifier = "astral-html-artifact-" + digest
            if let list = compiled[identifier] { return completion(.success(list)) }
            if waiting[identifier] != nil {
                waiting[identifier]?.append(completion)
                return
            }
            waiting[identifier] = [completion]
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: encoded
            ) { [weak self] list, error in
                guard let self else { return }
                let result: Result<WKContentRuleList, Error> =
                    list.map { .success($0) } ?? .failure(error ?? CocoaError(.featureUnsupported))
                if let list { self.compiled[identifier] = list }
                let callbacks = self.waiting.removeValue(forKey: identifier) ?? []
                for callback in callbacks { callback(result) }
            }
        }
    }

    @MainActor
    final class HtmlArtifactCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        enum Phase: Equatable {
            case idle, loading, loaded
            case failed
        }

        private(set) var phase = Phase.idle
        private(set) var cancelledNavigations: [URL] = []
        private var source: (html: String, title: String, background: String)?
        private var pending = HtmlArtifactNavigationPolicy.Pending()
        private var generation = UUID()
        var rules = HtmlArtifactDocument.productionRules
        var onPhase: ((Phase) -> Void)?

        static func webView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.allowsBackForwardNavigationGestures = false
            view.allowsMagnification = false
            return view
        }

        func update(
            _ webView: WKWebView, html: String, title: String, dark: Bool, background: NSColor, backgroundCSS: String
        ) {
            webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            webView.underPageBackgroundColor = background
            webView.navigationDelegate = self
            webView.uiDelegate = self
            if let source, source.html == html, source.title == title, source.background == backgroundCSS { return }
            source = (html, title, backgroundCSS)
            let next = HtmlArtifactDocument.hostPage(html: html, title: title, background: backgroundCSS)
            let current = UUID()
            generation = current
            pending = .init()
            setPhase(.loading)
            HtmlArtifactRuleStore.shared.rules(rules) { [weak self, weak webView] result in
                guard let self, let webView, self.generation == current else { return }
                webView.configuration.userContentController.removeAllContentRuleLists()
                guard case .success(let list) = result else {
                    self.setPhase(.failed)
                    webView.loadHTMLString("", baseURL: nil)
                    return
                }
                webView.configuration.userContentController.add(list)
                self.pending = .init(mainFrame: true, sourceDocument: true)
                webView.loadHTMLString(next, baseURL: nil)
            }
        }

        func dismantle(_ webView: WKWebView) {
            generation = UUID()
            source = nil
            pending = .init()
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeAllContentRuleLists()
            webView.loadHTMLString("", baseURL: nil)
        }

        private func setPhase(_ next: Phase) {
            phase = next
            onPhase?(next)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let policy = HtmlArtifactNavigationPolicy.decide(
                url: navigationAction.request.url, mainFrame: navigationAction.targetFrame?.isMainFrame,
                pending: &pending)
            if policy == .cancel, let url = navigationAction.request.url {
                cancelledNavigations = Array((cancelledNavigations + [url]).suffix(32))
            }
            decisionHandler(policy)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if phase == .loading { setPhase(.loaded) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { setPhase(.failed) }
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            if (error as NSError).code != NSURLErrorCancelled, phase == .loading { setPhase(.failed) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { setPhase(.failed) }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }

    struct HtmlArtifactWebView: NSViewRepresentable {
        let html: String
        let title: String
        let dark: Bool
        let background: Color
        let identifier: String
        @Binding var phase: HtmlArtifactCoordinator.Phase

        func makeCoordinator() -> HtmlArtifactCoordinator { HtmlArtifactCoordinator() }

        func makeNSView(context: Context) -> WKWebView {
            let view = HtmlArtifactCoordinator.webView()
            view.setAccessibilityIdentifier(identifier)
            return view
        }

        static func dismantleNSView(_ view: WKWebView, coordinator: HtmlArtifactCoordinator) {
            coordinator.dismantle(view)
        }

        func updateNSView(_ view: WKWebView, context: Context) {
            let binding = $phase
            context.coordinator.onPhase = { next in
                Task { @MainActor in
                    if binding.wrappedValue != next { binding.wrappedValue = next }
                }
            }
            context.coordinator.update(
                view, html: html, title: title, dark: dark, background: NSColor(background),
                backgroundCSS: String(format: "#%06X", AstralChartBackdrop(background).hex))
        }
    }

    enum HtmlArtifactFiles {
        static func write(_ document: HtmlArtifactDocument, folder: String) throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("astral-artifacts", isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(document.filename)
            try Data(document.html.utf8).write(to: file, options: .atomic)
            return file
        }

        static func defaultBrowser() -> URL? {
            URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        }
    }

    struct HtmlArtifactView: View {
        let component: AstralComponent
        var fillsSlot = false
        @Environment(ThemeStore.self) private var theme
        @State private var phase = HtmlArtifactCoordinator.Phase.idle
        @State private var savePanel: NativeDownloadSaveLease?
        @State private var failure: String?
        private var p: AstralPalette { theme.palette }
        static let unavailable = "This page could not be displayed."

        var body: some View {
            if let document = HtmlArtifactDocument(component: component) {
                content(document)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.warning)
                        .accessibilityHidden(true)
                    Text(Self.unavailable)
                        .font(ComponentTypeScale.body).foregroundStyle(p.muted)
                }
                .padding(ComponentSpacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .componentCardSurface(p)
            }
        }

        private func content(_ document: HtmlArtifactDocument) -> some View {
            VStack(spacing: 0) {
                toolbar(document)
                ZStack {
                    HtmlArtifactWebView(
                        html: document.html, title: document.title, dark: theme.colorScheme == .dark,
                        background: p.bg, identifier: ArtifactAccessibility.control(document.id, "web"), phase: $phase)
                    if phase == .failed {
                        Text(Self.unavailable)
                            .font(ComponentTypeScale.body).foregroundStyle(p.muted).padding(ComponentSpacing.loose)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: fillsSlot ? 240 : 520, maxHeight: fillsSlot ? .infinity : 520)
            }
            .background(p.bg)
            .clipShape(RoundedRectangle(cornerRadius: fillsSlot ? 0 : AstralRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: fillsSlot ? 0 : AstralRadius.md)
                    .strokeBorder(fillsSlot ? Color.clear : p.border, lineWidth: 1)
            )
            .onDisappear { savePanel?.cancel() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(ArtifactAccessibility.root(document.id))
        }

        private func toolbar(_ document: HtmlArtifactDocument) -> some View {
            HStack(spacing: ComponentSpacing.tight) {
                HStack(spacing: 8) {
                    Text(verbatim: document.title)
                        .font(ComponentTypeScale.heading).foregroundStyle(p.text).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(ArtifactAccessibility.title(document.id))
                    if let kind = document.kind { ArtifactChip(text: kind.capitalized, palette: p, accent: true) }
                    if let version = document.version { ArtifactChip(text: "v\(version)", palette: p) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let failure {
                    Text(failure).font(ComponentTypeScale.caption).foregroundStyle(p.error).lineLimit(1)
                }
                ComponentCopyButton(text: document.html, palette: p, label: "Copy HTML")
                    .accessibilityIdentifier(ArtifactAccessibility.control(document.id, "copy"))
                Button {
                    export(document)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(savePanel != nil)
                .accessibilityIdentifier(ArtifactAccessibility.control(document.id, "export"))
                Button {
                    open(document)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .accessibilityIdentifier(ArtifactAccessibility.control(document.id, "open"))
            }
            .buttonStyle(.plain)
            .font(ComponentTypeScale.caption.weight(.medium))
            .foregroundStyle(p.muted)
            .padding(.horizontal, ComponentSpacing.regular)
            .frame(minHeight: 44)
            .background(p.surface)
            .overlay(alignment: .bottom) { p.border.frame(height: 1) }
        }

        private func export(_ document: HtmlArtifactDocument) {
            guard savePanel == nil else { return }
            failure = nil
            let file: URL
            do {
                file = try HtmlArtifactFiles.write(document, folder: UUID().uuidString)
            } catch {
                failure = "The file could not be saved."
                return
            }
            let lease = NativeDownloadSaveLease(file: file)
            savePanel = lease
            lease.panel.nameFieldStringValue = document.filename
            lease.panel.canCreateDirectories = true
            lease.panel.begin { response in
                defer {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                    if savePanel === lease { savePanel = nil }
                }
                guard savePanel === lease, response == .OK, let destination = lease.panel.url else { return }
                do {
                    _ = try lease.save(to: destination, isCurrent: { savePanel === lease })
                } catch {
                    failure = "The file could not be saved."
                }
            }
        }

        private func open(_ document: HtmlArtifactDocument) {
            failure = nil
            do {
                let file = try HtmlArtifactFiles.write(document, folder: "open")
                if let browser = HtmlArtifactFiles.defaultBrowser() {
                    NSWorkspace.shared.open(
                        [file], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
                } else if !NSWorkspace.shared.open(file) {
                    failure = "The file could not be saved."
                }
            } catch {
                failure = "The file could not be saved."
            }
        }
    }
#endif
