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
    var withdrawn: [String] = []
    var succeeds = true
    var held: [@MainActor (Bool) -> Void] = []
    var holdReplies = false

    func publish(_ update: Data, kind: String, latestState: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        if let decoded = try? CompanionPhoneUpdate(data: update) {
            XCTAssertEqual(decoded.wireKind, kind)
            sent.append((decoded, latestState))
        }
        if holdReplies { held.append(completion) } else { completion(succeeds) }
    }

    func withdraw(kind: String) { withdrawn.append(kind) }

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
        var messages: [MeshChatMessage] = []
        for index in 0..<60 {
            let parent: String? = index == 0 ? nil : "m\(index - 1)"
            let author: MeshAuthor = index % 2 == 0 ? .owner : .assistant
            let text: String = String(repeating: "word \(index) ", count: 20)
            messages.append(
                MeshRuntimeHarness.message(
                    "m\(index)", parent: parent, author: author, text: text, at: TimeInterval(index)))
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
        _ = await r.relay.handle(try request(.openChat(owner: try owner(r.h), chatId: chat)))
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
        XCTAssertEqual(r.channel.runStates.last, .failed)
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

    private func labeled(
        _ id: String, parent: String?, author: MeshAuthor, text: String, at: TimeInterval,
        confidentiality: String = "private", integrity: String = "owner", surfaces: [String] = []
    ) -> MeshChatMessage {
        var message = MeshRuntimeHarness.message(
            id, parent: parent, author: author, text: text, at: at, surfaces: surfaces)
        message.confidentiality = confidentiality
        message.integrity = integrity
        return message
    }

    private func surface(_ id: String, untrusted: Bool = false, texts: [String]) -> MeshRenderedSurface {
        MeshRenderedSurface(
            surfaceId: id, tree: texts.map { .object(["type": .string("text"), "text": .string($0)]) },
            untrusted: untrusted, rejected: [])
    }

    func testRestrictedMessagesAndSurfacesNeverReachTheWatchBytes() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let messages = [
            labeled("m1", parent: nil, author: .owner, text: "hello there", at: 1),
            labeled("m2", parent: "m1", author: .assistant, text: "PHI-SECRET-TEXT", at: 2, confidentiality: "phi"),
            labeled("m3", parent: "m2", author: .assistant, text: "SECRET-TEXT", at: 3, confidentiality: "secret"),
            labeled("m4", parent: "m3", author: .assistant, text: "plain answer", at: 4, surfaces: ["priv"]),
            labeled(
                "m5", parent: "m4", author: .assistant, text: "second answer", at: 5, confidentiality: "public",
                integrity: "untrusted", surfaces: ["hostile"]),
            labeled(
                "m6", parent: "m5", author: .assistant, text: "third answer", at: 6, confidentiality: "public",
                surfaces: ["flagged", "good"]),
        ]
        let chat = r.h.kernel.seedChat(title: "Labels", messages: messages)
        r.h.kernel.setRendered(
            chatId: chat,
            [
                surface("priv", texts: ["PRIVATE-SURFACE-TEXT"]),
                surface("hostile", texts: ["HOSTILE-SURFACE-TEXT"]),
                surface("flagged", untrusted: true, texts: ["UNTRUSTED-SURFACE-TEXT"]),
                surface("good", texts: ["first line", "second line"]),
            ])
        await r.h.runtime.refreshChats()
        _ = await r.relay.handle(try request(.openChat(owner: try owner(r.h), chatId: chat)))
        let view = try XCTUnwrap(r.channel.chatViews.last).view
        for banned in ["PHI-SECRET", "SECRET-TEXT", "PRIVATE-SURFACE", "HOSTILE-SURFACE", "UNTRUSTED-SURFACE"] {
            XCTAssertFalse(view.contains(banned), banned)
        }
        XCTAssertTrue(view.contains(WatchChatText.placeholder))
        XCTAssertTrue(view.contains("plain answer") && view.contains("third answer"))
        XCTAssertFalse(view.contains("\(WatchChatText.placeholder)\n\(WatchChatText.placeholder)"))
        let first = try XCTUnwrap(view.range(of: "first line"))
        let second = try XCTUnwrap(view.range(of: "second line"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
    }

    func testOnlyTheCurrentBranchIsShown() {
        let view = MeshChatView(
            chatId: "c", title: "T",
            messages: [
                labeled("a", parent: nil, author: .owner, text: "root", at: 1),
                labeled("b", parent: "a", author: .assistant, text: "OLD-BRANCH", at: 2),
                labeled("c", parent: "a", author: .assistant, text: "new branch", at: 3),
            ], branches: [], surfaces: [], rendered: [], labels: [], status: .idle)
        let text = WatchChatText.make(view)
        XCTAssertEqual(text, "You: root\nAstral: new branch")
    }

    func testTextNeverStartsWithAPartialLine() {
        let messages = (0..<40).map {
            labeled(
                "m\($0)", parent: $0 == 0 ? nil : "m\($0 - 1)", author: .owner,
                text: "line-\($0)-" + String(repeating: "x", count: 150), at: TimeInterval($0))
        }
        let view = MeshChatView(
            chatId: "c", title: "T", messages: messages, branches: [], surfaces: [], rendered: [], labels: [],
            status: .idle)
        let text = WatchChatText.make(view)
        XCTAssertLessThanOrEqual(text.utf8.count, CompanionRelay.maximumViewBytes)
        XCTAssertTrue(text.hasPrefix("You: line-"))
        XCTAssertTrue(text.hasSuffix(String(repeating: "x", count: 150)))
    }

    func testCleanedTextIsAlwaysAcceptedByTheEncoder() throws {
        let nasty = "a\u{200E}b\u{202E}c\u{200B}d\u{0007}e\u{FEFF}f\ng\th"
        let id = "sha256:" + String(repeating: "ab", count: 32)
        let owner = try XCTUnwrap(CompanionVoiceOwner(meshId: id))
        let view = MeshChatView(
            chatId: "c", title: nasty,
            messages: [labeled("a", parent: nil, author: .owner, text: nasty, at: 1)],
            branches: [], surfaces: [], rendered: [], labels: [], status: .idle)
        let update = CompanionPhoneUpdate.chat(
            owner: owner, chatId: "c", title: WatchChatText.title(nasty), view: WatchChatText.make(view))
        XCTAssertNoThrow(try update.encoded())
        XCTAssertEqual(WatchChatText.clean(nasty, maximumBytes: 200), "a b c d e f g h")
    }

    func testASendToAnotherChatLeavesThePhonesCurrentChatAlone() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let first = await r.h.runtime.newChat(title: "First")
        let target = try XCTUnwrap(first)
        let second = await r.h.runtime.newChat(title: "Second")
        let current = try XCTUnwrap(second)
        XCTAssertEqual(r.h.runtime.currentChatId, current)
        let outcome = await r.relay.handle(
            try request(.sendMessage(owner: try owner(r.h), chatId: target, text: "for first")))
        XCTAssertEqual(outcome, .served)
        XCTAssertEqual(r.h.runtime.currentChatId, current)
        await r.h.runtime.settle()
        XCTAssertTrue(try r.h.kernel.chat(chatId: target).messages.contains { $0.text == "for first" })
        XCTAssertFalse(try r.h.kernel.chat(chatId: current).messages.contains { $0.text == "for first" })
    }

    func testInterleavedSendsEachLandInTheirOwnChat() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let aMade = await newChat(r, "A")
        let a = try XCTUnwrap(aMade)
        let bMade = await newChat(r, "B")
        let b = try XCTUnwrap(bMade)
        let id = try owner(r.h)
        let one = try request(.sendMessage(owner: id, chatId: a, text: "to A"))
        let two = try request(.sendMessage(owner: id, chatId: b, text: "to B"))
        async let first = r.relay.handle(one)
        async let second = r.relay.handle(two)
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes, [.served, .served])
        await r.h.runtime.settle()
        XCTAssertTrue(try r.h.kernel.chat(chatId: a).messages.contains { $0.text == "to A" })
        XCTAssertTrue(try r.h.kernel.chat(chatId: b).messages.contains { $0.text == "to B" })
        XCTAssertFalse(try r.h.kernel.chat(chatId: a).messages.contains { $0.text == "to B" })
        XCTAssertFalse(try r.h.kernel.chat(chatId: b).messages.contains { $0.text == "to A" })
    }

    private func newChat(_ r: Rig, _ title: String) async -> String? { await r.h.runtime.newChat(title: title) }

    func testAMeshChangeDuringASendDropsTheReply() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        let chatMade = await newChat(r, "Gone")
        let chat = try XCTUnwrap(chatMade)
        let id = try owner(r.h)
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        r.h.kernel.sendGate = {
            reached.signal()
            release.wait()
        }
        let request = try request(.sendMessage(owner: id, chatId: chat, text: "late"))
        let sending = Task { await r.relay.handle(request) }
        await Task.detached { reached.wait() }.value
        await r.h.runtime.close()
        release.signal()
        let outcome = await sending.value
        XCTAssertNotEqual(outcome, .served)
        XCTAssertTrue(r.channel.runStates.isEmpty && r.channel.chatViews.isEmpty)
    }

    func testChatListsAreWithdrawnWhenTheStateLeavesReady() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        _ = await newChat(r, "Visible")
        _ = await r.relay.handle(try request(.listChats(owner: try owner(r.h))))
        XCTAssertTrue(r.channel.withdrawn.isEmpty)
        await r.h.runtime.raiseStop()
        await r.relay.refresh()
        XCTAssertEqual(r.channel.withdrawn, ["chats"])
        await r.h.runtime.close()
        await r.relay.refresh()
        XCTAssertEqual(r.channel.withdrawn.count, 2)
        r.relay.unbind()
        XCTAssertEqual(r.channel.withdrawn.count, 3)
    }

    func testALateReplyAfterAWithdrawDoesNotSuppressTheResend() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        _ = await newChat(r, "Listed")
        r.channel.holdReplies = true
        _ = await r.relay.handle(try request(.listChats(owner: try owner(r.h))))
        let held = r.channel.held
        XCTAssertFalse(held.isEmpty)
        r.channel.holdReplies = false
        await r.h.runtime.raiseStop()
        await r.relay.refresh()
        XCTAssertEqual(r.channel.withdrawn, ["chats"])
        for reply in held { reply(true) }
        await r.h.runtime.resume()
        let before = r.channel.chatLists.count
        await r.relay.refresh()
        XCTAssertEqual(r.channel.chatLists.count, before + 1)
    }

    func testAFailedDeliveryIsRetriedAndASuccessfulOneIsNot() async throws {
        let r = await rig()
        defer { r.h.cleanUp() }
        r.channel.succeeds = false
        await r.relay.refresh()
        await r.relay.refresh()
        XCTAssertEqual(r.channel.phoneStates.count, 2)
        r.channel.succeeds = true
        await r.relay.refresh()
        await r.relay.refresh()
        XCTAssertEqual(r.channel.phoneStates.count, 3)
    }

    func testTheContextStoreMergesAndWithdrawsEntries() {
        var store = WatchContextStore()
        XCTAssertFalse(store.dirty)
        store.setEndpoint("https://example.test")
        XCTAssertTrue(store.set(kind: "chats", data: Data("c".utf8)))
        XCTAssertTrue(store.set(kind: "phone", data: Data("p".utf8)))
        XCTAssertFalse(store.set(kind: "chat", data: Data("x".utf8)))
        XCTAssertEqual(store.snapshot.count, 3)
        store.markFlushed()
        store.remove(kind: "chats")
        XCTAssertTrue(store.dirty)
        XCTAssertNil(store.snapshot["companion.chats"])
        XCTAssertNotNil(store.snapshot["companion.phone"])
        XCTAssertNotNil(store.snapshot[AstralConfig.serverOverrideDefaultsKey])
        store.markFlushed()
        store.remove(kind: "chats")
        XCTAssertFalse(store.dirty)
    }

    func testInboundDataRoutesVoiceToVoiceAndEverythingElseToTheRelay() throws {
        let id = "sha256:" + String(repeating: "ab", count: 32)
        let owner = try XCTUnwrap(CompanionVoiceOwner(meshId: id))
        let voice = try CompanionVoicePacket(
            kind: .start, session: UUID(), sequence: 0, microseconds: 0,
            payload: CompanionVoiceActivation(owner: owner, mode: .conversation).encoded())
        guard case .voice = WatchInbound.classify(voice.encoded) else { return XCTFail("voice must route to voice") }
        let relay = try CompanionWatchRequest.listChats(owner: owner).encoded()
        guard case .relay(let data) = WatchInbound.classify(relay) else { return XCTFail("relay must route to relay") }
        XCTAssertEqual(data, relay)
        guard case .relay = WatchInbound.classify(Data("nonsense".utf8)) else {
            return XCTFail("garbage is the relay's to refuse")
        }
    }
}
