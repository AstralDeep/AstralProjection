// Drives PhoneCompanionRelay over a MeshRuntime on the in-memory kernel with a recording channel in place of WatchConnectivity.
// It covers the chat list, the watch-adapted chat, forwarded send and stop, the owner packet, and every refusal.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
private final class RecordingRelayChannel: CompanionRelayChannel {
    var onRelayRequest: (@MainActor @Sendable (Data) async -> Void)?
    var onRelayReady: (@MainActor @Sendable () -> Void)?
    var sent: [(update: CompanionPhoneUpdate, latest: Bool)] = []

    func publish(_ update: Data, latestState: Bool) {
        if let decoded = try? CompanionPhoneUpdate(data: update) { sent.append((decoded, latestState)) }
    }

    var chatLists: [(CompanionVoiceOwner, [CompanionChatSummary], Int)] {
        sent.compactMap { if case .chats(let o, let c, let n) = $0.update { return (o, c, n) } else { return nil } }
    }
    var chatViews: [(chatId: String, title: String, view: String)] {
        sent.compactMap { if case .chat(_, let id, let t, let v) = $0.update { return (id, t, v) } else { return nil } }
    }
    var runStates: [CompanionRunState] {
        sent.compactMap { if case .run(_, _, let s) = $0.update { return s } else { return nil } }
    }
    var phoneStates: [(CompanionVoiceOwner, CompanionPhoneState)] {
        sent.compactMap { if case .phone(let o, let s) = $0.update { return (o, s) } else { return nil } }
    }
}

@MainActor
final class PhoneCompanionRelayTests: XCTestCase {
    private func owner(_ h: MeshRuntimeHarness) throws -> CompanionVoiceOwner {
        try XCTUnwrap(CompanionVoiceOwner(meshId: try XCTUnwrap(h.runtime.status.meshId)))
    }

    private func request(_ value: CompanionWatchRequest) throws -> Data { try value.encoded() }

    private struct Rig {
        let h: MeshRuntimeHarness
        let channel: RecordingRelayChannel
        let relay: PhoneCompanionRelay
    }

    private func rig(hasMesh: Bool = true) async -> Rig {
        let h = MeshRuntimeHarness(hasMesh: hasMesh)
        await h.runtime.open()
        let channel = RecordingRelayChannel()
        let relay = PhoneCompanionRelay(channel: channel)
        relay.bind(h.runtime)
        return Rig(h: h, channel: channel, relay: relay)
    }

    func testTheOwnerMeshIdReachesTheWatchAsAPhoneUpdate() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        await r.relay.refresh()
        let state = try XCTUnwrap(r.channel.sent.first)
        XCTAssertTrue(state.latest)
        XCTAssertEqual(state.update, .phone(owner: try owner(r.h), state: .ready))
    }

    func testTheChatListIsSentOnRequest() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        _ = await r.h.runtime.newChat(title: "Dosing plan")
        let outcome = await r.relay.handle(try request(.listChats(owner: try owner(r.h))))
        XCTAssertEqual(outcome, .served)
        let list = try XCTUnwrap(r.channel.chatLists.last)
        XCTAssertEqual(list.0, try owner(r.h))
        XCTAssertEqual(list.1.map(\.title), ["Dosing plan"])
        XCTAssertEqual(list.2, 0)
    }

    func testAWatchAdaptedChatUsesTheKernelWatchProfile() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let created = await r.h.runtime.newChat(title: "Rounds")
        let chat = try XCTUnwrap(created)
        _ = await r.h.runtime.send("What changed overnight?")
        await r.h.runtime.settle()
        let outcome = await r.relay.handle(try request(.openChat(owner: try owner(r.h), chatId: chat)))
        XCTAssertEqual(outcome, .served)
        let call = try XCTUnwrap(r.h.kernel.calls.last { $0.name == "chatForDevice" })
        XCTAssertTrue(call.detail.hasPrefix(chat + "|"))
        XCTAssertTrue(call.detail.contains("\"device_type\":\"watch\""))
        let sent = try XCTUnwrap(r.channel.chatViews.last)
        XCTAssertEqual(sent.title, "Rounds")
        XCTAssertTrue(sent.view.contains("You: What changed overnight?"))
        XCTAssertTrue(sent.view.contains("Astral: Hello there"))
        XCTAssertLessThanOrEqual(sent.view.utf8.count, CompanionRelay.maximumViewBytes)
    }

    func testALongChatKeepsTheNewestLinesWithinTheBound() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let messages = (0..<60).map {
            MeshRuntimeHarness.message(
                "m\($0)", parent: $0 == 0 ? nil : "m\($0 - 1)", author: $0 % 2 == 0 ? .owner : .assistant,
                text: String(repeating: "word \($0) ", count: 20), at: TimeInterval($0))
        }
        let chat = r.h.kernel.seedChat(title: "Long", messages: messages)
        await r.h.runtime.refreshChats()
        _ = await r.relay.handle(try request(.openChat(owner: try owner(r.h), chatId: chat)))
        let sent = try XCTUnwrap(r.channel.chatViews.last)
        XCTAssertLessThanOrEqual(sent.view.utf8.count, CompanionRelay.maximumViewBytes)
        XCTAssertTrue(sent.view.contains("word 59"))
        XCTAssertFalse(sent.view.contains("word 0 "))
    }

    func testASendIsForwardedThroughTheNormalTurnPath() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let created = await r.h.runtime.newChat(title: "Wrist")
        let chat = try XCTUnwrap(created)
        let outcome = await r.relay.handle(
            try request(.sendMessage(owner: try owner(r.h), chatId: chat, text: "Summarize labs")))
        XCTAssertEqual(outcome, .served)
        XCTAssertEqual(r.h.kernel.calls.filter { $0.name == "sendMessage" }.map(\.detail), ["Summarize labs|"])
        XCTAssertFalse(r.channel.runStates.isEmpty)
        XCTAssertTrue(r.channel.chatViews.last?.view.contains("You: Summarize labs") == true)
    }

    func testASendToAnUnknownChatIsRefusedBeforeTheKernelSeesIt() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let outcome = await r.relay.handle(
            try request(.sendMessage(owner: try owner(r.h), chatId: "chat-that-is-not-here", text: "hello")))
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(r.h.kernel.calls.contains { $0.name == "sendMessage" })
    }

    func testAStopIsForwardedAndReportsTheRunState() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let created = await r.h.runtime.newChat(title: "Long run")
        let chat = try XCTUnwrap(created)
        r.h.kernel.turnScript = [.started]
        _ = await r.h.runtime.send("long work")
        await r.h.runtime.settle()
        let outcome = await r.relay.handle(try request(.stopRun(owner: try owner(r.h), chatId: chat)))
        XCTAssertEqual(outcome, .served)
        XCTAssertEqual(r.h.kernel.calls.filter { $0.name == "interruptTurn" }.count, 1)
        XCTAssertEqual(r.channel.runStates.last, .stopping)
    }

    func testEverythingIsRefusedWhileNoMeshIsOpen() async throws {
        let r = await rig(hasMesh: false)
        defer { r.h.cleanUp() }
        let watchOwner = try XCTUnwrap(CompanionVoiceOwner(meshId: "sha256:" + String(repeating: "ab", count: 32)))
        let requests: [CompanionWatchRequest] = [
            .listChats(owner: watchOwner), .openChat(owner: watchOwner, chatId: "c1"),
            .sendMessage(owner: watchOwner, chatId: "c1", text: "hi"), .stopRun(owner: watchOwner, chatId: "c1"),
        ]
        for value in requests {
            let outcome = await r.relay.handle(try request(value))
            XCTAssertEqual(outcome, .noMesh)
        }
        let names = Set(r.h.kernel.calls.map(\.name))
        XCTAssertTrue(names.isDisjoint(with: ["listChats", "chat", "chatForDevice", "sendMessage", "interruptTurn"]))
        XCTAssertTrue(r.channel.phoneStates.allSatisfy { $0.1 == .noMesh })
        XCTAssertEqual(r.channel.phoneStates.count, requests.count)
        XCTAssertTrue(r.channel.chatViews.isEmpty && r.channel.chatLists.isEmpty && r.channel.runStates.isEmpty)
    }

    func testApprovalConsentPairingAndTicketPacketsAreRefused() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let id = try owner(r.h).meshId
        let before = r.h.kernel.calls.count
        for kind in ["approve_action", "consent", "pair_device", "ticket_mint", "grant_tool"] {
            let packet = Data("{\"kind\":\"\(kind)\",\"owner\":\"\(id)\"}".utf8)
            let outcome = await r.relay.handle(packet)
            XCTAssertEqual(outcome, .refused(.authorityRefused), kind)
        }
        XCTAssertEqual(r.h.kernel.calls.count, before)
        XCTAssertTrue(r.channel.sent.isEmpty)
        XCTAssertTrue(r.h.runtime.pendingConsents.isEmpty)
    }

    func testMalformedAndWrongDirectionPacketsAreRefused() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let id = try owner(r.h).meshId
        let garbage = await r.relay.handle(Data("not json".utf8))
        XCTAssertEqual(garbage, .refused(.invalidPacket))
        let phoneKind = await r.relay.handle(Data("{\"kind\":\"phone\",\"owner\":\"\(id)\",\"state\":\"ready\"}".utf8))
        XCTAssertEqual(phoneKind, .refused(.unknownKind))
        XCTAssertTrue(r.channel.sent.isEmpty)
    }

    func testAWatchBoundToAnotherMeshIsToldTheOpenMeshAndNothingRuns() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let other = try XCTUnwrap(CompanionVoiceOwner(meshId: "sha256:" + String(repeating: "cd", count: 32)))
        _ = await r.h.runtime.newChat(title: "Mine")
        let outcome = await r.relay.handle(try request(.listChats(owner: other)))
        XCTAssertEqual(outcome, .wrongOwner)
        XCTAssertEqual(r.channel.phoneStates.last?.0, try owner(r.h))
        XCTAssertTrue(r.channel.chatLists.isEmpty)
    }

    func testAStoppedMeshServesNothing() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let created = await r.h.runtime.newChat(title: "Paused")
        let chat = try XCTUnwrap(created)
        await r.h.runtime.raiseStop()
        let outcome = await r.relay.handle(
            try request(.sendMessage(owner: try owner(r.h), chatId: chat, text: "go")))
        XCTAssertEqual(outcome, .stopped)
        XCTAssertFalse(r.h.kernel.calls.contains { $0.name == "sendMessage" })
        XCTAssertEqual(r.channel.phoneStates.last?.1, .stopped)
    }

    func testUnbindingTellsTheWatchTheMeshIsGone() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        await r.relay.refresh()
        r.relay.unbind()
        XCTAssertEqual(r.channel.phoneStates.last?.1, .noMesh)
        let outcome = await r.relay.handle(try request(.listChats(owner: try owner(r.h))))
        XCTAssertEqual(outcome, .noMesh)
    }

    func testRefreshPushesTheOpenChatOnlyAfterTheWatchEngages() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let created = await r.h.runtime.newChat(title: "Live")
        let chat = try XCTUnwrap(created)
        await r.relay.refresh()
        XCTAssertTrue(r.channel.chatViews.isEmpty)
        _ = await r.relay.handle(try request(.openChat(owner: try owner(r.h), chatId: chat)))
        let count = r.channel.chatViews.count
        _ = await r.h.runtime.send("update me")
        await r.h.runtime.settle()
        await r.relay.refresh()
        XCTAssertGreaterThan(r.channel.chatViews.count, count)
        XCTAssertTrue(r.channel.chatViews.last?.view.contains("update me") == true)
    }

    func testChatTextDropsToolAuthorsAndUntrustedSurfaces() {
        let view = MeshChatView(
            chatId: "c", title: "T",
            messages: [
                MeshRuntimeHarness.message("a", parent: nil, author: .tool, text: "tool output", at: 1),
                MeshRuntimeHarness.message("b", parent: "a", author: .owner, text: "line\u{0007}one", at: 2),
            ],
            branches: [], surfaces: [],
            rendered: [
                MeshRenderedSurface(
                    surfaceId: "s", tree: [.object(["type": .string("text"), "text": .string("trusted note")])],
                    untrusted: false, rejected: []),
                MeshRenderedSurface(
                    surfaceId: "u", tree: [.object(["text": .string("untrusted note")])], untrusted: true,
                    rejected: []),
            ],
            labels: [], status: .idle)
        let text = WatchChatText.make(view)
        XCTAssertEqual(text, "You: line one\ntrusted note")
        XCTAssertEqual(WatchChatText.title("  \n "), CompanionRelay.untitledChat)
    }
}
