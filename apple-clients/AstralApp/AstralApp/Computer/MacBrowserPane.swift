// Owns the Mac browser pane's single locked-down WKWebView: non-persistent storage, an http-only content rule
// list, the isolated browser_snapshot.js world, origin-gated navigation, queued dialogs and refused popups,
// downloads and uploads. MacBrowserDriver runs browser verbs through it and MacBrowserPaneView displays it.

#if os(macOS)
    import AppKit
    import AstralCore
    import Foundation
    import Observation
    import WebKit

    struct MacBrowserFrame {
        let token: String
        let id: String
        let info: WKFrameInfo
        let isMain: Bool
        let url: String
        let origin: String?
    }

    struct MacBrowserDialog: Identifiable, Equatable {
        let id: UUID
        let type: String
        let message: String
        let defaultText: String?
        let origin: String?
        var json: JSONValue {
            var object: [String: JSONValue] = [
                "type": .string(type), "message": .string(String(message.prefix(1000))),
                "origin": origin.map(JSONValue.string) ?? .null,
            ]
            if let defaultText { object["default_text"] = .string(String(defaultText.prefix(1000))) }
            return .object(object)
        }
    }

    enum MacBrowserNotice: Equatable {
        case popup(String?)
        case download(String?)
        case upload
        case scheme(String)
        case origin(String)
        var json: JSONValue {
            switch self {
            case .popup(let url):
                return .object(["kind": .string("popup"), "url": url.map(JSONValue.string) ?? .null])
            case .download(let url):
                return .object(["kind": .string("download"), "url": url.map(JSONValue.string) ?? .null])
            case .upload: return .object(["kind": .string("upload")])
            case .scheme(let scheme): return .object(["kind": .string("scheme"), "scheme": .string(scheme)])
            case .origin(let origin): return .object(["kind": .string("origin"), "origin": .string(origin)])
            }
        }
    }

    enum MacBrowserLoadEvent: Equatable {
        case started, finished
        case failed(String)
        case refused, crashed
    }

    enum MacBrowserScriptCall: String {
        case snapshot, describe, focusTarget, click, settle, fill, press, scroll, text, geometry, probe, contains
        case state
        case secretRects
    }

    @MainActor
    private final class MacBrowserEvaluation {
        private var continuation: CheckedContinuation<Any?, Error>?
        private var result: Result<Any?, Error>?
        private var timeout: Task<Void, Never>?

        func begin(_ continuation: CheckedContinuation<Any?, Error>, limit: Duration) {
            if let result {
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: limit) } catch { return }
                self?.finish(
                    .failure(ComputerHostError("timeout", "The page did not answer in time. Try a fresh snapshot.")))
            }
        }

        func finish(_ result: Result<Any?, Error>) {
            guard self.result == nil else { return }
            self.result = result
            timeout?.cancel()
            timeout = nil
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    @MainActor
    private final class MacBrowserMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
        weak var pane: MacBrowserPane?
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor (Any?, String?) -> Void
        ) {
            replyHandler(pane?.receive(message), nil)
        }
    }

    @MainActor @Observable
    final class MacBrowserPane: NSObject, WKNavigationDelegate, WKUIDelegate {
        static let worldName = "astral-browser"
        static let messageName = "astralBrowser"
        static let ruleIdentifier = "astral-browser-pane-http-only-v1"
        static let ruleList =
            #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^https?://"},"action":{"type":"ignore-previous-rules"}}]"#
        static let placeholder = "__ASTRAL_BROWSER_RULES__"

        @ObservationIgnored let webView: WKWebView
        @ObservationIgnored let world = WKContentWorld.world(name: MacBrowserPane.worldName)
        private(set) var url: URL?
        private(set) var title = ""
        private(set) var canGoBack = false
        private(set) var canGoForward = false
        private(set) var isLoading = false
        private(set) var dialogs: [MacBrowserDialog] = []
        private(set) var generation = 0
        private(set) var unavailable: String?
        @ObservationIgnored private(set) var frames: [MacBrowserFrame] = []
        @ObservationIgnored private(set) var events: [(sequence: Int, event: MacBrowserLoadEvent)] = []
        @ObservationIgnored private(set) var sequence = 0
        @ObservationIgnored private(set) var mainStatus: Int?
        @ObservationIgnored var navigationRule: (URL, Bool) -> Bool = { _, _ in false }
        @ObservationIgnored var humanInput: (() -> Void)?
        @ObservationIgnored private var nextFrame = 1
        @ObservationIgnored private var replies: [UUID: (Bool, String?) -> Void] = [:]
        @ObservationIgnored private var notices: [MacBrowserNotice] = []
        @ObservationIgnored private var userNavigation = false
        @ObservationIgnored private var observations: [NSKeyValueObservation] = []
        @ObservationIgnored private var monitor: Any?
        @ObservationIgnored private let monitors: any MacComputerEventMonitoring
        @ObservationIgnored private var synthetic: Set<ObjectIdentifier> = []
        @ObservationIgnored private var nextEventNumber = 1
        @ObservationIgnored private var rules: Task<WKContentRuleList, Error>?
        @ObservationIgnored private let proxy = MacBrowserMessageProxy()
        @ObservationIgnored private var inflight: [UUID: MacBrowserEvaluation] = [:]

        init(bundle: Bundle = .main, monitors: any MacComputerEventMonitoring = MacComputerLiveEventMonitoring()) {
            self.monitors = monitors
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.preferences.isElementFullscreenEnabled = false
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            let source = Self.script(bundle: bundle)
            if let source {
                configuration.userContentController.addUserScript(
                    WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
                configuration.userContentController.addScriptMessageHandler(
                    proxy, contentWorld: world, name: Self.messageName)
            }
            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
            webView.allowsLinkPreview = false
            webView.allowsMagnification = false
            super.init()
            if source == nil { unavailable = "The browser pane's page script is missing or altered." }
            proxy.pane = self
            webView.navigationDelegate = self
            webView.uiDelegate = self
            observations = [
                webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.url = view.url }
                },
                webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.title = view.title ?? "" }
                },
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.isLoading = view.isLoading }
                },
            ]
            monitor = monitors.addLocal(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) {
                [weak self] event in
                if let self, self.isHumanPageInput(event) { self.humanInput?() }
                return event
            }
        }

        static func script(bundle: Bundle) -> String? {
            guard let url = bundle.url(forResource: "browser_snapshot", withExtension: "js"),
                let text = try? String(contentsOf: url, encoding: .utf8),
                text.components(separatedBy: placeholder).count == 2,
                let encoded = try? JSONEncoder.sorted.encode(ComputerBrowserPolicy.scriptRules),
                let rules = String(data: encoded, encoding: .utf8)
            else { return nil }
            return text.replacingOccurrences(of: placeholder, with: rules)
        }

        func close() {
            if let monitor { monitors.remove(monitor) }
            monitor = nil
            observations = []
            resolveDialogs(accept: false)
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        func prepare() async throws {
            if let unavailable { throw ComputerHostError("unsupported", unavailable) }
            let task =
                rules
                ?? Task { @MainActor in
                    guard
                        let list = try await WKContentRuleListStore.default().compileContentRuleList(
                            forIdentifier: Self.ruleIdentifier, encodedContentRuleList: Self.ruleList)
                    else { throw ComputerHostError("unsupported", "The browser pane's network rules are unavailable.") }
                    self.webView.configuration.userContentController.add(list)
                    return list
                }
            rules = task
            do { _ = try await task.value } catch {
                rules = nil
                throw ComputerHostError("unsupported", "The browser pane's network rules could not be compiled.")
            }
        }

        var rulesInstalled: Bool { rules != nil && unavailable == nil }

        func mark() -> Int { sequence }

        private func record(_ event: MacBrowserLoadEvent) {
            sequence += 1
            events.append((sequence, event))
            if events.count > 64 { events.removeFirst(events.count - 64) }
        }

        func takeNotices() -> [MacBrowserNotice] {
            defer { notices = [] }
            return notices
        }

        private func notice(_ value: MacBrowserNotice) {
            if notices.count < 16 { notices.append(value) }
        }

        func load(_ url: URL, userInitiated: Bool = false) {
            if userInitiated { userNavigation = true }
            webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        }

        func history(_ action: String, userInitiated: Bool = false) -> Bool {
            if userInitiated { userNavigation = true }
            switch action {
            case "back":
                guard webView.canGoBack else { return false }
                webView.goBack()
            case "forward":
                guard webView.canGoForward else { return false }
                webView.goForward()
            case "reload":
                guard webView.url != nil else { return false }
                webView.reload()
            default: return false
            }
            return true
        }

        func waitForLoad(after mark: Int, within limit: Duration) async throws -> MacBrowserLoadEvent? {
            let deadline = ContinuousClock.now.advanced(by: limit)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let terminal = events.last(where: { $0.sequence > mark && $0.event != .started })?.event,
                    terminal != .finished || !webView.isLoading
                {
                    return terminal
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            return nil
        }

        func waitForMainFrame(within limit: Duration) async throws -> MacBrowserFrame? {
            let deadline = ContinuousClock.now.advanced(by: limit)
            while ContinuousClock.now < deadline {
                if let main = frames.first(where: \.isMain) { return main }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(25))
            }
            return frames.first(where: \.isMain)
        }

        func call(
            _ function: MacBrowserScriptCall, _ args: [String: Any], in frame: MacBrowserFrame, within limit: Duration
        )
            async throws -> JSONValue
        {
            try Task.checkCancellation()
            let body =
                "const api = globalThis.__astralBrowser; if (!api || api.token() !== expected) return {error: 'stale_ref'}; return await api.\(function.rawValue)(args);"
            let evaluation = MacBrowserEvaluation()
            let key = UUID()
            inflight[key] = evaluation
            defer { inflight[key] = nil }
            let value = try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        evaluation.begin(continuation, limit: limit)
                        webView.callAsyncJavaScript(
                            body, arguments: ["args": args, "expected": frame.token], in: frame.info, in: world
                        ) { result in
                            switch result {
                            case .success(let value): evaluation.finish(.success(value))
                            case .failure(let error):
                                let gone =
                                    (error as? WKError)?.code == .javaScriptInvalidFrameTarget
                                    || (error as? WKError)?.code == .webViewInvalidated
                                evaluation.finish(
                                    .failure(
                                        gone
                                            ? ComputerHostError(
                                                "stale_ref", "That part of the page is gone. Take a fresh snapshot.")
                                            : ComputerHostError(
                                                "failed", "The page did not answer Astral's request.")))
                            }
                        }
                    }
                }, onCancel: { Task { @MainActor in evaluation.finish(.failure(CancellationError())) } })
            return Self.bridge(value as Any)
        }

        static func bridge(_ value: Any) -> JSONValue {
            switch value {
            case let dictionary as [String: Any]: return .object(dictionary.mapValues(bridge))
            case let array as [Any]: return .array(array.map(bridge))
            case let string as String: return .string(string)
            case let number as NSNumber:
                return CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? .bool(number.boolValue) : .number(number.doubleValue)
            default: return .null
            }
        }

        fileprivate func receive(_ message: WKScriptMessage) -> Any? {
            guard message.world == world, let body = message.body as? [String: Any],
                let kind = body["kind"] as? String, let token = body["token"] as? String,
                (8...64).contains(token.count)
            else { return nil }
            let frame = message.frameInfo
            if kind == "bye" {
                frames.removeAll { $0.token == token }
                return nil
            }
            guard kind == "hello" else { return nil }
            let origin = ComputerBrowserPolicy.origin(
                scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host,
                port: frame.securityOrigin.port == 0 ? nil : frame.securityOrigin.port)
            let url = String((body["url"] as? String ?? "").prefix(4096))
            if frame.isMainFrame {
                generation += 1
                nextFrame = 1
                frames = [MacBrowserFrame(token: token, id: "f0", info: frame, isMain: true, url: url, origin: origin)]
                return ["frame": "f0"]
            }
            frames.removeAll { $0.token == token }
            guard frames.count < 64 else { return nil }
            let id = "f\(nextFrame)"
            nextFrame += 1
            frames.append(MacBrowserFrame(token: token, id: id, info: frame, isMain: false, url: url, origin: origin))
            return ["frame": id]
        }

        func answer(accept: Bool, text: String?) throws -> MacBrowserDialog {
            guard let dialog = dialogs.first, let reply = replies.removeValue(forKey: dialog.id) else {
                throw ComputerHostError("no_dialog", "No page dialog is waiting.")
            }
            dialogs.removeFirst()
            reply(accept, text)
            return dialog
        }

        private func resolveDialogs(accept: Bool) {
            let pending = dialogs
            dialogs = []
            for dialog in pending { replies.removeValue(forKey: dialog.id)?(accept, nil) }
        }

        private func enqueue(
            _ type: String, message: String, defaultText: String?, frame: WKFrameInfo,
            reply: @escaping (Bool, String?) -> Void
        ) {
            guard dialogs.count < 4 else {
                reply(false, nil)
                return
            }
            let origin = ComputerBrowserPolicy.origin(
                scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host,
                port: frame.securityOrigin.port == 0 ? nil : frame.securityOrigin.port)
            let dialog = MacBrowserDialog(
                id: UUID(), type: type, message: message, defaultText: defaultText, origin: origin)
            replies[dialog.id] = reply
            dialogs.append(dialog)
            for evaluation in inflight.values {
                evaluation.finish(.failure(ComputerHostError("pending_dialog", "A page dialog opened.")))
            }
        }

        func nativeClick(at point: CGPoint, right: Bool, count: Int) throws {
            guard let window = webView.window, webView.bounds.contains(point) else {
                throw ComputerHostError("unsupported", "Open the browser pane to let Astral click this control.")
            }
            let location = webView.convert(point, to: nil)
            for index in 1...max(1, min(2, count)) {
                let kinds: [NSEvent.EventType] =
                    right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
                let events = kinds.compactMap { kind in
                    NSEvent.mouseEvent(
                        with: kind, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: nextEventNumber, clickCount: index, pressure: kind == kinds[0] ? 1 : 0)
                }
                nextEventNumber += 1
                guard events.count == 2 else {
                    throw ComputerHostError("failed", "The pane click could not be created.")
                }
                for event in events { synthetic.insert(ObjectIdentifier(event)) }
                defer { for event in events { synthetic.remove(ObjectIdentifier(event)) } }
                if right {
                    webView.rightMouseDown(with: events[0])
                    webView.rightMouseUp(with: events[1])
                } else {
                    webView.mouseDown(with: events[0])
                    webView.mouseUp(with: events[1])
                }
            }
        }

        func isSynthetic(_ event: NSEvent) -> Bool { synthetic.contains(ObjectIdentifier(event)) }

        func isHumanPageInput(_ event: NSEvent) -> Bool {
            guard let window = webView.window, event.window === window, !isSynthetic(event) else { return false }
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                guard webView.bounds.contains(webView.convert(event.locationInWindow, from: nil)) else { return false }
                guard let content = window.contentView,
                    let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
                else { return true }
                return hit === webView || hit.isDescendant(of: webView)
            case .keyDown:
                guard let responder = window.firstResponder as? NSView,
                    responder === webView || responder.isDescendant(of: webView)
                else { return false }
                if event.keyCode == 53 { return false }
                return !(event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == ".")
            default: return false
            }
        }

        func image(rect: CGRect?, width: CGFloat, within limit: Duration) async throws -> CGImage {
            guard webView.window != nil else {
                throw ComputerHostError("unsupported", "Open the browser pane to take a screenshot of it.")
            }
            let configuration = WKSnapshotConfiguration()
            if let rect { configuration.rect = rect }
            configuration.snapshotWidth = NSNumber(value: Double(width))
            configuration.afterScreenUpdates = true
            let evaluation = MacBrowserEvaluation()
            let key = UUID()
            inflight[key] = evaluation
            defer { inflight[key] = nil }
            let value = try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        evaluation.begin(continuation, limit: limit)
                        webView.takeSnapshot(with: configuration) { image, _ in
                            if let image {
                                evaluation.finish(.success(image))
                            } else {
                                evaluation.finish(
                                    .failure(ComputerHostError("failed", "The browser pane could not be captured.")))
                            }
                        }
                    }
                }, onCancel: { Task { @MainActor in evaluation.finish(.failure(CancellationError())) } })
            guard let image = value as? NSImage,
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { throw ComputerHostError("failed", "The browser pane could not be captured.") }
            return cgImage
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard rulesInstalled, let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            guard let target = navigationAction.targetFrame else {
                notice(.popup(url.absoluteString))
                decisionHandler(.cancel)
                return
            }
            if navigationAction.shouldPerformDownload {
                notice(.download(url.absoluteString))
                decisionHandler(.cancel)
                return
            }
            if !target.isMainFrame && ["about:blank", "about:srcdoc"].contains(url.absoluteString) {
                decisionHandler(.allow)
                return
            }
            guard ComputerBrowserPolicy.isNavigable(url), let origin = ComputerBrowserPolicy.origin(of: url) else {
                if target.isMainFrame {
                    notice(.scheme(url.scheme ?? ""))
                    record(.refused)
                }
                decisionHandler(.cancel)
                return
            }
            guard target.isMainFrame else {
                decisionHandler(.allow)
                return
            }
            guard navigationRule(url, userNavigation) else {
                notice(.origin(origin))
                record(.refused)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            let http = navigationResponse.response as? HTTPURLResponse
            let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
            if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
                notice(.download(navigationResponse.response.url?.absoluteString))
                if navigationResponse.isForMainFrame { record(.refused) }
                decisionHandler(.cancel)
                return
            }
            if navigationResponse.isForMainFrame { mainStatus = http?.statusCode }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            record(.started)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            generation += 1
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            userNavigation = false
            record(.finished)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            failed(error)
        }

        private func failed(_ error: Error) {
            userNavigation = false
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
            record(.failed(String(nsError.localizedDescription.prefix(200))))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            frames = []
            generation += 1
            resolveDialogs(accept: false)
            record(.crashed)
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            notice(.popup(navigationAction.request.url?.absoluteString))
            return nil
        }

        func webView(
            _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
        ) {
            enqueue("alert", message: message, defaultText: nil, frame: frame) { _, _ in completionHandler() }
        }

        func webView(
            _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
        ) {
            enqueue("confirm", message: message, defaultText: nil, frame: frame) { accept, _ in
                completionHandler(accept)
            }
        }

        func webView(
            _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void
        ) {
            enqueue("prompt", message: prompt, defaultText: defaultText, frame: frame) { accept, text in
                completionHandler(accept ? (text ?? defaultText ?? "") : nil)
            }
        }

        func webView(
            _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void
        ) {
            notice(.upload)
            completionHandler(nil)
        }

        func webView(
            _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }
    }

    extension JSONEncoder {
        fileprivate static var sorted: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }
    }
#endif
