// Verifies watch console negotiation, authoritative availability, request ownership, draft behavior and rendering.
// Synthetic loopback transport exercises real WebSocket fencing without replacing user authentication.

import AstralCore
import SwiftUI
import XCTest

@testable import AstralWatch

@MainActor
final class ConsoleWatchTests: XCTestCase {
    private let connection = "22222222-2222-4222-8222-222222222222"
    private let generation = "33333333-3333-4333-8333-333333333333"
    private let owner = ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!

    private func fixture(_ key: String) throws -> JSONValue {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "WatchConsoleFixtures", withExtension: "json"))
        return try XCTUnwrap(JSONValue.parse(Data(contentsOf: url))[key])
    }

    private func configured(_ model: WatchModel) throws {
        model.bindConversationAccount(owner)
        XCTAssertTrue(model.beginConversationConnection(connection))
        model.connected = true
        model.handleFrame(
            InboundFrame(
                name: "rote_config",
                payload: .object([
                    "device_profile": .object(["console": try fixture("presentation")])
                ])))
        model.handleFrame(InboundFrame(name: "chrome_menu", payload: .object(["model": try fixture("menu")])))
        XCTAssertNotNil(model.console)
    }

    private func button(_ action: String = "chat_message", prompt: String = "Roll six dice") -> JSONValue {
        .object([
            "type": .string("button"), "label": .string("Run"), "action": .string(action),
            "disabled": .bool(false), "local": .bool(false), "payload": .object(["message": .string(prompt)]),
        ])
    }

    private func response(_ generation: String, components: [JSONValue]? = nil) -> InboundFrame {
        InboundFrame(
            name: "chrome_surface",
            payload: .object([
                "type": .string("chrome_surface"), "surface_key": .string("agent_intro"), "region": .string("modal"),
                "title": .string("Dice"), "admin_only": .bool(false), "mode": .string("replace"),
                "request_generation": .string(generation), "components": .array(components ?? [button()]),
            ]))
    }

    func testSurfaceRequiresBoundedKnownSchemaAndOfferedActions() throws {
        let run = button()
        let wrapped = JSONValue.object(["type": .string("card"), "content": .array([run])])
        let valid = response(generation, components: [wrapped])
        let surface = try XCTUnwrap(WatchConsoleSurface(frame: valid))
        XCTAssertTrue(surface.permits(AstralComponent(json: run)!))
        XCTAssertFalse(surface.permits(AstralComponent(json: button(prompt: "unoffered"))!))
        XCTAssertFalse(surface.permits(AstralComponent(json: wrapped)!))
        for (key, value) in [
            ("request_generation", JSONValue.string("33333333-3333-1333-8333-333333333333")),
            ("region", .string("canvas")), ("mode", .string("append")), ("admin_only", .bool(true)),
            ("title", .string(String(repeating: "x", count: 4097))), ("selection", .object([:])),
            ("components", .array([.object(["type": .string("param_picker")])])),
            ("components", .array(Array(repeating: run, count: 257))),
            ("components", .array([button("chrome_note_save")])),
            ("components", .array([button(prompt: " ")])),
            ("components", .array([button(prompt: String(repeating: "x", count: 32_001))])),
        ] {
            var fields = valid.payload.objectValue!
            fields[key] = value
            XCTAssertNil(
                WatchConsoleSurface(frame: InboundFrame(name: "chrome_surface", payload: .object(fields))), key)
        }
        var nested = run
        for _ in 0..<10 { nested = .object(["type": .string("container"), "children": .array([nested])]) }
        XCTAssertNil(WatchConsoleSurface(frame: response(generation, components: [nested])))
        XCTAssertNil(WatchConsoleSurface(frame: InboundFrame(name: "ui_render", payload: valid.payload)))
        var malformed = run.objectValue!
        malformed["disabled"] = .bool(true)
        XCTAssertNil(WatchConsoleSurface(frame: response(generation, components: [.object(malformed)])))
        let permissions = JSONValue.object([
            "type": .string("button"), "label": .string("Permissions"),
            "action": .string("chrome_open"), "disabled": .bool(false), "local": .bool(false),
            "payload": .object(["surface": .string("agents"), "params": .object(["agent_id": .string("dice")])]),
        ])
        XCTAssertTrue(
            try XCTUnwrap(WatchConsoleSurface(frame: response(generation, components: [permissions])))
                .permits(AstralComponent(json: permissions)!))
        XCTAssertNotNil(WatchConsoleSurface(frame: response(generation, components: [button("compose_prompt")])))
        XCTAssertNil(WatchConsoleSurface(frame: response(generation, components: [button(prompt: "bad\0prompt")])))
        XCTAssertNil(
            WatchConsoleSurface(
                frame: response(
                    generation,
                    components: [
                        .object([
                            "type": .string("text"), "content": .string(String(repeating: "x", count: 1024 * 1024)),
                        ])
                    ])))
        var malformedPermissions = permissions.objectValue!
        malformedPermissions["payload"] = .object([
            "surface": .string("agents"),
            "params": .object(["agent_id": .string("dice"), "extra": .bool(true)]),
        ])
        XCTAssertNil(WatchConsoleSurface(frame: response(generation, components: [.object(malformedPermissions)])))
    }

    func testROTERequiredCatalogDraftRunHandoffsAndThemeAreServerOwned() throws {
        let model = WatchModel()
        model.handleFrame(InboundFrame(name: "chrome_menu", payload: .object(["model": try fixture("menu")])))
        XCTAssertNil(model.console)
        try configured(model)
        let scenario = try XCTUnwrap(model.console?.catalog.scenarios.first)
        var frames: [JSONValue] = []
        model.outboundTap = { frames.append(try! JSONValue.parse(Data($0.utf8))) }
        model.pendingDictation = "Existing draft"
        XCTAssertTrue(model.useScenario(scenario, run: true))
        XCTAssertEqual(model.pendingDictation, "Existing draft")
        XCTAssertEqual(frames.last?["payload"]?["message"]?.stringValue, scenario.prompt)
        XCTAssertEqual(frames.last?["action"]?.stringValue, "chat_message")
        XCTAssertTrue(model.consoleChatVisible)
        XCTAssertTrue(model.useScenario(scenario, run: false))
        XCTAssertEqual(model.pendingDictation, scenario.prompt)
        let before = frames.count
        let background = try XCTUnwrap(model.console?.composerActions.first { $0.key == "background" })
        model.performComposerAction(background)
        XCTAssertEqual(model.handoffMessage, background.availability?.message)
        XCTAssertEqual(frames.count, before)
        let agents = try XCTUnwrap(model.chromeMenu?.allItems.first { $0.surface == "agents" })
        model.openMenuItem(agents)
        XCTAssertEqual(model.handoffMessage, agents.availability?.message)
        XCTAssertEqual(frames.count, before)
        let oldPalette = model.theme.palette
        model.handleFrame(
            InboundFrame(
                name: "user_preferences",
                payload: .object([
                    "preferences": .object(["theme": .object(["preset": .string("daylight")])])
                ])))
        XCTAssertNotEqual(model.theme.palette, oldPalette)
        model.handleFrame(
            InboundFrame(name: "theme_apply", payload: .object(["theme": .object(["preset": .string("midnight")])])))
        XCTAssertEqual(model.theme.palette, oldPalette)
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "other")!)
        XCTAssertNil(model.console)
        XCTAssertFalse(model.useScenario(scenario, run: true))
        XCTAssertEqual(model.pendingDictation, "")
    }

    func testDeviceAggregationReportsMeaningfulChangesAndPassiveVoiceStatusIsAbsent() throws {
        let model = WatchModel()
        model.audioHardwareProvider = { (true, true) }
        try configured(model)
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.viewportChanged(width: 198, height: 242, scale: 2, reducedMotion: false)
        XCTAssertEqual(sent.last?["payload"]?["device"]?["viewport_width"], .number(198))
        XCTAssertEqual(sent.last?["payload"]?["device"]?["console_contract"], .string("console/v2"))
        XCTAssertEqual(sent.last?["payload"]?["device"]?["connection_type"], .string("unknown"))
        XCTAssertEqual(sent.last?["payload"]?["device"]?["has_camera"], .bool(false))
        let count = sent.count
        model.viewportChanged(width: 198, height: 242, scale: 2, reducedMotion: false)
        XCTAssertEqual(sent.count, count)
        model.networkCapabilitiesChanged("cellular")
        XCTAssertEqual(sent.last?["payload"]?["device"]?["connection_type"], .string("cellular"))
        model.viewportChanged(width: 198, height: 242, scale: 3, reducedMotion: true)
        XCTAssertEqual(sent.last?["payload"]?["device"]?["pixel_ratio"], .number(3))
        XCTAssertEqual(sent.last?["payload"]?["device"]?["reduced_motion"], .bool(true))
        let valid = model.currentDevice
        model.viewportChanged(width: 0, height: 242, scale: .infinity, reducedMotion: false)
        XCTAssertEqual(model.currentDevice, valid)
        model.audioHardwareProvider = { (false, false) }
        model.reportDeviceCapabilities()
        XCTAssertEqual(sent.last?["payload"]?["device"]?["has_microphone"], .bool(false))
        let registration = try JSONValue.parse(Data(model.registrationFrame(token: "synthetic", resumed: false).utf8))
        XCTAssertTrue(registration["capabilities"]!.arrayValue!.contains(.string("guidance_selection_v1")))
        XCTAssertFalse(registration["capabilities"]!.arrayValue!.contains(.string("voice")))
        XCTAssertFalse(model.currentDevice.supportedTypes.contains("param_picker"))
        for state in [WatchVoiceState.off, .unavailable] {
            model.voiceState = state
            XCTAssertFalse(model.showsVoiceStatus)
        }
        for state in [WatchVoiceState.listening, .connecting, .error, .suspended] {
            model.voiceState = state
            XCTAssertTrue(model.showsVoiceStatus)
        }
    }

    func testSelectionRequiresSuccessfulCurrentGuidanceConfirmationAndClearsOnChatReset() throws {
        let model = WatchModel()
        try configured(model)
        let selected = try fixture("confirmation")["cases"]!.arrayValue!.first!
        let frame = try XCTUnwrap(selected["frame"])
        let metadata = try XCTUnwrap(frame["selection"])
        let request = try XCTUnwrap(GuidanceRequest(action: "chrome_turn_selection_set", payload: metadata))
        let generation = try XCTUnwrap(frame["request_generation"]?.stringValue)
        model.guidanceVisible = true
        XCTAssertTrue(model.guidanceState.begin(.selection, generation: generation))
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: frame))
        XCTAssertTrue(model.turnSelection.isEmpty)
        model.guidanceState.invalidate()
        XCTAssertTrue(model.guidanceState.begin(request, generation: generation))
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: frame))
        XCTAssertEqual(model.turnSelection.json, metadata)
        var last: JSONValue?
        model.outboundTap = { last = try! JSONValue.parse(Data($0.utf8)) }
        model.pendingDictation = "Use selected guidance"
        model.sendPending()
        XCTAssertEqual(last?["payload"]?["selection"], metadata)
        model.newConversation()
        XCTAssertTrue(model.turnSelection.isEmpty)
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: frame))
        XCTAssertTrue(model.turnSelection.isEmpty)
    }

    func testRealCurrentSocketIntroAndRunRejectReplayAndOwnerReplacement() async throws {
        let peer = try GuidanceModelPeer()
        peer.start()
        defer { peer.stop() }
        await fulfillment(of: [peer.ready], timeout: 3)
        let socket = WSClient(url: URL(string: "ws://127.0.0.1:\(try XCTUnwrap(peer.listener.port).rawValue)/ws")!)
        let model = WatchModel(conversationResumeStore: ConversationResumeStore(), webSocket: socket)
        let ready = expectation(description: "console registered socket")
        let events = await socket.events()
        let consume = Task {
            for await event in events {
                if case .connected = event { ready.fulfill() }
                if case .frame(let frame) = event { model.handleFrame(frame) }
            }
        }
        await socket.start(onConnect: { #"{"type":"register_ui","token":"synthetic-local-only"}"# })
        await fulfillment(of: [ready], timeout: 3)
        try configured(model)
        let agent = try XCTUnwrap(model.console?.catalog.agents.first)
        model.openAgent(agent)
        try await until { !peer.reads.isEmpty }
        let generation = try XCTUnwrap(model.consoleSurfaceGeneration)
        let stale = response(UUID().uuidString.lowercased())
        model.handleFrame(stale)
        XCTAssertNil(model.consoleSurface)
        peer.send(String(decoding: try response(generation).payload.encoded(), as: UTF8.self))
        try await until { model.consoleSurface != nil }
        XCTAssertNil(model.consoleSurfaceGeneration)
        model.handleFrame(response(generation, components: [button(prompt: "replayed")]))
        XCTAssertFalse(model.sendConsoleComponent(AstralComponent(json: button(prompt: "replayed"))!))
        XCTAssertTrue(model.sendConsoleComponent(AstralComponent(json: button())!))
        XCTAssertFalse(model.sendConsoleComponent(AstralComponent(json: button())!))
        try await until {
            peer.reads.contains { InboundFrame.parse($0)?.payload["action"]?.stringValue == "chat_message" }
        }
        XCTAssertTrue(model.consoleChatVisible)
        model.openAgent(agent)
        let old = try XCTUnwrap(model.consoleSurfaceGeneration)
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "new-owner")!)
        model.handleFrame(response(old))
        XCTAssertNil(model.consoleSurface)
        XCTAssertFalse(model.consoleSurfaceVisible)
        await socket.stop()
        consume.cancel()
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    func testDisconnectedIntroRetryAndMalformedPresentationFailClosed() throws {
        let model = WatchModel()
        try configured(model)
        let agent = try XCTUnwrap(model.console?.catalog.agents.first)
        model.connected = false
        model.openAgent(agent)
        XCTAssertTrue(model.consoleSurfaceFailed)
        XCTAssertTrue(model.consoleSurfaceVisible)
        XCTAssertFalse(model.sendConsoleComponent(AstralComponent(json: button())!))
        model.retryConsoleSurface()
        XCTAssertTrue(model.consoleSurfaceFailed)
        model.closeConsoleSurface()
        XCTAssertFalse(model.consoleSurfaceVisible)
        model.retryConsoleSurface()
        XCTAssertFalse(model.consoleSurfaceVisible)
        model.handleFrame(InboundFrame(name: "rote_config", payload: .object([:])))
        XCTAssertNil(model.console)
        model.openAgent(agent)
        XCTAssertFalse(model.consoleSurfaceVisible)
    }

    func testExpandedResultTracksCurrentModelWithoutFrozenCopies() throws {
        let model = WatchModel()
        try configured(model)
        func image(_ view: AnyView) throws -> Data {
            let renderer = ImageRenderer(
                content: view.environment(model).frame(width: 198).fixedSize(horizontal: false, vertical: true))
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        func component(_ text: String) -> AstralComponent {
            AstralComponent(json: .object(["type": .string("text"), "content": .string(text)]))!
        }
        model.entries = [.turn(id: "result", components: [component("First streamed result")])]
        let before = try image(AnyView(WatchConsoleResultContent(model: model, entryID: "result")))
        model.entries = [.turn(id: "result", components: [component("Updated result from the current conversation")])]
        let after = try image(AnyView(WatchConsoleResultContent(model: model, entryID: "result")))
        XCTAssertNotEqual(before, after)
        model.newConversation()
        XCTAssertNotEqual(after, try image(AnyView(WatchConsoleResultContent(model: model, entryID: "result"))))
    }

    func testConsoleCatalogAndSettingsRenderAtSmallAndLargeWatchSizes() throws {
        let model = WatchModel()
        try configured(model)
        model.openAgent(try XCTUnwrap(model.console?.catalog.agents.first))
        for width: CGFloat in [162, 198, 216] {
            var snapshots: Set<Data> = []
            for (name, view) in [
                ("Catalog", AnyView(WatchConsoleCatalogViewContent(model: model, category: .constant("")))),
                ("Settings", AnyView(WatchConsoleSettingsViewContent(model: model))),
                ("Actions", AnyView(WatchConsoleActionsViewContent(model: model))),
                ("Home", AnyView(WatchConsoleHomeContent(model: model))),
                ("Agents", AnyView(WatchConsoleAgentsViewContent(model: model, query: .constant("")))),
                ("Failure", AnyView(WatchConsoleSurfaceViewContent(model: model))),
            ] {
                let renderer = ImageRenderer(
                    content: view.environment(model).font(ConsoleTypography.body).foregroundStyle(
                        model.theme.palette.text
                    ).tint(model.theme.palette.primary).environment(\.colorScheme, .dark)
                        .background(model.theme.palette.bg).frame(width: width)
                        .fixedSize(horizontal: false, vertical: true))
                let image = try XCTUnwrap(renderer.uiImage)
                snapshots.insert(try XCTUnwrap(image.pngData()))
                let attachment = XCTAttachment(image: image)
                attachment.name = "WatchConsole-\(name)-\(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertEqual(snapshots.count, 6)
        }
    }
}
