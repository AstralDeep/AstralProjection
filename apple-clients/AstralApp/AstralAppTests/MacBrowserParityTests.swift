// Drives the browser pane parity verbs through real WebKit loads: find, subtree and depth-bounded snapshots, hover,
// zoom, console and network capture with flood and forgery resistance, page-world evaluation, viewport emulation
// and tabs, including that every verb acts on the active tab.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import WebKit
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacBrowserParityTests: XCTestCase {
        private var harness: MacBrowserHarness!

        override func setUp() async throws {
            harness = try MacBrowserHarness()
            await harness.start()
        }

        override func tearDown() async throws {
            harness.close()
            harness = nil
        }

        private func lines(_ result: [String: JSONValue]) -> [String] {
            result["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }

        private func matches(_ result: [String: JSONValue]) -> [(ref: String, line: String, frame: String?)] {
            (result["matches"]?.arrayValue ?? []).compactMap { match in
                guard let ref = match["ref"]?.stringValue, let line = match["line"]?.stringValue else { return nil }
                return (ref, line, match["frame"]?.stringValue)
            }
        }

        func testFindReturnsMatchingRefsThatOtherVerbsAccept() async throws {
            _ = try await harness.open("/form")
            let found = try await harness.run("browser_find", ["query": .string("ACCEPT")])
            let id = try XCTUnwrap(found["snapshot_id"]?.stringValue)
            XCTAssertTrue(id.hasPrefix("s"))
            let terms = try XCTUnwrap(matches(found).first { $0.line.contains("checkbox \"Accept terms\"") })
            XCTAssertFalse(terms.ref.isEmpty)
            XCTAssertEqual(found["truncated"], .bool(false))
            _ = try await harness.run("browser_click", ["ref": .string(terms.ref), "snapshot_id": .string(id)])
            try await harness.expectPage("document.getElementById('terms').checked", true)
            let heading = try await harness.run("browser_find", ["query": .string("order")])
            XCTAssertTrue(matches(heading).contains { $0.line.hasPrefix("heading \"Order\"") })
            let one = try await harness.run("browser_find", ["query": .string("button"), "max": .number(1)])
            XCTAssertEqual(matches(one).count, 1)
            XCTAssertEqual(one["truncated"], .bool(true))
            let inner = try await harness.run("browser_find", ["query": .string("inner button")])
            XCTAssertEqual(matches(inner).first?.frame, "f1")
            for secret in ["hunter2", "4111111111111111", "123456"] {
                let probe = try await harness.run("browser_find", ["query": .string(secret)])
                XCTAssertTrue(matches(probe).isEmpty, secret)
            }
            let full = try await harness.snapshot()
            XCTAssertEqual(
                try harness.ref(full.lines, containing: "checkbox \"Accept terms\""), terms.ref,
                "find and snapshot share one reference scheme")
            await harness.expectCode("browser_find", ["query": .string("  ")], "out_of_range")
        }

        func testSnapshotRefAliasAndDepthBoundTheTree() async throws {
            _ = try await harness.open("/form")
            let full = try await harness.snapshot()
            let nav = try harness.ref(full.lines, containing: "navigation \"Primary\"")
            let scoped = lines(try await harness.run("browser_snapshot", ["ref": .string(nav)]))
            XCTAssertTrue(scoped.contains { $0.contains("link \"Next page\"") })
            XCTAssertFalse(scoped.contains { $0.contains("Sign in") })
            let both = try await harness.run("browser_snapshot", ["ref": .string(nav), "scope_ref": .string(nav)])
            XCTAssertEqual(lines(both).count, scoped.count)
            await harness.expectCode(
                "browser_snapshot", ["ref": .string(nav), "scope_ref": .string("e999999")], "out_of_range")
            await harness.expectCode("browser_snapshot", ["ref": .string("e999999")], "stale_ref")
            let shallow = lines(try await harness.run("browser_snapshot", ["depth": .number(1)])).joined(
                separator: "\n")
            XCTAssertTrue(shallow.contains("navigation \"Primary\""), shallow)
            XCTAssertFalse(shallow.contains("heading \"Order\""), shallow)
            XCTAssertFalse(shallow.contains("link \"Next page\""), shallow)
            let middle = lines(try await harness.run("browser_snapshot", ["depth": .number(2)])).joined(separator: "\n")
            XCTAssertTrue(middle.contains("heading \"Order\""), middle)
            XCTAssertFalse(middle.contains("textbox \"Name\""), middle)
            let deep = lines(try await harness.run("browser_snapshot", ["depth": .number(3)])).joined(separator: "\n")
            XCTAssertTrue(deep.contains("textbox \"Name\""), deep)
            let page = lines(
                try await harness.run("browser_snapshot", ["mode": .string("all"), "ref": .string(nav)]))
            XCTAssertTrue(page.contains { $0.contains("link \"Elsewhere\"") })
        }

        func testHoverDispatchesPointerAndMouseEventsAndLeavesThePreviousTarget() async throws {
            _ = try await harness.open("/hover")
            let snap = try await harness.snapshot()
            let menu = try harness.ref(snap.lines, containing: "button \"Menu\"")
            let other = try harness.ref(snap.lines, containing: "button \"Other\"")
            let hovered = try await harness.run(
                "browser_hover", ["ref": .string(menu), "snapshot_id": .string(snap.id)])
            XCTAssertEqual(hovered["hovered"], .string(menu))
            let events = try await harness.page("window.hovers.join(',')") as? String ?? ""
            for type in ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"] {
                XCTAssertTrue(events.contains(type), events)
            }
            try await harness.expectPage("document.getElementById('panel').hidden", false)
            _ = try await harness.run("browser_hover", ["ref": .string(other), "snapshot_id": .string(snap.id)])
            try await harness.expectEventually {
                (try await self.harness.page("window.hovers.includes('mouseleave')") as? Bool) == true
            }
            XCTAssertEqual(harness.takeovers, 0)
            await harness.expectCode(
                "browser_hover", ["ref": .string(menu), "snapshot_id": .string("s999")], "stale_ref")
            await harness.expectCode("browser_hover", ["ref": .string(menu)], "out_of_range")
        }

        func testZoomCropsAViewportRegionWithMasksAndRejectsOutOfBounds() async throws {
            _ = try await harness.open("/form")
            let zoomed = try await harness.run(
                "browser_zoom",
                ["x0": .number(0), "y0": .number(0), "x1": .number(200), "y1": .number(100), "scale": .number(2)])
            XCTAssertEqual(zoomed["width"], .number(400))
            XCTAssertEqual(zoomed["height"], .number(200))
            XCTAssertEqual(zoomed["media_type"], .string("image/jpeg"))
            XCTAssertEqual(
                zoomed["region"],
                .object(["x0": .number(0), "y0": .number(0), "x1": .number(200), "y1": .number(100)]))
            let data = try XCTUnwrap(Data(base64Encoded: zoomed["base64"]?.stringValue ?? ""))
            XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
            let edge = try await harness.run(
                "browser_zoom", ["x0": .number(1000), "y0": .number(0), "x1": .number(2000), "y1": .number(50)])
            XCTAssertEqual(edge["region"]?["x1"], .number(1024))
            XCTAssertEqual(edge["width"], .number(48))
            let whole = try await harness.run(
                "browser_zoom",
                ["x0": .number(0), "y0": .number(0), "x1": .number(1024), "y1": .number(768), "scale": .number(1)])
            XCTAssertGreaterThanOrEqual(whole["masked"]?.numberValue ?? 0, 3)
            await harness.expectCode(
                "browser_zoom", ["x0": .number(5000), "y0": .number(5000), "x1": .number(5100), "y1": .number(5100)],
                "out_of_range")
            await harness.expectCode(
                "browser_zoom", ["x0": .number(50), "y0": .number(0), "x1": .number(10), "y1": .number(10)],
                "out_of_range")
        }

        func testConsoleCapturesLevelsErrorsRejectionsAndNavigationFailures() async throws {
            _ = try await harness.open("/console")
            try await harness.expectEventually {
                (try await self.harness.entries("browser_console")).count >= 7
            }
            let entries = try await harness.entries("browser_console")
            func entry(_ text: String) -> JSONValue? {
                entries.first { $0["text"]?.stringValue?.contains(text) == true }
            }
            let hello = try XCTUnwrap(entry("hello 42"))
            XCTAssertEqual(hello["level"], .string("log"))
            XCTAssertEqual(hello["source"], .string("console"))
            XCTAssertEqual(hello["url"], .string(harness.url("/console")))
            XCTAssertGreaterThan(hello["line"]?.numberValue ?? 0, 0)
            XCTAssertTrue(hello["text"]?.stringValue?.contains("{\"a\":1}") == true)
            XCTAssertNotNil(hello["at"]?.stringValue.flatMap { ISO8601DateFormatter.fractional.date(from: $0) })
            XCTAssertEqual(entry("careful")?["level"], .string("warn"))
            XCTAssertEqual(entry("broken")?["level"], .string("error"))
            XCTAssertEqual(entry("boom")?["source"], .string("exception"))
            XCTAssertEqual(entry("nope")?["source"], .string("rejection"))
            XCTAssertEqual(entry("yyyy")?["text"]?.stringValue?.count, MacBrowserPane.textLimit)
            let errors = try await harness.entries("browser_console", ["level": .string("error")])
            XCTAssertFalse(errors.isEmpty)
            XCTAssertTrue(errors.allSatisfy { $0["level"] == .string("error") })
            let careful = try await harness.entries("browser_console", ["pattern": .string("CAREFUL")])
            XCTAssertEqual(careful.count, 1)
            let limited = try await harness.run("browser_console", ["limit": .number(2)])
            XCTAssertEqual(limited["entries"]?.arrayValue?.count, 2)
            XCTAssertEqual(limited["truncated"], .bool(true))
            let closed = MacBrowserHarness.closedLoopbackPort()
            await harness.expectCode(
                "browser_navigate", ["url": .string("http://127.0.0.1:\(closed)/")], "navigation_failed")
            let failures = try await harness.entries("browser_console", ["pattern": .string("navigation failed")])
            XCTAssertEqual(failures.first?["source"], .string("navigation"))
            harness.driver.userNavigate("http://localhost:\(harness.server.port)/console")
            try await harness.expectEventually { self.harness.pane.webView.url?.host == "localhost" }
            try await harness.expectEventually { !self.harness.pane.isLoading }
            await harness.expectCode("browser_console", [:], "origin_not_approved")
            await harness.expectCode("browser_network", [:], "origin_not_approved")
        }

        func testConsoleCaptureResistsFloodsTamperingAndForgedMessages() async throws {
            _ = try await harness.open("/flood")
            try await harness.expectEventually { self.harness.pane.consoleDropped >= 2900 }
            let pane = harness.pane
            XCTAssertLessThanOrEqual(pane.console.count, MacBrowserPane.entriesPerSecond)
            XCTAssertEqual(pane.console.first?.text, "{\"b\":2}")
            XCTAssertFalse(pane.console.contains { $0.text.contains("forged") || $0.text.contains("tampered") })
            try await harness.expectPage("window.forgeFailed", 3)
            try await harness.expectPage("window.pushed === undefined", true)
            try await harness.expectPage("Object.keys(window.webkit.messageHandlers).length", 0)
            try await harness.expectPage("typeof window.webkit.messageHandlers.astralBrowser", "undefined")
            let before = pane.console.count
            let dropped = pane.consoleDropped
            let forged = """
                const reply = window.webkit.messageHandlers[\(MacBrowserDriver.quoted(pane.channel))].postMessage({
                  v: 1, d: 3, source: 'navigation',
                  e: [{ k: 'c', l: 'warn', t: 'learned channel', source: 'navigation' },
                      { k: 'c', l: 'navigation', t: 'bad level' }, { k: 'x', t: 'bad kind' },
                      { k: 'n', u: 'javascript:alert(1)' }].concat(Array(60).fill({ k: 'c', l: 'log', t: 'bulk' }))
                });
                const answer = reply === undefined ? undefined : await reply;
                return answer === undefined || answer === null ? 'nothing' : typeof answer;
                """
            let reply = try await pane.webView.callAsyncJavaScript(forged, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(reply as? String, "nothing")
            try await harness.expectEventually { self.harness.pane.console.contains { $0.text == "learned channel" } }
            let learned = try XCTUnwrap(pane.console.first { $0.text == "learned channel" })
            XCTAssertEqual(learned.source, "console")
            XCTAssertEqual(learned.level, "warn")
            XCTAssertFalse(pane.console.contains { $0.text == "bad level" || $0.text == "bad kind" })
            XCTAssertFalse(pane.console.contains { $0.source == "navigation" })
            XCTAssertLessThanOrEqual(pane.console.count - before, MacBrowserPane.entriesPerMessage)
            XCTAssertGreaterThanOrEqual(pane.consoleDropped - dropped, 3 + 14)
            XCTAssertFalse(pane.network.contains { $0.url.hasPrefix("javascript:") })
            var window = MacBrowserRateWindow()
            XCTAssertEqual((0..<50).filter { _ in window.admit(at: 10, limit: 50) }.count, 50)
            XCTAssertFalse(window.admit(at: 10.99, limit: 50))
            XCTAssertTrue(window.admit(at: 11, limit: 50))
        }

        func testNetworkRecordsNavigationsAndResourcesWithRedactedQueries() async throws {
            _ = try await harness.run("browser_navigate", ["url": .string(harness.url("/console?token=abc&q=1"))])
            try await harness.expectEventually {
                (try await self.harness.entries("browser_network", ["url_pattern": .string("/next")])).count >= 1
            }
            let all = try await harness.entries("browser_network")
            let navigation = try XCTUnwrap(all.first { $0["type"] == .string("navigation") })
            XCTAssertEqual(navigation["status"], .number(200))
            XCTAssertEqual(navigation["url"], .string(harness.url("/console?token=<redacted>&q=1")))
            XCTAssertEqual(navigation["mime_type"], .string("text/html"))
            let resources = try await harness.entries("browser_network", ["url_pattern": .string("/NEXT")])
            let fetched = try XCTUnwrap(resources.first)
            XCTAssertEqual(fetched["type"], .string("resource"))
            XCTAssertEqual(fetched["url"], .string(harness.url("/next?session=<redacted>&page=2")))
            XCTAssertEqual(fetched["initiator_type"], .string("fetch"))
            XCTAssertNotNil(fetched["duration_ms"]?.numberValue)
            XCTAssertFalse(all.contains { $0["url"]?.stringValue?.contains("zzz") == true })
            XCTAssertFalse(all.contains { $0["url"]?.stringValue?.contains("abc") == true })
            let limited = try await harness.run("browser_network", ["limit": .number(1)])
            XCTAssertEqual(limited["entries"]?.arrayValue?.count, 1)
        }

        func testEvaluateRunsInThePageWorldAndBoundsResultsAndErrors() async throws {
            _ = try await harness.open("/form")
            func result(_ script: String) async throws -> [String: JSONValue] {
                try await harness.run("browser_evaluate", ["script": .string(script)])
            }
            let title = try await result("document.title;")
            XCTAssertEqual(title["result"], .string("Order form"))
            XCTAssertEqual(title["type"], .string("string"))
            let expectations: [(String, JSONValue)] = [
                ("window.events.length", .number(0)),
                ("typeof globalThis.__astralBrowser", .string("undefined")),
                ("const a = 2;\nreturn a * 21;", .number(42)),
                ("await new Promise((done) => setTimeout(() => done(7), 10))", .number(7)),
                (
                    "({list: [1, 'two'], ok: true})",
                    .object(["list": .array([.number(1), .string("two")]), "ok": .bool(true)])
                ),
                ("const o = {}; o.self = o; return o;", .object(["self": .string("[Circular]")])),
                ("document.body", .string("[BODY]")),
            ]
            for (script, expected) in expectations {
                let actual = try await result(script)["result"]
                XCTAssertEqual(actual, expected, script)
            }
            let nothing = try await result("void 0")
            XCTAssertEqual(nothing["result"], .null)
            XCTAssertEqual(nothing["type"], .string("undefined"))
            let large = try await result("'x'.repeat(60000)")
            XCTAssertEqual(large["truncated"], .bool(true))
            XCTAssertLessThanOrEqual(
                large["result"]?.stringValue?.utf8.count ?? .max, MacBrowserDriver.maximumEvaluationBytes)
            let thrown = await harness.failure("browser_evaluate", ["script": .string("throw new Error('kaput')")])
            XCTAssertEqual(thrown?.code, "script_error")
            XCTAssertTrue(thrown?.message.contains("kaput") == true, thrown?.message ?? "")
            let broken = await harness.failure("browser_evaluate", ["script": .string("return )(")])
            XCTAssertEqual(broken?.code, "script_error")
            XCTAssertTrue(broken?.message.contains("SyntaxError") == true, broken?.message ?? "")
            try await harness.expectPage("document.title", "Order form")
            _ = try await result("document.title = 'changed'")
            try await harness.expectPage("document.title", "changed")
            harness.driver.userNavigate("http://localhost:\(harness.server.port)/next")
            try await harness.expectEventually { self.harness.pane.webView.url?.host == "localhost" }
            try await harness.expectEventually { !self.harness.pane.isLoading }
            await harness.expectCode("browser_evaluate", ["script": .string("1")], "origin_not_approved")
        }

        func testResizeEmulatesPresetsInALetterboxAndFollowsTheColorScheme() async throws {
            _ = try await harness.open("/next")
            let webView = harness.pane.webView
            let slot = try XCTUnwrap(webView.superview).bounds
            let mobile = try await harness.run("browser_resize", ["preset": .string("mobile")])
            XCTAssertEqual(mobile["width"], .number(375))
            XCTAssertEqual(mobile["height"], .number(812))
            XCTAssertEqual(mobile["preset"], .string("mobile"))
            XCTAssertEqual(harness.driver.emulation, ComputerBrowserViewport(width: 375, height: 812))
            XCTAssertLessThan(webView.pageZoom, 1)
            XCTAssertEqual(webView.frame.midX, slot.midX, accuracy: 1)
            XCTAssertLessThanOrEqual(webView.frame.height, slot.height)
            try await harness.expectEventually {
                let width = try await self.harness.page("innerWidth") as? Double ?? 0
                return abs(width - 375) <= 1
            }
            let tablet = try await harness.run("browser_resize", ["preset": .string("tablet")])
            XCTAssertEqual(tablet["width"], .number(768))
            let custom = try await harness.run("browser_resize", ["width": .number(1600), "height": .number(900)])
            XCTAssertEqual(custom["preset"], .string("custom"))
            XCTAssertEqual(custom["scale"]?.numberValue ?? 0, 0.64, accuracy: 0.001)
            try await harness.expectEventually {
                let width = try await self.harness.page("innerWidth") as? Double ?? 0
                return abs(width - 1600) <= 2
            }
            let dark = try await harness.run("browser_resize", ["color_scheme": .string("dark")])
            XCTAssertEqual(dark["color_scheme"], .string("dark"))
            XCTAssertEqual(dark["width"], .number(1600))
            try await harness.expectEventually {
                (try await self.harness.page("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool) == true
            }
            let desktop = try await harness.run("browser_resize", ["preset": .string("desktop")])
            XCTAssertEqual(desktop["preset"], .string("desktop"))
            XCTAssertEqual(desktop["color_scheme"], .string("dark"))
            XCTAssertEqual(desktop["width"], .number(Double(slot.width)))
            XCTAssertEqual(webView.frame, slot)
            XCTAssertEqual(webView.pageZoom, 1)
            XCTAssertNil(harness.driver.emulation)
            _ = try await harness.run("browser_resize", ["color_scheme": .string("light")])
            try await harness.expectEventually {
                (try await self.harness.page("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool) == false
            }
            await harness.expectCode("browser_resize", ["width": .number(800)], "out_of_range")
            await harness.expectCode("browser_resize", ["width": .number(100), "height": .number(400)], "out_of_range")
            await harness.expectCode("browser_resize", ["preset": .string("watch")], "out_of_range")
        }

        func testLetterboxMathCentersAndScalesDownOnly() throws {
            let mobile = ComputerBrowserViewport(width: 375, height: 812)
            let fitted = mobile.letterbox(in: CGSize(width: 1024, height: 768))
            XCTAssertEqual(fitted.scale, 768.0 / 812.0, accuracy: 0.0001)
            XCTAssertEqual(fitted.frame.height, 768, accuracy: 0.001)
            XCTAssertEqual(fitted.frame.minX, ((1024 - 375 * fitted.scale) / 2).rounded(.down))
            let roomy = mobile.letterbox(in: CGSize(width: 2000, height: 2000))
            XCTAssertEqual(roomy.scale, 1)
            XCTAssertEqual(roomy.frame, CGRect(x: 812, y: 594, width: 375, height: 812))
            XCTAssertEqual(mobile.letterbox(in: .zero).frame, CGRect(x: 0, y: 0, width: 375, height: 812))
            XCTAssertNil(ComputerBrowserViewport(validWidth: 319, height: 800))
            XCTAssertNil(ComputerBrowserViewport(validWidth: 800, height: 2161))
            XCTAssertNotNil(ComputerBrowserViewport(validWidth: 3840, height: 2160))
            let viewport = MacBrowserViewportView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            let webView = WKWebView(frame: .zero)
            viewport.show(webView)
            viewport.emulation = ComputerBrowserViewport.presets["tablet"]
            viewport.layoutSubtreeIfNeeded()
            XCTAssertEqual(webView.pageZoom, 600.0 / 1024.0, accuracy: 0.0001)
            XCTAssertEqual(webView.frame.midX, 400, accuracy: 1)
            viewport.emulation = nil
            viewport.layoutSubtreeIfNeeded()
            XCTAssertEqual(webView.frame, viewport.bounds)
            XCTAssertEqual(webView.pageZoom, 1)
        }

        func testTabsCreateSelectCloseAndBoundTheirCount() async throws {
            let listed = try await harness.run("browser_tabs", ["action": .string("list")])
            XCTAssertEqual(listed["tabs"]?.arrayValue?.count, 1)
            XCTAssertEqual(listed["active"], .string("t1"))
            _ = try await harness.open("/form")
            let first = try await harness.snapshot()
            let terms = try harness.ref(first.lines, containing: "checkbox \"Accept terms\"")
            let created = try await harness.run(
                "browser_tabs", ["action": .string("create"), "url": .string(harness.url("/next"))])
            let second = try XCTUnwrap(created["tab"]?["id"]?.stringValue)
            XCTAssertEqual(created["active"], .string(second))
            XCTAssertEqual(created["loaded"], .bool(true))
            XCTAssertEqual(created["tab_id"], .string(second))
            XCTAssertEqual(created["url"], .string(harness.url("/next")))
            XCTAssertEqual(harness.driver.activeTabId, second)
            XCTAssertFalse(harness.driver.pane === harness.pane)
            let text = try await harness.run("browser_get_text")
            XCTAssertTrue(text["text"]?.stringValue?.contains("Next page") == true)
            let evaluated = try await harness.run("browser_evaluate", ["script": .string("document.title")])
            XCTAssertEqual(evaluated["result"], .string("Next"))
            await harness.expectCode(
                "browser_click", ["ref": .string(terms), "snapshot_id": .string(first.id)], "stale_ref")
            _ = try await harness.page("document.cookie = 'shared=yes; path=/'")
            try await harness.expectEventually {
                (try await self.harness.active("document.cookie") as? String)?.contains("shared=yes") == true
            }
            let other = try await harness.snapshot()
            let heading = try harness.ref(other.lines, containing: "heading \"Next page\"")
            _ = try await harness.run("browser_tabs", ["action": .string("select"), "tab_id": .string("t1")])
            XCTAssertTrue(harness.driver.pane === harness.pane)
            let back = try await harness.run("browser_get_text")
            XCTAssertEqual(back["title"], .string("Order form"))
            await harness.expectCode("browser_get_text", ["ref": .string(heading)], "stale_ref")
            let refreshed = try await harness.snapshot()
            let again = try harness.ref(refreshed.lines, containing: "checkbox \"Accept terms\"")
            _ = try await harness.run("browser_click", ["ref": .string(again), "snapshot_id": .string(refreshed.id)])
            try await harness.expectPage("document.getElementById('terms').checked", true)
            let closed = try await harness.run("browser_tabs", ["action": .string("close"), "tab_id": .string(second)])
            XCTAssertEqual(closed["tabs"]?.arrayValue?.count, 1)
            await harness.expectCode(
                "browser_tabs", ["action": .string("close"), "tab_id": .string("t1")], "out_of_range")
            await harness.expectCode(
                "browser_tabs", ["action": .string("select"), "tab_id": .string("t99")], "out_of_range")
            for _ in 1..<MacBrowserDriver.maximumTabs {
                _ = try await harness.run("browser_tabs", ["action": .string("create")])
            }
            XCTAssertEqual(harness.driver.tabs.count, MacBrowserDriver.maximumTabs)
            await harness.expectCode("browser_tabs", ["action": .string("create")], "out_of_range")
            let active = harness.driver.activeTabId
            _ = try await harness.run("browser_tabs", ["action": .string("close"), "tab_id": .string(active)])
            XCTAssertNotEqual(harness.driver.activeTabId, active)
            XCTAssertEqual(harness.driver.tabs.count, MacBrowserDriver.maximumTabs - 1)
        }

        func testTabCreationUsesOriginApprovalAndRollsBackRefusedLoads() async throws {
            let opened = try await harness.run(
                "browser_tabs", ["action": .string("create"), "url": .string(harness.url("/form"))])
            XCTAssertEqual(opened["origin"], .string(harness.origin))
            XCTAssertEqual(harness.driver.approved, [harness.origin])
            XCTAssertEqual(harness.driver.tabs.count, 2)
            let redirect = await harness.failure(
                "browser_tabs", ["action": .string("create"), "url": .string(harness.url("/redirect"))])
            XCTAssertEqual(redirect?.code, "origin_not_approved")
            XCTAssertEqual(harness.driver.tabs.count, 2)
            XCTAssertEqual(harness.driver.activeTabId, opened["tab"]?["id"]?.stringValue)
            await harness.expectCode(
                "browser_tabs", ["action": .string("create"), "url": .string("ftp://example.org/")], "url_rejected")
            XCTAssertEqual(harness.driver.tabs.count, 2)
            harness.driver.userNavigate("http://localhost:\(harness.server.port)/next")
            try await harness.expectEventually { self.harness.driver.pane.webView.url?.host == "localhost" }
            try await harness.expectEventually { !self.harness.driver.pane.isLoading }
            let listed = try await harness.run("browser_tabs", ["action": .string("list")])
            let hidden = try XCTUnwrap(listed["tabs"]?.arrayValue?.first { $0["active"] == .bool(true) })
            XCTAssertEqual(hidden["url"], .null)
            XCTAssertEqual(hidden["approved"], .bool(false))
            XCTAssertEqual(listed["url"], .null)
            XCTAssertEqual(listed["title"], .null)
        }

        func testHumanTabStripClicksTakeOverAndInvalidateReferences() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let terms = try harness.ref(snap.lines, containing: "checkbox \"Accept terms\"")
            harness.driver.userNewTab()
            XCTAssertEqual(harness.takeovers, 1)
            XCTAssertEqual(harness.driver.tabs.count, 2)
            harness.driver.userSelectTab("t1")
            XCTAssertEqual(harness.takeovers, 2)
            await harness.expectCode(
                "browser_click", ["ref": .string(terms), "snapshot_id": .string(snap.id)], "stale_ref")
            harness.driver.userCloseTab(harness.driver.tabs[1].id)
            XCTAssertEqual(harness.takeovers, 3)
            XCTAssertEqual(harness.driver.tabs.count, 1)
            harness.driver.userCloseTab("t1")
            XCTAssertEqual(harness.driver.tabs.count, 1)
            harness.active = false
            harness.driver.userNewTab()
            XCTAssertEqual(harness.takeovers, 3)
            harness.driver.bind(owner: "https://fixture.test|account-b")
            XCTAssertEqual(harness.driver.tabs.count, 1)
        }

        func testPaneViewShowsTabsConsoleAndTheActiveTabsWebView() async throws {
            harness.active = true
            _ = try await harness.open("/console")
            _ = try await harness.run(
                "browser_tabs", ["action": .string("create"), "url": .string(harness.url("/next"))])
            _ = try await harness.run("browser_resize", ["preset": .string("mobile")])
            let view = NSHostingView(rootView: MacBrowserPaneView(driver: harness.driver))
            view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer {
                window.contentView = nil
                window.close()
            }
            view.layoutSubtreeIfNeeded()
            let active = harness.driver.pane.webView
            try await harness.expectEventually { active.window === window }
            XCTAssertTrue(active.superview is MacBrowserViewportView)
            try await harness.expectEventually { active.pageZoom < 1 }
            XCTAssertFalse(harness.pane.webView.window === window)
            harness.driver.userSelectTab("t1")
            view.layoutSubtreeIfNeeded()
            try await harness.expectEventually { self.harness.pane.webView.window === window }
            XCTAssertNil(active.window)
            XCTAssertFalse(harness.pane.console.isEmpty)
            view.layoutSubtreeIfNeeded()
        }
    }

    extension ISO8601DateFormatter {
        fileprivate static var fractional: ISO8601DateFormatter {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }
    }
#endif
