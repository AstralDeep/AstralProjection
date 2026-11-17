// Checks the watch companion: phone packets bind its owner and drive its chats, requests leave only through the phone sink, snapshots render through WatchComponentView, and no watch source reaches a network or a credential.
// A source scan is the drift guard that keeps the watch from regaining its own transport or token store.

import AstralCore
import SwiftUI
import XCTest

@testable import AstralWatch

@MainActor
final class WatchCompanionTests: XCTestCase {
    private static let meshA = "sha256:" + String(repeating: "ab", count: 32)
    private static let meshB = "sha256:" + String(repeating: "cd", count: 32)

    private var ownerA: CompanionVoiceOwner { CompanionVoiceOwner(meshId: Self.meshA)! }
    private var ownerB: CompanionVoiceOwner { CompanionVoiceOwner(meshId: Self.meshB)! }

    private func make(reachable: Bool = true, deliver: Bool = true) -> (WatchModel, Sent) {
        let model = WatchModel()
        let sent = Sent()
        model.requestSink = { data in
            sent.requests.append(try! CompanionWatchRequest(data: data))
            return deliver
        }
        model.phoneReachable = reachable
        return (model, sent)
    }

    private func phone(_ owner: CompanionVoiceOwner, _ state: CompanionPhoneState) throws -> Data {
        try CompanionPhoneUpdate.phone(owner: owner, state: state).encoded()
    }

    private func chatList(_ owner: CompanionVoiceOwner, _ ids: [String]) throws -> Data {
        try CompanionPhoneUpdate.chatList(
            owner: owner, chats: ids.map { CompanionChatSummary(chatId: $0, title: "Chat \($0)") }
        ).encoded()
    }

    private func drain() async { for _ in 0..<30 { await Task.yield() } }

    func testPhoneContextBindsOwnerAppliesStateBeforeChatsAndAsksForTheListOnce() async throws {
        let (model, sent) = make()
        model.receivePhoneContext(phone: try phone(ownerA, .ready), chats: try chatList(ownerA, ["c1", "c2"]))
        await drain()
        XCTAssertEqual(model.companionOwner, ownerA)
        XCTAssertEqual(model.link, .ready)
        XCTAssertEqual(model.chats.map(\.chatId), ["c1", "c2"])
        XCTAssertEqual(sent.requests, [.listChats(owner: ownerA)])
    }

    func testListRequestWaitsForAnOwnerAndForReachability() async throws {
        let (model, sent) = make(reachable: false)
        model.receivePhoneContext(phone: try phone(ownerA, .ready), chats: nil)
        await drain()
        XCTAssertTrue(sent.requests.isEmpty)
        model.phoneReachable = true
        await drain()
        XCTAssertEqual(sent.requests, [.listChats(owner: ownerA)])
        let (bare, bareSent) = make(reachable: false)
        bare.phoneReachable = true
        await drain()
        XCTAssertNil(bare.companionOwner)
        XCTAssertTrue(bareSent.requests.isEmpty)
    }

    func testMissingChatsContextClearsTheListAndANoMeshPhoneEmptiesTheWatch() throws {
        let (model, _) = make()
        model.receivePhoneContext(phone: try phone(ownerA, .ready), chats: try chatList(ownerA, ["c1"]))
        XCTAssertEqual(model.chats.count, 1)
        model.receivePhoneContext(phone: try phone(ownerA, .ready), chats: nil)
        XCTAssertTrue(model.chats.isEmpty)
        model.receivePhoneContext(phone: try phone(ownerA, .ready), chats: try chatList(ownerA, ["c1"]))
        model.openChat(model.chats[0])
        model.receivePhoneContext(phone: try phone(ownerA, .noMesh), chats: nil)
        XCTAssertEqual(model.link, .noMesh)
        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertNil(model.activeChatId)
        model.receivePhoneContext(phone: try phone(ownerA, .stopped), chats: nil)
        XCTAssertEqual(model.link, .stopped)
    }

    func testPacketsFromAnotherOwnerAreDroppedAndAPhoneOwnerChangeClearsEverything() throws {
        let (model, _) = make()
        model.receiveRelay(try phone(ownerA, .ready))
        model.receiveRelay(try chatList(ownerA, ["c1"]))
        model.receiveRelay(try chatList(ownerB, ["x1", "x2"]))
        XCTAssertEqual(model.chats.map(\.chatId), ["c1"])
        model.openChat(model.chats[0])
        model.receiveRelay(
            try CompanionPhoneUpdate.chat(owner: ownerB, chatId: "c1", title: "t", view: "Astral: hi").encoded())
        XCTAssertTrue(model.chatComponents.isEmpty)
        model.receiveRelay(try phone(ownerB, .ready))
        XCTAssertEqual(model.companionOwner, ownerB)
        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertNil(model.activeChatId)
    }

    func testMalformedAndWrongDirectionPacketsChangeNothing() throws {
        let (model, _) = make()
        model.receiveRelay(try phone(ownerA, .ready))
        model.receiveRelay(Data("not json".utf8))
        model.receiveRelay(try CompanionWatchRequest.listChats(owner: ownerA).encoded())
        model.receiveRelay(Data(#"{"kind":"consent_grant","owner":"\#(Self.meshA)"}"#.utf8))
        XCTAssertEqual(model.link, .ready)
        XCTAssertEqual(model.companionOwner, ownerA)
        XCTAssertTrue(model.chats.isEmpty)
    }

    func testOpeningAChatRequestsItAndRendersOnlyThatChatsSnapshotAndRun() async throws {
        let (model, sent) = make()
        model.receiveRelay(try phone(ownerA, .ready))
        model.receiveRelay(try chatList(ownerA, ["c1", "c2"]))
        await drain()
        model.openChat(model.chats[0])
        await drain()
        XCTAssertEqual(sent.requests.last, .openChat(owner: ownerA, chatId: "c1"))
        let view = "You: hello\nAstral: hi there\nOpen on your iPhone to see this."
        model.receiveRelay(
            try CompanionPhoneUpdate.chat(owner: ownerA, chatId: "c2", title: "o", view: "Astral: other").encoded())
        XCTAssertTrue(model.chatComponents.isEmpty)
        model.receiveRelay(
            try CompanionPhoneUpdate.chat(owner: ownerA, chatId: "c1", title: "Chat c1", view: view).encoded())
        XCTAssertEqual(
            model.chatComponents.map(\.fallbackText),
            ["You: hello", "Astral: hi there", "Open on your iPhone to see this."])
        XCTAssertEqual(model.chatComponents.last?.variant, "caption")
        model.receiveRelay(try CompanionPhoneUpdate.run(owner: ownerA, chatId: "c2", state: .running).encoded())
        XCTAssertFalse(model.runActive)
        model.receiveRelay(try CompanionPhoneUpdate.run(owner: ownerA, chatId: "c1", state: .running).encoded())
        XCTAssertTrue(model.runActive)
        model.stopRun()
        await drain()
        XCTAssertEqual(sent.requests.last, .stopRun(owner: ownerA, chatId: "c1"))
        model.receiveRelay(try CompanionPhoneUpdate.run(owner: ownerA, chatId: "c1", state: .failed).encoded())
        XCTAssertNotNil(model.errorBanner)
    }

    func testSendingSanitizesDictationClearsTheDraftOnDeliveryAndKeepsItOnFailure() async throws {
        let (model, sent) = make()
        model.receiveRelay(try phone(ownerA, .ready))
        model.receiveRelay(try chatList(ownerA, ["c1"]))
        model.openChat(model.chats[0])
        model.pendingDictation = "  hello\nthere\t world \u{200E}"
        model.sendPending()
        await drain()
        XCTAssertEqual(sent.requests.last, .sendMessage(owner: ownerA, chatId: "c1", text: "hello there world"))
        XCTAssertEqual(model.pendingDictation, "")
        XCTAssertEqual(model.statusText, "Sent to your iPhone")

        let (failing, failedSent) = make(deliver: false)
        failing.receiveRelay(try phone(ownerA, .ready))
        failing.receiveRelay(try chatList(ownerA, ["c1"]))
        failing.openChat(failing.chats[0])
        failing.pendingDictation = "keep me"
        failing.sendPending()
        await drain()
        XCTAssertEqual(failedSent.requests.last, .sendMessage(owner: ownerA, chatId: "c1", text: "keep me"))
        XCTAssertEqual(failing.pendingDictation, "keep me")
        XCTAssertNotNil(failing.errorBanner)
        XCTAssertNil(failing.statusText)
    }

    func testSendingNeedsAReadyPhoneAnOpenChatAndALengthTheRelayAccepts() async throws {
        let (model, sent) = make()
        model.pendingDictation = "hello"
        model.sendPending()
        XCTAssertNotNil(model.errorBanner)
        model.receiveRelay(try phone(ownerA, .ready))
        model.receiveRelay(try chatList(ownerA, ["c1"]))
        model.openChat(model.chats[0])
        await drain()
        let before = sent.requests.count
        model.pendingDictation = String(repeating: "a", count: CompanionRelay.maximumMessageCharacters + 1)
        model.sendPending()
        await drain()
        XCTAssertEqual(sent.requests.count, before)
        XCTAssertEqual(model.errorBanner, "That message is too long for your watch.")
        model.pendingDictation = "   "
        model.sendPending()
        await drain()
        XCTAssertEqual(sent.requests.count, before)
    }

    func testRelayPacketsAreClassifiedApartFromVoicePackets() throws {
        let relay = try phone(ownerA, .ready)
        guard case .relay(let data) = WatchInbound.classify(relay) else { return XCTFail("phone packet is relay data") }
        XCTAssertEqual(data, relay)
        guard case .relay = WatchInbound.classify(Data("garbage".utf8)) else { return XCTFail("garbage is relay data") }
        let voice = try CompanionVoicePacket(kind: .ack, session: UUID(), sequence: 1, microseconds: 0)
        guard case .voice(let packet) = WatchInbound.classify(voice.encoded) else { return XCTFail("voice packet") }
        XCTAssertEqual(packet.sequence, 1)
    }

    func testRelaySnapshotsRenderThroughWatchComponentView() throws {
        let (model, _) = make()
        let text = "You: caf\u{E9} \u{65E5}\u{672C}\u{8A9E} \u{1F600}"
        let components = WatchModel.components(for: "\(text)\nAstral: hello")
        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(components[0].fallbackText, text)
        let host = VStack {
            ForEach(Array(components.enumerated()), id: \.offset) { _, c in WatchComponentView(component: c) }
        }
        .environment(model)
        let renderer = ImageRenderer(content: host)
        XCTAssertNotNil(renderer.cgImage)
        let view = Mirror(reflecting: WatchComponentView(component: components[0])).children
        XCTAssertTrue(view.contains { ($0.value as? AstralComponent)?.textContent == text })
    }

    func testALaterFailedRunIsVisibleAfterTheSendWasAcknowledged() async throws {
        let (model, _) = make()
        model.receiveRelay(try phone(ownerA, .ready))
        model.receiveRelay(try chatList(ownerA, ["c1"]))
        model.openChat(model.chats[0])
        model.pendingDictation = "do it"
        model.sendPending()
        await drain()
        XCTAssertEqual(model.statusText, "Sent to your iPhone")
        model.receiveRelay(try CompanionPhoneUpdate.run(owner: ownerA, chatId: "c1", state: .failed).encoded())
        XCTAssertEqual(model.runState, .failed)
        XCTAssertEqual(model.errorBanner, "Your iPhone couldn't run that. Try again.")
    }

    func testRelayMessageDataAlwaysGetsAnEmptyReplyAndReachesTheModel() async throws {
        let sync = WatchOverrideSync()
        var relayed: [Data] = []
        sync.onRelay = { relayed.append($0) }
        let packets = [
            try phone(ownerA, .ready), Data("garbage".utf8),
            try CompanionWatchRequest.listChats(owner: ownerB).encoded(),
        ]
        var replies: [Data] = []
        for packet in packets { sync.handleMessageData(packet) { replies.append($0) } }
        await drain()
        XCTAssertEqual(replies, [Data(), Data(), Data()])
        XCTAssertEqual(relayed, packets)
    }

    func testWatchSourcesHaveNoNetworkOrCredentialStore() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AstralWatch")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 8)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in Self.forbidden {
                XCTAssertFalse(text.contains(pattern), "\(file.lastPathComponent) names \(pattern)")
            }
        }
    }

    static let forbidden = [
        "URLSession", "WSClient", "DeviceLoginClient", "RestClient", "NoStoreHTTP", "NWConnection",
        "TokenStorage", "TokenSet", "KeychainTokenStore", "InMemoryTokenStore",
        "SecItem", "kSec", "import Security", "Keychain", "com.personalailabs.astraldeep.watch",
        "WatchVoiceREST", "DeviceLoginView",
    ]
}

@MainActor
private final class Sent {
    var requests: [CompanionWatchRequest] = []
}
