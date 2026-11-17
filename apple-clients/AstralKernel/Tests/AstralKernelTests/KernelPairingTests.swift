// Pairs two real kernels on loopback through the pairing offer, preview and approval calls and checks that chats sync both ways and that a denied presence prompt blocks the approval.
// The first kernel creates the mesh with local device approval, so no identity provider or network is involved.
import XCTest

@testable import AstralKernel

final class KernelPairingTests: XCTestCase {
    private func enrolled(_ device: TestDevice) throws -> KernelService {
        let service = try device.open()
        _ = try service.kernel.createMesh()
        try service.kernel.confirmMeshRecovery()
        return service
    }

    private func messageIds(_ service: KernelService, _ chat: String) -> [String] {
        (try? service.kernel.chat(chatId: chat).view.messages.map(\.id)) ?? []
    }

    func testPairedDevicesSyncChatsBothWays() async throws {
        let mac = try TestDevice(label: "mac", in: self, marker: 1)
        let phone = try TestDevice(label: "phone", in: self, marker: 2)
        let a = try enrolled(mac)
        _ = try await a.kernel.startNetwork()
        let chat = try a.kernel.createChat(title: "shared")
        _ = try a.kernel.sendMessage(chatId: chat, text: "from mac", continues: nil)

        let b = try phone.open()
        let offer = try await b.kernel.createPairingOffer()
        XCTAssertFalse(offer.code.isEmpty)
        let preview = try a.kernel.previewPairing(payload: offer.payload)
        XCTAssertEqual(preview.label, "phone")
        XCTAssertEqual(preview.code, offer.code)
        let approved = try await a.kernel.approvePairing(payload: offer.payload, historyGrant: .all)
        XCTAssertEqual(approved.label, "phone")
        XCTAssertEqual(mac.signer.seenPrompts.last?.kind, .rosterAdd)
        XCTAssertTrue(mac.signer.seenPrompts.last?.requiresBiometry ?? false)

        try await until("the phone to join") { try b.kernel.roster().members.count == 2 }
        XCTAssertEqual(try a.kernel.roster().members.count, 2)
        try await until("the phone to read the mac chat") { self.messageIds(b, chat).count == 1 }
        _ = try b.kernel.sendMessage(chatId: chat, text: "from phone", continues: nil)
        _ = try a.kernel.sendMessage(chatId: chat, text: "from mac again", continues: nil)
        try await until("both to hold three messages") {
            self.messageIds(a, chat).count == 3 && self.messageIds(b, chat).count == 3
        }
        XCTAssertEqual(messageIds(a, chat), messageIds(b, chat))
        let fromPhone = try b.kernel.createChat(title: "from phone")
        try await until("the mac to list the phone chat") {
            try a.kernel.listChats().contains { $0.chatId == fromPhone }
        }
        let peers = try await a.kernel.syncState()
        XCTAssertEqual(peers.map(\.label), ["phone"])
        await a.kernel.stopNetwork()
        await b.kernel.stopNetwork()
    }

    func testANodeJoinsThroughAnOfferWithNoWebSession() async throws {
        let mac = try TestDevice(label: "mac", in: self, marker: 3)
        let node = try TestDevice(label: "mac node", in: self, marker: 4, kind: .node)
        let owner = try enrolled(mac)
        let ownerStatus = try await owner.kernel.meshStatus()
        XCTAssertEqual(ownerStatus.state, .enrolled)
        _ = try await owner.kernel.startNetwork()

        let joining = try node.open()
        let beforeJoin = try await joining.kernel.meshStatus()
        XCTAssertNotEqual(beforeJoin.state, .enrolled)
        let offer = try await joining.kernel.createPairingOffer()
        let preview = try owner.kernel.previewPairing(payload: offer.payload)
        XCTAssertEqual(preview.label, "mac node")
        XCTAssertEqual(preview.code, offer.code)
        _ = try await owner.kernel.approvePairing(payload: offer.payload, historyGrant: .all)
        XCTAssertEqual(mac.signer.seenPrompts.last?.kind, .rosterAdd)
        XCTAssertTrue(node.signer.seenPrompts.isEmpty)

        try await until("the node to join") { try joining.kernel.roster().members.count == 2 }
        let members = try owner.kernel.roster().members
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members.first { !$0.isLocal }?.kind, "node")
        let joinedStatus = try await joining.kernel.meshStatus()
        XCTAssertEqual(joinedStatus.state, .enrolled)
        XCTAssertEqual(joinedStatus.meshId, ownerStatus.meshId)
        await owner.kernel.stopNetwork()
        await joining.kernel.stopNetwork()
    }

    func testDeniedPresenceBlocksApprovalAndLeavesTheRosterAlone() async throws {
        let mac = try TestDevice(label: "mac", in: self, marker: 3)
        let phone = try TestDevice(label: "phone", in: self, marker: 4)
        let a = try enrolled(mac)
        let b = try phone.open()
        let offer = try await b.kernel.createPairingOffer()
        mac.signer.allowPresence = false
        do {
            _ = try await a.kernel.approvePairing(payload: offer.payload, historyGrant: .all)
            XCTFail("approval should have been refused")
        } catch {}
        XCTAssertEqual(try a.kernel.roster().members.count, 1)
        XCTAssertThrowsError(try a.kernel.previewPairing(payload: "not a payload"))
        await a.kernel.stopNetwork()
        await b.kernel.stopNetwork()
    }
}
