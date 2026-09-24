// UI tests for watch guidance (private notes) navigation: edit defaults, category/expiry picker persistence,
// wrist text-entry retention, and home ordering of Work versus notes, via a scripted NotesNavigationPeer.

import Foundation
import Network
import XCTest

@MainActor
final class WatchGuidanceNavigationUITests: XCTestCase {
    private var peer: NotesNavigationPeer!
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        peer = try NotesNavigationPeer()
        peer.start()
        XCTAssertEqual(XCTWaiter.wait(for: [peer.ready], timeout: 5), .completed)
        app = XCUIApplication()
        app.launchEnvironment["ASTRAL_WATCH_NAVIGATION_PEER"] =
            "ws://127.0.0.1:\(try XCTUnwrap(peer.port))/watch-navigation"
        app.launch()
        XCTAssertTrue(app.buttons["Work records"].waitForExistence(timeout: 10), app.debugDescription)
    }
    override func tearDownWithError() throws {
        if let peer {
            let data = try JSONSerialization.data(withJSONObject: peer.frames)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Actual synthetic notes wire frames"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertTrue(peer.errors.isEmpty, peer.errors.joined(separator: "; "))
            peer.stop()
        }
        app?.terminate()
    }
    private func tap(_ element: XCUIElement) {
        for _ in 0..<24 where !element.isHittable {
            let movingDown = element.exists && element.frame.midY < 88
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: movingDown ? 0.45 : 0.8))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: movingDown ? 0.7 : 0.55))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
        element.tap()
    }
    private func frame(_ index: Int, action: String) throws -> [String: Any] {
        let received = XCTNSPredicateExpectation(
            predicate: NSPredicate { [peer] _, _ in peer!.frames.count > index }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 5), .completed)
        let frame = peer.frames[index]
        XCTAssertEqual(frame["action"] as? String, action)
        XCTAssertTrue(frame["session_id"] is NSNull)
        XCTAssertNil(frame["chat_id"])
        for key in ["request_generation", "submission_id"] {
            let value = try XCTUnwrap(frame[key] as? String)
            XCTAssertEqual(UUID(uuidString: value)?.uuidString.lowercased(), value)
        }
        return frame
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testActualEditDefaultsSaveUnknownRecoveryAndForgetReview() throws {
        tap(app.buttons["Private notes"])
        let first = try frame(0, action: "chrome_open")
        peer.respond(to: first, mode: "list")
        XCTAssertTrue(app.buttons["Add note"].waitForExistence(timeout: 5), app.debugDescription)
        let literal = "Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private"
        XCTAssertTrue(app.staticTexts[literal].exists, app.debugDescription)
        tap(app.buttons["Edit"])
        let edit = try frame(1, action: "chrome_open")
        peer.respond(to: edit, mode: "edit")
        XCTAssertTrue(app.staticTexts["Edit note"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.textFields["note-field-expiry_date"].exists)
        screenshot("Actual Watch note editor")
        tap(app.buttons["note-submit"])
        let save = try frame(2, action: "chrome_note_save")
        let payload = try XCTUnwrap(save["payload"] as? [String: Any])
        XCTAssertEqual(payload["expected_revision"] as? Int, 3)
        let fields = try XCTUnwrap(payload["fields"] as? [String: Any])
        XCTAssertEqual(fields["category"] as? String, "Preference")
        XCTAssertEqual(fields["value"] as? String, literal)
        XCTAssertEqual(fields["enabled"] as? Bool, true)
        XCTAssertEqual(fields["expiry"] as? String, "Keep current expiry")
        peer.refuse(save)
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Retry"].tap()
        let retry = try frame(3, action: "chrome_open")
        let retryPayload = try XCTUnwrap(retry["payload"] as? [String: Any])
        XCTAssertEqual(retryPayload["params"] as? [String: String], ["mode": "list"])
        XCTAssertNil(retryPayload["fields"])
        XCTAssertNotEqual(save["request_generation"] as? String, retry["request_generation"] as? String)
        peer.respond(to: retry, mode: "list")
        XCTAssertTrue(app.buttons["Add note"].waitForExistence(timeout: 5))
        tap(app.buttons["Forget"])
        let review = try frame(4, action: "chrome_open")
        XCTAssertEqual(
            ((review["payload"] as? [String: Any])?["params"] as? [String: Any])?["mode"] as? String, "forget")
        peer.respond(to: review, mode: "forget")
        XCTAssertTrue(app.buttons["Keep note"].waitForExistence(timeout: 5))
        let warning = "Forget permanently erases this note's current value. This cannot be undone."
        XCTAssertTrue(app.staticTexts[warning].exists, app.debugDescription)
        screenshot("Actual Watch Forget review")
        tap(app.buttons["Forget note"])
        let forget = try frame(5, action: "chrome_note_forget")
        let forgotten = try XCTUnwrap(forget["payload"] as? [String: Any])
        XCTAssertEqual(forgotten["note_id"] as? String, payload["note_id"] as? String)
        XCTAssertEqual(forgotten["expected_revision"] as? Int, 3)
        peer.respond(to: forget, mode: "list")
        XCTAssertTrue(app.buttons["Add note"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        _ = try frame(6, action: "chrome_close")
        XCTAssertEqual(peer.frames.count, 7)
    }
    func testActualCategoryAndExpiryPickerChangesRemainInTheCurrentForm() throws {
        tap(app.buttons["Private notes"])
        let first = try frame(0, action: "chrome_open")
        peer.respond(to: first, mode: "edit")
        XCTAssertTrue(app.staticTexts["Edit note"].waitForExistence(timeout: 5))
        let category = app.descendants(matching: .any).matching(identifier: "note-field-category").firstMatch
        tap(category)
        screenshot("Watch category picker")
        tap(app.buttons["Goal"])
        XCTAssertFalse(app.buttons["Retry"].exists, app.debugDescription)
        let expiry = app.descendants(matching: .any).matching(identifier: "note-field-expiry").firstMatch
        tap(expiry)
        tap(app.buttons["Set a date"])
        let date = app.textFields["note-field-expiry_date"]
        XCTAssertTrue(date.waitForExistence(timeout: 3), app.debugDescription)
        screenshot("Watch conditional UTC expiry editor")
    }

    func testActualWristTextEntryPreservesExactValueUntilSave() throws {
        tap(app.buttons["Private notes"])
        let first = try frame(0, action: "chrome_open")
        peer.respond(to: first, mode: "new")
        XCTAssertTrue(app.staticTexts["Add note"].waitForExistence(timeout: 5))
        let field = app.textFields["note-field-value"]
        tap(field)
        screenshot("Watch native note text editor")
        app.typeText("Wrist **literal** note")
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), app.debugDescription)
        done.tap()
        XCTAssertFalse(app.buttons["Retry"].exists, app.debugDescription)
        tap(app.buttons["note-submit"])
        let save = try frame(1, action: "chrome_note_save")
        let payload = try XCTUnwrap(save["payload"] as? [String: Any])
        let fields = try XCTUnwrap(payload["fields"] as? [String: Any])
        XCTAssertEqual(fields["value"] as? String, "Wrist **literal** note")
        XCTAssertEqual(fields["category"] as? String, "Context")
        XCTAssertEqual(fields["expiry"] as? String, "No expiry")
        XCTAssertEqual(payload["expected_revision"] as? Int, 0)
    }

    func testHomePreservesServerWorkThenPrivateNotesOrder() {
        let work = app.buttons["Work records"]
        let notes = app.buttons["Private notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertLessThan(work.frame.minY, notes.frame.minY, app.debugDescription)
        XCTAssertTrue(peer.frames.isEmpty)
        screenshot("Server ordered Work and notes controls")
    }

    func testDisabledNotesButtonRetainsItsLiteralLabelWithoutHandoffOrSend() throws {
        tap(app.buttons["Private notes"])
        let first = try frame(0, action: "chrome_open")
        peer.respond(to: first, mode: "list", disabledAdd: true)
        let add = app.buttons["Add note"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(add.isEnabled)
        XCTAssertFalse(app.staticTexts["Continue on your phone or desktop"].exists)
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(peer.frames.count, 1)
        screenshot("Disabled native notes control")
    }
}

private final class NotesNavigationPeer: @unchecked Sendable {
    let ready = XCTestExpectation(description: "private loopback peer ready")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "astral.watch-navigation.test-peer")
    private var connections: [NWConnection] = []
    private var received: [[String: Any]] = []
    private var failures: [String] = []
    private var count = 0
    var port: UInt16? { listener.port?.rawValue }
    var frames: [[String: Any]] { queue.sync { received } }
    var errors: [String] { queue.sync { failures } }

    init() throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.isEmpty else {
                connection.cancel()
                return
            }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            self.count += 1
            guard data.count <= 65536, self.count <= 32,
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                self.failures.append("Bounded peer rejected malformed frame")
                connection.cancel()
                return
            }
            if value["type"] as? String == "register_ui" {
                guard value["token"] as? String == "synthetic-loopback-only" else {
                    self.failures.append("Unexpected registration")
                    connection.cancel()
                    return
                }
                self.send(["type": "ready"], to: connection)
                self.send(
                    [
                        "type": "chrome_menu",
                        "model": [
                            "version": 2,
                            "topbar": [
                                [
                                    "key": "work", "kind": "action", "label": "Work records", "icon": "briefcase",
                                    "action": ["surface": "work", "params": ["mode": "list"]],
                                ],
                                [
                                    "key": "guidance", "kind": "action", "label": "Private notes", "icon": "note.text",
                                    "action": ["surface": "guidance", "params": ["mode": "list"]],
                                ],
                            ], "menu": [],
                        ],
                    ], to: connection)
                self.send(
                    [
                        "type": "ui_render", "target": "history",
                        "components": [
                            [
                                "type": "chat_history", "title": "Recent chats", "items": [],
                            ]
                        ],
                    ], to: connection)
            } else if value["type"] as? String == "ui_event", value["action"] as? String == "get_history" {
                // Connection hook only; history was sent above.
            } else if [
                "chrome_open", "chrome_close", "chrome_note_save", "chrome_note_search", "chrome_note_toggle",
                "chrome_note_forget",
            ].contains(value["action"] as? String ?? "") {
                self.received.append(value)
            } else {
                self.failures.append("Unexpected non-Work frame")
            }
            self.receive(connection)
        }
    }

    private func send(_ value: [String: Any], to connection: NWConnection) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        let context = NWConnection.ContentContext(
            identifier: "navigation",
            metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(
            content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func respond(to request: [String: Any], mode: String, disabledAdd: Bool = false) {
        queue.async {
            guard let connection = self.connections.first else { return }
            var frame =
                (try! JSONSerialization.jsonObject(with: Data(Self.framesJSON.utf8)) as! [String: [String: Any]])[mode]!
            frame["request_generation"] = request["request_generation"]!
            if disabledAdd {
                var components = frame["components"] as! [[String: Any]]
                components[1]["disabled"] = true
                frame["components"] = components
            }
            self.send(frame, to: connection)
        }
    }
    func refuse(_ request: [String: Any]) {
        queue.async {
            guard let connection = self.connections.first else { return }
            self.send(
                [
                    "type": "error", "submission_id": request["submission_id"]!, "accepted": false,
                    "code": "capacity_exceeded", "message": "Try later", "retryable": true,
                    "retry_after_ms": NSNull(),
                ], to: connection)
        }
    }
    private static let framesJSON =
        #"{"list":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"text","content":"Private notes are guidance you can select for your work.","variant":"body"},{"type":"button","label":"Add note","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"new"}},"variant":"secondary","disabled":false,"local":false},{"type":"param_picker","title":"","description":"","fields":[{"name":"search","label":"Search notes","kind":"text","default":""}],"submit_label":"Search","submit_action":"chrome_note_search","submit_payload":{}},{"type":"card","title":"Preference","content":[{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"},{"type":"button","label":"Edit","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"edit","note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}},"variant":"secondary","disabled":false,"local":false},{"type":"button","label":"Disable","action":"chrome_note_toggle","payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3,"enabled":false},"variant":"secondary","disabled":false,"local":false},{"type":"button","label":"Forget","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"forget","note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}},"variant":"secondary","disabled":false,"local":false}],"variant":"default"},{"type":"button","label":"Refresh","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list","search":""}},"variant":"secondary","disabled":false,"local":false}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"},"new":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Back to notes","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"param_picker","title":"Add note","description":"","fields":[{"name":"category","label":"Category","kind":"select","default":"Context","options":["Profession","Goal","Preference","Workflow tag","Context"]},{"name":"value","label":"Note","kind":"textarea","default":"","help":"Describe your preferences or context. Do not include patient information."},{"name":"enabled","label":"Enabled","kind":"boolean","default":true},{"name":"expiry","label":"Expiry","kind":"select","default":"No expiry","options":["No expiry","Set a date"]},{"name":"expiry_date","label":"Expiry date (UTC)","kind":"text","default":"","help":"Use a UTC date and time, for example 2026-12-31T23:59:00Z.","visible_when":{"expiry":"Set a date"}}],"submit_label":"Save note","submit_action":"chrome_note_save","submit_payload":{"note_id":"0fe0d7ba-812a-4881-9f61-77e23327d492","expected_revision":0}}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"},"edit":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Back to notes","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"text","content":"Current note","variant":"h3"},{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"},{"type":"param_picker","title":"Edit note","description":"","fields":[{"name":"category","label":"Category","kind":"select","default":"Preference","options":["Profession","Goal","Preference","Workflow tag","Context"]},{"name":"value","label":"Note","kind":"textarea","default":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","help":"Describe your preferences or context. Do not include patient information."},{"name":"enabled","label":"Enabled","kind":"boolean","default":true},{"name":"expiry","label":"Expiry","kind":"select","default":"Keep current expiry","options":["Keep current expiry","No expiry","Set a date"]},{"name":"expiry_date","label":"Expiry date (UTC)","kind":"text","default":"","help":"Use a UTC date and time, for example 2026-12-31T23:59:00Z.","visible_when":{"expiry":"Set a date"}}],"submit_label":"Save note","submit_action":"chrome_note_save","submit_payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"},"forget":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Keep note","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"card","title":"Preference","content":[{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"}],"variant":"default"},{"type":"alert","message":"Forget permanently erases this note's current value. This cannot be undone.","variant":"warning"},{"type":"button","label":"Forget note","action":"chrome_note_forget","payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3},"variant":"danger","disabled":false,"local":false}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"}}"#

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}
