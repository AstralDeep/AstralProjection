// UI tests for watch Work-surface navigation: the real timeout/retry/detail/back read lifecycle, and
// back-navigation cancelling a pending read while rejecting its late response, via a scripted
// WatchNavigationPeer.

import Foundation
import Network
import XCTest

@MainActor
final class WatchWorkNavigationUITests: XCTestCase {
    private var peer: WatchNavigationPeer!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        peer = try WatchNavigationPeer()
        peer.start()
        XCTAssertEqual(XCTWaiter.wait(for: [peer.ready], timeout: 5), .completed)
        let port = try XCTUnwrap(peer.port)
        app = XCUIApplication()
        app.launchEnvironment["ASTRAL_WATCH_NAVIGATION_PEER"] = "ws://127.0.0.1:\(port)/watch-navigation"
        app.launch()
        XCTAssertTrue(app.buttons["Work records"].waitForExistence(timeout: 10), app.debugDescription)
    }

    override func tearDownWithError() throws {
        if let peer {
            let attachment = XCTAttachment(
                data: try JSONSerialization.data(withJSONObject: peer.frames),
                uniformTypeIdentifier: "public.json")
            attachment.name = "Actual loopback Work frames"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertTrue(peer.errors.isEmpty, peer.errors.joined(separator: "; "))
            peer.stop()
        }
        app?.terminate()
    }

    private func frame(_ index: Int, action: String, mode: String? = nil) throws -> [String: Any] {
        let received = XCTNSPredicateExpectation(
            predicate: NSPredicate { [peer] _, _ in
                peer!.frames.count > index
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 5), .completed)
        let frame = peer.frames[index]
        XCTAssertEqual(frame["type"] as? String, "ui_event")
        XCTAssertEqual(frame["action"] as? String, action)
        XCTAssertTrue(frame["session_id"] is NSNull)
        let payload = try XCTUnwrap(frame["payload"] as? [String: Any])
        XCTAssertEqual(payload["surface"] as? String, "work")
        XCTAssertNil(payload["chat_id"])
        if let mode {
            XCTAssertEqual((payload["params"] as? [String: Any])?["mode"] as? String, mode)
        }
        for key in ["submission_id", "request_generation"] {
            let text = try XCTUnwrap(frame[key] as? String)
            XCTAssertEqual(UUID(uuidString: text)?.uuidString.lowercased(), text)
        }
        return frame
    }

    private func backToHome() {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3), app.debugDescription)
        back.tap()
        XCTAssertTrue(app.buttons["Work records"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHomeEntryRealTimeoutRetryDetailAndBackRetireTheRead() throws {
        screenshot("Actual Watch Home List")
        app.buttons["Work records"].tap()
        let first = try frame(0, action: "chrome_open", mode: "list")
        let started = Date()
        let unavailable = app.staticTexts["This view is unavailable. Reconnect and retry."]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 9)
        screenshot("Actual ten-second timeout")
        peer.respond(to: first, title: "Stale timeout response")
        app.buttons["Retry"].tap()
        let retry = try frame(1, action: "chrome_open", mode: "list")
        XCTAssertNotEqual(first["request_generation"] as? String, retry["request_generation"] as? String)
        peer.respond(to: retry, title: "Current work list", detailButton: true)
        XCTAssertTrue(app.staticTexts["Current work list"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Stale timeout response"].exists)
        app.buttons["View task"].tap()
        let detail = try frame(2, action: "chrome_open", mode: "detail")
        XCTAssertNotEqual(retry["request_generation"] as? String, detail["request_generation"] as? String)
        peer.respond(to: detail, title: "Task detail")
        XCTAssertTrue(app.staticTexts["Task detail"].waitForExistence(timeout: 5))
        screenshot("Actual task detail")
        backToHome()
        _ = try frame(3, action: "chrome_close")
        peer.respond(to: detail, title: "Late closed detail")
        app.buttons["Work records"].tap()
        let reopened = try frame(4, action: "chrome_open", mode: "list")
        XCTAssertNotEqual(detail["request_generation"] as? String, reopened["request_generation"] as? String)
        peer.respond(to: reopened, title: "Fresh re-entry")
        XCTAssertTrue(app.staticTexts["Fresh re-entry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Late closed detail"].exists)
        backToHome()
        _ = try frame(5, action: "chrome_close")
        XCTAssertEqual(peer.frames.count, 6)
    }

    func testBackDuringPendingReadCancelsViewTaskAndRejectsLateResponse() throws {
        app.buttons["Work records"].tap()
        let pending = try frame(0, action: "chrome_open", mode: "list")
        backToHome()
        _ = try frame(1, action: "chrome_close")
        peer.respond(to: pending, title: "Late pending response")
        app.buttons["Work records"].tap()
        let current = try frame(2, action: "chrome_open", mode: "list")
        XCTAssertNotEqual(pending["request_generation"] as? String, current["request_generation"] as? String)
        peer.respond(to: current, title: "Current reopened view")
        XCTAssertTrue(app.staticTexts["Current reopened view"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Late pending response"].exists)
        screenshot("Re-entry after pending read cancellation")
        backToHome()
        _ = try frame(3, action: "chrome_close")
        XCTAssertEqual(peer.frames.count, 4)
    }
}

final class WatchNavigationPeer: @unchecked Sendable {
    let ready = XCTestExpectation(description: "private loopback peer ready")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "astral.watch-navigation.test-peer")
    private var connections: [NWConnection] = []
    private var received: [[String: Any]] = []
    private var failures: [String] = []
    private var count = 0
    private let consoleFixture: [String: Any]?
    private var connectionGeneration: String?
    var port: UInt16? { listener.port?.rawValue }
    var frames: [[String: Any]] { queue.sync { received } }
    var errors: [String] { queue.sync { failures } }

    init(consoleFixture: [String: Any]? = nil) throws {
        self.consoleFixture = consoleFixture
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
                self.connectionGeneration = value["connection_generation"] as? String
                if let consoleFixture = self.consoleFixture {
                    self.send(
                        ["type": "rote_config", "device_profile": ["console": consoleFixture["presentation"]!]],
                        to: connection)
                    self.send(["type": "chrome_menu", "model": consoleFixture["menu"]!], to: connection)
                } else {
                    self.send(
                        [
                            "type": "chrome_menu",
                            "model": [
                                "version": 2,
                                "topbar": [
                                    [
                                        "key": "work", "kind": "action", "label": "Work records", "icon": "briefcase",
                                        "action": ["surface": "work", "params": ["mode": "list"]],
                                    ]
                                ], "menu": [],
                            ],
                        ], to: connection)
                }
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
            } else if ["chrome_open", "chrome_close"].contains(value["action"] as? String ?? "") {
                self.received.append(value)
            } else if self.consoleFixture != nil,
                ["chat_message", "new_chat", "load_chat"].contains(value["action"] as? String ?? "")
            {
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

    func respond(to request: [String: Any], title: String, detailButton: Bool = false, surface: String = "work") {
        queue.async {
            guard let connection = self.connections.first else { return }
            var components: [[String: Any]] = [
                ["type": "text", "variant": "body", "content": "Synthetic retained evidence"]
            ]
            if detailButton {
                components.append([
                    "type": "button", "variant": "secondary", "label": "View task",
                    "action": "chrome_open", "local": false, "disabled": false,
                    "payload": [
                        "surface": "work",
                        "params": [
                            "mode": "detail",
                            "operation_id": "11111111-1111-4111-8111-111111111111",
                        ],
                    ],
                ])
            }
            self.send(
                [
                    "type": "chrome_surface", "surface_key": surface, "region": "modal", "title": title,
                    "mode": "replace", "admin_only": false, "request_generation": request["request_generation"]!,
                    "components": components,
                ], to: connection)
        }
    }

    func renderResult(for request: [String: Any], text: String) {
        queue.async {
            guard let connection = self.connections.first, let generation = self.connectionGeneration,
                let requestGeneration = request["request_generation"] as? String
            else { return }
            let chat = "11111111-1111-4111-8111-111111111111"
            self.send(["type": "chat_created", "chat_id": chat], to: connection)
            self.send(
                [
                    "type": "ui_render", "target": "canvas", "chat_id": chat,
                    "connection_generation": generation, "request_generation": requestGeneration,
                    "base_render_revision": 0, "frame_sequence": 1,
                    "components": [["type": "text", "content": text]],
                ], to: connection)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}
