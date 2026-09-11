import AstralCore
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
        XCTAssertTrue(["ready", "error"].contains(state))
        let inert = try await view.evaluateJavaScript("window.compromised === undefined")
        XCTAssertEqual(inert as? Bool, true)
        coordinator.update(view, component: try component(#"{"type":"bar_chart","datasets":[]}"#), viewportWidth: 400)
        let empty = try await waitForState(view, expected: "empty")
        XCTAssertEqual(empty, "empty")
    }

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
