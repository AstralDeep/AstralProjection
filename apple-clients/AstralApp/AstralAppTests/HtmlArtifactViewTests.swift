// Tests for HtmlArtifactView.swift: html_artifact decoding and size cap, the sandboxed srcdoc host page, content
// rules that compile and block every host but the allowlist, a navigation delegate that cancels link clicks, and
// light/dark propagation into prefers-color-scheme, all against real WebKit and a loopback fixture server.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import WebKit
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class HtmlArtifactViewTests: XCTestCase {
        private func component(_ json: String) throws -> AstralComponent {
            try XCTUnwrap(AstralComponent(json: JSONValue.parse(Data(json.utf8))))
        }

        private func artifact(_ html: String, title: String = "Fixture page") -> AstralComponent {
            AstralComponent(
                type: "html_artifact",
                raw: .object([
                    "type": .string("html_artifact"), "id": .string("art_fixture"), "title": .string(title),
                    "kind": .string("visualization"), "version": .number(2), "html": .string(html),
                    "created_at": .string("2026-11-01T12:00:00Z"),
                ]))
        }

        private func eventually(timeout: Double = 8, _ condition: () async throws -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if try await condition() { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return try await condition()
        }

        private final class Mount {
            let window: NSWindow
            let webView: WKWebView
            let coordinator: HtmlArtifactCoordinator

            init(rules: String) {
                coordinator = HtmlArtifactCoordinator()
                coordinator.rules = rules
                webView = HtmlArtifactCoordinator.webView()
                window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 640, height: 480), styleMask: .borderless,
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                webView.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
                window.contentView = webView
            }

            func load(_ html: String, dark: Bool = true) {
                coordinator.update(
                    webView, html: html, title: "Fixture page", dark: dark, background: .black,
                    backgroundCSS: "#121214")
            }

            func evaluate(_ script: String) async throws -> Any? {
                try await webView.evaluateJavaScript(script)
            }

            func close() {
                coordinator.dismantle(webView)
                window.contentView = nil
                window.close()
            }
        }

        private func servers() async throws -> (MacBrowserFixtureServer, MacBrowserFixtureServer) {
            let page = MacBrowserFixturePage(contentType: "image/gif", body: "GIF89a")
            let allowed = try MacBrowserFixtureServer(
                pages: ["/allowed.gif": page, "/ran.gif": page, "/next": .init(body: "<p>next</p>")])
            let blocked = try MacBrowserFixtureServer(pages: ["/blocked.gif": page])
            allowed.start()
            blocked.start()
            await XCTWaiter().fulfillment(of: [allowed.ready, blocked.ready], timeout: 5)
            return (allowed, blocked)
        }

        func testDecodesTheServerShapeAndRefusesOversizedOrForeignPayloads() throws {
            let document = try XCTUnwrap(HtmlArtifactDocument(component: artifact("<!doctype html><p>Hi</p>")))
            XCTAssertEqual(document.id, "art_fixture")
            XCTAssertEqual(document.title, "Fixture page")
            XCTAssertEqual(document.kind, "visualization")
            XCTAssertEqual(document.version, 2)
            XCTAssertEqual(document.createdAt, "2026-11-01T12:00:00Z")
            XCTAssertEqual(document.filename, "fixture-page-v2.html")
            let limit = String(repeating: "a", count: HtmlArtifactDocument.maximumBytes)
            XCTAssertNotNil(HtmlArtifactDocument(component: artifact(limit)))
            XCTAssertNil(HtmlArtifactDocument(component: artifact(limit + "a")))
            XCTAssertNil(HtmlArtifactDocument(component: artifact("")))
            XCTAssertNil(HtmlArtifactDocument(component: try component(#"{"type":"artifact","html":"<p>x</p>"}"#)))
            XCTAssertNil(
                HtmlArtifactDocument(component: try component(#"{"type":"html_artifact","title":"No body"}"#)))
            let odd = try XCTUnwrap(
                HtmlArtifactDocument(
                    component: try component(#"{"type":"html_artifact","html":"<p>x</p>","kind":"virus"}"#)))
            XCTAssertNil(odd.kind)
            XCTAssertNil(odd.version)
            XCTAssertEqual(odd.filename, "astraldeep-artifact.html")
        }

        func testHostPageEmbedsTheEscapedSourceInAScriptsOnlySandbox() throws {
            let hostile = #"<p title="x">A & B</p>"><script>parent.document.title='owned'</script>"#
            let page = HtmlArtifactDocument.hostPage(html: hostile, title: #"Q"<b>"#, background: "#121214")
            XCTAssertTrue(page.contains(#"<iframe sandbox="allow-scripts" "#))
            XCTAssertFalse(page.contains("allow-same-origin"))
            XCTAssertFalse(page.contains("allow-top-navigation"))
            XCTAssertFalse(page.contains("allow-popups"))
            XCTAssertTrue(page.contains(#"style="border:0;width:100%;height:100%""#))
            XCTAssertTrue(page.contains("connect-src 'none'"))
            XCTAssertTrue(page.contains(#"title="Q&quot;&lt;b&gt;""#))
            XCTAssertTrue(
                page.contains(
                    "srcdoc=\"&lt;p title=&quot;x&quot;&gt;A &amp; B&lt;/p&gt;&quot;&gt;&lt;script&gt;parent.document.title=&#39;owned&#39;&lt;/script&gt;\""
                ))
            XCTAssertEqual(page.components(separatedBy: "<script").count, 1)
        }

        func testContentRulesCompileAndBlockEveryHostButTheAllowlist() async throws {
            let production = HtmlArtifactDocument.productionRules
            let rules = try XCTUnwrap(JSONValue.parse(Data(production.utf8)).arrayValue)
            let filters = rules.compactMap { $0["trigger"]?["url-filter"]?.stringValue }
            let actions = rules.compactMap { $0["action"]?["type"]?.stringValue }
            XCTAssertEqual(Array(filters.prefix(4)), ["^https?:", "^wss?:", "^ftp:", "^file:"])
            XCTAssertEqual(Array(actions.prefix(4)), Array(repeating: "block", count: 4))
            let allowlist = HtmlArtifactDocument.allowedHosts.map {
                "^https://" + $0.replacingOccurrences(of: ".", with: "\\.") + "/"
            }
            XCTAssertEqual(Array(filters.dropFirst(4)), allowlist)
            XCTAssertEqual(Set(actions.dropFirst(4)), ["ignore-previous-rules"])
            let compiled = expectation(description: "production rules compile")
            HtmlArtifactRuleStore.shared.rules(production) { result in
                if case .success = result { compiled.fulfill() }
            }
            await fulfillment(of: [compiled], timeout: 10)

            let (allowed, blocked) = try await servers()
            defer {
                allowed.stop()
                blocked.stop()
            }
            let mount = Mount(
                rules: HtmlArtifactDocument.contentRules(allowing: ["http://127.0.0.1:\(allowed.port)"]))
            defer { mount.close() }
            mount.load(
                """
                <!doctype html><body><img src="http://127.0.0.1:\(blocked.port)/blocked.gif">
                <img src="http://127.0.0.1:\(allowed.port)/allowed.gif">
                <script>new Image().src = 'http://127.0.0.1:\(allowed.port)/ran.gif'</script></body>
                """)
            let loaded = try await eventually {
                let seen = allowed.requests.joined(separator: "\n")
                return seen.contains("/allowed.gif") && seen.contains("/ran.gif")
            }
            XCTAssertTrue(loaded, "allowlisted loads and the sandboxed script must run: \(allowed.requests)")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(blocked.requests.isEmpty, "\(blocked.requests)")
            XCTAssertEqual(mount.coordinator.phase, .loaded)
            XCTAssertFalse(mount.webView.configuration.websiteDataStore.isPersistent)
            XCTAssertFalse(mount.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
            XCTAssertNotNil(mount.webView.uiDelegate)
        }

        func testNavigationPolicyAllowsOnlyTheInitialHostAndSourceLoads() {
            var pending = HtmlArtifactNavigationPolicy.Pending(mainFrame: true, sourceDocument: true)
            let blank = URL(string: "about:blank")
            let source = URL(string: "about:srcdoc")
            let link = URL(string: "https://example.com/next")
            XCTAssertEqual(HtmlArtifactNavigationPolicy.decide(url: link, mainFrame: true, pending: &pending), .cancel)
            XCTAssertEqual(HtmlArtifactNavigationPolicy.decide(url: blank, mainFrame: true, pending: &pending), .allow)
            XCTAssertEqual(HtmlArtifactNavigationPolicy.decide(url: blank, mainFrame: true, pending: &pending), .cancel)
            XCTAssertEqual(
                HtmlArtifactNavigationPolicy.decide(url: source, mainFrame: true, pending: &pending), .cancel)
            XCTAssertEqual(
                HtmlArtifactNavigationPolicy.decide(url: source, mainFrame: false, pending: &pending), .allow)
            XCTAssertEqual(
                HtmlArtifactNavigationPolicy.decide(url: source, mainFrame: false, pending: &pending), .cancel)
            XCTAssertEqual(HtmlArtifactNavigationPolicy.decide(url: link, mainFrame: false, pending: &pending), .cancel)
            XCTAssertEqual(HtmlArtifactNavigationPolicy.decide(url: link, mainFrame: nil, pending: &pending), .cancel)
            XCTAssertEqual(pending, .init())
        }

        func testLinkClicksInsideTheArtifactAreCancelledBeforeTheyLeave() async throws {
            let (allowed, blocked) = try await servers()
            defer {
                allowed.stop()
                blocked.stop()
            }
            let mount = Mount(
                rules: HtmlArtifactDocument.contentRules(allowing: ["http://127.0.0.1:\(allowed.port)"]))
            defer { mount.close() }
            let next = "http://127.0.0.1:\(allowed.port)/next"
            mount.load(
                """
                <!doctype html><body><a id="go" href="\(next)">Go</a>
                <a id="top" href="\(next)" target="_top">Top</a>
                <script>setTimeout(() => { document.getElementById('go').click(); document.getElementById('top').click(); }, 100)</script></body>
                """)
            let cancelled = try await eventually {
                mount.coordinator.cancelledNavigations.contains { $0.absoluteString == next }
            }
            XCTAssertTrue(cancelled, "\(mount.coordinator.cancelledNavigations)")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(allowed.requests.contains { $0.contains("/next") }, "\(allowed.requests)")
            let sandbox = try await mount.evaluate("document.querySelector('iframe').getAttribute('sandbox')")
            XCTAssertEqual(sandbox as? String, "allow-scripts")
            let isolated = try await mount.evaluate("document.querySelector('iframe').contentDocument === null")
            XCTAssertEqual(isolated as? Bool, true)
            XCTAssertEqual(mount.webView.url?.absoluteString, "about:blank")
        }

        func testAppearanceFollowsTheAppIntoPrefersColorScheme() async throws {
            let mount = Mount(rules: HtmlArtifactDocument.productionRules)
            defer { mount.close() }
            mount.load("<!doctype html><p>Theme</p>", dark: true)
            let loaded = try await eventually { mount.coordinator.phase == .loaded }
            XCTAssertTrue(loaded)
            XCTAssertEqual(mount.webView.appearance?.name, .darkAqua)
            let dark = try await mount.evaluate("matchMedia('(prefers-color-scheme: dark)').matches")
            XCTAssertEqual(dark as? Bool, true)
            mount.load("<!doctype html><p>Theme</p>", dark: false)
            XCTAssertEqual(mount.webView.appearance?.name, .aqua)
            let light = try await eventually {
                try await mount.evaluate("matchMedia('(prefers-color-scheme: light)').matches") as? Bool == true
            }
            XCTAssertTrue(light)
            XCTAssertEqual(mount.coordinator.phase, .loaded)
        }

        func testTheViewShowsItsToolbarAndAnUnavailableStateForAnInvalidPayload() throws {
            let model = AppModel(tokenStore: InMemoryTokenStore())
            let theme = ThemeStore()
            for payload in [artifact("<p>ok</p>"), artifact("")] {
                let view = NSHostingView(
                    rootView: HtmlArtifactView(component: payload).environment(model).environment(theme)
                        .frame(width: 640))
                view.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(view.fittingSize.height, 30)
            }
        }
    }
#endif
