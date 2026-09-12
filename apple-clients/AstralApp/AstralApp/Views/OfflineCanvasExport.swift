import AstralCore
import CryptoKit
import SwiftUI
import WebKit

enum CanvasExportFailure: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "This page couldn't be exported. Try again or open it in the web client."
    }
}

/// Only bundled executable bytes enter this document. The authenticated
/// response is inserted as base64 display data, never as script source.
enum OfflineCanvasExportDocument {
    static func html(presentation: Data, bundle: Bundle = .main) throws -> String {
        guard presentation.count <= CanvasExportPolicy.maximumOutputBytes,
            let templateURL = bundle.url(forResource: "export", withExtension: "html"),
            let manifestURL = bundle.url(forResource: "export.manifest", withExtension: "json")
        else { throw CanvasExportFailure.unavailable }
        let template = try Data(contentsOf: templateURL)
        let manifest = try JSONValue.parse(Data(contentsOf: manifestURL))
        let digest = SHA256.hash(data: template).map { String(format: "%02x", $0) }.joined()
        guard template.count <= 16 * 1024 * 1024,
            manifest["template_sha256"]?.stringValue == digest,
            let text = String(data: template, encoding: .utf8),
            text.components(separatedBy: "__ASTRAL_EXPORT_PRESENTATION_BASE64__").count == 2
        else { throw CanvasExportFailure.unavailable }
        return text.replacingOccurrences(
            of: "__ASTRAL_EXPORT_PRESENTATION_BASE64__", with: presentation.base64EncodedString())
    }

    static func windowSize(_ presentation: Data) throws -> CGSize {
        let value = try JSONValue.parse(presentation)
        guard let width = value["viewport"]?["window_width"]?.numberValue,
            let height = value["viewport"]?["window_height"]?.numberValue,
            width.isFinite, height.isFinite, (64...16384).contains(width), (32...16384).contains(height)
        else { throw CanvasExportFailure.unavailable }
        return CGSize(width: width, height: height)
    }
}

/// Callback, cancellation and timeout compete for one continuation. Late
/// WebKit callbacks cannot resume a newer export or keep its request alive.
@MainActor
private final class CanvasExportEvaluation {
    private var continuation: CheckedContinuation<Any?, Error>?
    private var result: Result<Any?, Error>?
    private var timeout: Task<Void, Never>?

    func begin(_ continuation: CheckedContinuation<Any?, Error>) {
        if let result {
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.finish(.failure(CanvasExportFailure.unavailable))
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
final class OfflineCanvasExport: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var initialNavigation = true

    static func render(
        presentation: Data, bundle: Bundle = .main, isCurrent: () -> Bool
    ) async throws -> Data {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        let html = try OfflineCanvasExportDocument.html(presentation: presentation, bundle: bundle)
        let size = try OfflineCanvasExportDocument.windowSize(presentation)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let compiled = try await boundedCallback { evaluation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "astral-canvas-export-network-deny-v1",
                encodedContentRuleList:
                    #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]"#
            ) { rules, error in
                if let error { evaluation.finish(.failure(error)) } else { evaluation.finish(.success(rules)) }
            }
        }
        try Task.checkCancellation()
        guard isCurrent(), let rules = compiled as? WKContentRuleList else { throw CanvasExportFailure.unavailable }
        configuration.userContentController.add(rules)
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        let delegate = OfflineCanvasExport()
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        #if os(iOS)
            webView.scrollView.isScrollEnabled = false
        #endif
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeAllContentRuleLists()
            webView.loadHTMLString("", baseURL: nil)
            webView.removeFromSuperview()
        }
        webView.loadHTMLString(html, baseURL: nil)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let result = try await evaluate(
                webView, script: "window.AstralExportResult || ({state:'loading'})")
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw CanvasExportFailure.unavailable }
            if let object = result as? [String: Any], let state = object["state"] as? String {
                if state == "error" { throw CanvasExportFailure.unavailable }
                if state == "ready" {
                    guard let output = object["html"] as? String, !output.isEmpty,
                        output.utf8.count <= CanvasExportPolicy.maximumOutputBytes
                    else { throw CanvasExportFailure.unavailable }
                    return Data(output.utf8)
                }
                guard state == "loading" else { throw CanvasExportFailure.unavailable }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CanvasExportFailure.unavailable
    }

    private static func evaluate(_ webView: WKWebView, script: String) async throws -> Any? {
        try await boundedCallback { evaluation in
            webView.evaluateJavaScript(script) { result, error in
                if let error { evaluation.finish(.failure(error)) } else { evaluation.finish(.success(result)) }
            }
        }
    }

    private static func boundedCallback(_ begin: (CanvasExportEvaluation) -> Void) async throws -> Any? {
        let evaluation = CanvasExportEvaluation()
        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    evaluation.begin(continuation)
                    begin(evaluation)
                }
            },
            onCancel: {
                Task { @MainActor in evaluation.finish(.failure(CancellationError())) }
            })
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let allow =
            initialNavigation && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url?.absoluteString == "about:blank"
        if allow { initialNavigation = false }
        decisionHandler(allow ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }
}
