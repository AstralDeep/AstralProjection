// Drives MacBrowserDriver through real WebKit loads: origin approval, URL rejection, secret refusal, the one-shot
// consequential permit and its withdrawal when authorization is refused, dialogs, blocked popups, downloads and
// uploads, screenshots, the native click fallback, takeover classification, the per-account pane preference and the
// pane view.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import WebKit
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacBrowserDriverTests: XCTestCase {
        private var harness: MacBrowserHarness!

        override func setUp() async throws {
            harness = try MacBrowserHarness()
            await harness.start()
        }

        override func tearDown() async throws {
            harness.close()
            harness = nil
        }

        private static func closedLoopbackPort() -> Int {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
                }
            }
            XCTAssertTrue(bound)
            return Int(UInt16(bigEndian: address.sin_port))
        }

        private func refusal(_ verb: String, _ args: [String: JSONValue], at call: Int) async -> ComputerHostError? {
            let gate = RefusingAuthorization(refusing: call)
            do {
                _ = try await harness.driver.execute(
                    verb, args: args, session: MacBrowserHarness.session, remaining: 20, authorize: { try gate.check() }
                )
                return nil
            } catch {
                return error as? ComputerHostError
            }
        }

        func testNavigationApprovesOnlyTheForwardedOriginAndRejectsTrickURLs() async throws {
            await harness.expectCode("browser_snapshot", [:], nil)
            let blank = try await harness.run("browser_snapshot")
            XCTAssertEqual(blank["lines"], .array([]))
            XCTAssertEqual(blank["url"], .string("about:blank"))
            for text in [
                "https://good.example\\@evil.example/", "https://user@example.org/", "https://example.org/\u{202E}x",
                "file:///etc/passwd", "javascript:alert(1)", "http://exa\tmple.org/",
            ] {
                await harness.expectCode("browser_navigate", ["url": .string(text)], "url_rejected", text)
            }
            XCTAssertTrue(harness.driver.approved.isEmpty)
            _ = try await harness.open("/form")
            XCTAssertEqual(harness.driver.approved, [harness.origin])
            _ = try await harness.open("/next")
            let back = try await harness.run("browser_navigate", ["action": .string("back")])
            XCTAssertEqual(back["url"], .string(harness.url("/form")))
            let forward = try await harness.run("browser_navigate", ["action": .string("forward")])
            XCTAssertEqual(forward["url"], .string(harness.url("/next")))
            let reload = try await harness.run("browser_navigate", ["action": .string("reload")])
            XCTAssertEqual(reload["loaded"], .bool(true))
            _ = try await harness.run("browser_navigate", ["action": .string("back")])
            await harness.expectCode("browser_navigate", ["action": .string("back")], "out_of_range")
        }

        func testAgentCannotFollowUnapprovedOriginsButTheUserCan() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let away = try harness.ref(snap.lines, containing: "link \"Elsewhere\"")
            let clicked = try await harness.run(
                "browser_click", ["ref": .string(away), "snapshot_id": .string(snap.id)])
            let blocked = clicked["blocked"]?.arrayValue ?? []
            XCTAssertTrue(
                blocked.contains(
                    .object(["kind": .string("origin"), "origin": .string("http://localhost:\(harness.server.port)")])),
                "\(clicked)")
            XCTAssertEqual(harness.pane.webView.url?.path, "/form")
            let redirect = await harness.failure("browser_navigate", ["url": .string(harness.url("/redirect"))])
            XCTAssertEqual(redirect?.code, "origin_not_approved")
            XCTAssertEqual(harness.pane.webView.url?.path, "/form")
            harness.driver.userNavigate("http://localhost:\(harness.server.port)/next")
            try await harness.expectEventually { self.harness.pane.webView.url?.host == "localhost" }
            try await harness.expectEventually { !self.harness.pane.isLoading }
            for verb in ["browser_snapshot", "browser_get_text", "browser_scroll", "browser_screenshot"] {
                await harness.expectCode(verb, [:], "origin_not_approved", verb)
            }
            await harness.expectCode("browser_navigate", ["action": .string("reload")], "origin_not_approved")
            harness.driver.userNavigate("ftp://example.org")
            XCTAssertEqual(harness.driver.lastError, "Enter an http or https address without sign-in details.")
        }

        func testSecretFieldsAreNeverFilledReadOrTypedInto() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            for label in ["textbox \"Password\"", "textbox \"Card\"", "textbox \"Code\""] {
                let ref = try harness.ref(snap.lines, containing: label)
                await harness.expectCode(
                    "browser_fill",
                    [
                        "snapshot_id": .string(snap.id),
                        "fields": .array([.object(["ref": .string(ref), "value": .string("x")])]),
                    ], "secret_field", label)
                await harness.expectCode("browser_get_text", ["ref": .string(ref)], "secret_field", label)
                await harness.expectCode("browser_press", ["keys": .string("a"), "ref": .string(ref)], "secret_field")
                await harness.expectCode("browser_press", ["keys": .string("tab"), "ref": .string(ref)], nil)
            }
            try await harness.expectPage("document.getElementById('pw').value", "hunter2")
            let password = try harness.ref(snap.lines, containing: "textbox \"Password\"")
            let enter = await harness.failure("browser_press", ["keys": .string("enter"), "ref": .string(password)])
            XCTAssertEqual(enter?.code, "confirmation_required")
            XCTAssertTrue(enter?.message.contains("browser_click") == true)
        }

        func testConsequentialClickNeedsAMatchingOneShotPermit() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let pay = try harness.ref(snap.lines, containing: "button \"Pay now\"")
            let click: [String: JSONValue] = ["ref": .string(pay), "snapshot_id": .string(snap.id)]
            let review = await harness.failure("browser_click", click)
            XCTAssertEqual(review?.code, "confirmation_required")
            XCTAssertTrue(review?.message.hasSuffix("[\(pay)] button \"Pay now\"") == true, review?.message ?? "")
            func permit(ref: String = pay, origin: String? = nil, snapshot: String? = nil) -> JSONValue {
                .object([
                    "ref": .string(ref), "origin": .string(origin ?? harness.origin),
                    "snapshot_id": .string(snapshot ?? snap.id),
                ])
            }
            let later = try await harness.snapshot()
            await harness.expectCode(
                "browser_click", click.merging(["permit": permit(snapshot: later.id)]) { $1 }, "confirmation_required")
            await harness.expectCode(
                "browser_click", click.merging(["permit": permit(origin: "http://localhost:1")]) { $1 },
                "confirmation_required")
            await harness.expectCode(
                "browser_click", click.merging(["permit": permit(ref: "e1")]) { $1 }, "confirmation_required")
            try await harness.expectPage("document.title", "Order form")
            let done = try await harness.run(
                "browser_click", click.merging(["permit": permit(), "confirm_element": .string("x")]) { $1 })
            XCTAssertEqual(done["clicked"], .string(pay))
            try await harness.expectPage("document.title", "paid")
            await harness.expectCode(
                "browser_click", click.merging(["permit": permit()]) { $1 }, "confirmation_required")
            let signIn = try harness.ref(snap.lines, containing: "button \"Sign in\"")
            await harness.expectCode(
                "browser_click", ["ref": .string(signIn), "snapshot_id": .string(snap.id)], "confirmation_required")
            _ = try await harness.open("/next")
            await harness.expectCode("browser_click", click.merging(["permit": permit()]) { $1 }, "stale_ref")
        }

        func testConsequentialFillsAccumulatePermitsUntilTheFillRuns() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let holder = try harness.ref(snap.lines, containing: "textbox \"Card holder\"")
            let recipient = try harness.ref(snap.lines, containing: "textbox \"Send to\"")
            let name = try harness.ref(snap.lines, containing: "textbox \"Name\"")
            var args: [String: JSONValue] = [
                "snapshot_id": .string(snap.id),
                "fields": .array([
                    .object(["ref": .string(name), "value": .string("Ada")]),
                    .object(["ref": .string(holder), "value": .string("A Lovelace")]),
                    .object(["ref": .string(recipient), "value": .string("Charles")]),
                ]),
            ]
            let first = await harness.failure("browser_fill", args)
            XCTAssertEqual(first?.code, "confirmation_required")
            XCTAssertTrue(first?.message.contains("[\(holder)]") == true)
            args["permit"] = .object([
                "refs": .array([.string(holder)]), "origin": .string(harness.origin), "snapshot_id": .string(snap.id),
            ])
            let second = await harness.failure("browser_fill", args)
            XCTAssertEqual(second?.code, "confirmation_required")
            XCTAssertTrue(second?.message.contains("[\(recipient)]") == true)
            try await harness.expectPage("document.getElementById('name').value", "")
            args["permit"] = .object([
                "refs": .array([.string(recipient)]), "origin": .string(harness.origin),
                "snapshot_id": .string(snap.id),
            ])
            let filled = try await harness.run("browser_fill", args)
            XCTAssertEqual(filled["filled"]?.arrayValue?.count, 3)
            try await harness.expectPage("document.getElementById('holder').value", "A Lovelace")
            await harness.expectCode("browser_fill", args, "confirmation_required")
        }

        func testRefusedAuthorizationAfterAValidPermitLeavesNothingApproved() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let pay = try harness.ref(snap.lines, containing: "button \"Pay now\"")
            let click: [String: JSONValue] = ["ref": .string(pay), "snapshot_id": .string(snap.id)]
            let permitted = click.merging([
                "permit": .object([
                    "ref": .string(pay), "origin": .string(harness.origin), "snapshot_id": .string(snap.id),
                ])
            ]) { $1 }
            await harness.expectCode("browser_click", click, "confirmation_required")
            let refused = await refusal("browser_click", permitted, at: 2)
            XCTAssertEqual(refused?.code, "interrupted")
            try await harness.expectPage("document.title", "Order form")
            await harness.expectCode("browser_click", click, "confirmation_required")
            try await harness.expectPage("document.title", "Order form")
            let done = try await harness.run("browser_click", permitted)
            XCTAssertEqual(done["clicked"], .string(pay))
            try await harness.expectPage("document.title", "paid")
        }

        func testRefusedAuthorizationDropsFillPermitsAlreadyAccepted() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let holder = try harness.ref(snap.lines, containing: "textbox \"Card holder\"")
            let recipient = try harness.ref(snap.lines, containing: "textbox \"Send to\"")
            let name = try harness.ref(snap.lines, containing: "textbox \"Name\"")
            var args: [String: JSONValue] = [
                "snapshot_id": .string(snap.id),
                "fields": .array([
                    .object(["ref": .string(name), "value": .string("Ada")]),
                    .object(["ref": .string(holder), "value": .string("A Lovelace")]),
                    .object(["ref": .string(recipient), "value": .string("Charles")]),
                ]),
            ]
            func permit(_ ref: String) -> JSONValue {
                .object([
                    "refs": .array([.string(ref)]), "origin": .string(harness.origin),
                    "snapshot_id": .string(snap.id),
                ])
            }
            await harness.expectCode("browser_fill", args, "confirmation_required")
            args["permit"] = permit(holder)
            await harness.expectCode("browser_fill", args, "confirmation_required")
            args["permit"] = permit(recipient)
            let refused = await refusal("browser_fill", args, at: 2)
            XCTAssertEqual(refused?.code, "interrupted")
            args["permit"] = nil
            let again = await harness.failure("browser_fill", args)
            XCTAssertEqual(again?.code, "confirmation_required")
            XCTAssertTrue(again?.message.contains("[\(holder)]") == true, again?.message ?? "")
            for field in ["name", "holder", "recipient"] {
                try await harness.expectPage("document.getElementById('\(field)').value", "")
            }
        }

        func testDiscardingPermitsWithdrawsReviewsAndAcceptedApprovals() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let holder = try harness.ref(snap.lines, containing: "textbox \"Card holder\"")
            let recipient = try harness.ref(snap.lines, containing: "textbox \"Send to\"")
            let pay = try harness.ref(snap.lines, containing: "button \"Pay now\"")
            func permit(_ ref: String) -> JSONValue {
                .object([
                    "refs": .array([.string(ref)]), "ref": .string(ref), "origin": .string(harness.origin),
                    "snapshot_id": .string(snap.id),
                ])
            }
            var fill: [String: JSONValue] = [
                "snapshot_id": .string(snap.id),
                "fields": .array([
                    .object(["ref": .string(holder), "value": .string("A Lovelace")]),
                    .object(["ref": .string(recipient), "value": .string("Charles")]),
                ]),
            ]
            await harness.expectCode("browser_fill", fill, "confirmation_required")
            fill["permit"] = permit(holder)
            await harness.expectCode("browser_fill", fill, "confirmation_required")
            harness.driver.discardPermits()
            fill["permit"] = permit(recipient)
            let reviewed = await harness.failure("browser_fill", fill)
            XCTAssertEqual(reviewed?.code, "confirmation_required")
            XCTAssertTrue(reviewed?.message.contains("[\(holder)]") == true, reviewed?.message ?? "")
            try await harness.expectPage("document.getElementById('holder').value", "")
            let click: [String: JSONValue] = ["ref": .string(pay), "snapshot_id": .string(snap.id)]
            let permitted = click.merging(["permit": permit(pay)]) { $1 }
            await harness.expectCode("browser_click", click, "confirmation_required")
            harness.driver.discardPermits()
            await harness.expectCode("browser_click", permitted, "confirmation_required")
            try await harness.expectPage("document.title", "Order form")
            let done = try await harness.run("browser_click", permitted)
            XCTAssertEqual(done["clicked"], .string(pay))
            try await harness.expectPage("document.title", "paid")
        }

        func testRefusedNavigationApprovesNoOrigin() async throws {
            let local = "http://localhost:\(harness.server.port)/next"
            let refused = await refusal("browser_navigate", ["url": .string(local)], at: 2)
            XCTAssertEqual(refused?.code, "interrupted")
            XCTAssertTrue(harness.driver.approved.isEmpty)
            XCTAssertTrue(harness.pane.webView.url.map { $0.absoluteString == "about:blank" } ?? true)
            harness.driver.userNavigate(local)
            try await harness.expectEventually { self.harness.pane.webView.url?.host == "localhost" }
            try await harness.expectEventually { !self.harness.pane.isLoading }
            await harness.expectCode("browser_navigate", ["action": .string("reload")], "origin_not_approved")
            await harness.expectCode("browser_snapshot", [:], "origin_not_approved")
        }

        func testDialogsQueueAndBlockOtherVerbsUntilAnswered() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let ask = try harness.ref(snap.lines, containing: "button \"Ask\"")
            await harness.expectCode("browser_dialog", ["action": .string("accept")], "no_dialog")
            let clicked = try await harness.run(
                "browser_click", ["ref": .string(ask), "snapshot_id": .string(snap.id)])
            XCTAssertEqual(clicked["dialog_opened"], .bool(true))
            XCTAssertEqual(clicked["pending_dialog"]?["type"], .string("confirm"))
            XCTAssertEqual(clicked["pending_dialog"]?["message"], .string("Proceed with the step?"))
            XCTAssertEqual(clicked["pending_dialog"]?["origin"], .string(harness.origin))
            let blocked = try await harness.run("browser_snapshot")
            XCTAssertEqual(blocked["lines"], .array([]))
            XCTAssertEqual(blocked["pending_dialog"]?["type"], .string("confirm"))
            for verb in ["browser_get_text", "browser_scroll", "browser_screenshot"] {
                await harness.expectCode(verb, [:], "pending_dialog", verb)
            }
            await harness.expectCode(
                "browser_click", ["ref": .string(ask), "snapshot_id": .string(snap.id)], "pending_dialog")
            await harness.expectCode(
                "browser_dialog", ["action": .string("accept"), "text": .string("x")], "out_of_range")
            let answered = try await harness.run("browser_dialog", ["action": .string("dismiss")])
            XCTAssertEqual(answered["answered"], .string("confirm"))
            XCTAssertEqual(answered["pending_dialog"], .null)
            try await harness.expectEventually { try await self.harness.page("window.answer") as? String == "false" }
        }

        func testPopupsDownloadsAndUploadsAreRefusedWithClearResults() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let popup = try harness.ref(snap.lines, containing: "link \"Open popup\"")
            let opener = try harness.ref(snap.lines, containing: "button \"Open window\"")
            for ref in [popup, opener] {
                let result = try await harness.run(
                    "browser_click", ["ref": .string(ref), "snapshot_id": .string(snap.id)])
                let kinds = (result["blocked"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }
                XCTAssertTrue(kinds.contains("popup"), "\(result)")
            }
            XCTAssertEqual(harness.pane.webView.url?.path, "/form")
            let download = await harness.failure("browser_navigate", ["url": .string(harness.url("/download"))])
            XCTAssertEqual(download?.code, "unsupported")
            XCTAssertTrue(download?.message.contains("Downloads are blocked") == true)
            let attachment = try harness.ref(snap.lines, containing: "button \"Attachment\"")
            await harness.expectCode(
                "browser_fill",
                [
                    "snapshot_id": .string(snap.id),
                    "fields": .array([.object(["ref": .string(attachment), "value": .string("/etc/hosts")])]),
                ], "unsupported")
            let chooser = try await harness.run(
                "browser_click", ["ref": .string(attachment), "snapshot_id": .string(snap.id)])
            let kinds = (chooser["blocked"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }
            XCTAssertTrue(kinds.contains("upload"), "\(chooser)")
        }

        func testScreenshotIsBoundedJPEGWithSecretFieldsMasked() async throws {
            _ = try await harness.open("/form")
            let shot = try await harness.run("browser_screenshot", ["max_width": .number(640)])
            XCTAssertEqual(shot["media_type"], .string("image/jpeg"))
            let width = try XCTUnwrap(shot["width"]?.numberValue)
            XCTAssertLessThanOrEqual(width, 640)
            XCTAssertGreaterThanOrEqual(shot["masked"]?.numberValue ?? 0, 3)
            let data = try XCTUnwrap(Data(base64Encoded: shot["base64"]?.stringValue ?? ""))
            XCTAssertLessThanOrEqual(data.count, MacBrowserDriver.maximumImageBytes)
            XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
            let snap = try await harness.snapshot()
            let heading = try harness.ref(snap.lines, containing: "heading \"Order\"")
            let cropped = try await harness.run("browser_screenshot", ["ref": .string(heading)])
            XCTAssertLessThan(try XCTUnwrap(cropped["height"]?.numberValue), 200)
            let image = try XCTUnwrap(CGImage.solid(width: 100, height: 50))
            let encoded = try XCTUnwrap(
                MacBrowserDriver.encode(
                    image, capture: CGRect(x: 0, y: 0, width: 100, height: 50),
                    masks: [CGRect(x: 0, y: 0, width: 50, height: 50)], maximumWidth: 40, flipped: true))
            XCTAssertEqual(encoded.width, 40)
            XCTAssertEqual(encoded.height, 20)
        }

        func testNativeFallbackClicksControlsThatIgnoreSyntheticEvents() async throws {
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let trusted = try harness.ref(snap.lines, containing: "button \"Trusted only\"")
            let result = try await harness.run(
                "browser_click", ["ref": .string(trusted), "snapshot_id": .string(snap.id)])
            XCTAssertEqual(result["method"], .string("native"))
            try await harness.expectEventually { try await self.harness.page("document.title") as? String == "trusted" }
            XCTAssertEqual(harness.takeovers, 0)
            let next = try harness.ref(snap.lines, containing: "link \"Next page\"")
            let link = try await harness.run("browser_click", ["ref": .string(next), "snapshot_id": .string(snap.id)])
            XCTAssertEqual(link["method"], .string("synthetic"))
            XCTAssertEqual(link["navigated"], .bool(true))
        }

        func testHumanInputInsideThePageTakesOverButPaneChromeAndSyntheticEventsDoNot() throws {
            let pane = harness.pane
            let webView = pane.webView
            webView.frame = CGRect(x: 0, y: 0, width: 1024, height: 700)
            let inside = webView.convert(CGPoint(x: 200, y: 200), to: nil)
            let outside = CGPoint(x: 200, y: 740)
            func mouse(_ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                    windowNumber: harness.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: 1)!
            }
            XCTAssertTrue(pane.isHumanPageInput(mouse(inside)))
            XCTAssertFalse(pane.isHumanPageInput(mouse(outside)))
            let key = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: harness.window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            let escape = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: harness.window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            harness.window.makeFirstResponder(nil)
            XCTAssertFalse(pane.isHumanPageInput(key))
            harness.window.makeFirstResponder(webView)
            XCTAssertTrue(pane.isHumanPageInput(key))
            XCTAssertFalse(pane.isHumanPageInput(escape))
            pane.humanInput?()
            XCTAssertEqual(harness.takeovers, 1)
            harness.active = false
            pane.humanInput?()
            harness.driver.requestTakeover()
            XCTAssertEqual(harness.takeovers, 1)
            harness.active = true
            harness.driver.requestTakeover()
            XCTAssertEqual(harness.takeovers, 2)
            XCTAssertThrowsError(try pane.nativeClick(at: CGPoint(x: -5, y: -5), right: false, count: 1))
        }

        func testPanePreferenceIsPerAccountAndGatesTheVerbs() async throws {
            let driver = harness.driver
            XCTAssertTrue(driver.isEnabled)
            XCTAssertTrue(driver.accountBound)
            driver.bind(owner: "https://fixture.test|account-b")
            XCTAssertFalse(driver.isEnabled)
            XCTAssertFalse(driver.isPresented)
            driver.bind(owner: "https://fixture.test|account-a")
            XCTAssertTrue(driver.isEnabled)
            driver.bind(owner: nil)
            XCTAssertFalse(driver.isEnabled)
            XCTAssertFalse(driver.accountBound)
            driver.setPaneEnabled(true)
            XCTAssertFalse(driver.isEnabled)
            driver.bind(owner: "https://fixture.test|account-a")
            let request = try ComputerHostRequest(
                json: .object([
                    "type": .string("computer_request"),
                    "request_id": .string("creq_" + String(repeating: "b", count: 32)),
                    "session_id": .string(MacBrowserHarness.session), "verb": .string("browser_snapshot"),
                    "args": .object([:]), "deadline_ms": .number(5000),
                ]))
            let authority = ComputerHostAuthority()
            authority.setDesktopAvailable(true)
            try authority.begin(MacBrowserHarness.session)
            let ticket = try authority.admit(request)
            let result = try await driver.handle(request, ticket: ticket) { try authority.verify(ticket) }
            XCTAssertEqual(result["url"], .string("about:blank"))
            XCTAssertTrue(driver.driving)
            XCTAssertTrue(driver.isPresented)
            try await harness.expectEventually(timeout: 4) { !driver.driving }
            driver.setPaneEnabled(false)
            XCTAssertFalse(driver.isPresented)
            do {
                _ = try await driver.handle(request, ticket: ticket) {}
                XCTFail("Disabled pane accepted a verb")
            } catch { XCTAssertEqual((error as? ComputerHostError)?.code, "unsupported") }
            authority.invalidate()
            driver.setPaneEnabled(true)
            do {
                _ = try await driver.handle(request, ticket: ticket) { try authority.verify(ticket) }
                XCTFail("Revoked ticket accepted")
            } catch { XCTAssertEqual((error as? ComputerHostError)?.code, "interrupted") }
            await harness.expectCode("browser_snapshot", [:], nil)
            do {
                _ = try await driver.execute(
                    "browser_snapshot", args: [:], session: MacBrowserHarness.session, remaining: 0.1, authorize: {})
                XCTFail("Expired deadline accepted")
            } catch { XCTAssertEqual((error as? ComputerHostError)?.code, "interrupted") }
            await harness.expectCode("browser_find", [:], "unsupported")
        }

        func testAlertsPromptsSchemesAndLoadFailuresSurfaceClearly() async throws {
            _ = try await harness.open("/prompts")
            let snap = try await harness.snapshot()
            let notify = try harness.ref(snap.lines, containing: "button \"Notify\"")
            let name = try harness.ref(snap.lines, containing: "button \"Name\"")
            let alerted = try await harness.run(
                "browser_click", ["ref": .string(notify), "snapshot_id": .string(snap.id)])
            XCTAssertEqual(alerted["pending_dialog"]?["type"], .string("alert"))
            XCTAssertEqual(alerted["pending_dialog"]?["message"], .string("Saved"))
            let accepted = try await harness.run("browser_dialog", ["action": .string("accept")])
            XCTAssertEqual(accepted["answered"], .string("alert"))
            let prompted = try await harness.run(
                "browser_click", ["ref": .string(name), "snapshot_id": .string(snap.id)])
            XCTAssertEqual(prompted["pending_dialog"]?["default_text"], .string("Ada"))
            _ = try await harness.run("browser_dialog", ["action": .string("accept"), "text": .string("Grace")])
            try await harness.expectEventually { try await self.harness.page("window.reply") as? String == "Grace" }
            for label in ["link \"Custom\"", "link \"Inline\""] {
                let ref = try harness.ref(snap.lines, containing: label)
                let result = try await harness.run(
                    "browser_click", ["ref": .string(ref), "snapshot_id": .string(snap.id)])
                let kinds = (result["blocked"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }
                XCTAssertTrue(kinds.contains("scheme"), "\(result)")
            }
            XCTAssertEqual(harness.pane.webView.url?.path, "/prompts")
            let closed = Self.closedLoopbackPort()
            let unreachable = await harness.failure(
                "browser_navigate", ["url": .string("http://127.0.0.1:\(closed)/")])
            XCTAssertEqual(unreachable?.code, "navigation_failed")
            XCTAssertTrue(unreachable?.message.contains("desktop path") == true)
            _ = try await harness.open("/prompts")
            let before = harness.pane.generation
            harness.pane.webViewWebContentProcessDidTerminate(harness.pane.webView)
            XCTAssertGreaterThan(harness.pane.generation, before)
            XCTAssertTrue(harness.pane.frames.isEmpty)
            await harness.expectCode("browser_get_text", ["ref": .string(notify)], "stale_ref")
            let empty = try await harness.run("browser_snapshot")
            XCTAssertEqual(empty["lines"], .array([]))
            harness.pane.webView.removeFromSuperview()
            await harness.expectCode("browser_screenshot", [:], "unsupported")
        }

        func testControlsShowTheBrowserPaneToggleForTheAttachedDriver() throws {
            let store = harness.defaults
            let host = MacComputerHost(
                available: false, defaults: store,
                permissionProvider: { MacComputerPermissions(accessibility: false, screen: false, monitoring: false) },
                desktopProbe: { true }, desktopRearm: { false }, system: MacComputerTestSystem())
            let driver = MacBrowserDriver(host: host, defaults: store, pane: harness.pane)
            XCTAssertTrue(host.browser === driver)
            XCTAssertFalse(driver.agentActive())
            driver.takeover()
            driver.bind(owner: "https://fixture.test|account-a")
            XCTAssertTrue(driver.isEnabled)
            let view = NSHostingView(rootView: MacComputerControls(host: host))
            view.frame = NSRect(x: 0, y: 0, width: 560, height: 900)
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(view.fittingSize.height, 0)
            driver.setPaneEnabled(false)
            XCTAssertFalse(driver.isEnabled)
            XCTAssertNil(host.session)
        }

        func testUnavailableScriptFailsClosed() async throws {
            let pane = MacBrowserPane(bundle: Bundle(for: MacBrowserDriverTests.self))
            defer { pane.close() }
            XCTAssertNotNil(pane.unavailable)
            let driver = MacBrowserDriver(host: nil, defaults: harness.defaults, pane: pane)
            driver.bind(owner: "https://fixture.test|account-a")
            XCTAssertFalse(driver.isEnabled)
            do {
                try await pane.prepare()
                XCTFail("Pane without its script prepared")
            } catch { XCTAssertEqual((error as? ComputerHostError)?.code, "unsupported") }
        }

        func testPaneViewHostsTheWebViewAndShowsDrivingState() async throws {
            harness.active = true
            let view = NSHostingView(rootView: MacBrowserPaneView(driver: harness.driver))
            view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
            let window = NSWindow(
                contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer {
                window.contentView = nil
                window.close()
            }
            view.layoutSubtreeIfNeeded()
            try await harness.expectEventually { self.harness.pane.webView.window === window }
            _ = try await harness.open("/prompts")
            XCTAssertTrue(harness.driver.driving)
            let snap = try await harness.snapshot()
            let name = try harness.ref(snap.lines, containing: "button \"Name\"")
            _ = try await harness.run("browser_click", ["ref": .string(name), "snapshot_id": .string(snap.id)])
            harness.driver.userNavigate("ftp://example.org")
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(harness.pane.dialogs.first?.type, "prompt")
            harness.driver.userAnswerDialog(accept: false)
            XCTAssertTrue(harness.pane.dialogs.isEmpty)
            try await harness.expectEventually { try await self.harness.page("window.reply === null") as? Bool == true }
            harness.driver.userNavigate("bad host")
            XCTAssertEqual(harness.driver.lastError, "Enter an http or https address without sign-in details.")
            harness.driver.userNavigate(harness.url("/next"))
            XCTAssertNil(harness.driver.lastError)
            try await harness.expectEventually { self.harness.pane.webView.url?.path == "/next" }
            try await harness.expectEventually { !self.harness.pane.isLoading }
            harness.driver.userHistory("back")
            try await harness.expectEventually { self.harness.pane.webView.url?.path == "/prompts" }
            view.layoutSubtreeIfNeeded()
        }
    }

    private final class RefusingAuthorization: @unchecked Sendable {
        private let lock = NSLock()
        private let refused: Int
        private var calls = 0

        init(refusing call: Int) { refused = call }

        func check() throws {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            if calls == refused { throw ComputerHostError("interrupted", "The human paused the task.") }
        }
    }

    extension CGImage {
        fileprivate static func solid(width: Int, height: Int) -> CGImage? {
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
    }
#endif
