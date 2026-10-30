// Exercises nested renderer controls through their actual button actions and current workspace-bound event path.

import AstralCore
@testable import AstralDeep
import SwiftUI
import XCTest

#if os(macOS)
    import AppKit
    import ApplicationServices
#endif

@MainActor
final class NestedComponentActionTests: XCTestCase {
    private var suites: [String] = []
    private let chat = "11111111-1111-4111-8111-111111111111"

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func ready() -> AppModel {
        let suite = "NestedComponentActionTests.\(UUID().uuidString)"
        suites.append(suite)
        let model = AppModel(tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: suite)!)
        model.signedIn = true
        model.connected = true
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.test", subject: "owner")!)
        XCTAssertTrue(model.beginConversationConnection("22222222-2222-4222-8222-222222222222"))
        XCTAssertTrue(
            model.openConversationRequest(
                chatId: chat, requestGeneration: "33333333-3333-4333-8333-333333333333", purpose: .hydration))
        model.canvas = [card()]
        return model
    }

    private func card() -> AstralComponent {
        AstralComponent(
            json: .object([
                "type": .string("card"), "component_id": .string("wc_preview"), "title": .string("Site preview"),
                "content": .array([
                    .object([
                        "type": .string("container"), "children": .array([button("status"), button("stop")]),
                    ])
                ]),
            ]))!
    }

    private func button(_ action: String) -> JSONValue {
        .object([
            "type": .string("button"), "label": .string(action == "status" ? "Check status" : "Stop preview"),
            "action": .string("component_action"),
            "payload": .object([
                "kind": .string("invoke"),
                "params_patch": .object(["action": .string(action), "job_id": .string("owned-job")]),
            ]),
        ])
    }

    func testInvocationCallbackPreservesPatchAndRejectsStaleOrConflictingContext() throws {
        for mutation in ["chat", "owner", "connection", "replacement", "duplicate", "history", "payload"] {
            let model = ready()
            let root = model.canvas[0]
            let child = AstralComponent(json: button("status"))!
            let invoke = model.componentInvocationCallback(child, owner: root)
            var frames: [String] = []
            model.outboundTap = { frames.append($0) }
            var payload = child.raw["payload"]!.objectValue!
            switch mutation {
            case "chat": model.activeChatId = "other"
            case "owner":
                model.bindConversationAccount(ConversationAccount(issuer: "https://iam.test", subject: "other")!)
            case "connection":
                XCTAssertTrue(model.beginConversationConnection("44444444-4444-4444-8444-444444444444"))
            case "replacement": model.canvas = []
            case "duplicate": model.canvas.append(root)
            case "history": model.timelineReadOnly = true
            default: payload["component_id"] = .string("another-component")
            }
            invoke(payload)
            XCTAssertTrue(frames.isEmpty, mutation)
        }
    }

    #if os(macOS)
        func testMountedNestedCardButtonsSendCanonicalContextAndUntouchedStatusStopPatches() async throws {
            let model = ready()
            let view = NSHostingView(
                rootView: ComponentView(component: model.canvas[0]).environment(model).environment(model.themeStore))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Nested component actions \(UUID().uuidString)"
            window.contentView = view
            window.orderBack(nil)
            defer { window.close() }
            var frames: [String] = []
            model.outboundTap = { frames.append($0) }
            for (label, action) in [("Check status", "status"), ("Stop preview", "stop")] {
                var pressed = false
                for _ in 0..<10 {
                    view.layoutSubtreeIfNeeded()
                    if press(label, windowTitle: window.title) {
                        pressed = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertTrue(pressed, "Nested \(label) was not reachable")
                let frame = try JSONValue.parse(Data(try XCTUnwrap(frames.last).utf8))
                XCTAssertEqual(frame["action"], .string("component_action"))
                XCTAssertEqual(frame["session_id"], .string(chat))
                XCTAssertEqual(frame["payload"]?["component_id"], .string("wc_preview"))
                XCTAssertEqual(frame["payload"]?["chat_id"], .string(chat))
                XCTAssertEqual(frame["payload"]?["kind"], .string("invoke"))
                XCTAssertEqual(
                    frame["payload"]?["params_patch"],
                    .object([
                        "action": .string(action), "job_id": .string("owned-job"),
                    ]))
            }
            XCTAssertEqual(frames.count, 2)
        }

        private func press(_ label: String, windowTitle: String) -> Bool {
            let application = AXUIElementCreateApplication(getpid())
            let windows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] ?? []
            guard let window = windows.first(where: { attribute(kAXTitleAttribute, of: $0) as? String == windowTitle }),
                let button = find(label, in: window, depth: 0)
            else { return false }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }

        private func find(_ label: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
            let title = attribute(kAXTitleAttribute, of: element) as? String
            let description = attribute(kAXDescriptionAttribute, of: element) as? String
            if attribute(kAXRoleAttribute, of: element) as? String == kAXButtonRole,
                title == label || description == label
            {
                return element
            }
            guard depth < 64 else { return nil }
            let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
            return children.lazy.compactMap { self.find(label, in: $0, depth: depth + 1) }.first
        }

        private func attribute(_ key: String, of element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
    #endif
}
