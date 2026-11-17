// Verifies the companion relay packets: strict key sets, size bounds, owner form and refusal of authority kinds.
// Both directions are checked so the watch can never push a consent, pairing or ticket through the phone.

import Foundation
import XCTest

@testable import AstralCore

final class CompanionRelayTests: XCTestCase {
    private let owner = CompanionVoiceOwner(meshId: "sha256:" + String(repeating: "0f", count: 32))!

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testPhoneUpdatesRoundTripAndStayWithinTheMessageLimit() throws {
        let rows = (0..<CompanionRelay.maximumChats).map {
            CompanionChatSummary(chatId: "chat-\($0)", title: String(repeating: "t", count: 200))
        }
        let updates: [CompanionPhoneUpdate] = [
            .chats(owner: owner, chats: rows),
            .chat(owner: owner, chatId: "c1", title: "Title", view: String(repeating: "v", count: CompanionRelay.maximumViewBytes)),
            .run(owner: owner, chatId: "c1", state: .running), .phone(owner: owner, state: .noMesh),
        ]
        for update in updates {
            let data = try update.encoded()
            XCTAssertLessThanOrEqual(data.count, CompanionRelay.maximumBytes)
            XCTAssertEqual(try CompanionPhoneUpdate(data: data), update)
        }
    }

    func testWatchRequestsRoundTrip() throws {
        let requests: [CompanionWatchRequest] = [
            .listChats(owner: owner), .openChat(owner: owner, chatId: "c1"),
            .sendMessage(owner: owner, chatId: "c1", text: "Hello"), .stopRun(owner: owner, chatId: "c1"),
        ]
        for request in requests {
            XCTAssertEqual(try CompanionWatchRequest(data: request.encoded()), request)
            XCTAssertEqual(request.owner, owner)
        }
    }

    func testUnknownKeysAreRefusedInEveryPacket() throws {
        let samples: [(Data, (Data) throws -> Void)] = [
            (try CompanionPhoneUpdate.chats(owner: owner, chats: [.init(chatId: "a", title: "b")]).encoded(), { _ = try CompanionPhoneUpdate(data: $0) }),
            (try CompanionPhoneUpdate.chat(owner: owner, chatId: "a", title: "b", view: "{}").encoded(), { _ = try CompanionPhoneUpdate(data: $0) }),
            (try CompanionPhoneUpdate.run(owner: owner, chatId: "a", state: .idle).encoded(), { _ = try CompanionPhoneUpdate(data: $0) }),
            (try CompanionPhoneUpdate.phone(owner: owner, state: .ready).encoded(), { _ = try CompanionPhoneUpdate(data: $0) }),
            (try CompanionWatchRequest.listChats(owner: owner).encoded(), { _ = try CompanionWatchRequest(data: $0) }),
            (try CompanionWatchRequest.openChat(owner: owner, chatId: "a").encoded(), { _ = try CompanionWatchRequest(data: $0) }),
            (try CompanionWatchRequest.sendMessage(owner: owner, chatId: "a", text: "b").encoded(), { _ = try CompanionWatchRequest(data: $0) }),
            (try CompanionWatchRequest.stopRun(owner: owner, chatId: "a").encoded(), { _ = try CompanionWatchRequest(data: $0) }),
        ]
        for (data, decode) in samples {
            try decode(data)
            var extra = try object(data)
            extra["token"] = "x"
            XCTAssertThrowsError(try decode(json(extra)))
            var missing = try object(data)
            missing["owner"] = nil
            XCTAssertThrowsError(try decode(json(missing)))
        }
        var nested = try object(CompanionPhoneUpdate.chats(owner: owner, chats: [.init(chatId: "a", title: "b")]).encoded())
        nested["chats"] = [["chat_id": "a", "title": "b", "approved": true]]
        XCTAssertThrowsError(try CompanionPhoneUpdate(data: json(nested)))
    }

    func testAuthorityKindsAreRefusedInBothDirections() throws {
        for kind in ["consent", "consent_decision", "approve", "pairing", "pair_device", "ticket", "mint_ticket", "Grant", "delegate"] {
            let data = try json(["kind": kind, "owner": owner.meshId])
            XCTAssertThrowsError(try CompanionWatchRequest(data: data)) {
                XCTAssertEqual($0 as? CompanionRelayError, .authorityRefused, kind)
            }
            XCTAssertThrowsError(try CompanionPhoneUpdate(data: data)) {
                XCTAssertEqual($0 as? CompanionRelayError, .authorityRefused, kind)
            }
        }
    }

    func testDirectionAndUnknownKindsAreRefused() throws {
        XCTAssertThrowsError(try CompanionWatchRequest(data: CompanionPhoneUpdate.phone(owner: owner, state: .ready).encoded())) {
            XCTAssertEqual($0 as? CompanionRelayError, .unknownKind)
        }
        XCTAssertThrowsError(try CompanionPhoneUpdate(data: CompanionWatchRequest.listChats(owner: owner).encoded())) {
            XCTAssertEqual($0 as? CompanionRelayError, .unknownKind)
        }
        XCTAssertThrowsError(try CompanionWatchRequest(data: json(["kind": "run_tool", "owner": owner.meshId])))
    }

    func testOwnerThatIsNotTheMeshIdIsRefused() throws {
        var request = try object(CompanionWatchRequest.listChats(owner: owner).encoded())
        for bad in ["owner-1", "sha256:abc", "sha256:" + String(repeating: "Z", count: 64), ""] {
            request["owner"] = bad
            XCTAssertThrowsError(try CompanionWatchRequest(data: json(request)), bad)
        }
        request["owner"] = ["issuer": "i", "subject": "s"]
        XCTAssertThrowsError(try CompanionWatchRequest(data: json(request)))
    }

    func testOversizedAndMalformedPacketsAreRefused() throws {
        XCTAssertThrowsError(try CompanionWatchRequest(data: Data("not json".utf8)))
        XCTAssertThrowsError(try CompanionWatchRequest(data: Data("[]".utf8)))
        XCTAssertThrowsError(try CompanionWatchRequest(data: Data(repeating: 32, count: CompanionRelay.maximumBytes + 1)))
        XCTAssertThrowsError(
            try CompanionWatchRequest.sendMessage(
                owner: owner, chatId: "c", text: String(repeating: "x", count: CompanionRelay.maximumMessageCharacters + 1)
            ).encoded())
        XCTAssertThrowsError(try CompanionWatchRequest.sendMessage(owner: owner, chatId: "c", text: "").encoded())
        XCTAssertThrowsError(try CompanionWatchRequest.openChat(owner: owner, chatId: "bad\u{0}").encoded())
        XCTAssertThrowsError(
            try CompanionPhoneUpdate.chat(
                owner: owner, chatId: "c", title: "t", view: String(repeating: "v", count: CompanionRelay.maximumViewBytes + 1)
            ).encoded())
        XCTAssertThrowsError(
            try CompanionPhoneUpdate.chats(
                owner: owner, chats: Array(repeating: .init(chatId: "a", title: "b"), count: CompanionRelay.maximumChats + 1)
            ).encoded())
        var tooMany = try object(CompanionPhoneUpdate.chats(owner: owner, chats: []).encoded())
        tooMany["chats"] = Array(repeating: ["chat_id": "a", "title": "b"], count: CompanionRelay.maximumChats + 1)
        XCTAssertThrowsError(try CompanionPhoneUpdate(data: json(tooMany)))
    }

    func testRunAndPhoneStatesMustBeKnown() throws {
        var run = try object(CompanionPhoneUpdate.run(owner: owner, chatId: "a", state: .idle).encoded())
        run["state"] = "approved"
        XCTAssertThrowsError(try CompanionPhoneUpdate(data: json(run)))
        var phone = try object(CompanionPhoneUpdate.phone(owner: owner, state: .ready).encoded())
        phone["state"] = 3
        XCTAssertThrowsError(try CompanionPhoneUpdate(data: json(phone)))
    }
}
